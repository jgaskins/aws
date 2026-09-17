require "base64"
require "xml"
require "uuid"

module AWS
  module SQS
    class InvalidXML < ::Exception
    end

    struct Message
      getter id, receipt_handle, md5, body, attributes, message_attributes

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
        children(xml, "Attribute").each do |attribute|
          attributes[child(attribute, "Name").text] = child(attribute, "Value").text
        end

        attributes
      end

      private def self.get_message_attributes(xml : XML::Node)
        attributes = {} of String => String | Bytes | Int64 | Float64
        children(xml, "MessageAttribute").each do |attribute|
          name = child(attribute, "Name").text
          value_node = child(attribute, "Value")
          value = case child(value_node, "DataType").text
                  when "String"
                    child(value_node, "StringValue").text
                  when "Number"
                    string = child(value_node, "StringValue").text
                    if string.includes? '.'
                      string.to_f64
                    else
                      string.to_i64
                    end
                  when "Binary"
                    Base64.decode(child(value_node, "BinaryValue").text)
                  else # Return bytes for custom data types in case it's not UTF8 strings
                    child(value_node, "BinaryValue").text.to_slice
                  end

          attributes[name] = value
        end

        attributes
      end

      private def self.get_xml_child(xml, name) : String
        child?(xml, name).try(&.text) || ""
      end

      # SQS responses declare a default namespace on the root element, which
      # makes the `xmlns:` XPath prefix work, but fragments and some
      # compatible services omit it. Matching on the local name works either
      # way.
      private def self.children(xml : XML::Node, name : String)
        xml.xpath_nodes("*[local-name()='#{name}']")
      end

      private def self.child?(xml : XML::Node, name : String) : XML::Node?
        xml.xpath_node("*[local-name()='#{name}']")
      end

      private def self.child(xml : XML::Node, name : String) : XML::Node
        child?(xml, name) || raise InvalidXML.new("Expected a <#{name}> element inside: #{xml}")
      end
    end
  end
end
