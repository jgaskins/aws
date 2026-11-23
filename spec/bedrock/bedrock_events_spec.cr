require "../spec_helper"
require "../../src/bedrock_events.cr"
require "../../src/eventstream.cr"

describe AWS do
  describe AWS::BedrockRuntime do
    describe AWS::BedrockRuntime::BedrockRuntimeEvent do
      real_message = {"type" => "message_start", "message" => {"id" => "msg_bdrk_01GuZRyDETP2CY6ZsiYoLgZT", "type" => "message", "role" => "assistant", "model" => "claude-3-5-sonnet-20241022", "content" => [] of String, "stop_reason" => nil, "stop_sequence" => nil, "usage" => {"input_tokens" => 91, "cache_creation_input_tokens" => 0, "cache_read_input_tokens" => 0, "output_tokens" => 7}}}
      it "knows some message types" do
        event = AWS::BedrockRuntime::BedrockRuntimeEvent.from_event_payload(
          real_message.to_json
        )
        case event
        when AWS::BedrockRuntime::BedrockRuntimeEvent::MessageStart
          event.type.should eq("message_start")
          event.message.id.should eq("msg_bdrk_01GuZRyDETP2CY6ZsiYoLgZT")
          event.message.type.should eq("message")
          event.message.role.should eq("assistant")
          event.message.model.should eq("claude-3-5-sonnet-20241022")
          event.message.content.should eq([] of String)
        else
          false.should eq(true)
        end
      end
      it "can access fields through the unmapped json" do
        event = AWS::BedrockRuntime::BedrockRuntimeEvent.from_event_payload(
          real_message.to_json
        )
        event["type"].should eq("message_start")
        event["message"]["id"].should eq("msg_bdrk_01GuZRyDETP2CY6ZsiYoLgZT")
        event["message"]["type"].should eq("message")
        event["message"]["role"].should eq("assistant")
        event["message"]["model"].should eq("claude-3-5-sonnet-20241022")
        event["message"]["content"].should eq([] of String)
      end
      it "can apply types to messages with some unknown fields" do
        event = AWS::BedrockRuntime::BedrockRuntimeEvent.from_event_payload(
          real_message.merge({"UNKNOWN_FIELD" => 4}).to_json
        )
        event["UNKNOWN_FIELD"].should eq(4)
        case event
        when AWS::BedrockRuntime::BedrockRuntimeEvent::MessageStart
          true.should eq(true)
        else
          false.should eq(true)
        end
      end
      it "accepts unknown message types" do
        message = {"type" => "UNKNOWN_TYPE", "UNKNOWN_FIELD" => 4}
        event = AWS::BedrockRuntime::BedrockRuntimeEvent.from_event_payload(
          message.to_json
        )
        event["type"].should eq("UNKNOWN_TYPE")
        event["UNKNOWN_FIELD"].should eq(4)
      end
    end
  end
end
