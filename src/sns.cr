require "json"

require "./client"

module AWS
  module SNS
    class Client < AWS::Client
      SERVICE_NAME = "sns"

      def publish(topic_arn : String, message : String, subject : String = "")
        xml = XML.parse(
          http("#{service_name}.#{@region}.amazonaws.com", &.post(
            path: "/",
            form: {
              "Action" => "Publish",
              "TopicArn" => topic_arn,
              "Message" => message,
              "Subject" => subject,
              "Version" => "2010-03-31",
            }.select { |key, value| !value.empty? },
          )).body
        )
        xml.to_xml
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
