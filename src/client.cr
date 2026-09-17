require "http"
require "db/pool"

require "./aws"
require "./signature_v4"

module AWS
  abstract class Client
    macro service_name
      {{SERVICE_NAME}}
    end

    def initialize(
      @access_key_id = AWS.access_key_id,
      @secret_access_key = AWS.secret_access_key,
      @region = AWS.region,
      @endpoint = URI.parse("https://#{service_name}.#{region}.amazonaws.com"),
      @session_token = AWS.session_token,
    )
      @signer = SignatureV4.new(service_name, region, access_key_id, secret_access_key, session_token)
      @connection_pools = Hash({String, Int32?, Bool}, DB::Pool(HTTP::Client)).new
    end

    DEFAULT_HEADERS = HTTP::Headers{
      "Connection" => "keep-alive",
      "User-Agent" => "Crystal AWS #{VERSION}",
    }

    def get(path : String, headers = HTTP::Headers.new)
      headers = DEFAULT_HEADERS.dup.merge!(headers)
      http(&.get(path, headers: headers))
    end

    def get(path : String, headers = HTTP::Headers.new, &block : HTTP::Client::Response ->)
      headers = DEFAULT_HEADERS.dup.merge!(headers)
      http(&.get(path, headers: headers, &block))
    end

    def post(path : String, body : String, headers = HTTP::Headers.new)
      headers = DEFAULT_HEADERS.dup.merge!(headers)
      http(&.post(path, body: body, headers: headers))
    end

    def put(path : String, body : IO, headers = HTTP::Headers.new)
      headers = DEFAULT_HEADERS.dup.merge!(headers)
      http(&.put(path, body: body, headers: headers))
    end

    def head(path : String, headers : HTTP::Headers)
      headers = DEFAULT_HEADERS.dup.merge!(headers)
      http(&.head(path, headers))
    end

    def delete(path : String, headers = HTTP::Headers.new)
      headers = DEFAULT_HEADERS.dup.merge!(headers)
      http(&.delete(path, headers: headers))
    end

    protected getter endpoint

    protected def http(host = endpoint.host.not_nil!, port = endpoint.port, tls = endpoint.scheme != "http", &)
      pool = @connection_pools.fetch({host, port, tls}) do |key|
        @connection_pools[key] = DB::Pool.new(DB::Pool::Options.new(initial_pool_size: 0, max_idle_pool_size: 20)) do
          if port
            http = HTTP::Client.new(host, port, tls: tls)
          else
            http = HTTP::Client.new(host, tls: tls)
          end
          http.before_request do |request|
            # Sign at send time so the timestamp is fresh and every header
            # `HTTP::Client` adds (such as `Host`) is covered. Paths are
            # signed verbatim, so service clients must percent-encode them.
            @signer.sign request
          end

          http
        end
      end

      pool.checkout { |http| yield http }
    end
  end
end
