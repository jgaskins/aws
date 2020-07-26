require "../spec_helper"
require "../../src/sqs/message"

module AWS
  module SQS
    describe Message do
      it "parses its XML representation" do
        id = UUID.random
        xml = <<-XML
        <Message>
          <MessageId>#{id}</MessageId>
          <ReceiptHandle>receipt_handle</ReceiptHandle>
          <MD5OfBody>md5_of_body</MD5OfBody>
          <Body>body!</Body>
        </Message>
        XML

        message = Message.from_xml(xml)

        message.id.should eq id
        message.receipt_handle.should eq "receipt_handle"
        message.md5.should eq "md5_of_body"
        message.body.should eq "body!"
      end
    end
  end
end
