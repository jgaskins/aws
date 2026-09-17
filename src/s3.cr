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

      def presigned_url(method : String, bucket_name : String, key : String, ttl = 10.minutes, headers = HTTP::Headers.new)
        date = Time.utc.to_s("%Y%m%dT%H%M%SZ")
        algorithm = "AWS4-HMAC-SHA256"
        scope = "#{date[0...8]}/#{@region}/s3/aws4_request"
        credential = "#{@access_key_id}/#{scope}"
        headers = headers.dup # Don't mutate headers we received
        headers["Host"] = bucket_host(bucket_name)

        path = object_path(key)
        request = HTTP::Request.new(
          method: method,
          resource: path,
          headers: headers,
        )

        canonical_headers = headers
          .to_a
          .sort_by { |(key, values)| key.downcase }
        signed_headers = canonical_headers
          .map { |(key, values)| key.downcase }
          .join(';')
        params = URI::Params{
          "X-Amz-Algorithm"     => algorithm,
          "X-Amz-Credential"    => credential,
          "X-Amz-Date"          => date,
          "X-Amz-Expires"       => ttl.total_seconds.to_i.to_s,
          "X-Amz-SignedHeaders" => signed_headers,
        }

        canonical_request = String.build { |str|
          str << method << '\n'
          str << path << '\n'
          str << params
            .to_a
            .sort_by { |(key, value)| key }
            .each_with_object(URI::Params.new) { |(key, value), params| params[key] = value.gsub(/\s+/, ' ') }
          str << '\n'

          canonical_headers
            .each do |(key, values)|
              values.each do |value|
                str << key.downcase << ':' << value.strip << '\n'
              end
            end
          str << '\n'

          str << signed_headers << '\n'
          str << "UNSIGNED-PAYLOAD"
        }

        string_to_sign = <<-STRING
        #{algorithm}
        #{date}
        #{scope}
        #{(OpenSSL::Digest.new("SHA256") << canonical_request).final.hexstring}
        STRING

        date_key = OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA256, "AWS4#{@secret_access_key}", date[0...8])
        region_key = OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA256, date_key, @region)
        service_key = OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA256, region_key, "s3")
        signing_key = OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA256, service_key, "aws4_request")
        signature = OpenSSL::HMAC.hexdigest(OpenSSL::Algorithm::SHA256, signing_key, string_to_sign)
        uri = URI.parse("#{endpoint.scheme}://#{bucket_host(bucket_name)}#{request.resource}")

        params["X-Amz-Signature"] = signature

        uri.query = params.to_s
        uri
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
