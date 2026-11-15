# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/runconvert"

class FakeClient < RunConvert::Client
  attr_reader :calls, :downloads

  def initialize(&handler)
    super(api_key: "rc_live_test", base_url: "https://api.example/v3", max_retries: 2)
    @handler = handler
    @calls = []
    @downloads = {}
  end

  def send_request(method, url, headers, body, _timeout)
    uri = URI(url)
    call = { method: method, path: uri.path.sub("/v3", ""), query: URI.decode_www_form(uri.query || "").to_h, headers: headers, body: body.respond_to?(:read) ? body.read : body }
    @calls << call
    @handler.call(call, @calls.size)
  end

  def stream_to(url, dest)
    return 404 unless @downloads.key?(url)

    File.binwrite(dest, @downloads[url])
    200
  end

  private

  def sleep(_seconds); end # no real waiting in tests
end

def ok(data, meta = nil)
  body = { success: true, data: data }
  body[:meta] = meta if meta
  RunConvert::Response.new(200, {}, JSON.generate(body))
end

def fail_with(status, code, message, headers = {})
  RunConvert::Response.new(status, headers, JSON.generate(success: false, error: { code: code, message: message }))
end

class RunConvertTest < Minitest::Test
  def setup
    # Jobs#wait sleeps through Kernel; make it instant.
    RunConvert::Jobs.class_eval { private def sleep(_s); end }
  end

  def test_key_and_envelope
    rc = FakeClient.new { ok("credits" => { "total_remaining" => 42 }) }
    assert_equal 42, rc.me["credits"]["total_remaining"]
    assert_equal "Bearer rc_live_test", rc.calls[0][:headers]["Authorization"]
    assert rc.calls[0][:headers]["User-Agent"].start_with?("runconvert-ruby/")
  end

  def test_api_error
    rc = FakeClient.new { fail_with(422, "BILLING_INSUFFICIENT_CREDITS", "Insufficient credits.") }
    e = assert_raises(RunConvert::Error) { rc.jobs.get("job_1") }
    assert_equal [422, "BILLING_INSUFFICIENT_CREDITS", "Insufficient credits."], [e.status, e.code, e.message]
  end

  def test_get_retries_503
    rc = FakeClient.new { |_c, n| n < 3 ? RunConvert::Response.new(503, {}, "busy") : ok("id" => "job_1", "status" => "finished") }
    assert_equal "finished", rc.jobs.get("job_1")["status"]
    assert_equal 3, rc.calls.size
  end

  def test_create_not_retried_after_500_but_retried_on_429
    rc = FakeClient.new { fail_with(500, "INTERNAL", "boom") }
    assert_raises(RunConvert::Error) { rc.jobs.create({}) }
    assert_equal 1, rc.calls.size
    rc2 = FakeClient.new { |_c, n| n == 1 ? fail_with(429, "ACTIVE_JOB_LIMIT_REACHED", "x", "Retry-After" => "0") : ok("id" => "job_1", "status" => "waiting") }
    assert_equal "job_1", rc2.jobs.create({})["id"]
    assert_equal 2, rc2.calls.size
    assert_equal "tasks", rc2.calls[1][:query]["include"]
  end

  def test_list_and_each
    rc = FakeClient.new { |c, _n| ok([{ "id" => "job_p#{c[:query]['page']}", "status" => "finished" }], { "page" => c[:query]["page"].to_i, "total_pages" => 2 }) }
    page = rc.jobs.list(status: "finished", tag: "x", page: 1, per_page: 1)
    assert_equal 2, page["meta"]["total_pages"]
    assert_equal "finished", rc.calls[0][:query]["filter[status]"]
    assert_equal %w[job_p1 job_p2], rc.jobs.each(per_page: 1).map { |j| j["id"] }
  end

  def test_wait
    states = %w[waiting processing finished]
    rc = FakeClient.new { |_c, n| ok("id" => "job_1", "status" => states[[n - 1, 2].min]) }
    seen = []
    assert_equal "finished", rc.jobs.wait("job_1") { |j| seen << j["status"] }["status"]
    assert_equal states, seen
  end

  def test_wait_failed_and_timeout
    failed = { "id" => "job_1", "status" => "error", "tasks" => [{ "name" => "c", "operation" => "convert", "status" => "error", "code" => "INVALID_DATA", "reason" => "INPUT_EMPTY", "message" => "The file is empty." }] }
    rc = FakeClient.new { ok(failed) }
    e = assert_raises(RunConvert::JobFailedError) { rc.jobs.wait("job_1") }
    assert_equal ["INPUT_EMPTY", "The file is empty."], [e.task["reason"], e.message]
    assert_equal "error", rc.jobs.wait("job_1", raise_on_error: false)["status"]
    slow = FakeClient.new { ok("id" => "job_1", "status" => "processing") }
    assert_raises(RunConvert::WaitTimeoutError) { slow.jobs.wait("job_1", timeout: 0.001) }
  end

  def test_delete_and_operations
    rc = FakeClient.new { |c, _n| c[:method] == :delete ? RunConvert::Response.new(204, {}, "") : ok("engines" => []) }
    assert_nil rc.jobs.delete("job_1")
    rc.operations.for_pair("MP4", "MP3")
    assert_equal({ "input" => "mp4", "output" => "mp3" }, rc.calls[1][:query])
  end

  def test_webhooks
    body = JSON.generate(event: "job.finished", job: { id: "job_1" })
    sig = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', 'whsec_x', body)}"
    assert RunConvert::Webhooks.verify(body, sig, "whsec_x")
    refute RunConvert::Webhooks.verify("#{body} ", sig, "whsec_x")
    refute RunConvert::Webhooks.verify(body, sig, "other")
    refute RunConvert::Webhooks.verify(body, "sha256=nothex", "whsec_x")
    refute RunConvert::Webhooks.verify(body, nil, "whsec_x")
    assert_equal "job_1", RunConvert::Webhooks.construct_event(body, sig, "whsec_x")["job"]["id"]
    assert_raises(ArgumentError) { RunConvert::Webhooks.construct_event(body, "sha256=#{'0' * 64}", "whsec_x") }
  end

  def test_convert_upload_wait_download
    polls = 0
    rc = FakeClient.new do |c, _n|
      if c[:method] == :post && c[:path] == "/jobs"
        ok("id" => "job_1", "status" => "waiting", "tasks" => [{ "name" => "import-1", "operation" => "import/direct/upload", "status" => "waiting", "upload_url" => "https://up.example/u/1?token=t" }])
      elsif c[:method] == :put
        RunConvert::Response.new(200, {}, "")
      else
        polls += 1
        ok("id" => "job_1", "status" => polls > 1 ? "finished" : "processing", "tasks" => [{ "name" => "export-1", "operation" => "export/url", "status" => "finished", "result" => { "files" => [{ "filename" => "notes.pdf", "url" => "https://dl.example/notes.pdf" }] } }])
      end
    end
    rc.downloads["https://dl.example/notes.pdf"] = "PDF"
    Dir.mktmpdir do |dir|
      src = File.join(dir, "notes.txt")
      File.write(src, "hello")
      res = rc.convert(src, to: "pdf", out_dir: File.join(dir, "out"), options: { page_size: "a4" })
      created = JSON.parse(rc.calls[0][:body])
      assert_equal({ "page_size" => "a4", "operation" => "convert", "input" => "import-1", "input_format" => "txt", "output_format" => "pdf" }, created["tasks"]["convert-1"])
      put = rc.calls.find { |c| c[:method] == :put }
      assert_equal ["notes.txt", "t", "hello"], [put[:query]["filename"], put[:query]["token"], put[:body]]
      assert_equal "PDF", File.read(res.saved[0])
    end
  end

  def test_convert_url_and_bad_input
    rc = FakeClient.new { |c, _n| ok("id" => "job_2", "status" => c[:method] == :get ? "finished" : "waiting") }
    rc.convert("https://example.com/a/talk.MP4?x=1", to: "mp3")
    tasks = JSON.parse(rc.calls[0][:body])["tasks"]
    assert_equal({ "operation" => "import/url", "source_url" => "https://example.com/a/talk.MP4?x=1" }, tasks["import-1"])
    assert_equal "mp4", tasks["convert-1"]["input_format"]
    assert_raises(ArgumentError) { rc.convert(StringIO.new("x"), to: "pdf") }
  end
end
