# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "uri"
require "fileutils"

# Official RunConvert SDK for Ruby: convert files between 240+ formats.
#
#   rc = RunConvert::Client.new # reads RUNCONVERT_API_KEY
#   rc.convert("report.docx", to: "pdf", out_dir: "out").saved # => ["out/report.pdf"]
module RunConvert
  VERSION = "0.1.0" # x-release-please-version
  DEFAULT_BASE_URL = "https://api.runconvert.com/v3"

  # The API said no: {"success": false, "error": {"code", "message"}}. New codes can appear,
  # so branch on #status for anything you don't recognise.
  class Error < StandardError
    attr_reader :status, :code, :body

    def initialize(message, status: 0, code: "", body: nil)
      super(message)
      @status = status
      @code = code.to_s
      @body = body
    end
  end

  # The job ended with status "error". #task is the first failed task (code, reason, message).
  class JobFailedError < Error
    attr_reader :job, :task

    def initialize(job, task = nil)
      @job = job
      @task = task
      super((task && task["message"]).to_s.empty? ? "Job #{job['id']} failed" : task["message"], code: task ? task["code"].to_s : "", body: job)
    end
  end

  # Client::Jobs#wait gave up before the job reached "finished" or "error".
  class WaitTimeoutError < Error
    attr_reader :job

    def initialize(job, timeout)
      @job = job
      super("Job #{job['id']} still #{job['status']} after #{timeout.round}s", code: "WAIT_TIMEOUT", body: job)
    end
  end

  # Result of Client#convert.
  ConvertResult = Struct.new(:job, :files, :saved, keyword_init: true)

  # A raw HTTP exchange (internal).
  Response = Struct.new(:status, :headers, :body)

  # Webhook signature checks: "sha256=" + hex HMAC-SHA256 of the raw body, keyed with the secret.
  module Webhooks
    module_function

    # True when the X-RunConvert-Signature header matches the raw body.
    def verify(raw_body, signature, secret)
      return false if signature.nil? || signature.empty? || secret.nil? || secret.empty?

      given = signature.strip.downcase.sub(/\Asha256=/, "")
      return false unless given.match?(/\A[0-9a-f]{64}\z/)

      expected = OpenSSL::HMAC.hexdigest("SHA256", secret, raw_body.to_s)
      secure_compare(expected, given)
    end

    # Constant-time comparison of two equal-length strings (OpenSSL's own needs Ruby 3.0+).
    def secure_compare(a, b)
      return OpenSSL.fixed_length_secure_compare(a, b) if OpenSSL.respond_to?(:fixed_length_secure_compare)
      return false unless a.bytesize == b.bytesize

      diff = 0
      a.bytes.zip(b.bytes) { |x, y| diff |= x ^ y }
      diff.zero?
    end

    # Verifies the signature, then parses the event. Raises ArgumentError if it doesn't match.
    def construct_event(raw_body, signature, secret)
      raise ArgumentError, "Invalid RunConvert webhook signature" unless verify(raw_body, signature, secret)

      JSON.parse(raw_body)
    end
  end

  # The RunConvert API client.
  class Client
    RETRY_STATUS = [408, 425, 429, 500, 502, 503, 504].freeze

    attr_reader :jobs, :operations, :files, :base_url

    # api_key: defaults to ENV["RUNCONVERT_API_KEY"]. timeout: per API request, seconds.
    def initialize(api_key: nil, base_url: DEFAULT_BASE_URL, timeout: 60, max_retries: 2)
      @api_key = api_key.nil? ? ENV.fetch("RUNCONVERT_API_KEY", "") : api_key
      @base_url = base_url.sub(%r{/+\z}, "")
      @timeout = timeout
      @max_retries = max_retries
      @user_agent = "runconvert-ruby/#{VERSION} ruby/#{RUBY_VERSION}"
      @jobs = Jobs.new(self)
      @operations = Operations.new(self)
      @files = Files.new(self)
    end

    attr_reader :user_agent

    def webhooks
      Webhooks
    end

    # The account, team and credit balance behind the API key.
    def me
      request(:get, "/me")
    end

    # Converts one file in one call: upload (or import a URL), convert, wait, download.
    # file is a path, an http(s) URL or an IO. Engine options go in options:.
    def convert(file, to:, from: nil, options: {}, out_dir: nil, filename: nil, tag: nil, timeout: nil, &on_update)
      is_url = file.is_a?(String) && file.match?(%r{\Ahttps?://}i)
      name = filename || (is_url ? URI(file).path : (file.is_a?(String) ? file : (file.respond_to?(:path) ? file.path : "")))
      source = (from || File.extname(name.to_s).delete_prefix(".")).downcase
      raise ArgumentError, 'Can\'t tell the source format: pass from: "mp4" or filename: "video.mp4"' if source.empty?

      import = is_url ? { operation: "import/url", source_url: file } : { operation: "import/direct/upload" }
      convert_task = options.merge(operation: "convert", input: "import-1", input_format: source, output_format: to.to_s.downcase.delete_prefix("."))
      job = jobs.create({ "import-1" => import, "convert-1" => convert_task, "export-1" => { operation: "export/url", input: "convert-1" } }, tag: tag)
      unless is_url
        task = (job["tasks"] || []).find { |t| t["name"] == "import-1" }
        raise Error.new("The job has no upload URL", body: job) unless task && task["upload_url"]

        files.upload(task, file, filename: File.basename(name.to_s))
      end
      job = jobs.wait(job["id"], timeout: timeout, &on_update)
      exported = Jobs.exported_files(job)
      saved = out_dir ? exported.map { |f| files.download(f, out_dir) } : []
      ConvertResult.new(job: job, files: exported, saved: saved)
    end

    # Sends a request and returns "data" (internal; use the resource methods).
    def request(method, path, body: nil, query: nil)
      request_raw(method, path, body: body, query: query).first
    end

    # Like #request, returning [data, meta].
    def request_raw(method, path, body: nil, query: nil)
      params = (query || {}).reject { |_, v| v.nil? || v == "" }
      url = @base_url + path + (params.empty? ? "" : "?#{URI.encode_www_form(params)}")
      headers = { "Accept" => "application/json", "User-Agent" => @user_agent }
      headers["Authorization"] = "Bearer #{@api_key}" unless @api_key.empty?
      payload = nil
      unless body.nil?
        headers["Content-Type"] = "application/json"
        payload = JSON.generate(body)
      end
      # POST /jobs is only repeated when it never reached the server: a job is never created twice.
      idempotent = method != :post || path.end_with?("/cancel")
      attempt = 0
      loop do
        begin
          res = send_request(method, url, headers, payload, @timeout)
        rescue Timeout::Error, SystemCallError, IOError, SocketError, OpenSSL::SSL::SSLError => e
          reached = e.is_a?(Timeout::Error)
          if attempt < @max_retries && (idempotent || !reached)
            attempt += 1
            sleep(backoff(attempt))
            next
          end
          raise Error, "Request to RunConvert failed: #{e.message}"
        end
        if RETRY_STATUS.include?(res.status) && attempt < @max_retries && (idempotent || res.status == 429)
          attempt += 1
          sleep(retry_after(res) || backoff(attempt))
          next
        end
        return [nil, {}] if res.status == 204

        data = begin
          res.body.to_s.empty? ? nil : JSON.parse(res.body)
        rescue JSON::ParserError
          nil
        end
        if res.status >= 400 || (data.is_a?(Hash) && data["success"] == false)
          err = data.is_a?(Hash) ? (data["error"] || {}) : {}
          raise Error.new(err["message"] || "RunConvert API error (HTTP #{res.status})", status: res.status, code: err["code"].to_s, body: data || res.body)
        end
        data ||= {}
        return [data["data"], data["meta"] || {}]
      end
    end

    # One HTTP exchange; overridden in tests. body may be a String or an IO (streamed).
    def send_request(method, url, headers, body, timeout)
      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      if timeout
        http.open_timeout = 15
        http.read_timeout = timeout
        http.write_timeout = timeout if http.respond_to?(:write_timeout=)
      end
      klass = { get: Net::HTTP::Get, post: Net::HTTP::Post, put: Net::HTTP::Put, delete: Net::HTTP::Delete }.fetch(method)
      req = klass.new(uri.request_uri, headers)
      if body.respond_to?(:read)
        req.body_stream = body
      elsif body
        req.body = body
      end
      res = http.request(req)
      Response.new(res.code.to_i, res.each_header.to_h, res.body.to_s)
    end

    # Downloads url into dest; returns the status. Overridden in tests.
    def stream_to(url, dest)
      uri = URI(url)
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
        http.request(Net::HTTP::Get.new(uri.request_uri, "User-Agent" => @user_agent)) do |res|
          return res.code.to_i if res.code.to_i >= 300

          File.open(dest, "wb") { |f| res.read_body { |chunk| f.write(chunk) } }
          return res.code.to_i
        end
      end
    end

    private

    def backoff(attempt)
      [8.0, 0.5 * (2**(attempt - 1))].min * (0.75 + rand / 2)
    end

    def retry_after(res)
      value = res.headers.find { |k, _| k.to_s.casecmp("retry-after").zero? }&.last
      seconds = value.to_f
      seconds.positive? ? [seconds, 30.0].min : nil
    end
  end

  # Create, read, wait for and stop jobs.
  class Jobs
    def initialize(client)
      @c = client
    end

    # Creates a job from named tasks. Returned with its tasks (an upload task carries "upload_url").
    def create(tasks, tag: nil, metadata: nil)
      body = { tasks: tasks }
      body[:tag] = tag if tag
      body[:metadata] = metadata if metadata
      @c.request(:post, "/jobs", body: body, query: { include: "tasks" })
    end

    # A job with its tasks.
    def get(id)
      @c.request(:get, "/jobs/#{escape(id)}", query: { include: "tasks" })
    end

    # One page of jobs, newest first: {"data" => [...], "meta" => {...}}.
    def list(status: nil, tag: nil, page: nil, per_page: nil, include_tasks: false)
      data, meta = @c.request_raw(:get, "/jobs", query: { "filter[status]" => status, "filter[tag]" => tag, page: page, per_page: per_page, include: include_tasks ? "tasks" : nil })
      { "data" => data || [], "meta" => meta }
    end

    # Every job, page by page: rc.jobs.each(status: "finished") { |job| ... }
    def each(**filters)
      return enum_for(:each, **filters) unless block_given?

      page = 1
      loop do
        result = list(page: page, **filters)
        result["data"].each { |j| yield j }
        total = result["meta"]["total_pages"]
        break if result["data"].empty? || (total && page >= total)

        page += 1
      end
    end

    # Cancels pending tasks; credits for unfinished tasks are refunded.
    def cancel(id)
      @c.request(:post, "/jobs/#{escape(id)}/cancel")
    end

    # Deletes a job.
    def delete(id)
      @c.request(:delete, "/jobs/#{escape(id)}")
      nil
    end

    # Polls until "finished" or "error" (0.7 s, slowing to 3 s). Raises JobFailedError for a failed job.
    def wait(id, timeout: nil, raise_on_error: true)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      delay = 0.7
      loop do
        job = get(id)
        yield job if block_given?
        return job if job["status"] == "finished"
        if job["status"] == "error"
          return job unless raise_on_error

          raise JobFailedError.new(job, (job["tasks"] || []).find { |t| t["status"] == "error" })
        end
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        raise WaitTimeoutError.new(job, timeout) if timeout && elapsed + delay > timeout

        sleep(delay)
        delay = [delay + 0.3, 3.0].min
      end
    end

    # The files produced by the job's export/url tasks.
    def self.exported_files(job)
      (job["tasks"] || []).select { |t| t["operation"] == "export/url" }.flat_map { |t| (t["result"] || {})["files"] || [] }
    end

    private

    def escape(id)
      URI.encode_www_form_component(id.to_s)
    end
  end

  # Formats, targets, engines and options. Public: no key needed.
  class Operations
    def initialize(client)
      @c = client
    end

    # Every input format with its targets.
    def list(category: nil)
      @c.request(:get, "/operations", query: { category: category })
    end

    # What one format converts to, with credit costs.
    def for_input(input)
      @c.request(:get, "/operations", query: { input: input.to_s.downcase })
    end

    # Engines for one conversion and the options a convert task accepts.
    def for_pair(input, output)
      @c.request(:get, "/operations", query: { input: input.to_s.downcase, output: output.to_s.downcase })
    end
  end

  # Uploads to import/direct/upload tasks and downloads of results.
  class Files
    def initialize(client)
      @c = client
    end

    # PUTs a path or IO to the task's "upload_url" before its deadline.
    def upload(task, file, filename: nil)
      upload_url = task.is_a?(String) ? task : task["upload_url"]
      raise ArgumentError, "This task has no upload_url (is it an import/direct/upload task?)" if upload_url.to_s.empty?

      filename ||= File.basename(file) if file.is_a?(String)
      uri = URI(upload_url)
      query = URI.decode_www_form(uri.query || "").to_h
      query["filename"] = filename if filename
      uri.query = URI.encode_www_form(query)
      headers = { "Content-Type" => "application/octet-stream", "User-Agent" => @c.user_agent }
      res = if file.is_a?(String)
              File.open(file, "rb") do |io|
                headers["Content-Length"] = File.size(file).to_s
                @c.send_request(:put, uri.to_s, headers, io, nil)
              end
            else
              headers["Content-Length"] = file.size.to_s if file.respond_to?(:size)
              @c.send_request(:put, uri.to_s, headers, file, nil)
            end
      raise Error.new("Upload failed (HTTP #{res.status}): #{res.body.to_s[0, 300]}", status: res.status) if res.status >= 300

      nil
    end

    # Saves a result file (or a URL) into dir keeping its name; returns the path.
    def download(file, dir, filename: nil)
      url = file.is_a?(String) ? file : file["url"]
      name = filename || (file.is_a?(String) ? File.basename(URI(url).path) : file["filename"])
      FileUtils.mkdir_p(dir)
      dest = File.join(dir, File.basename(name))
      status = @c.stream_to(url, dest)
      raise Error.new("Download failed (HTTP #{status})", status: status) if status >= 300

      dest
    end
  end
end
