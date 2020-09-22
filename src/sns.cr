require "json"
require "http"
require "xml"

require "./client"
require "./sqs"

module AWS
  module SNS
    class Client < AWS::Client
      SERVICE_NAME = "sns"

      def publish(topic_arn : String, message : String, subject : String = "")
        response = http(&.post(
          path: "/",
          form: {
            "Action" => "Publish",
            "TopicArn" => topic_arn,
            "Message" => message,
            "Subject" => subject,
            "Version" => "2010-03-31",
          }.select { |key, value| !value.empty? },
        ))

        if response.success?
          true
        else
          raise "AWS::SNS#publish: #{XML.parse(response.body).to_xml}"
        end
      end

      def create_topic(name : String)
        http do |http|
          response = http.post(
            path: "/",
            form: {
              "Action" => "CreateTopic",
              "Name" => name,
            },
          )

          if response.success?
            Topic.from_xml response.body
          else
            raise "AWS::SNS#create_topic: #{XML.parse(response.body).to_xml}"
          end
        end
      end

      def subscribe(
        topic : Topic,
        queue : SQS::Queue,
        sqs = SQS::Client.new(
          access_key_id: access_key_id,
          secret_access_key: secret_access_key,
          region: region,
          endpoint: endpoint,
        ),
      )
        subscribe(
          topic_arn: topic.arn,
          protocol: "sqs",
          endpoint: sqs.get_queue_attributes(queue.url, %w[QueueArn])["QueueArn"]
        )
      end

      def subscribe(
        topic_arn : String,
        protocol : String,
        endpoint : String,
      )
        http do |http|
          response = http.post(
            path: "/",
            form: {
              "Action" => "Subscribe",
              "TopicArn" => topic_arn,
              "Protocol" => protocol,
              "Endpoint" => endpoint,
            },
          )

          if response.success?
            TopicSubscription.from_xml(response.body)
          else
            raise "AWS::SNS#subscribe: #{XML.parse(response.body).to_xml}"
          end
        end
      end
    end

    struct Topic
      getter arn

      def self.from_xml(xml : String)
        from_xml XML.parse xml
      end

      def self.from_xml(xml : XML::Node)
        new(arn: xml.xpath_node("//xmlns:TopicArn").not_nil!.text)
      end

      def initialize(@arn : String)
      end
    end

    struct TopicSubscription
      getter arn

      def self.from_xml(xml : String)
        from_xml XML.parse xml
      end

      def self.from_xml(xml : XML::Node)
        new(arn: xml.xpath_node("//xmlns:SubscriptionArn").not_nil!.text)
      end

      def initialize(@arn : String)
      end
    end

    struct Message
      include JSON::Serializable

      @[JSON::Field(key: "Type")]
      getter type : String

      @[JSON::Field(key: "Subject")]
      getter subject : String

      @[JSON::Field(key: "MessageId")]
      getter message_id : String

      @[JSON::Field(key: "TopicArn")]
      getter topic_arn : String

      @[JSON::Field(key: "Message")]
      getter message : String

      # Because srsly calling message.message is ridiculous
      def body
        message
      end

      @[JSON::Field(key: "Timestamp", converter: ::AWS::SNS::TimestampConverter)]
      getter timestamp : Time

      @[JSON::Field(key: "SignatureVersion")]
      getter signature_version : String

      @[JSON::Field(key: "Signature")]
      getter signature : String

      @[JSON::Field(key: "SigningCertURL", converter: ::AWS::SNS::URIConverter)]
      getter signing_cert_url : URI

      @[JSON::Field(key: "UnsubscribeURL", converter: ::AWS::SNS::URIConverter)]
      getter unsubscribe_url : URI
    end

    module TimestampConverter
      FORMAT = Time::Format::ISO_8601_DATE_TIME

      def self.from_json(json : JSON::PullParser) : Time
        FORMAT.parse json.read_string
      end

      def self.to_json(value : Time, json : JSON::Builder)
        FORMAT.format value, json
      end
    end

    module URIConverter
      def self.from_json(json : JSON::PullParser) : URI
        URI.parse json.read_string
      end
    end
  end
end
