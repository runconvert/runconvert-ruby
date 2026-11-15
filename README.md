# RunConvert SDK for Ruby

> **Not published yet.** This SDK launches on RubyGems soon, so the install command below won't work until then. Updates: https://www.runconvert.com/sdks

Convert files between 240+ formats (3,000+ conversions) with the [RunConvert API](https://www.runconvert.com/docs):
documents, images, video, audio, ebooks, archives, fonts and CAD. Ruby 2.7+, standard library only.

```bash
gem install runconvert
```

```ruby
require "runconvert"

rc = RunConvert::Client.new # reads RUNCONVERT_API_KEY

# One call: upload, convert, wait, download.
rc.convert("report.docx", to: "pdf", out_dir: "out").saved # => ["out/report.pdf"]
```

Get an API key in **Dashboard → API Keys** on [runconvert.com](https://www.runconvert.com). Keep keys on the server.

## Convert

```ruby
# From a URL (imported by RunConvert, nothing to upload)
rc.convert("https://example.com/talk.mp4", to: "mp3", options: { audioBitrate: "192k" })

# From an IO: give a filename (or from:)
rc.convert(File.open("photo.heic", "rb"), to: "jpg", out_dir: "out")

# Progress and a time limit (seconds)
rc.convert("movie.mov", to: "mp4", out_dir: "out", timeout: 600) { |job| puts job["status"] }
```

## Jobs with your own tasks

```ruby
# Merge two PDFs
job = rc.jobs.create({
  "a" => { operation: "import/url", source_url: "https://example.com/cover.pdf" },
  "b" => { operation: "import/url", source_url: "https://example.com/body.pdf" },
  "merge" => { operation: "convert", input: %w[a b], input_format: "pdf", output_format: "pdf" },
  "export" => { operation: "export/url", input: "merge" }
}, tag: "merge")
done = rc.jobs.wait(job["id"])
RunConvert::Jobs.exported_files(done).each { |f| rc.files.download(f, "out") }

# Upload your own file
job = rc.jobs.create({
  "upload" => { operation: "import/direct/upload" },
  "convert" => { operation: "convert", input: "upload", input_format: "png", output_format: "webp", image_quality: 80 },
  "export" => { operation: "export/url", input: "convert" }
})
rc.files.upload(job["tasks"].find { |t| t["name"] == "upload" }, "image.png")
```

| Method | What it does |
|---|---|
| `rc.jobs.create / get / list / each / wait / cancel / delete` | Jobs, with paging (`list`, `each`) and polling (`wait`) |
| `rc.files.upload(task, path_or_io)` / `download(file, dir)` | Transfers |
| `rc.operations.list(category:)` / `for_input("mp4")` / `for_pair("mp4", "mp3")` | Formats, targets, engines (no key needed) |
| `rc.me` | Account, team and credit balance |

## Webhooks

```ruby
post "/webhooks/runconvert" do # Sinatra
  body = request.body.read
  event = RunConvert::Webhooks.construct_event(body, request.env["HTTP_X_RUNCONVERT_SIGNATURE"], ENV["RUNCONVERT_WEBHOOK_SECRET"])
  puts "done #{event['job']['id']}" if event["event"] == "job.finished"
  200
rescue ArgumentError
  400
end
```

## Errors

| Error | When |
|---|---|
| `RunConvert::Error` | The API said no: `status`, `code` (e.g. `BILLING_INSUFFICIENT_CREDITS`), `message` |
| `RunConvert::JobFailedError` | The job ended in `error`; `task` has `code`, `reason`, `message` |
| `RunConvert::WaitTimeoutError` | `wait` ran past its `timeout` |

Network errors, `429` and `5xx` are retried twice with backoff (`max_retries:`). Creating a job is only
retried when the request never reached the API, so a job is never created twice.

## Development

```bash
ruby -Ilib test/test_unit.rb                               # no network
RUNCONVERT_API_KEY=rc_live_… ruby -Ilib test/test_live.rb  # real API, about 2 credits
```

## License

MIT
