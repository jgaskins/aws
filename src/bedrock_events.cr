require "json"

module AWS
  module BedrockRuntime

    class BedrockRuntimeEvent
      include JSON::Serializable
      include JSON::Serializable::Unmapped


      macro handle_json_access_pattern(known_primitive_keys = [] of String, known_object_keys = [] of String)
        def [](key : String)
          {% for known_key in known_primitive_keys %}
          return JSON::Any.new(@{{known_key.id}}) if key == {{known_key}}
          {% end %}
          {% for known_key in known_object_keys %}
          return JSON.parse(@{{known_key.id}}.to_json) if key == {{known_key}}
          {% end %}
          @json_unmapped[key]
        end
      end

      handle_json_access_pattern([] of String, [] of String)

      def self.from_event(event : EventStream::EventMessage) : BedrockRuntimeEvent
        payload_hash = JSON.parse(String.new(event.payload)).as_h
        # named "bytes" but that doesn't make sense for JSON
        encoded_bytes = payload_hash["bytes"].as_s
        # The only other field is "p" which appears to be a sanity check. Its value is some amount of the alphabet, in order, lowercase, then uppercase, then digits.
        inner_json_bytes = Base64.decode(encoded_bytes)
        json_str = String.new(inner_json_bytes)
        from_event_payload(json_str)
      end

      def self.from_event_payload(json_str : String) : BedrockRuntimeEvent
        raw = JSON.parse(json_str).as_h

        case raw["type"]
        when "message_start"
          MessageStart.from_json(json_str)
        when "content_block_start"
          ContentBlockStart.from_json(json_str)
        when "content_block_delta"
          ContentBlockDelta.from_json(json_str)
        when "content_block_stop"
          ContentBlockStop.from_json(json_str)
        else
          # No subtype - everything can be accessed through the unmapped json
          BedrockRuntimeEvent.from_json(json_str)
        end
      end

      class MessageStart < BedrockRuntimeEvent
        # {"type" => "message_start", "message" => {"id" => "msg_bdrk_01GuZRyDETP2CY6ZsiYoLgZT", "type" => "message", "role" => "assistant", "model" => "claude-3-5-sonnet-20241022", "content" => [], "stop_reason" => nil, "stop_sequence" => nil, "usage" => {"input_tokens" => 91, "cache_creation_input_tokens" => 0, "cache_read_input_tokens" => 0, "output_tokens" => 7}}}
        include JSON::Serializable
        include JSON::Serializable::Unmapped

        property type : String
        property message : Message

        handle_json_access_pattern(["type"], ["message"])

        class Message < BedrockRuntimeEvent
          include JSON::Serializable
          include JSON::Serializable::Unmapped

          property id : String
          property type : String
          property role : String
          property model : String
          property content : Array(JSON::Any)
          @[JSON::Field(key: "stop_reason")]
          property stop_reason : String?
          @[JSON::Field(key: "stop_sequence")]
          property stop_sequence : String?
          property usage : Usage
          handle_json_access_pattern(["id", "type", "role", "model", "content", "stop_reason", "stop_sequence"], ["usage"])

          class Usage < BedrockRuntimeEvent
            include JSON::Serializable
            include JSON::Serializable::Unmapped
            @[JSON::Field(key: "input_tokens")]
            property input_tokens : Int32
            @[JSON::Field(key: "cache_creation_input_tokens")]
            property cache_creation_input_tokens : Int32?
            @[JSON::Field(key: "cache_read_input_tokens")]
            property cache_read_input_tokens : Int32?
            @[JSON::Field(key: "output_tokens")]
            property output_tokens : Int32
            handle_json_access_pattern(["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"], [] of String)

          end
        end
      end

      class ContentBlockStart < BedrockRuntimeEvent
        # {"type" => "content_block_start", "index" => 0, "content_block" => {"type" => "text", "text" => ""}}
        include JSON::Serializable
        include JSON::Serializable::Unmapped

        property type : String
        property index : Int32
        @[JSON::Field(key: "content_block")]
        property content_block : ContentBlock

        handle_json_access_pattern(["type", "index"], ["content_block"])
        class ContentBlock < BedrockRuntimeEvent
          include JSON::Serializable
          include JSON::Serializable::Unmapped

          property type : String
          property text : String
          handle_json_access_pattern(["type", "text"], [] of String)
        end
      end

      class ContentBlockDelta < BedrockRuntimeEvent
        # {"type" => "content_block_delta", "index" => 0, "delta" => {"type" => "text_delta", "text" => "\n\nA jungle fowl wandere"}}
        include JSON::Serializable
        include JSON::Serializable::Unmapped

        property type : String
        property index : Int32
        property delta : Delta

        handle_json_access_pattern(["type", "index"], ["delta"])
        class Delta < BedrockRuntimeEvent
          include JSON::Serializable
          include JSON::Serializable::Unmapped

          property type : String
          property text : String
          handle_json_access_pattern(["type", "text"], [] of String)
        end
      end

      class ContentBlockStop < BedrockRuntimeEvent
        # {"type" => "content_block_stop", "index" => 0}
        include JSON::Serializable
        include JSON::Serializable::Unmapped
        property type : String
        property index : Int32
        handle_json_access_pattern(["type", "index"], [] of String)
      end
    end
  end
end
