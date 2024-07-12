require "./list_bucket_result"

class BucketIterator
  include Iterator(ListBucketResult::Contents)

  def initialize(@s3_client : AWS::S3::Client, @bucket_name : String)
    @contents = [] of ListBucketResult::Contents
    @continuation_token = ""
    @end_of_bucket = false
  end

  def next : ListBucketResult::Contents | Iterator::Stop
    if @contents.empty?
      if @end_of_bucket
        return stop
      else
        fetch_contents
      end
    end

    @contents.shift
  end

  def fetch_contents
    puts "fetching new contents"
    response = @s3_client.list_objects(
      bucket_name: @bucket_name,
      continuation_token: @continuation_token,
      count: 10
    )
    # p response
    @contents = response.contents
    @continuation_token = response.next_continuation_token
    # @end_of_bucket = response.is_truncated == false
  end
end

