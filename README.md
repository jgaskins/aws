# Crystal AWS

This shard provides clients for various services on AWS. So far, clients implemented are:

- S3
- SQS
- SNS

## Installation

1. Add the dependency to your `shard.yml`:

   ```yaml
   dependencies:
     aws:
       github: jgaskins/aws
   ```

2. Run `shards install`

## Usage

To use each service client, you need to require that client specifically. This avoids loading the entire suite of clients just to use a single one. So for example, to use S3, you would use `require "aws/s3"`.

All AWS clients are instantiated with credentials and a service endpoint. The defaults can be set either programmatically or via environment variables. To set them programmatically, you can set them directly on the `AWS` namespace:

```crystal
AWS.access_key_id = "AKIAOMGLOLWTFBBQ"
AWS.secret_access_key = "this is a secret, don't tell anyone"
AWS.region = "us-east-1"
```

There is no global default endpoint since those are specific to the service. If you wish to use a nonstandard endpoint (for example, to use DigitalOcean Spaces or a MinIO instance instead of S3), you must set it when instantiating the client.

To set the defaults via environment variables

| Property | Environment Variable |
|-|-|
| `access_key_id` | `AWS_ACCESS_KEY_ID` |
| `secret_access_key` | `AWS_SECRET_ACCESS_KEY` |
| `region` | `AWS_REGION` |
| `session_token` | `AWS_SESSION_TOKEN` |

Individual services and their APIs are documented below. All examples assume credentials are set globally and use default AWS endpoints for brevity.

Whenever feasible, method and argument names are snake-cased versions of those of the AWS REST API for ease of translating docs to application code. For example, with SQS, the `ReceiveMessage` API takes `QueueUrl`, `MaxNumberOfMessages`, and `WaitTimeSeconds` arguments. Your application would call `sqs.receive_message(queue_url: url, max_number_of_messages: 10, wait_time_seconds: 20)`. Additional method overrides are planned to make some of these API calls easier to read.

### S3

```crystal
require "aws/s3"

s3 = AWS::S3::Client.new

s3.list_buckets
s3.list_objects(bucket_name: "my-bucket")
s3.get_object(bucket_name: "my-bucket", key: "my-object")
s3.head_object(bucket_name: "my-bucket", key: "my-object")
s3.put_object(
  bucket_name: "my-bucket",
  key: "my-object",
  headers: HTTP::Headers {
    "Content-Type" => "image/jpeg",
    "Cache-Control" => "private, max-age=3600",
  },
  body: body, # String | IO - if you provide an IO, it MUST be rewindable!
)
s3.delete_object(bucket_name: "my-bucket", key: "my-object")

# Pre-signed URLs for direct uploads or serving <img/> tags for user-uploaded objects
s3.presigned_url("PUT", "my-bucket", "my-object", ttl: 10.minutes)
```

#### Multipart uploads

Objects larger than 5GB must be uploaded in parts, and multipart uploads are also the way to upload a stream whose size you don't know up front or that can't be rewound. The simplest way is to hand the client an `IO` and let it split it into parts:

```crystal
File.open("big-video.mp4") do |file|
  s3.multipart_upload(
    bucket_name: "my-bucket",
    key: "big-video.mp4",
    body: file,
    headers: HTTP::Headers{"Content-Type" => "video/mp4"},
    part_size: 16 * 1024 * 1024, # optional, defaults to the 5MB minimum
  )
end
```

Only one part is held in memory at a time, and if anything fails the upload is aborted so you aren't billed for orphaned parts.

If you need more control (for example, to upload parts concurrently or to resume an upload after a crash), the individual API calls are available, too:

```crystal
upload = s3.create_multipart_upload("my-bucket", "big-video.mp4", headers: HTTP::Headers{"Content-Type" => "video/mpeg"})

# Parts are numbered from 1 and may be uploaded in any order. Each part
# except the last must be at least 5MB. String, Bytes, and IO bodies are
# accepted; a non-`IO::Memory` IO must be rewindable and needs a
# Content-Length header.
parts = [
  s3.upload_part(upload, 1, first_chunk),
  s3.upload_part(upload, 2, second_chunk),
]

# If you lost track of which parts made it, S3 can tell you
s3.list_parts(upload).parts

s3.complete_multipart_upload(upload, parts)
# ... or, to give up and free the storage the parts are using:
s3.abort_multipart_upload(upload)
```

### SNS

```crystal
require "aws/sns"

sns = AWS::SNS::Client.new

topic = sns.create_topic("my-topic")

# Publishing a message - subject is optional
sns.publish topic_arn: topic.arn, message: "hello"
sns.publish topic_arn: topic.arn, message: "hello", subject: "MySubject"

# This endpoint requires an SQS client and a queue instance from that client. If
# you omit the client, it will create one for you.
sns.subscribe topic: topic.arn, queue: queue, sqs: sqs
```

### SQS

```crystal
require "aws/sqs"

sqs = AWS::SQS::Client.new

queue = sqs.create_queue(queue_name: "my-queue")

sqs.send_message(
  queue_url: queue.url,
  message_body: "hi",
)
msgs = sqs.receive_message(
  queue_url: queue.url,
  max_number_of_messages: 10,
  wait_time_seconds: 20,
)
msgs.each do |msg|
  process msg
end

sqs.delete_message_batch msgs
```

## Connection pooling

This shard maintains its own connection pools, so you can assign clients directly to a constant for use throughout your application:

```crystal
require "aws/s3"

S3 = AWS::S3::Client.new
```

You can use this client anywhere in your application by calling the methods listed above directly on the constant. There is no worry about collisions due to concurrent access. The client manages that transparently.

## Contributing

1. Fork it (<https://github.com/jgaskins/aws/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Jamie Gaskins](https://github.com/jgaskins) - creator and maintainer
