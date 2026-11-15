# frozen_string_literal: true

# Live tests against the real API. Needs RUNCONVERT_API_KEY; converts one small text file (about 2 credits).
require "minitest/autorun"
require "tmpdir"
require_relative "../lib/runconvert"

class LiveTest < Minitest::Test
  def setup
    skip "set RUNCONVERT_API_KEY to run live tests" if ENV["RUNCONVERT_API_KEY"].to_s.empty?
  end

  def test_me_and_operations
    assert RunConvert::Client.new.me["credits"]
    rc = RunConvert::Client.new(api_key: "")
    assert(rc.operations.for_input("TXT")["outputs"].any? { |o| o["format"] == "pdf" })
    refute_empty rc.operations.for_pair("mp4", "mp3")["engines"]
  end

  def test_convert_text_to_pdf
    Dir.mktmpdir do |dir|
      src = File.join(dir, "sdk-live-test.txt")
      File.write(src, "RunConvert Ruby SDK live test\nLine two\n\nCafé – 你好 – Привет\n")
      seen = []
      res = RunConvert::Client.new.convert(src, to: "pdf", out_dir: File.join(dir, "out"), tag: "sdk-ruby-live-test", timeout: 150) { |j| seen << j["status"] }
      pdf = File.binread(res.saved[0])
      assert_equal "%PDF-", pdf[0, 5]
      puts "\n  job #{res.job['id']}: #{seen.uniq.join(' → ')}, #{res.job['credits_used']} credit(s), #{pdf.bytesize} bytes"
    end
  end

  def test_bad_key
    e = assert_raises(RunConvert::Error) { RunConvert::Client.new(api_key: "rc_live_invalid", max_retries: 0).me }
    assert_equal 401, e.status
  end
end
