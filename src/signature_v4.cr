require "digest/sha256"
require "http"
require "openssl/hmac"
require "uri"

module AWS
  # Implements [AWS Signature Version 4](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv.html)
  # for both `Authorization`-header signing (`#sign`) and query-string
  # presigning (`#presign`).
  #
  # Request paths are signed verbatim. Callers are responsible for
  # percent-encoding paths the way the service expects them on the wire, which
  # for S3 means encoding each key segment exactly once.
  class SignatureV4
    private ALGORITHM        = "AWS4-HMAC-SHA256"
    private UNSIGNED_PAYLOAD = "UNSIGNED-PAYLOAD"
    private EMPTY_SHA256     = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    private DATE_FORMAT      = "%Y%m%d"
    private TIMESTAMP_FORMAT = "%Y%m%dT%H%M%SZ"

    # Headers that are never signed because proxies and HTTP clients commonly
    # add, remove, or rewrite them in transit. Everything else on the request
    # is signed.
    UNSIGNABLE_HEADERS = Set{
      "authorization",
      "cache-control",
      "connection",
      "content-length",
      "expect",
      "from",
      "keep-alive",
      "max-forwards",
      "pragma",
      "referer",
      "te",
      "trailer",
      "transfer-encoding",
      "upgrade",
      "user-agent",
      "x-amzn-trace-id",
    }

    getter service : String
    getter region : String

    def initialize(
      @service : String,
      @region : String,
      @access_key_id : String,
      @secret_access_key : String,
      @session_token : String? = nil,
    )
    end

    # Signs `request` in place by setting the `X-Amz-Date`,
    # `X-Amz-Content-Sha256`, and `Authorization` headers (and
    # `X-Amz-Security-Token` when a session token is configured).
    #
    # The request must already carry the `Host` header it will be sent with.
    # If `X-Amz-Content-Sha256` is already set (for example to
    # `UNSIGNED-PAYLOAD`), it is signed as given instead of hashing the body,
    # so a non-rewindable body can be streamed to services that allow it.
    def sign(request : HTTP::Request, now : Time = Time.utc) : Nil
      timestamp = now.to_utc.to_s(TIMESTAMP_FORMAT)
      scope = scope_for(now)

      request.headers["X-Amz-Date"] = timestamp
      request.headers["X-Amz-Content-Sha256"] ||= hash_payload(request.body)
      if token = @session_token
        request.headers["X-Amz-Security-Token"] = token
      end

      headers = canonical_headers(request.headers)
      canonical = canonical_request(
        method: request.method,
        path: request.path,
        query: canonical_query(request.query_params),
        headers: headers,
        payload_hash: request.headers["X-Amz-Content-Sha256"],
      )
      signature = signature(canonical, now, scope)

      request.headers["Authorization"] = String.build do |str|
        str << ALGORITHM
        str << " Credential=" << @access_key_id << '/' << scope
        str << ", SignedHeaders=" << signed_header_names(headers)
        str << ", Signature=" << signature
      end
    end

    # Returns a copy of `uri` carrying the query parameters that authorize an
    # unauthenticated client to perform `method` on it until `expires_in` has
    # elapsed. Any query parameters already on `uri` are preserved and signed.
    #
    # Every header in `headers` becomes part of the signature, so the client
    # using the URL must send them exactly as given. `Host` is derived from
    # `uri` unless supplied.
    def presign(
      method : String,
      uri : URI,
      headers : HTTP::Headers = HTTP::Headers.new,
      expires_in : Time::Span = 10.minutes,
      now : Time = Time.utc,
    ) : URI
      timestamp = now.to_utc.to_s(TIMESTAMP_FORMAT)
      scope = scope_for(now)

      headers = headers.dup
      headers["Host"] ||= host_header(uri)
      canonical_headers = canonical_headers(headers)

      params = URI::Params.parse(uri.query || "")
      params["X-Amz-Algorithm"] = ALGORITHM
      params["X-Amz-Credential"] = "#{@access_key_id}/#{scope}"
      params["X-Amz-Date"] = timestamp
      params["X-Amz-Expires"] = expires_in.total_seconds.to_i.to_s
      params["X-Amz-SignedHeaders"] = signed_header_names(canonical_headers)
      if token = @session_token
        params["X-Amz-Security-Token"] = token
      end

      query = canonical_query(params)
      canonical = canonical_request(
        method: method,
        path: uri.path,
        query: query,
        headers: canonical_headers,
        payload_hash: presigned_payload_hash,
      )

      # The canonical query is already sorted and RFC 3986-encoded, which is
      # exactly what we want on the wire, so reuse it rather than letting
      # `URI::Params#to_s` re-encode spaces as `+`. The signature goes last by
      # convention.
      uri.dup.tap do |signed|
        signed.query = "#{query}&X-Amz-Signature=#{signature(canonical, now, scope)}"
      end
    end

    private def presigned_payload_hash : String
      # S3 requires UNSIGNED-PAYLOAD for presigned URLs since the payload is
      # not known when the URL is generated. Other services expect the hash of
      # an empty body.
      @service == "s3" ? UNSIGNED_PAYLOAD : EMPTY_SHA256
    end

    private def scope_for(time : Time) : String
      "#{time.to_utc.to_s(DATE_FORMAT)}/#{@region}/#{@service}/aws4_request"
    end

    private def host_header(uri : URI) : String
      host = uri.host || raise ArgumentError.new("Cannot presign a URI without a host: #{uri}")
      if port = uri.port
        "#{host}:#{port}"
      else
        host
      end
    end

    private def canonical_request(
      method : String,
      path : String,
      query : String,
      headers : Array({String, String}),
      payload_hash : String,
    ) : String
      String.build do |str|
        str << method << '\n'
        str << (path.empty? ? "/" : path) << '\n'
        str << query << '\n'
        headers.each do |(name, value)|
          str << name << ':' << value << '\n'
        end
        str << '\n'
        str << signed_header_names(headers) << '\n'
        str << payload_hash
      end
    end

    # Lowercased names and whitespace-normalized values of the headers that
    # participate in the signature, sorted by name.
    private def canonical_headers(headers : HTTP::Headers) : Array({String, String})
      headers
        .compact_map do |(name, values)|
          name = name.downcase
          next if UNSIGNABLE_HEADERS.includes? name

          {name, values.join(',') { |value| value.strip.squeeze(' ') }}
        end
        .sort_by! { |(name, _)| name }
    end

    private def signed_header_names(headers : Array({String, String})) : String
      headers.join(';') { |(name, _)| name }
    end

    # Query parameters sorted by encoded name, then value, each RFC 3986
    # encoded. Parameters without a value are rendered as `name=`.
    private def canonical_query(params : URI::Params) : String
      pairs = [] of {String, String}
      params.each do |name, value|
        pairs << {encode(name), encode(value)}
      end
      pairs.sort!
      pairs.join('&') { |(name, value)| "#{name}=#{value}" }
    end

    private def encode(string : String) : String
      URI.encode_www_form(string, space_to_plus: false)
    end

    # Hashes the body from its current position and seeks back to it, since
    # `HTTP::Client` will send the body from that same position. The body must
    # therefore be seekable, or `X-Amz-Content-Sha256` must be set up front.
    private def hash_payload(body : IO?) : String
      return EMPTY_SHA256 unless body

      start = body.pos
      digest = Digest::SHA256.new
      buffer = uninitialized UInt8[65_536]
      while (read = body.read(buffer.to_slice)) > 0
        digest.update buffer.to_slice[0, read]
      end
      body.pos = start
      digest.hexfinal
    end

    private def signature(canonical_request : String, time : Time, scope : String) : String
      string_to_sign = String.build do |str|
        str << ALGORITHM << '\n'
        str << time.to_utc.to_s(TIMESTAMP_FORMAT) << '\n'
        str << scope << '\n'
        str << Digest::SHA256.hexdigest(canonical_request)
      end

      OpenSSL::HMAC.hexdigest(:sha256, signing_key(time), string_to_sign)
    end

    private def signing_key(time : Time) : Bytes
      key = OpenSSL::HMAC.digest(:sha256, "AWS4#{@secret_access_key}", time.to_utc.to_s(DATE_FORMAT))
      key = OpenSSL::HMAC.digest(:sha256, key, @region)
      key = OpenSSL::HMAC.digest(:sha256, key, @service)
      OpenSSL::HMAC.digest(:sha256, key, "aws4_request")
    end
  end
end
