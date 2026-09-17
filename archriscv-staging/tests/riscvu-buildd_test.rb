# frozen_string_literal: true

require 'minitest/autorun'
require 'minitest/mock'
require 'stringio'
require 'webrick'
require 'open3'
require 'tmpdir'
load File.expand_path('../archriscv-buildd', __dir__)
load File.expand_path('../riscvu-buildd', __dir__)

class RiscvuBuilddTestAuth < GitHubAuth
  private

  def github_user(*)
    {'id' => 123, 'login' => 'AllowedUser'}
  end
end

class RiscvuBuilddTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir('riscvu-buildd-test-')
    @session_path = File.join(@directory, 'sessions', 'session.json')
    @requests = []
    @streams = []
    @server = WEBrick::HTTPServer.new(BindAddress: '127.0.0.1', Port: 0,
      Logger: WEBrick::Log.new(File::NULL), AccessLog: [])
    @server.mount_proc('/') do |req, res|
      @requests << [req.path, req.query]
      req.instance_variable_set(:@path, req.path.delete_prefix(@endpoint.path)) unless @endpoint.path.empty?
      if req.path.end_with?('/events')
        res['Content-Type'] = 'text/event-stream'
        res.body = @streams.shift || ''
      else
        @app.call(req, res)
      end
    end
    @endpoint = URI("http://127.0.0.1:#{@server.listeners.first.addr[1]}")
    @build = Build.new(id: 'test-build', command_line: 'test', argv: ['test'], pkgbase: 'test',
      log_path: File.join(@directory, 'build.log'), status: 'waiting_upload')
    @manager = Struct.new(:all_builds, :refresh_pending, :deferred_retries).new([@build], [], [])
    @manager.define_singleton_method(:enqueue) { |*, **| all_builds.first }
    @manager.define_singleton_method(:find) { |_| all_builds.first }
    @manager.define_singleton_method(:answer_upload) { |*, **| true }
    @manager.define_singleton_method(:stop_build) { |_| true }
    @output = StringIO.new
    @error = StringIO.new
    configure_auth
    @thread = Thread.new { @server.start }
    sign_in
  end

  def configure_auth
    @auth = RiscvuBuilddTestAuth.new(client_id: 'test', client_secret: 'test', public_url: @endpoint.to_s, editors: 'AllowedUser')
    @app = WebApp.new(@manager, auth: @auth)
  end

  def sign_in
    response = browser_request('GET', '/auth/github')
    state = URI.decode_www_form(URI(response['Location']).query).to_h.fetch('state')
    @browser_cookie = response['Set-Cookie'].split(';').first
    response = browser_request('GET', "/auth/github/callback?code=test&state=#{state}")
    @browser_cookie = response['Set-Cookie'].split(';').first
    @browser_csrf = browser_request('GET', '/auth/cli').body[/name="_csrf" value="([^"]+)"/, 1]
    code = browser_request('POST', '/auth/cli', {_csrf: @browser_csrf}).body[/aria-label="Terminal login code" value="([^"]+)"/, 1]
    client = RiscvuBuildd.new(endpoint: @endpoint, input: StringIO.new("#{code}\n"),
      error: @error, session_path: @session_path)
    raise 'test login failed' unless client.run(['--login']) == 0

    @client = RiscvuBuildd.new(endpoint: @endpoint, input: StringIO.new("yes\n"),
      output: @output, error: @error, session_path: @session_path)
    @requests.clear
  end

  def browser_request(method, path, params = {})
    req = (method == 'POST' ? Net::HTTP::Post : Net::HTTP::Get).new("#{@endpoint.path}#{path}")
    req['Cookie'] = @browser_cookie if @browser_cookie
    req.set_form_data(params) if method == 'POST'
    Net::HTTP.new(@endpoint.hostname, @endpoint.port, nil).request(req)
  end

  def run_process(environment = {})
    Open3.capture3(environment.merge('ARCHRISCV_BUILDD_URL' => @endpoint.to_s), RbConfig.ruby, '-e',
      'load ARGV.shift; exit RiscvuBuildd.new(session_path: ARGV.shift).run(ARGV)',
      File.expand_path('../riscvu-buildd', __dir__), @session_path, 'pkg')
  end

  def teardown
    @server&.shutdown
    @thread&.join
    FileUtils.remove_entry(@directory) if @directory
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
    output, error, result = run_process
    assert_equal 137, result.exitstatus, error
    assert_equal 'finished', output
  end

  def test_process_forwards_only_supported_environment_variables
    @streams << status(done: true, exit_status: 0)
    _, error, result = run_process('NOUPLOAD' => '1', 'SERVER' => 'builder@example-host',
      'KEEPCHROOT' => '1', 'UNRELATED_SECRET' => 'not-forwarded')
    assert_equal 0, result.exitstatus, error
    assert_equal({'command' => 'pkg', 'NOUPLOAD' => '1', 'SERVER' => 'builder@example-host', 'KEEPCHROOT' => '1'}, @requests.first.last)
  end

  def test_process_forwards_disabled_keep_chroot
    @streams << status(done: true, exit_status: 0)
    _, error, result = run_process('NOUPLOAD' => nil, 'SERVER' => nil, 'KEEPCHROOT' => '0')
    assert_equal 0, result.exitstatus, error
    assert_equal({'command' => 'pkg', 'KEEPCHROOT' => '0'}, @requests.first.last)
  end

  def test_process_preserves_empty_and_unset_environment_variables
    @streams << status(done: true, exit_status: 0)
    _, error, result = run_process('NOUPLOAD' => '', 'SERVER' => nil, 'KEEPCHROOT' => nil)
    assert_equal 0, result.exitstatus, error
    assert_equal({'command' => 'pkg', 'NOUPLOAD' => ''}, @requests.first.last)
  end

  def test_login_saves_private_endpoint_bound_credentials
    session = JSON.parse(File.read(@session_path))
    assert_equal 0o600, File.stat(@session_path).mode & 0o777
    assert_equal 0o700, File.stat(File.dirname(@session_path)).mode & 0o777
    assert_equal @endpoint.to_s, session['endpoint']
    assert_equal 'AllowedUser', session['login']
    refute_equal @browser_cookie, session['cookie']
    refute_includes @error.string, session['cookie']
    refute_includes @error.string, session['csrf']
  end

  def test_subpath_login_submission_upload_stop_and_events
    @endpoint.path = '/buildd'
    configure_auth
    sign_in
    @streams << status(status: 'waiting_upload', done: false) + status(done: true, exit_status: 0)
    assert_equal 0, @client.run(['pkg'])
    assert_includes @requests, ['/buildd/builds', {'command' => 'pkg'}]
    assert_includes @requests, ['/buildd/builds/test-build/upload', {'decision' => 'yes'}]
    assert_includes @requests, ['/buildd/builds/test-build/events', {'offset' => '0'}]
    @client.send(:post, '/builds/test-build/stop', {})
    assert_equal '/buildd/builds/test-build/stop', @requests.last.first
    assert_equal 0, @client.run(['--logout'])
    assert_equal '/buildd/auth/logout', @requests.last.first
    assert @requests.all? { |path, _| path.start_with?('/buildd/') }
  end

  def test_missing_expired_or_wrong_endpoint_credentials_do_not_submit
    original = JSON.parse(File.read(@session_path))
    [original.merge('expires_at' => Time.now.to_i - 1), original.merge('endpoint' => 'https://other.example')].each do |session|
      File.write(@session_path, JSON.generate(session))
      assert_match(/--login/, assert_raises(RuntimeError) { @client.run(['pkg']) }.message)
    end
    File.unlink(@session_path)
    assert_match(/--login/, assert_raises(RuntimeError) { @client.run(['pkg']) }.message)
    assert_empty @requests
  end

  def test_revoked_session_does_not_retry_submission
    session = JSON.parse(File.read(@session_path))
    @auth.instance_variable_get(:@sessions).delete(session['cookie'].split('=', 2).last)
    assert_match(/--login/, assert_raises(RuntimeError) { @client.run(['pkg']) }.message)
    assert_equal 1, @requests.count { |path, _| path == '/builds' }
  end

  def test_two_week_build_can_still_answer_upload_prompt
    @streams << status(status: 'waiting_upload', done: false) + status(done: true, exit_status: 0)
    original_watch = @client.method(:watch)
    @client.define_singleton_method(:watch) do
      Time.stub(:now, Time.now + 14 * 86_400) { original_watch.call }
    end
    assert_equal 0, @client.run(['pkg'])
    assert_includes @requests, ['/builds/test-build/upload', {'decision' => 'yes'}]
  end

  def test_logout_revokes_only_terminal_session_and_removes_local_credentials
    session = JSON.parse(File.read(@session_path))
    assert_equal 0, @client.run(['--logout'])
    refute File.exist?(@session_path)
    assert_includes browser_request('GET', '/').body, 'AllowedUser &middot; Editor'
    req = Net::HTTP::Post.new('/builds')
    req['Cookie'] = session['cookie']
    req['X-CSRF-Token'] = session['csrf']
    req.set_form_data(command: 'pkg')
    assert_equal '403', Net::HTTP.new(@endpoint.hostname, @endpoint.port, nil).request(req).code
  end

  def test_logout_also_clears_credentials_after_daemon_restart
    configure_auth
    assert_equal 0, @client.run(['--logout'])
    refute File.exist?(@session_path)
    assert_equal 0, @client.run(['--logout'])
  end

  def test_unsafe_urls_are_rejected_and_trailing_slashes_are_normalized
    %w[http://public.example https://user:pass@example.com https://example.com/../x https://example.com//x https://example.com?x=1 https://example.com/#x].each do |url|
      assert_raises(RuntimeError) { RiscvuBuildd.new(endpoint: URI(url), session_path: @session_path) }
    end
    client = RiscvuBuildd.new(endpoint: URI("#{@endpoint}/"), session_path: @session_path)
    assert_equal @endpoint.to_s, client.send(:session)['endpoint']
  end
end
