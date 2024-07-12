require "xml"

require "./client"
require "./bucket_iterator"

module AWS
  module S3
    class Exception < AWS::Exception
    end

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
        xml = get("/").body
        doc = XML.parse xml

        if buckets = doc.xpath_node("//xmlns:Buckets")
          buckets.children.map { |b| Bucket.new b }
        else
          raise UnexpectedResponse.new("The following XML was unexpected from the ListBuckets request: #{xml}")
        end
      end

      def list_objects(bucket : Bucket)
        list_objects bucket.name
      end

      def list_objects(bucket_name : String, *, continuation_token : String = "", count : Int32 = 100)
        query_params = URI::Params{"list-type" => "2"}
        query_params["continuation-token"] = continuation_token unless continuation_token.blank?
        query_params["max-keys"] = count.to_s unless count.blank?

        xml = get(
          "/",
          headers: HTTP::Headers{ "Host" => "#{bucket_name}.#{endpoint.host}" },
          query: query_params
        ).body

        ListBucketResult.from_xml xml
      end

      def bucket_iterator(bucket_name : String)
        BucketIterator.new(self, bucket_name)
      end

      def get_object(bucket : Bucket, key : String)
        get_object bucket.name, key
      end

      def get_object(bucket_name : String, key : String) : String
        Log.warn { "Getting object #{key} from bucket #{bucket_name}" }

        response = get("/#{key}", headers: HTTP::Headers{
          "Host" => "#{bucket_name}.#{endpoint.host}",
        })

        unless response.success?
          raise Exception.new("S3 GetObject returned HTTP status #{response.status}: #{XML.parse(response.body).to_xml}")
        end

        response.body
      end

      def get_object(bucket_name : String, key : String, io : IO) : Nil
        headers = HTTP::Headers{
          "Host" => "#{bucket_name}.#{endpoint.host}",
        }
        get "/#{key}", headers: headers do |response|
          if response.success?
            IO.copy response.body_io, io
          else
            raise Exception.new("S3 GetObject returned HTTP status #{response.status}")
          end
        end
      end

      def head_object(bucket : Bucket, key : String)
        head_object bucket.name, key
      end

      def head_object(bucket_name : String, key : String)
        head("/#{key}", headers: HTTP::Headers{
          "Host" => "#{bucket_name}.#{endpoint.host}",
        })
      end

      def presigned_url(method : String, bucket_name : String, key : String, ttl = 10.minutes, headers = HTTP::Headers.new)
        date = Time.utc.to_s("%Y%m%dT%H%M%SZ")
        algorithm = "AWS4-HMAC-SHA256"
        scope = "#{date[0...8]}/#{@region}/s3/aws4_request"
        credential = "#{@access_key_id}/#{scope}"
        headers = headers.dup # Don't mutate headers we received
        headers["Host"] = "#{bucket_name}.#{endpoint.host}"

        unless key.starts_with? "/"
          key = "/#{key}"
        end
        request = HTTP::Request.new(
          method: method,
          resource: key,
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
          str << key << '\n'
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
        uri = URI.parse("#{endpoint.scheme}://#{bucket_name}.#{endpoint.host}#{request.resource}")

        params["X-Amz-Signature"] = signature

        uri.query = params.to_s
        uri
      end

      def put_object(bucket_name : String, key : String, headers my_headers : HTTP::Headers, body : IO)
        headers = HTTP::Headers{
          "Host" => "#{bucket_name}.#{endpoint.host}",
        }
        headers.merge! my_headers

        response = put(
          "/#{key}",
          headers: headers,
          body: body
        )

        unless response.success?
          raise Exception.new("S3 PutObject returned HTTP status #{response.status}: #{XML.parse(response.body).to_xml}")
        end

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
        delete("/#{key}", headers: HTTP::Headers{
          "Host" => "#{bucket_name}.#{endpoint.host}",
        })
      end
    end


    class Exception < ::AWS::Exception
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

