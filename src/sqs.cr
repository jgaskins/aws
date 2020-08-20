require "http"
require "xml"

require "./sqs/message"
require "./client"

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
            "#{queue_url.path}?#{HTTP::Params.encode({Action: "ReceiveMessage", MaxNumberOfMessages: max_number_of_messages.to_s, WaitTimeSeconds: wait_time_seconds.to_s, "AttributeName.1": "All", "MessageAttributeName.1": "All"})}"
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
          SendMessageResponse.from_xml response.body
        end
      end

      def delete_message(queue_url : URI, receipt_handle : String)
        http(queue_url.host.not_nil!) do |http|
          http
            .delete("#{queue_url.path}?#{HTTP::Params.encode({ Action: "DeleteMessage", ReceiptHandle: receipt_handle })}")
            .body
        end
      end

      def delete_message_batch(
        queue_url : URI,
        change_message_visibility_batch_request_entries messages : Enumerable(Message),
      )
        http(queue_url.host.not_nil!) do |http|
          params = HTTP::Params{"Action" => "DeleteMessageBatch"}
          messages.each_with_index(1) do |message, index|
            params["DeleteMessageBatchRequestEntry.#{index}.Id"] = message.id.to_s
            params["DeleteMessageBatchRequestEntry.#{index}.ReceiptHandle"] = message.receipt_handle
          end
          http.delete("#{queue_url.path}?#{params}").body
        end
      end

      def change_message_visibility_batch(queue_url, change_message_visibility_batch_request_entries, visibility_timeout : Time::Span)
        change_message_visibility_batch(
          queue_url,
          change_message_visibility_batch_request_entries,
          visibility_timeout: visibility_timeout.total_seconds.to_i,
        )
      end

      def change_message_visibility_batch(
        queue_url : URI,
        change_message_visibility_batch_request_entries messages : Enumerable(Message),
        visibility_timeout : Int32 | String,
      )
        http(queue_url.host.not_nil!) do |http|
          params = HTTP::Params{"Action" => "DeleteMessageBatch"}
          messages.each_with_index(1) do |message, index|
            params["ChangeMessageVisibilityBatchRequestEntry.#{index}.Id"] = message.id.to_s
            params["ChangeMessageVisibilityBatchRequestEntry.#{index}.ReceiptHandle"] = message.receipt_handle
            params["ChangeMessageVisibilityBatchRequestEntry.#{index}.VisibilityTimeout"] = visibility_timeout.to_s
          end
          http.delete("#{queue_url.path}?#{params}").body
        end
      end

      def create_queue(queue_name name : String)
        http do |http|
          params = HTTP::Params{"Action" => "CreateQueue", "QueueName" => name}
          response = http.post("/?#{params}")
          if response.success?
            Queue.from_xml response.body
          else
            raise "AWS::SQS#create_queue: #{XML.parse(response.body).to_xml}"
          end
        end
      end

      def list_queues(queue_name_prefix : String? = nil)
        http do |http|
          params = HTTP::Params{"Action" => "ListQueues"}
          if queue_name_prefix
            params["QueueNamePrefix"] = queue_name_prefix
          end

          response = http.get("/?#{pp params}")

          if response.success?
            ListQueuesResult.from_xml response.body
          else
            raise "AWS::SQS#list_queues: #{XML.parse(response.body).to_xml}"
          end
        end
      end

      def get_queue_attributes(queue_url : URI, attributes : Enumerable(String))
        q_attrs = Hash(String, String).new(initial_capacity: attributes.size)

        http do |http|
          params = HTTP::Params{
            "Action" => "GetQueueAttributes",
            "QueueUrl" => queue_url.to_s
          }
          attributes.each_with_index(1) do |attribute, index|
            params["AttributeName.#{index}"] = attribute
          end
          response = http.get("?#{params}")

          if response.success?
            XML.parse(response.body).xpath_nodes("//xmlns:Attribute").each do |attribute|
              q_attrs[attribute.xpath_node("./xmlns:Name").not_nil!.text] =
                attribute.xpath_node("./xmlns:Value").not_nil!.text
            end
          else
            raise "AWS::SQS#get_queue_attributes: #{XML.parse(response.body).to_xml}"
          end
        end

        q_attrs
      end
    end

    struct ListQueuesResult
      getter queues : Enumerable(Queue)
      getter next_token : String?

      def self.from_xml(xml : String)
        from_xml XML.parse xml
      end

      def self.from_xml(xml : XML::Node)
        queues = xml.xpath_nodes("//xmlns:QueueUrl").map do |url|
          Queue.new(url.text)
        end

        new(queues: queues)
      end

      def initialize(@queues : Enumerable(Queue), @next_token = nil)
      end
    end
    struct Queue
      getter url : URI

      def self.from_xml(xml : String)
        from_xml XML.parse xml
      end

      def self.from_xml(xml : XML::Node)
        if xml.document?
          from_xml xml.root.not_nil!
        else
          new(url: xml.xpath_node("//xmlns:QueueUrl").not_nil!.text)
        end
      end

      def initialize(url : String)
        initialize URI.parse(url)
      end

      def initialize(@url : URI)
      end
    end

    struct SendMessageResponse
      def self.from_xml(xml : String)
        from_xml XML.parse xml
      end
      
      def self.from_xml(xml : XML::Node)
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

      def self.from_xml(xml : String)
        from_xml XML.parse xml
      end

      def self.from_xml(xml : XML::Node)
        if xml.name == "ReceiveMessageResult"
          new(xml.children.map { |message| Message.from_xml(message) })
        elsif xml.name == "ErrorResponse"
          raise ERROR_MAP.fetch(xml.xpath_node("//xmlns:Code").not_nil!.text, Exception).new(
            message: xml.xpath_node("//xmlns:Message").not_nil!.text,
          )
        else
          from_xml(xml.children.first)
        end
      end

      def initialize(@messages : Array(Message))
      end
    end

    class Exception < AWS::Exception
    end
    class ResultParsingError < Exception
    end
    class InvalidParameterValue < Exception
    end

    ERROR_MAP = {
      "InvalidParameterValue" => InvalidParameterValue,
    }
  end
end
