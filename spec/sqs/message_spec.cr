require "../spec_helper"
require "../../src/sqs/message"

module AWS
  module SQS
    describe Message do
      id = UUID.random
      body = <<-XML
        <MessageId>#{id}</MessageId>
        <ReceiptHandle>receipt_handle</ReceiptHandle>
        <MD5OfBody>md5_of_body</MD5OfBody>
        <Body>body!</Body>
        <Attribute><Name>SenderId</Name><Value>AIDAEXAMPLE</Value></Attribute>
        <Attribute><Name>ApproximateReceiveCount</Name><Value>2</Value></Attribute>
        <MessageAttribute>
          <Name>label</Name>
          <Value><DataType>String</DataType><StringValue>hello</StringValue></Value>
        </MessageAttribute>
        <MessageAttribute>
          <Name>count</Name>
          <Value><DataType>Number</DataType><StringValue>3</StringValue></Value>
        </MessageAttribute>
        <MessageAttribute>
          <Name>ratio</Name>
          <Value><DataType>Number</DataType><StringValue>0.5</StringValue></Value>
        </MessageAttribute>
        <MessageAttribute>
          <Name>blob</Name>
          <Value><DataType>Binary</DataType><BinaryValue>#{Base64.strict_encode("raw bytes")}</BinaryValue></Value>
        </MessageAttribute>
        XML

      it "parses its XML representation" do
        message = Message.from_xml("<Message>#{body}</Message>")

        message.id.should eq id
        message.receipt_handle.should eq "receipt_handle"
        message.md5.should eq "md5_of_body"
        message.body.should eq "body!"
        message.attributes.should eq({
          "SenderId"                => "AIDAEXAMPLE",
          "ApproximateReceiveCount" => "2",
        })
        message.message_attributes["label"].should eq "hello"
        message.message_attributes["count"].should eq 3_i64
        message.message_attributes["ratio"].should eq 0.5
        message.message_attributes["blob"].should eq "raw bytes".to_slice
      end

      it "parses XML that declares the SQS namespace" do
        xml = %(<Message xmlns="http://queue.amazonaws.com/doc/2012-11-05/">#{body}</Message>)

        message = Message.from_xml(xml)

        message.id.should eq id
        message.attributes["SenderId"].should eq "AIDAEXAMPLE"
        message.message_attributes["count"].should eq 3_i64
      end

      it "leaves attributes empty when the message has none" do
        message = Message.from_xml(<<-XML)
          <Message>
            <MessageId>#{id}</MessageId>
            <ReceiptHandle>rh</ReceiptHandle>
            <MD5OfBody>md5</MD5OfBody>
            <Body>b</Body>
          </Message>
          XML

        message.attributes.should be_empty
        message.message_attributes.should be_empty
      end
    end
  end
end
