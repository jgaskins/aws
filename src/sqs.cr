require "http"
require "xml"

require "./sqs/message"

module AWS
  module SQS
    class Client < AWS::Client
      SERVICE_NAME = "sqs"

      def receive_message(
        queue_url : URI,
        max_number_of_messages : Int = 1,
        wait_time_seconds : Int = 0,
      )
        xml = XML.parse(
          http(queue_url.host.not_nil!, &.get(
            "#{queue_url.path}?#{HTTP::Params.encode({Action: "ReceiveMessage", MaxNumberOfMessages: max_number_of_messages.to_s, WaitTimeSeconds: wait_time_seconds.to_s})}"
          )).body
        )
        ReceiveMessageResult.from_xml(xml)
      end

      def send_message(
        queue_url : URI,
        message_body : String,
      )
        http(queue_url.host.not_nil!) do |http|
          headers = DEFAULT_HEADERS.dup.merge!({
            "Host" => queue_url.host.not_nil!,
            "Content-Type" => "application/x-www-form-urlencoded",
          })
          params = HTTP::Params {
            "Action" => "SendMessage",
            "MessageBody" => message_body
          }
          response = http.post(queue_url.path, body: params.to_s, headers: headers)
          pp SendMessageResponse.from_xml response.body
        end
      end

      def delete_message(queue_url : URI, receipt_handle : String)
        http(queue_url.host.not_nil!) do |http|
          http
            .delete("#{queue_url.path}?#{HTTP::Params.encode({ Action: "DeleteMessage", ReceiptHandle: receipt_handle })}")
            .body
        end
      end
    end

    struct SendMessageResponse
      def self.from_xml(xml : String)
        from_xml XML.parse xml
      end
      
      def self.from_xml(xml : XML::Node)
        xml
        if xml.document?
          from_xml xml.root.not_nil!
        else
          new(
            send_message_result: SendMessageResult.from_xml(xml.xpath_node("./xmlns:SendMessageResult").not_nil!),
            response_metadata: ResponseMetadata.from_xml(xml.xpath_node("./xmlns:ResponseMetadata").not_nil!),
          )
        end
      end
      
      getter send_message_result : SendMessageResult
      getter response_metadata : ResponseMetadata
      
      def initialize(@send_message_result, @response_metadata)
      end
      
      struct SendMessageResult
        def self.from_xml(xml : XML::Node)
          new(
            message_id: UUID.new(xml.xpath_string("string(./xmlns:MessageId)")),
            md5_of_message_body: xml.xpath_string("string(./xmlns:MD5OfMessageBody)"),
          )
        end
        
        def initialize(@message_id : UUID, md5_of_message_body : String)
        end
      end
      
      struct ResponseMetadata
        def self.from_xml(xml : XML::Node)
          new(
            request_id: UUID.new(xml.xpath_string("string(./xmlns:RequestId)")),
          )
        end
        
        def initialize(@request_id : UUID)
        end
      end
    end

    struct ReceiveMessageResult
      getter messages

      def self.from_xml(node : XML::Node)
        if node.name == "ReceiveMessageResult"
          new(node.children.map { |message| Message.from_xml(message) })
        else
          from_xml(node.children.first)
        end
      end

      def initialize(@messages : Array(Message))
      end
    end

    class Exception < AWS::Exception
    end
    class ResultParsingError < Exception
    end
  end
end
