require "http"
require "awscr-signer"
require "db/pool"

require "./aws"

module AWS
  abstract class Client
    macro service_name
      {{SERVICE_NAME}}
    end

    def initialize(
      @access_key_id = AWS.access_key_id,
      @secret_access_key = AWS.secret_access_key,
      @region = AWS.region,
      @endpoint = URI.parse("https://#{service_name}.amazonaws.com"),
    )
      @signer = Awscr::Signer::Signers::V4.new(service_name, region, access_key_id, secret_access_key)
      @connection_pools = Hash({String, Bool}, DB::Pool(HTTP::Client)).new
    end

    def head(path : String, headers : HTTP::Headers)
      headers = DEFAULT_HEADERS.dup.merge!(headers)
      http(&.head(path, headers))
    end

    DEFAULT_HEADERS = HTTP::Headers {
      # Can't sign requests to DigitalOcean with this 🤬
      # "Connection" => "keep-alive",
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

    protected getter endpoint

    protected def http(host = endpoint.host.not_nil!, tls = true)
      pool = @connection_pools.fetch({host, tls}) do |key|
        @connection_pools[key] = DB::Pool.new(initial_pool_size: 0, max_idle_pool_size: 20) do
          http = HTTP::Client.new(host, tls: tls)
          http.before_request do |request|
            @signer.sign request
          end

          http
        end
      end

      pool.checkout { |http| yield http }
    end
  end
end
