require "xml"

require "./client"

module AWS
  module S3
    struct Bucket
      getter name, creation_date

      def self.new(xml : XML::Node)
        if (name = xml.xpath_node("./xmlns:Name")) && (creation_date = xml.xpath_node("./xmlns:CreationDate"))
          new(
            name: name.text,
            creation_date: Time::Format::ISO_8601_DATE_TIME.parse(creation_date.text),
          )
        else
          raise XMLIsNotABucket.new("The following XML does not represent an AWS S3 bucket: #{xml}")
        end
      end

      def initialize(@name : String, @creation_date : Time)
      end
    end

    class Client < AWS::Client
      SERVICE_NAME = "s3"

      def list_buckets
        response = get("/")
        raise_error response unless response.success?

        xml = response.body
        doc = XML.parse xml

        if buckets = doc.xpath_node("//xmlns:Buckets")
          buckets.xpath_nodes("./xmlns:Bucket").map { |b| Bucket.new b }
        else
          raise UnexpectedResponse.new("The following XML was unexpected from the ListBuckets request: #{xml}")
        end
      end

      def list_objects(bucket : Bucket, continuation_token : String? = nil)
        list_objects bucket.name, continuation_token: continuation_token
      end

      def list_objects(bucket_name : String, continuation_token : String? = nil)
        params = URI::Params{
          "list-type" => "2",
        }
        params["continuation-token"] = continuation_token if continuation_token

        response = get("/?#{params}", headers: bucket_headers(bucket_name))
        if response.success?
          ListBucketResult.from_xml response.body
        else
          raise_error response
        end
      end

      def get_object(bucket : Bucket, key : String)
        get_object bucket.name, key
      end

      def get_object(bucket_name : String, key : String) : String
        response = get(object_path(key), headers: bucket_headers(bucket_name))
        raise_error response, bucket_name: bucket_name, key: key unless response.success?

        response.body
      end

      def get_object(bucket_name : String, key : String, io : IO) : Nil
        get object_path(key), headers: bucket_headers(bucket_name) do |response|
          unless response.success?
            raise_error response, response.body_io.gets_to_end, bucket_name: bucket_name, key: key
          end

          IO.copy response.body_io, io
        end
      end

      def head_object(bucket : Bucket, key : String)
        head_object bucket.name, key
      end

      def head_object(bucket_name : String, key : String)
        response = head(object_path(key), headers: bucket_headers(bucket_name))
        # HEAD responses carry no body, so we only have the status to go on.
        raise_error response, bucket_name: bucket_name, key: key unless response.success?

        response
      end

      # Returns a URL that lets anyone holding it perform `method` on the
      # object until `ttl` elapses. Any `headers` given are part of the
      # signature, so the client using the URL must send them exactly.
      def presigned_url(method : String, bucket_name : String, key : String, ttl = 10.minutes, headers = HTTP::Headers.new)
        uri = URI.parse("#{endpoint.scheme}://#{bucket_host(bucket_name)}#{object_path(key)}")
        @signer.presign(method, uri, headers: headers, expires_in: ttl)
      end

      def put_object(bucket_name : String, key : String, headers my_headers : HTTP::Headers, body : IO)
        headers = bucket_headers(bucket_name)
        headers.merge! my_headers

        response = put(
          object_path(key),
          headers: headers,
          body: body
        )

        raise_error response, bucket_name: bucket_name, key: key unless response.success?

        response
      end

      def put_object(bucket_name : String, key : String, headers : HTTP::Headers, body : String)
        put_object bucket_name,
          key: key,
          headers: HTTP::Headers{"Content-Length" => body.bytesize.to_s}
            .tap(&.merge!(headers)),
          body: IO::Memory.new(body)
      end

      def delete_object(bucket_name : String, key : String)
        response = delete(object_path(key), headers: bucket_headers(bucket_name))
        raise_error response, bucket_name: bucket_name, key: key unless response.success?

        response
      end

      # S3 requires every part of a multipart upload except the last to be at
      # least this large.
      MINIMUM_PART_SIZE = 5 * 1024 * 1024
      # Part numbers must be in `1..MAXIMUM_PART_COUNT`.
      MAXIMUM_PART_COUNT = 10_000

      # Uploads `body` as a multipart upload, reading it `part_size` bytes at a
      # time and never holding more than one part in memory. This is the
      # simplest way to upload something large or something that can't be
      # rewound, such as a socket or a pipe.
      #
      # `headers` are applied to the object the same way they are for
      # `put_object`. If anything goes wrong after the upload has been created,
      # it is aborted so S3 does not keep billing for the orphaned parts, and
      # the original error is re-raised.
      def multipart_upload(
        bucket_name : String,
        key : String,
        body : IO,
        headers : HTTP::Headers = HTTP::Headers.new,
        part_size : Int = MINIMUM_PART_SIZE,
      ) : CompleteMultipartUploadResult
        if part_size < MINIMUM_PART_SIZE
          raise ArgumentError.new("part_size must be at least #{MINIMUM_PART_SIZE} bytes, got #{part_size}")
        end

        upload = create_multipart_upload(bucket_name, key, headers)
        parts = [] of MultipartUpload::Part
        buffer = IO::Memory.new(part_size)

        begin
          MultipartUpload::PART_NUMBERS.each do |part_number|
            buffer.clear
            IO.copy body, buffer, limit: part_size
            buffer.rewind
            # S3 rejects empty parts, so only send one if it is the sole part
            # (an empty object). Otherwise the previous part was the last.
            break if buffer.size == 0 && !parts.empty?

            parts << upload_part(upload, part_number, buffer)
            break if buffer.size < part_size
          end

          if body.read_byte
            raise ArgumentError.new("#{key} is too large to upload in #{MAXIMUM_PART_COUNT} parts of #{part_size} bytes each. Increase part_size.")
          end

          complete_multipart_upload upload, parts
        rescue ex
          abort_multipart_upload upload rescue nil
          raise ex
        end
      end

      # Starts a multipart upload. Every part is then sent with `upload_part`
      # and the object is assembled with `complete_multipart_upload`. Object
      # metadata such as `Content-Type` is set here, not on the parts.
      def create_multipart_upload(bucket_name : String, key : String, headers my_headers : HTTP::Headers = HTTP::Headers.new) : MultipartUpload
        headers = bucket_headers(bucket_name)
        headers.merge! my_headers

        response = post("#{object_path(key)}?uploads", body: "", headers: headers)
        raise_error response, bucket_name: bucket_name, key: key unless response.success?

        MultipartUpload.from_xml response.body
      end

      def upload_part(upload : MultipartUpload, part_number : Int, body : IO, headers : HTTP::Headers = HTTP::Headers.new) : MultipartUpload::Part
        upload_part upload.bucket, upload.key, upload.id, part_number, body, headers
      end

      def upload_part(upload : MultipartUpload, part_number : Int, body : String | Bytes, headers : HTTP::Headers = HTTP::Headers.new) : MultipartUpload::Part
        upload_part upload.bucket, upload.key, upload.id, part_number, body, headers
      end

      def upload_part(bucket_name : String, key : String, upload_id : String, part_number : Int, body : String | Bytes, headers : HTTP::Headers = HTTP::Headers.new) : MultipartUpload::Part
        body = body.to_slice
        upload_part bucket_name, key, upload_id, part_number,
          body: IO::Memory.new(body),
          headers: HTTP::Headers{"Content-Length" => body.size.to_s}.tap(&.merge!(headers))
      end

      # Uploads one part of a multipart upload. Parts are numbered from 1 and
      # can be uploaded in any order, concurrently, or more than once (the last
      # upload of a given number wins).
      #
      # The `body` must be rewindable so it can be hashed for the signature. If
      # it is not an `IO::Memory`, you must set `Content-Length` in `headers`
      # yourself, since S3 does not accept chunked uploads.
      def upload_part(bucket_name : String, key : String, upload_id : String, part_number : Int, body : IO, headers my_headers : HTTP::Headers = HTTP::Headers.new) : MultipartUpload::Part
        unless MultipartUpload::PART_NUMBERS.includes? part_number
          raise ArgumentError.new("part_number must be in #{MultipartUpload::PART_NUMBERS}, got #{part_number}")
        end

        headers = bucket_headers(bucket_name)
        if body.is_a? IO::Memory
          headers["Content-Length"] = (body.size - body.pos).to_s
        end
        headers.merge! my_headers

        params = URI::Params{
          "partNumber" => part_number.to_s,
          "uploadId"   => upload_id,
        }
        response = put("#{object_path(key)}?#{params}", headers: headers, body: body)
        raise_error response, bucket_name: bucket_name, key: key unless response.success?

        etag = response.headers["ETag"]? || raise UnexpectedResponse.new("S3 did not return an ETag for part #{part_number} of #{bucket_name}/#{key}")
        MultipartUpload::Part.new(part_number, etag.gsub('"', ""))
      end

      def complete_multipart_upload(upload : MultipartUpload, parts : Enumerable(MultipartUpload::Part)) : CompleteMultipartUploadResult
        complete_multipart_upload upload.bucket, upload.key, upload.id, parts
      end

      # Assembles the uploaded `parts` into the final object. Parts are
      # assembled in ascending part number order regardless of the order given
      # here, and any uploaded parts left out of `parts` are discarded.
      def complete_multipart_upload(bucket_name : String, key : String, upload_id : String, parts : Enumerable(MultipartUpload::Part)) : CompleteMultipartUploadResult
        body = MultipartUpload.completion_xml(parts)
        headers = bucket_headers(bucket_name)
        headers["Content-Type"] = "application/xml"

        params = URI::Params{"uploadId" => upload_id}
        response = post("#{object_path(key)}?#{params}", body: body, headers: headers)
        raise_error response, bucket_name: bucket_name, key: key unless response.success?

        # S3 starts sending a 200 before it has finished assembling the object
        # so the connection doesn't time out, which means an error can arrive
        # in the body of a successful response.
        if response.body.includes?("<Error>") && XML.parse(response.body).xpath_node("/Error")
          raise_error response, bucket_name: bucket_name, key: key
        end

        CompleteMultipartUploadResult.from_xml response.body
      end

      def abort_multipart_upload(upload : MultipartUpload)
        abort_multipart_upload upload.bucket, upload.key, upload.id
      end

      # Cancels the upload and frees the storage used by its parts. Parts still
      # being uploaded when this is called may survive, so it is worth calling
      # again if any uploads were in flight.
      def abort_multipart_upload(bucket_name : String, key : String, upload_id : String)
        params = URI::Params{"uploadId" => upload_id}
        response = delete("#{object_path(key)}?#{params}", headers: bucket_headers(bucket_name))
        raise_error response, bucket_name: bucket_name, key: key unless response.success?

        response
      end

      def list_parts(upload : MultipartUpload, part_number_marker : Int? = nil, max_parts : Int? = nil) : ListPartsResult
        list_parts upload.bucket, upload.key, upload.id, part_number_marker: part_number_marker, max_parts: max_parts
      end

      # Lists the parts uploaded so far, which is how a client that lost track
      # of an upload in progress can resume it. Results are paginated: when
      # `truncated?` is set, pass `next_part_number_marker` back in as
      # `part_number_marker` to get the next page.
      def list_parts(bucket_name : String, key : String, upload_id : String, part_number_marker : Int? = nil, max_parts : Int? = nil) : ListPartsResult
        params = URI::Params{"uploadId" => upload_id}
        params["part-number-marker"] = part_number_marker.to_s if part_number_marker
        params["max-parts"] = max_parts.to_s if max_parts

        response = get("#{object_path(key)}?#{params}", headers: bucket_headers(bucket_name))
        raise_error response, bucket_name: bucket_name, key: key unless response.success?

        ListPartsResult.from_xml response.body
      end

      # The virtual-hosted-style host for a bucket, including the port when the
      # endpoint specifies a nonstandard one. This must match what goes on the
      # wire because the Host header is part of the signature.
      private def bucket_host(bucket_name : String) : String
        if port = endpoint.port
          "#{bucket_name}.#{endpoint.host}:#{port}"
        else
          "#{bucket_name}.#{endpoint.host}"
        end
      end

      private def bucket_headers(bucket_name : String) : HTTP::Headers
        HTTP::Headers{"Host" => bucket_host(bucket_name)}
      end

      # Percent-encodes an object key for use as a request path. This uses the
      # same rules as the SigV4 canonical URI, so the request path and the
      # signed path are identical and `AWS::Client` can sign it verbatim.
      private def object_path(key : String) : String
        "/#{URI.encode_path(key)}"
      end

      private def raise_error(response : HTTP::Client::Response, body : String = response.body, *, bucket_name : String? = nil, key : String? = nil) : NoReturn
        raise Exception.from_response(response.status, body, bucket_name: bucket_name, key: key)
      end
    end

    struct ListBucketResult
      getter name : String
      getter prefix : String
      getter key_count : Int64?
      getter max_keys : Int64?
      getter contents : Array(Contents)
      getter? truncated : Bool
      getter next_continuation_token : String?

      def self.from_xml(xml : String)
        from_xml XML.parse(xml).root.not_nil!
      end

      def self.from_xml(xml : XML::Node)
        name = xml.xpath_node("./xmlns:Name")
        prefix = xml.xpath_node("./xmlns:Prefix")
        max_keys = xml.xpath_node("./xmlns:MaxKeys")
        key_count = xml.xpath_node("./xmlns:KeyCount")
        truncated = xml.xpath_node("./xmlns:IsTruncated")
        next_continuation_token = xml.xpath_node("./xmlns:NextContinuationToken")

        if name && prefix && max_keys && truncated
          contents = xml.xpath_nodes("./xmlns:Contents")
          new(
            name: name.text,
            prefix: prefix.text,
            max_keys: max_keys.text.to_i64,
            key_count: key_count.try(&.text.to_i64),
            truncated: truncated.text == "true",
            contents: contents.map { |c| Contents.from_xml c },
            next_continuation_token: next_continuation_token.try(&.text),
          )
        else
          raise InvalidXML.new("The following XML does not represent a ListBucketResult: #{xml}")
        end
      end

      def initialize(
        @name,
        @prefix,
        @key_count,
        @max_keys,
        @truncated,
        @contents,
        @next_continuation_token,
      )
      end

      struct Contents
        getter key, last_modified, etag, size, storage_class

        def self.from_xml(xml : String)
          from_xml XML.parse xml
        end

        def self.from_xml(xml : XML::Node)
          key = xml.xpath_node("./xmlns:Key")
          last_modified = xml.xpath_node("./xmlns:LastModified")
          size = xml.xpath_node("./xmlns:Size")

          if key && last_modified && size
            new(
              key: key.text,
              last_modified: Time::Format::ISO_8601_DATE_TIME.parse(last_modified.text),
              etag: (xml.xpath_node("./xmlns:ETag").try(&.text) || "").gsub('"', ""),
              size: size.text.to_i64,
              storage_class: xml.xpath_node("./xmlns:StorageClass").try(&.text) || "",
            )
          else
            raise InvalidXML.new("The following XML is not a ListBucketResult::Contents: #{xml}")
          end
        end

        def initialize(
          @key : String,
          @last_modified : Time,
          @etag : String,
          @size : Int64,
          @storage_class : String,
        )
        end
      end
    end

    # An in-progress multipart upload, as returned by
    # `Client#create_multipart_upload`.
    struct MultipartUpload
      PART_NUMBERS = 1..Client::MAXIMUM_PART_COUNT

      getter bucket : String
      getter key : String
      getter id : String

      def self.from_xml(xml : String)
        from_xml XML.parse(xml).root.not_nil!
      end

      def self.from_xml(xml : XML::Node)
        bucket = xml.xpath_node("./xmlns:Bucket")
        key = xml.xpath_node("./xmlns:Key")
        id = xml.xpath_node("./xmlns:UploadId")

        if bucket && key && id
          new(bucket: bucket.text, key: key.text, id: id.text)
        else
          raise InvalidXML.new("The following XML does not represent an InitiateMultipartUploadResult: #{xml}")
        end
      end

      # The request body for CompleteMultipartUpload, listing `parts` in
      # ascending part number order as S3 requires.
      def self.completion_xml(parts : Enumerable(Part)) : String
        XML.build(encoding: "UTF-8") do |xml|
          xml.element("CompleteMultipartUpload", xmlns: "http://s3.amazonaws.com/doc/2006-03-01/") do
            parts.to_a.sort_by(&.part_number).each do |part|
              xml.element("Part") do
                xml.element("ETag") { xml.text %("#{part.etag}") }
                xml.element("PartNumber") { xml.text part.part_number.to_s }
              end
            end
          end
        end
      end

      def initialize(@bucket, @key, @id)
      end

      # The identity of a part that has been uploaded, as needed to complete
      # the upload.
      struct Part
        getter part_number : Int32
        getter etag : String

        def self.from_xml(xml : XML::Node)
          part_number = xml.xpath_node("./xmlns:PartNumber")
          etag = xml.xpath_node("./xmlns:ETag")

          if part_number && etag
            new(
              part_number: part_number.text.to_i,
              etag: etag.text.gsub('"', ""),
              size: xml.xpath_node("./xmlns:Size").try(&.text.to_i64),
              last_modified: xml.xpath_node("./xmlns:LastModified").try { |node| Time::Format::ISO_8601_DATE_TIME.parse(node.text) },
            )
          else
            raise InvalidXML.new("The following XML does not represent a multipart upload Part: #{xml}")
          end
        end

        # Only populated for parts returned by `Client#list_parts`.
        getter size : Int64?
        getter last_modified : Time?

        def initialize(@part_number, @etag, @size = nil, @last_modified = nil)
        end
      end
    end

    struct CompleteMultipartUploadResult
      getter location : String
      getter bucket : String
      getter key : String
      # The ETag of a multipart object is not an MD5 of its contents. It is the
      # MD5 of the concatenated part MD5s followed by `-` and the part count.
      getter etag : String

      def self.from_xml(xml : String)
        from_xml XML.parse(xml).root.not_nil!
      end

      def self.from_xml(xml : XML::Node)
        location = xml.xpath_node("./xmlns:Location")
        bucket = xml.xpath_node("./xmlns:Bucket")
        key = xml.xpath_node("./xmlns:Key")
        etag = xml.xpath_node("./xmlns:ETag")

        if location && bucket && key && etag
          new(
            location: location.text,
            bucket: bucket.text,
            key: key.text,
            etag: etag.text.gsub('"', ""),
          )
        else
          raise InvalidXML.new("The following XML does not represent a CompleteMultipartUploadResult: #{xml}")
        end
      end

      def initialize(@location, @bucket, @key, @etag)
      end
    end

    struct ListPartsResult
      getter bucket : String
      getter key : String
      getter upload_id : String
      getter parts : Array(MultipartUpload::Part)
      getter part_number_marker : Int32?
      getter next_part_number_marker : Int32?
      getter max_parts : Int32?
      getter? truncated : Bool

      def self.from_xml(xml : String)
        from_xml XML.parse(xml).root.not_nil!
      end

      def self.from_xml(xml : XML::Node)
        bucket = xml.xpath_node("./xmlns:Bucket")
        key = xml.xpath_node("./xmlns:Key")
        upload_id = xml.xpath_node("./xmlns:UploadId")

        if bucket && key && upload_id
          new(
            bucket: bucket.text,
            key: key.text,
            upload_id: upload_id.text,
            parts: xml.xpath_nodes("./xmlns:Part").map { |part| MultipartUpload::Part.from_xml part },
            part_number_marker: xml.xpath_node("./xmlns:PartNumberMarker").try(&.text.to_i?),
            next_part_number_marker: xml.xpath_node("./xmlns:NextPartNumberMarker").try(&.text.to_i?),
            max_parts: xml.xpath_node("./xmlns:MaxParts").try(&.text.to_i?),
            truncated: xml.xpath_node("./xmlns:IsTruncated").try(&.text) == "true",
          )
        else
          raise InvalidXML.new("The following XML does not represent a ListPartsResult: #{xml}")
        end
      end

      def initialize(
        @bucket,
        @key,
        @upload_id,
        @parts,
        @part_number_marker,
        @next_part_number_marker,
        @max_parts,
        @truncated,
      )
      end
    end

    class Exception < ::AWS::Exception
      getter status : HTTP::Status?
      getter code : String?
      getter request_id : String?

      # Builds the most specific exception we can from an S3 error response.
      # S3 error bodies look like:
      #
      #     <Error>
      #       <Code>NoSuchKey</Code>
      #       <Message>The specified key does not exist.</Message>
      #       <Key>foo</Key>
      #       <RequestId>...</RequestId>
      #     </Error>
      #
      # HEAD responses and some proxies return no body, so we fall back to the
      # HTTP status alone.
      def self.from_response(status : HTTP::Status, body : String, *, bucket_name : String? = nil, key : String? = nil) : self
        code = nil
        message = nil
        request_id = nil

        unless body.blank?
          if error = XML.parse(body).xpath_node("//Error")
            code = error.xpath_node("./Code").try(&.text)
            message = error.xpath_node("./Message").try(&.text)
            request_id = error.xpath_node("./RequestId").try(&.text)
          end
        end

        klass = case code
                when "NoSuchBucket"
                  UnknownBucket
                when "NoSuchKey"
                  UnknownObject
                when nil
                  if status.not_found?
                    key ? UnknownObject : UnknownBucket
                  else
                    Exception
                  end
                else
                  Exception
                end

        location = [bucket_name, key].compact.join('/')
        description = message || (body.blank? ? status.description : body)
        text = String.build do |str|
          str << "S3 returned HTTP " << status.code << ' ' << status.description
          str << " (" << code << ')' if code
          str << " for " << location unless location.empty?
          str << ": " << description if description && description != status.description
        end

        klass.new(text, status: status, code: code, request_id: request_id)
      end

      def initialize(message : String? = nil, *, @status = nil, @code = nil, @request_id = nil)
        super message
      end
    end

    class InvalidXML < Exception
    end

    class UnknownBucket < Exception
    end

    class UnknownObject < Exception
    end

    class XMLIsNotABucket < Exception
    end

    class UnexpectedResponse < Exception
    end
  end
end
