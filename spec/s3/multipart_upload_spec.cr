require "../spec_helper"
require "../../src/s3"

module AWS::S3
  describe MultipartUpload do
    describe ".from_xml" do
      it "parses an InitiateMultipartUploadResult" do
        upload = MultipartUpload.from_xml <<-XML
          <?xml version="1.0" encoding="UTF-8"?>
          <InitiateMultipartUploadResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
            <Bucket>example-bucket</Bucket>
            <Key>example-object</Key>
            <UploadId>VXBsb2FkIElEIGZvciA2aWWpbmcncyBteS1tb3ZpZS5tMnRzIHVwbG9hZA</UploadId>
          </InitiateMultipartUploadResult>
          XML

        upload.bucket.should eq "example-bucket"
        upload.key.should eq "example-object"
        upload.id.should eq "VXBsb2FkIElEIGZvciA2aWWpbmcncyBteS1tb3ZpZS5tMnRzIHVwbG9hZA"
      end

      it "raises when the XML is not an InitiateMultipartUploadResult" do
        expect_raises InvalidXML do
          MultipartUpload.from_xml %(<Foo xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Bar/></Foo>)
        end
      end
    end

    describe ".completion_xml" do
      it "lists parts in ascending part number order with quoted ETags" do
        xml = MultipartUpload.completion_xml [
          MultipartUpload::Part.new(2, "d8c2eafd90c266e19ab9dcacc479f8af"),
          MultipartUpload::Part.new(1, "a54357aff0632cce46d942af68356b38"),
        ]

        doc = XML.parse(xml)
        root = doc.root.not_nil!
        root.name.should eq "CompleteMultipartUpload"
        root.namespace.try(&.href).should eq "http://s3.amazonaws.com/doc/2006-03-01/"

        parts = root.xpath_nodes("./xmlns:Part")
        parts.map(&.xpath_node("./xmlns:PartNumber").not_nil!.text).should eq ["1", "2"]
        parts.map(&.xpath_node("./xmlns:ETag").not_nil!.text).should eq [
          %("a54357aff0632cce46d942af68356b38"),
          %("d8c2eafd90c266e19ab9dcacc479f8af"),
        ]
      end
    end
  end

  describe CompleteMultipartUploadResult do
    it "parses the result and strips quotes from the ETag" do
      result = CompleteMultipartUploadResult.from_xml <<-XML
        <?xml version="1.0" encoding="UTF-8"?>
        <CompleteMultipartUploadResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
          <Location>http://Example-Bucket.s3.amazonaws.com/Example-Object</Location>
          <Bucket>Example-Bucket</Bucket>
          <Key>Example-Object</Key>
          <ETag>"3858f62230ac3c915f300c664312c11f-9"</ETag>
        </CompleteMultipartUploadResult>
        XML

      result.location.should eq "http://Example-Bucket.s3.amazonaws.com/Example-Object"
      result.bucket.should eq "Example-Bucket"
      result.key.should eq "Example-Object"
      result.etag.should eq "3858f62230ac3c915f300c664312c11f-9"
    end
  end

  describe ListPartsResult do
    it "parses a ListPartsResult" do
      result = ListPartsResult.from_xml <<-XML
        <?xml version="1.0" encoding="UTF-8"?>
        <ListPartsResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
          <Bucket>example-bucket</Bucket>
          <Key>example-object</Key>
          <UploadId>XXBsb2FkIElEIGZvciBlbHZpbmcncyVcdS1tb3ZpZS5tMnRzEEEwbG9hZA</UploadId>
          <Initiator>
            <ID>arn:aws:iam::111122223333:user/some-user-11116a31-17b5-4fb7-9df5-b288870f11xx</ID>
            <DisplayName>umat-user-11116a31-17b5-4fb7-9df5-b288870f11xx</DisplayName>
          </Initiator>
          <Owner>
            <ID>75aa57f09aa0c8caeab4f8c24e99d10f8e7faeebf76c078efc7c6caea54ba06a</ID>
            <DisplayName>someName</DisplayName>
          </Owner>
          <StorageClass>STANDARD</StorageClass>
          <PartNumberMarker>1</PartNumberMarker>
          <NextPartNumberMarker>3</NextPartNumberMarker>
          <MaxParts>2</MaxParts>
          <IsTruncated>true</IsTruncated>
          <Part>
            <PartNumber>2</PartNumber>
            <LastModified>2010-11-10T20:48:34.000Z</LastModified>
            <ETag>"7778aef83f66abc1fa1e8477f296d394"</ETag>
            <Size>10485760</Size>
          </Part>
          <Part>
            <PartNumber>3</PartNumber>
            <LastModified>2010-11-10T20:48:33.000Z</LastModified>
            <ETag>"aaaa18db4cc2f85cedef654fccc4a4x8"</ETag>
            <Size>10485760</Size>
          </Part>
        </ListPartsResult>
        XML

      result.bucket.should eq "example-bucket"
      result.key.should eq "example-object"
      result.upload_id.should eq "XXBsb2FkIElEIGZvciBlbHZpbmcncyVcdS1tb3ZpZS5tMnRzEEEwbG9hZA"
      result.part_number_marker.should eq 1
      result.next_part_number_marker.should eq 3
      result.max_parts.should eq 2
      result.truncated?.should be_true

      result.parts.size.should eq 2
      part = result.parts.first
      part.part_number.should eq 2
      part.etag.should eq "7778aef83f66abc1fa1e8477f296d394"
      part.size.should eq 10_485_760
      part.last_modified.should eq Time.utc(2010, 11, 10, 20, 48, 34)
    end
  end
end
