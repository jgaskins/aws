require "./spec_helper"
require "../src/signature_v4"

module AWS
  # Known-answer vectors come from the AWS S3 documentation:
  #
  # - "Examples: Signature Calculations in AWS Signature Version 4"
  # - "Authenticating Requests: Using Query Parameters"
  #
  # They use the documented example credentials, bucket, and timestamp.
  describe SignatureV4 do
    access_key_id = "AKIAIOSFODNN7EXAMPLE"
    secret_access_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
    host = "examplebucket.s3.amazonaws.com"
    at = Time.utc(2013, 5, 24, 0, 0, 0)
    signer = SignatureV4.new("s3", "us-east-1", access_key_id, secret_access_key)

    describe "#sign" do
      it "signs a GET with an extra header" do
        request = HTTP::Request.new("GET", "/test.txt", HTTP::Headers{
          "Host"  => host,
          "Range" => "bytes=0-9",
        })

        signer.sign request, now: at

        request.headers["X-Amz-Date"].should eq "20130524T000000Z"
        request.headers["X-Amz-Content-Sha256"].should eq "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        request.headers["Authorization"].should eq String.build { |str|
          str << "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, "
          str << "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, "
          str << "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
        }
      end

      it "signs a PUT with a body and a pre-encoded path" do
        request = HTTP::Request.new(
          "PUT",
          "/test%24file.text",
          HTTP::Headers{
            "Host"                => host,
            "Date"                => "Fri, 24 May 2013 00:00:00 GMT",
            "x-amz-storage-class" => "REDUCED_REDUNDANCY",
          },
          "Welcome to Amazon S3.",
        )

        signer.sign request, now: at

        request.headers["X-Amz-Content-Sha256"].should eq "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072"
        signature_of(request).should eq "98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd"
        signed_headers_of(request).should eq "date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class"
      end

      it "signs a query parameter that has no value" do
        request = HTTP::Request.new("GET", "/?lifecycle", HTTP::Headers{"Host" => host})

        signer.sign request, now: at

        signature_of(request).should eq "fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543"
      end

      it "signs multiple query parameters" do
        request = HTTP::Request.new("GET", "/?max-keys=2&prefix=J", HTTP::Headers{"Host" => host})

        signer.sign request, now: at

        signature_of(request).should eq "34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7"
      end

      it "leaves the body positioned where it found it" do
        body = IO::Memory.new("skip this|Welcome to Amazon S3.")
        body.pos = "skip this|".bytesize
        request = HTTP::Request.new("PUT", "/test%24file.text", HTTP::Headers{"Host" => host}, body)

        signer.sign request, now: at

        request.headers["X-Amz-Content-Sha256"].should eq "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072"
        body.gets_to_end.should eq "Welcome to Amazon S3."
      end

      it "signs a preset X-Amz-Content-Sha256 without reading the body" do
        request = HTTP::Request.new(
          "PUT",
          "/streamed",
          HTTP::Headers{"Host" => host, "X-Amz-Content-Sha256" => "UNSIGNED-PAYLOAD"},
          UnreadableIO.new,
        )

        signer.sign request, now: at

        request.headers["X-Amz-Content-Sha256"].should eq "UNSIGNED-PAYLOAD"
        request.headers["Authorization"].should contain "Signature="
      end

      it "does not sign headers that intermediaries rewrite" do
        request = HTTP::Request.new("GET", "/", HTTP::Headers{
          "Host"           => host,
          "Connection"     => "keep-alive",
          "User-Agent"     => "Crystal AWS",
          "Content-Length" => "0",
          "Expect"         => "100-continue",
        })

        signer.sign request, now: at

        signed_headers_of(request).should eq "host;x-amz-content-sha256;x-amz-date"
      end

      it "normalizes header values and merges duplicates" do
        request = HTTP::Request.new("GET", "/", HTTP::Headers{"Host" => host})
        request.headers.add "X-Amz-Meta-Tag", "  first   value "
        request.headers.add "X-Amz-Meta-Tag", "second"

        signer.sign request, now: at

        # Equivalent to a request that sent the canonical value directly.
        canonical = HTTP::Request.new("GET", "/", HTTP::Headers{
          "Host"           => host,
          "x-amz-meta-tag" => "first value,second",
        })
        signer.sign canonical, now: at

        request.headers["Authorization"].should eq canonical.headers["Authorization"]
      end

      it "includes the session token when configured" do
        with_token = SignatureV4.new("s3", "us-east-1", access_key_id, secret_access_key, "TOKEN")
        request = HTTP::Request.new("GET", "/", HTTP::Headers{"Host" => host})

        with_token.sign request, now: at

        request.headers["X-Amz-Security-Token"].should eq "TOKEN"
        signed_headers_of(request).should contain "x-amz-security-token"
      end
    end

    describe "#presign" do
      it "produces the documented presigned URL" do
        uri = URI.parse("https://#{host}/test.txt")

        url = signer.presign("GET", uri, expires_in: 86400.seconds, now: at)

        url.to_s.should eq String.build { |str|
          str << "https://examplebucket.s3.amazonaws.com/test.txt"
          str << "?X-Amz-Algorithm=AWS4-HMAC-SHA256"
          str << "&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request"
          str << "&X-Amz-Date=20130524T000000Z"
          str << "&X-Amz-Expires=86400"
          str << "&X-Amz-SignedHeaders=host"
          str << "&X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"
        }
      end

      it "does not modify the URI it was given" do
        uri = URI.parse("https://#{host}/test.txt")

        signer.presign("GET", uri, now: at)

        uri.query.should be_nil
      end

      it "preserves and signs existing query parameters" do
        uri = URI.parse("https://#{host}/test.txt?response-content-disposition=attachment%3B%20filename%3D%22a%20b.txt%22")

        url = signer.presign("GET", uri, now: at)

        # RFC 3986 encoding on the wire, with the signature last.
        url.query.to_s.should start_with "X-Amz-Algorithm=AWS4-HMAC-SHA256&"
        url.query.to_s.should contain "&response-content-disposition=attachment%3B%20filename%3D%22a%20b.txt%22&X-Amz-Signature="
        url.query.to_s.should_not contain "+"
      end

      it "includes a nonstandard port in the signed Host header" do
        uri = URI.parse("http://#{host}:9000/test.txt")

        url = signer.presign("GET", uri, now: at)
        explicit_host = signer.presign("GET", uri, headers: HTTP::Headers{"Host" => "#{host}:9000"}, now: at)
        wrong_host = signer.presign("GET", uri, headers: HTTP::Headers{"Host" => host}, now: at)

        url.port.should eq 9000
        url.query.to_s.should eq explicit_host.query
        url.query.to_s.should_not eq wrong_host.query
      end

      it "signs additional headers so the client must send them" do
        uri = URI.parse("https://#{host}/upload.png")

        url = signer.presign("PUT", uri, headers: HTTP::Headers{"Content-Type" => "image/png"}, now: at)

        url.query.to_s.should contain "X-Amz-SignedHeaders=content-type%3Bhost"
      end

      it "includes the session token when configured" do
        with_token = SignatureV4.new("s3", "us-east-1", access_key_id, secret_access_key, "TOKEN")

        url = with_token.presign("GET", URI.parse("https://#{host}/test.txt"), now: at)

        url.query.to_s.should contain "X-Amz-Security-Token=TOKEN"
      end
    end
  end

  private def self.signature_of(request : HTTP::Request) : String
    request.headers["Authorization"].split("Signature=").last
  end

  private def self.signed_headers_of(request : HTTP::Request) : String
    request.headers["Authorization"].split("SignedHeaders=").last.split(',').first
  end

  # An IO that fails if anything tries to read it.
  private class UnreadableIO < IO
    def read(slice : Bytes) : Int32
      raise "The request body was read even though its hash was supplied"
    end

    def write(slice : Bytes) : Nil
      raise "not writable"
    end
  end
end
