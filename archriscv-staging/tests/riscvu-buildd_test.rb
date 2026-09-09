# frozen_string_literal: true

require 'minitest/autorun'
require 'stringio'
require 'webrick'
require 'open3'
load File.expand_path('../riscvu-buildd', __dir__)

class RiscvuBuilddTest < Minitest::Test
  def setup
    @requests = []
    @streams = []
    @server = WEBrick::HTTPServer.new(BindAddress: '127.0.0.1', Port: 0,
      Logger: WEBrick::Log.new(File::NULL), AccessLog: [])
    @server.mount_proc('/') do |req, res|
      @requests << [req.path, req.query]
      if req.path == '/builds'
        res.status = 201
        res.body = JSON.generate(id: 'test-build')
      elsif req.path.end_with?('/events')
        res['Content-Type'] = 'text/event-stream'
        res.body = @streams.shift || ''
      else
        res.status = 303
        res['Location'] = '/'
      end
    end
    @thread = Thread.new { @server.start }
    @endpoint = URI("http://127.0.0.1:#{@server.listeners.first.addr[1]}")
    @output = StringIO.new
    @client = RiscvuBuildd.new(endpoint: @endpoint, input: StringIO.new("yes\n"),
      output: @output, error: StringIO.new)
  end

  def teardown
    @server&.shutdown
    @thread&.join
  end

  def log(text, offset)
    "event: log\nid: #{offset}\ndata: #{JSON.generate(text)}\n\n"
  end

  def status(**values)
    "event: status\ndata: #{JSON.generate(values)}\n\n"
  end

  def test_arguments_output_prompt_and_exact_failure_status
    @streams << log("\e[32mbuild output\e[0m\r\nUpload log? [y/N] ", 52) +
      status(status: 'waiting_upload', done: false) +
      log("yes\r\nfinal output\r\n", 72) + status(done: true, exit_status: 42)
    assert_equal 42, @client.run(['pkg:nocheck', '--', 'argument with spaces'])
    assert_equal ['pkg:nocheck', '--', 'argument with spaces'],
      Shellwords.split(@requests.first.last.fetch('command'))
    assert_includes @requests, ['/builds/test-build/upload', {'decision' => 'yes'}]
    assert_equal "\e[32mbuild output\e[0m\r\nUpload log? [y/N] yes\r\nfinal output\r\n", @output.string
  end

  def test_reconnect_resumes_at_last_offset
    @streams << log('first', 5)
    @streams << log('last', 9) + status(done: true, exit_status: 0)
    assert_equal 0, @client.run(['pkg'])
    assert_equal 'firstlast', @output.string
    assert_equal %w[0 5], @requests.select { |path, _| path.end_with?('/events') }.map { |_, query| query['offset'] }
  end

  def test_missing_exit_status_is_an_error
    @streams << status(done: true, exit_status: nil)
    assert_raises(RuntimeError) { @client.run(['pkg']) }
  end

  def test_interrupt_requests_remote_stop_and_keeps_watching
    @streams << status(done: true, exit_status: 130)
    @client.define_singleton_method(:watch) do
      unless @interrupted
        @interrupted = true
        raise Interrupt
      end
      super()
    end
    assert_equal 130, @client.run(['pkg'])
    assert_includes @requests, ['/builds/test-build/stop', {}]
  end

  def test_process_exit_code
    @streams << log('finished', 8) + status(done: true, exit_status: 137)
    output, error, result = Open3.capture3({'ARCHRISCV_BUILDD_URL' => @endpoint.to_s},
      RbConfig.ruby, File.expand_path('../riscvu-buildd', __dir__), 'pkg')
    assert_equal 137, result.exitstatus, error
    assert_equal 'finished', output
  end

  def test_process_forwards_only_supported_environment_variables
    @streams << status(done: true, exit_status: 0)
    _, error, result = Open3.capture3({'ARCHRISCV_BUILDD_URL' => @endpoint.to_s,
      'NOUPLOAD' => '1', 'SERVER' => 'builder@example-host', 'UNRELATED_SECRET' => 'not-forwarded'},
      RbConfig.ruby, File.expand_path('../riscvu-buildd', __dir__), 'pkg')
    assert_equal 0, result.exitstatus, error
    assert_equal({'command' => 'pkg', 'NOUPLOAD' => '1', 'SERVER' => 'builder@example-host'}, @requests.first.last)
  end

  def test_process_preserves_empty_and_unset_environment_variables
    @streams << status(done: true, exit_status: 0)
    _, error, result = Open3.capture3({'ARCHRISCV_BUILDD_URL' => @endpoint.to_s,
      'NOUPLOAD' => '', 'SERVER' => nil},
      RbConfig.ruby, File.expand_path('../riscvu-buildd', __dir__), 'pkg')
    assert_equal 0, result.exitstatus, error
    assert_equal({'command' => 'pkg', 'NOUPLOAD' => ''}, @requests.first.last)
  end
end
