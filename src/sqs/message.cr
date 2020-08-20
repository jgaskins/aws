require "xml"
require "uuid"

module AWS
  module SQS
    struct Message
      getter id, receipt_handle, md5, body

      def self.from_xml(xml : String)
        from_xml XML.parse(xml).first_element_child.not_nil!
      end

      def self.from_xml(xml : XML::Node)
        new(
          id: UUID.new(get_xml_child(xml, "MessageId")),
          receipt_handle: get_xml_child(xml, "ReceiptHandle"),
          md5: get_xml_child(xml, "MD5OfBody"),
          body: get_xml_child(xml, "Body"),
          attributes: get_attributes(xml),
          message_attributes: get_message_attributes(xml),
        )
      end

      @id : UUID
      @receipt_handle : String
      @md5 : String
      @body : String
      @attributes : Hash(String, String)
      @message_attributes : Hash(String, String | Bytes | Int64 | Float64)

      def initialize(@id, @receipt_handle, @md5, @body, @attributes, @message_attributes)
      end

      private def self.get_attributes(xml : XML::Node)
        attributes = {} of String => String
        xml.xpath_nodes("xmlns:Attribute").each do |attribute|
          name_node = attribute.xpath_node("./xmlns:Name").not_nil!
          value_node = attribute.xpath_node("./xmlns:Value").not_nil!

          attributes[name_node.text] = value_node.text
        end

        attributes
      end

      private def self.get_message_attributes(xml : XML::Node)
        attributes = {} of String => String | Bytes | Int64 | Float64
        xml.xpath_nodes("xmlns:MessageAttribute").each do |attribute|
          name_node = attribute.xpath_node("./xmlns:Name").not_nil!
          value_node = attribute.xpath_node("./xmlns:Value").not_nil!
          value_type = value_node.xpath_node("./xmlns:DataType").not_nil!
          value = case value_type.text
                  when "String"
                    value_node.xpath_node("./xmlns:StringValue").not_nil!.text
                  when "Number"
                    string = value_node.xpath_node("./xmlns:StringValue").not_nil!.text
                    if string.includes? '.'
                      string.to_f64
                    else
                      string.to_i64
                    end
                  when "Binary"
                    Base64.decode(value_node.xpath_node("./xmlns:BinaryValue").not_nil!.text)
                  else # Return bytes for custom data types in case it's not UTF8 strings
                    value_node.xpath_node("./xmlns:BinaryValue").not_nil!.text.to_slice
                  end

          attributes[name_node.text] = value
        end

        attributes
      end

      private def self.get_xml_child(xml, name) : String
        xml.xpath_node("*[name()='#{name}']/text()").to_s
      end
    end
  end
end
