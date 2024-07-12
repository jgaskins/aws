class InvalidXML < Exception
end

struct ListBucketResult
  getter name, prefix, key_count, max_keys, contents, next_continuation_token
  getter? truncated

  def self.from_xml(xml : String)
    from_xml XML.parse(xml).root.not_nil!
  end

  def self.from_xml(xml : XML::Node)
    name = xml.xpath_node("./xmlns:Name")
    prefix = xml.xpath_node("./xmlns:Prefix")
    max_keys = xml.xpath_node("./xmlns:MaxKeys")
    key_count = xml.xpath_node("./xmlns:KeyCount")
    truncated = xml.xpath_node("./xmlns:IsTruncated")
    next_continuation_token = xml.xpath_node("./xmlns:NextContinuationToken")

    if name && prefix && max_keys && truncated && next_continuation_token
      contents = xml.xpath_nodes("./xmlns:Contents")
      new(
        name: name.text,
        prefix: prefix.text,
        max_keys: max_keys.text.to_i,
        key_count: key_count.try(&.text.to_i),
        truncated: truncated.text == "true",
        next_continuation_token: next_continuation_token.text,
        contents: contents.map { |c| Contents.from_xml c },
      )
    else
      raise InvalidXML.new("The following XML does not represent a ListBucketResult: #{xml}")
    end
  end

  def initialize(
    @name : String,
    @prefix : String,
    @key_count : Int32?,
    @max_keys : Int32,
    @truncated : Bool,
    @next_continuation_token : String,
    @contents : Array(Contents)
  )
  end

  struct Contents
    getter key, last_modified, etag, size, storage_class

    def self.from_xml(xml : String)
      from_xml XML.parse xml
    end

    def self.from_xml(xml : XML::Node)
      if (key = xml.xpath_node("./xmlns:Key")) && (size = xml.xpath_node("./xmlns:Size"))
        new(
          key: key.text,
          last_modified: Time.utc,
          etag: (xml.xpath_node("./xmlns:ETag").try(&.text) || "").gsub('"', ""),
          size: size.text.to_i64,
          storage_class: xml.xpath_node("./xmlns:StorageClass").try(&.text) || "",
        )
      else
        raise InvalidXML.new("The following XML is not a ListBucketResult::Contents: #{xml}")
      end
    end

    def initialize(
      @key : String,
      @last_modified : Time,
      @etag : String,
      @size : Int64,
      @storage_class : String
    )
    end
  end
end
