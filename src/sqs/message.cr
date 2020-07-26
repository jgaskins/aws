require "xml"
require "uuid"

module AWS
  module SQS
    struct Message
      getter id, receipt_handle, md5, body

      def self.get_xml_child(xml, name) : String
        xml.xpath_node("*[name()='#{name}']/text()").to_s
      end

      def self.from_xml(xml : String)
        from_xml XML.parse(xml).first_element_child.not_nil!
      end

      def self.from_xml(xml : XML::Node)
        new(
          id: UUID.new(get_xml_child(xml, "MessageId")),
          receipt_handle: get_xml_child(xml, "ReceiptHandle"),
          md5: get_xml_child(xml, "MD5OfBody"),
          body: get_xml_child(xml, "Body"),
        )
      end

      def initialize(@id : UUID, @receipt_handle : String, @md5 : String, @body : String)
      end
    end
  end
end
