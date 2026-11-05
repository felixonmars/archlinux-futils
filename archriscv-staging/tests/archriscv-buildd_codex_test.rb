# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'minitest/mock'
require 'stringio'
require 'tmpdir'

CODEX_TEST_ROOT = Dir.mktmpdir('buildd-codex-test-')
ENV['ARCHRISCV_BUILDD_STATE_DIR'] = CODEX_TEST_ROOT
ENV['ARCHRISCV_BUILDD_LOG_DIR'] = File.join(CODEX_TEST_ROOT, 'logs')
ENV['ARCHRISCV_BUILDD_BUILD_COMMAND'] = File.join(CODEX_TEST_ROOT, 'fake-build')
ENV['ARCHRISCV_BUILDD_WORKDIR'] = CODEX_TEST_ROOT
load File.expand_path('../archriscv-buildd', __dir__)
Object.send(:remove_const, :OVERLAY_REPO)
OVERLAY_REPO = CODEX_TEST_ROOT
Minitest.after_run { FileUtils.remove_entry(CODEX_TEST_ROOT) }

class CodexReplayTest < Minitest::Test
  IDLE = "\e[?2026h\e[39m\e[49m\e[0m\e[28;3H\e[?25h\e[?2026l".b

  def test_reduces_long_idle_runs_but_keeps_real_output
    replay = CodexReplay.new
    assert_equal IDLE, replay.compact((IDLE + "\e]2;working\a") * 10_000)
    ["text", "\e[1A", "\e[K", "\e[2;20r", "\e7", "\e[?6h"].each do |change|
      assert_equal change + IDLE, replay.compact(change + IDLE * 2)
    end
    replay.resize
    assert_equal IDLE, replay.compact(IDLE * 2)
  end

  def test_keeps_relative_redraws_printing_and_non_title_terminal_strings
    relative = "\e[?2026h\e[1A\e[?2026l"
    printing = "\e[?2026h\e[1;1Htext\e[?2026l"
    strings = ["\e]8;;https://example.com\a", "\ePtext #{IDLE}\e\\", "\e]9;#{IDLE}\a",
      "\e]2;aborted\x18visible\a", "\e]0;aborted\x1avisible\a", "\e]2;aborted\e[2J\a"]
    data = relative * 3 + printing * 3 + strings.join
    assert_equal data, CodexReplay.new.compact(data)
  end

  def test_chunk_boundaries_preserve_unfinished_sequences_and_utf8
    [IDLE, "\e]2;⠋ title\a".b, "\eP#{IDLE}\e\\".b, "\e[31m", "café".b].each do |sequence|
      (1...sequence.bytesize).each do |split|
        replay = CodexReplay.new
        first = sequence.byteslice(0, split)
        assert_equal first, replay.compact(first)
        # An already-emitted prefix must never be removed or duplicated.
        assert_equal sequence.byteslice(split..), replay.compact(sequence.byteslice(split..))
      end
    end
    replay = CodexReplay.new
    unfinished = "\e]2;#{'x' * 65_536}"
    assert_equal unfinished, replay.compact(unfinished)
    assert_equal "\a#{IDLE * 2}", replay.compact("\a#{IDLE * 2}")
    replay = CodexReplay.new
    assert_equal "\e]2;", replay.compact("\e]2;")
    replay.resize
    assert_equal "title\a#{IDLE}", replay.compact("title\a#{IDLE * 2}")
  end
end

class CodexTestService
  attr_reader :pids, :starts
  attr_accessor :failure

  def initialize(mode)
    @mode = mode
    @pids = {}
    @starts = []
  end

  def start(entry, directory)
    raise failure if failure

    @starts << entry.id
    @pids[entry.id] = Process.spawn(RbConfig.ruby, File.expand_path('../archriscv-buildd', __dir__),
      @mode, directory, out: File::NULL, err: File::NULL)
  end

  def active?(entry)
    pid = @pids[entry.id]
    return false unless pid
    return true unless Process.waitpid(pid, Process::WNOHANG)

    @pids.delete(entry.id)
    false
  rescue Errno::ECHILD
    @pids.delete(entry.id)
    false
  end

  def stop(entry)
    return unless active?(entry)

    Process.kill('TERM', @pids.fetch(entry.id))
    Process.waitpid(@pids.delete(entry.id))
  end

  def cleanup
    @pids.keys.each { |id| stop(Struct.new(:id).new(id)) }
  end
end

class CodexIntegrationTest < Minitest::Test
  def setup
    FileUtils.rm_rf(Dir.children(CODEX_TEST_ROOT).map { |name| File.join(CODEX_TEST_ROOT, name) })
    @old_path = ENV.fetch('PATH')
    FileUtils.mkdir_p(File.join(CODEX_TEST_ROOT, 'bin'))
    ENV['PATH'] = "#{CODEX_TEST_ROOT}/bin:#{@old_path}"
    File.write(File.join(CODEX_TEST_ROOT, 'bin/codex'), <<~'RUBY')
      #!/usr/bin/env ruby
      require 'io/console'
      require 'timeout'
      STDOUT.sync = true
      STDIN.raw!
      print "\e[6n"
      cursor = +''
      Timeout.timeout(5) { cursor << STDIN.readpartial(4096) until cursor.match?(/\e\[\d+;\d+R/) }
      print "\e]2;packages\a"
      puts "\e[31mREADY café\e[0m"
      input = +''
      loop do
        chunk = STDIN.readpartial(4096)
        input << chunk
        print "\e]2;⠋ packages\e\\" if chunk.include?('work')
        print "\e]0;[ ! ] Action Required | packages\a" if chunk.include?('approve')
        print "\e]2;packages\a" if chunk.include?('idle')
        puts "INPUT=#{input.inspect}"
        puts "SIZE=#{STDIN.winsize.join('x')}" if input.include?('size')
        exit 7 if input.include?('/exit')
      end
    RUBY
    File.write(BUILD_COMMAND, <<~'RUBY')
      #!/usr/bin/env ruby
      puts "overlay=#{ENV['SWITCHBRANCH']} command=#{ARGV.first}"
      exit(ENV['SWITCHBRANCH'] == '1' ? 0 : 1)
    RUBY
    File.chmod(0o755, File.join(CODEX_TEST_ROOT, 'bin/codex'), BUILD_COMMAND)
    @build_service = CodexTestService.new('--worker')
    @codex_service = CodexTestService.new('--codex-worker')
    @manager = BuildManager.new(service: @build_service, codex_service: @codex_service)
    @auth = GitHubAuth.new(editors: 'tester', public_url: 'https://buildd.example/buildd/')
    @app = WebApp.new(@manager, auth: @auth)
  end

  def teardown
    @manager&.shutdown
    @codex_service&.cleanup
    @build_service&.cleanup
    ENV['PATH'] = @old_path
  end

  def wait_for
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 8
    loop do
      result = yield
      return result if result
      flunk 'timed out waiting for worker' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.02
    end
  end

  def failed_build(name = 'example', **options)
    build = @manager.enqueue(name, **options)
    wait_for { @manager.find(build.id).status == 'failed' }
    @manager.find(build.id)
  end

  def start_codex(build = failed_build, **options)
    session = @manager.spawn_codex(build.id, **options)
    wait_for { File.socket?(File.join(CODEX_TEST_ROOT, 'codex', session.id, 'terminal.sock')) }
    @manager.codex_input(session.id, 'action' => 'resize', 'rows' => 30, 'cols' => 100)
    wait_for { @manager.codex_output(session.id, 0)[:data].unpack1('m0').include?("\e[6n") }
    input(session, "\e[1;1R")
    wait_for { @manager.codex_output(session.id, 0)[:data].unpack1('m0').include?('READY') }
    session
  end

  def input(session, text)
    @manager.codex_input(session.id, 'action' => 'input', 'data' => [text].pack('m0'))
  end

  def request(method, path, editor: true, csrf: true, params: {}, body: nil, encoding: nil)
    body ||= URI.encode_www_form(params)
    headers = "Host: buildd.example\r\nContent-Type: #{body.start_with?('{') ? 'application/json' : 'application/x-www-form-urlencoded'}\r\nContent-Length: #{body.bytesize}\r\n"
    headers += "X-CSRF-Token: test-csrf\r\n" if csrf
    headers += "Accept-Encoding: #{encoding}\r\n" if encoding
    req = WEBrick::HTTPRequest.new(WEBrick::Config::HTTP)
    req.parse(StringIO.new("#{method} #{path} HTTP/1.1\r\n#{headers}\r\n#{body}"))
    res = WEBrick::HTTPResponse.new(WEBrick::Config::HTTP)
    @auth.stub(:session, editor ? {login: 'tester', csrf: 'test-csrf'} : nil) { @app.call(req, res) }
    res
  end

  def test_real_pty_input_resize_binary_output_and_reconnect
    session = start_codex(rebuild: false)
    output = @manager.codex_output(session.id, 0)
    assert_includes output[:data].unpack1('m0'), "\e[31mREADY café\e[0m".b
    @manager.codex_input(session.id, 'action' => 'resize', 'rows' => 45, 'cols' => 123)
    input(session, "size café\r")
    wait_for { @manager.codex_output(session.id, output[:offset])[:data].unpack1('m0').include?('SIZE=45x123') }
    @manager.shutdown
    @manager = BuildManager.new(service: @build_service, codex_service: @codex_service)
    @manager.start
    assert_equal 'running', @manager.codex_sessions.first.status
    assert_equal [session.id], @codex_service.starts
    assert_includes @manager.codex_output(session.id, 0)[:data].unpack1('m0'), 'SIZE=45x123'
    input(session, '/exit')
    wait_for { @manager.codex_sessions.first.status == 'exited' }
    assert_equal 7, @manager.codex_sessions.first.exit_status
    assert_equal 1, @manager.all_builds.size
  end

  def test_recorded_frames_preserve_bytes_and_resize_order_after_restart
    session = start_codex(rebuild: false)
    @manager.codex_input(session.id, 'action' => 'resize', 'rows' => 45, 'cols' => 123)
    input(session, "size\r")
    wait_for { @manager.codex_output(session.id, 0)[:data].unpack1('m0').include?('SIZE=45x123') }
    frames = @manager.codex_frames(session.id, 0)
    refute frames[:legacy]
    refute frames[:more]
    assert_equal({'cols' => 100, 'rows' => 30}, frames[:events].first)
    assert_includes frames[:events], {'cols' => 123, 'rows' => 45}
    bytes = frames[:events].filter_map { |event| event['data']&.unpack1('m0') }.join
    assert_equal File.binread(File.join(CODEX_TEST_ROOT, 'codex', session.id, 'output')), bytes.b
    assert_empty @manager.codex_frames(session.id, frames[:cursor])[:events]
    assert_raises(ArgumentError) { @manager.codex_frames(session.id, -1) }
    @manager.shutdown
    @manager = BuildManager.new(service: @build_service, codex_service: @codex_service)
    @manager.start
    assert_equal frames, @manager.codex_frames(session.id, 0)
    input(session, '/exit')
    wait_for { @manager.codex_sessions.first.status == 'exited' }
    assert_equal 'exited', @manager.codex_frames(session.id, 0)[:status]
  end

  def test_activity_follows_titles_through_work_approval_idle_and_reconnect
    session = start_codex(rebuild: false)
    assert_equal 'waiting_for_input', @manager.codex_sessions.first.activity
    input(session, 'work')
    wait_for { @manager.codex_sessions.first.activity == 'working' }
    output = File.join(CODEX_TEST_ROOT, 'codex', session.id, 'output')
    File.utime(Time.now - 3600, Time.now - 3600, output)
    assert_equal 'working', @manager.codex_sessions.first.activity, 'quiet output is not evidence that Codex needs input'
    assert_equal 'working', @manager.codex_output(session.id, 0)[:activity]
    status = JSON.parse(request('GET', '/codex/status').body).first
    assert_equal 'working', status['label']
    assert_equal 'is-info', status['css']
    input(session, 'approve')
    wait_for { @manager.codex_sessions.first.activity == 'waiting_for_input' }
    status = JSON.parse(request('GET', '/codex/status').body).first
    assert_equal 'waiting for input', status['label']
    assert_equal 'is-warning', status['css']
    assert status['active']
    assert_includes request('GET', '/').body, %(id="codex-status-#{session.id}" class="tag is-warning">waiting for input</span>)
    refute @manager.codex_sessions.first.to_h.key?('activity')
    @manager.shutdown
    @manager = BuildManager.new(service: @build_service, codex_service: @codex_service)
    @manager.start
    assert_equal 'waiting_for_input', @manager.codex_sessions.first.activity
    input(session, 'work')
    wait_for { @manager.codex_sessions.first.activity == 'working' }
    input(session, 'idle')
    wait_for { @manager.codex_sessions.first.activity == 'waiting_for_input' }
    input(session, '/exit')
    wait_for { @manager.codex_sessions.first.status == 'exited' }
    assert_nil @manager.codex_sessions.first.activity
    assert_includes request('GET', "/codex/#{session.id}").body, 'data-active="false"'
  end

  def test_recording_batches_tiny_frames_and_stops_at_its_original_endpoint
    session = CodexSession.new(id: 'a' * 24, status: 'exited')
    @manager.instance_variable_get(:@codex_sessions)[session.id] = session
    directory = File.join(CODEX_TEST_ROOT, 'codex', session.id)
    FileUtils.mkdir_p(directory)
    File.binwrite(File.join(directory, 'output'), 'a' * 40_000 + 'b' * 200_000)
    journal = JSON.generate(cols: 100, rows: 30) + "\n"
    40_000.times { |i| journal << JSON.generate(offset: i + 1, bytes: 1) + "\n" }
    journal << JSON.generate(cols: 87, rows: 39) + "\n"
    4.times { |i| journal << JSON.generate(offset: 40_000 + (i + 1) * 50_000, bytes: 50_000) + "\n" }
    File.write(File.join(directory, 'frames'), journal)
    response = request('GET', "/codex/#{session.id}/recording")
    assert_equal 200, response.status
    assert response.chunked?
    assert_equal 'application/x-ndjson', response['Content-Type']
    File.open(File.join(directory, 'output'), 'ab') { |f| f.write('live') }
    File.open(File.join(directory, 'frames'), 'a') { |f| f.puts(JSON.generate(offset: 240_004, bytes: 4)) }
    body = StringIO.new
    response.body.call(body)
    batches = body.string.lines.map { |line| JSON.parse(line) }
    assert_operator batches.size, :<, 20, 'tiny frames must not become individual network writes'
    events = batches.flat_map { |batch| batch.fetch('events') }
    assert_equal [{'cols' => 100, 'rows' => 30}, {'cols' => 87, 'rows' => 39}], events.reject { |event| event['data'] }
    assert_equal 'a' * 40_000 + 'b' * 200_000, events.filter_map { |event| event['data']&.unpack1('m0') }.join
    batches.each do |batch|
      assert_equal journal.bytesize, batch.fetch('finish')
      assert_operator batch.fetch('events').sum { |event| event['data']&.unpack1('m0')&.bytesize || 0 }, :<, 262_144
    end
    refute batches.last.fetch('more')
    assert_equal 'live', @manager.codex_frames(session.id, batches.last.fetch('cursor'))[:events].first.fetch('data').unpack1('m0')
  end

  def test_recording_compression_negotiation_compaction_and_raw_resume
    session = CodexSession.new(id: 'a' * 24, status: 'exited')
    @manager.instance_variable_get(:@codex_sessions)[session.id] = session
    directory = File.join(CODEX_TEST_ROOT, 'codex', session.id)
    FileUtils.mkdir_p(directory)
    idle = CodexReplayTest::IDLE
    bytes = "start\r\n" + (idle + "\e]2;idle\a") * 12_000 + "end\e[31"
    File.binwrite(File.join(directory, 'output'), bytes)
    [nil, 'identity', 'br, gzip', 'gzip;q=0', 'br, gzip;q=0.5'].each do |encoding|
      response = request('GET', "/codex/#{session.id}/recording", encoding: encoding)
      assert_equal 'no-store', response['Cache-Control']
      assert_equal 'Accept-Encoding', response['Vary']
      stream = StringIO.new
      response.body.call(stream)
      refute stream.closed?
      compressed = ['br, gzip', 'br, gzip;q=0.5'].include?(encoding)
      if compressed
        assert_equal 'gzip', response['Content-Encoding']
        assert_operator stream.string.bytesize, :<, bytes.bytesize / 100
      else
        assert_nil response['Content-Encoding']
      end
      body = compressed ? Zlib.gunzip(stream.string) : stream.string
      batches = body.lines.map { |line| JSON.parse(line) }
      output = batches.flat_map { |batch| batch.fetch('events') }.filter_map { |event| event['data']&.unpack1('m0') }.join
      assert_operator output.bytesize, :<, bytes.bytesize / 100
      assert output.start_with?("start\r\n#{idle}")
      assert output.end_with?("end\e[31")
      assert_equal bytes.bytesize, batches.last.fetch('cursor')
      refute batches.last.fetch('more')
    end
    # A resumed request has no prior parser state: preserve every remaining byte,
    # including a suffix that completes the browser's unfinished escape sequence.
    resumed = request('GET', "/codex/#{session.id}/recording?cursor=#{bytes.bytesize - 2}", encoding: 'gzip')
    stream = StringIO.new
    resumed.body.call(stream)
    events = Zlib.gunzip(stream.string).lines.flat_map { |line| JSON.parse(line).fetch('events') }
    assert_equal '31', events.map { |event| event.fetch('data').unpack1('m0') }.join
    assert_equal bytes, File.binread(File.join(directory, 'output'))
  end

  def test_incomplete_frame_is_retried_and_legacy_output_is_bounded
    session = CodexSession.new(id: 'b' * 24, status: 'exited')
    @manager.instance_variable_get(:@codex_sessions)[session.id] = session
    directory = File.join(CODEX_TEST_ROOT, 'codex', session.id)
    FileUtils.mkdir_p(directory)
    File.binwrite(File.join(directory, 'output'), 'x' * 200_000)
    legacy = @manager.codex_frames(session.id, 0)
    assert legacy[:legacy]
    assert legacy[:more]
    assert_equal 131_072, legacy[:cursor]
    assert_equal 'x' * 68_928, @manager.codex_frames(session.id, legacy[:cursor])[:events].first.fetch('data').unpack1('m0')
    File.write(File.join(directory, 'frames'), '{"offset":3,"bytes":3}')
    partial = @manager.codex_frames(session.id, 0)
    refute partial[:more]
    assert_equal 0, partial[:cursor]
    assert_empty partial[:events]
    File.open(File.join(directory, 'frames'), 'a') { |f| f.write("\n") }
    assert_equal 'xxx', @manager.codex_frames(session.id, partial[:cursor])[:events].first.fetch('data').unpack1('m0')
  end

  def test_activity_ignores_incomplete_titles_and_absent_activity_signals
    session = CodexSession.new(id: 'a' * 24, status: 'running')
    directory = File.join(CODEX_TEST_ROOT, 'codex', session.id)
    FileUtils.mkdir_p(directory)
    output = File.join(directory, 'output')
    File.binwrite(output, 'x' * 80_000 + "\e]2;⠹ packages\a\e]2;packages")
    assert_equal 'working', @manager.send(:codex_activity, session)
    File.open(output, 'ab') { |file| file.write("\e\\") }
    assert_equal 'waiting_for_input', @manager.send(:codex_activity, session)
    File.binwrite(output, 'no title emitted')
    assert_nil @manager.send(:codex_activity, session)
    File.unlink(output)
    assert_nil @manager.send(:codex_activity, session)
  end

  def test_stop_action_returns_to_dashboard_and_active_page_has_redirect_context
    session = start_codex
    html = request('GET', "/codex/#{session.id}").body
    assert_includes html, 'data-dashboard-url="/buildd/" data-active="true"'
    response = request('POST', "/codex/#{session.id}/stop")
    assert_equal 303, response.status
    assert_equal '/buildd/', response['Location']
    assert_equal 'stopped', @manager.codex_sessions.first.status
  end

  def test_exit_schedules_exactly_one_overlay_retry_and_survives_recovery
    source = failed_build('example:nocheck', target_builder: 'builder@test', environment: {'KEEPCHROOT' => '1', 'SWITCHBRANCH' => '0'})
    session = start_codex(source)
    input(session, '/exit')
    retry_id = wait_for { @manager.codex_sessions.first.rebuild_id }
    retry_build = wait_for { build = @manager.find(retry_id); build if build.terminal? }
    assert_equal 'succeeded', retry_build.status
    assert_equal 'example:nocheck', retry_build.command_line
    assert_equal 'builder@test', retry_build.target_builder
    assert_equal({'KEEPCHROOT' => '1', 'SWITCHBRANCH' => '1'}, retry_build.environment)
    @manager.shutdown
    @manager = BuildManager.new(service: @build_service, codex_service: @codex_service)
    @manager.start
    3.times { assert_equal retry_id, @manager.codex_sessions.first.rebuild_id }
    assert_equal 2, @manager.all_builds.size
    assert_equal 1, @build_service.starts.count(retry_id)
  end

  def test_exit_while_scheduler_is_down_is_reconciled_once
    session = start_codex
    @manager.shutdown
    input(session, '/exit')
    wait_for { !@codex_service.active?(session) }
    @manager = BuildManager.new(service: @build_service, codex_service: @codex_service)
    @manager.start
    retry_id = wait_for { @manager.codex_sessions.first.rebuild_id }
    assert_equal 2, @manager.all_builds.size
    assert_equal 1, @build_service.starts.count(retry_id)
  end

  def test_recovery_after_saving_retry_before_launch
    session = start_codex
    input(session, '/exit')
    retry_id = nil
    @manager.stub(:launch_worker, nil) do
      retry_id = wait_for { @manager.codex_sessions.first.rebuild_id }
    end
    refute_includes @build_service.starts, retry_id
    @manager.shutdown
    @manager = BuildManager.new(service: @build_service, codex_service: @codex_service)
    @manager.start
    wait_for { @manager.find(retry_id).terminal? }
    assert_equal 1, @build_service.starts.count(retry_id)
    assert_equal retry_id, @manager.codex_sessions.first.rebuild_id
    assert_equal 2, @manager.all_builds.size
  end

  def test_queued_terminal_waits_for_attachment_and_survives_restart
    source = failed_build
    session = @manager.spawn_codex(source.id)
    wait_for { @manager.codex_output(session.id, 0)[:ready] }
    assert_equal 'queued', @manager.codex_sessions.first.status
    assert_equal '', @manager.codex_output(session.id, 0)[:data]
    @manager.shutdown
    @manager = BuildManager.new(service: @build_service, codex_service: @codex_service)
    @manager.start
    assert_equal [session.id], @codex_service.starts
    @manager.stop_codex(session.id)
    assert_equal 'stopped', @manager.codex_sessions.first.status
    assert_equal 1, @manager.all_builds.size
  end

  def test_skip_can_be_changed_and_stop_never_rebuilds
    session = start_codex
    @manager.set_codex_rebuild(session.id, rebuild: false)
    input(session, '/exit')
    wait_for { @manager.codex_sessions.first.status == 'exited' }
    assert_equal 1, @manager.all_builds.size
    session = start_codex(@manager.all_builds.first)
    @manager.stop_codex(session.id)
    assert_equal 'stopped', @manager.codex_sessions.first.status
    refute @manager.codex_sessions.first.rebuild
    assert_equal 1, @manager.all_builds.size
  end

  def test_start_failure_and_abrupt_worker_loss_do_not_rebuild
    source = failed_build
    @codex_service.failure = 'missing systemd'
    session = @manager.spawn_codex(source.id)
    assert_equal 'failed', session.status
    assert_equal 'missing systemd', session.note
    assert_nil session.rebuild_id
    @codex_service.failure = nil
    session = start_codex(source)
    # Simulate loss of the worker snapshot after the process has been reaped.
    @codex_service.stop(session)
    File.unlink(File.join(CODEX_TEST_ROOT, 'codex', session.id, 'status.json'))
    @manager.start
    assert_equal 'interrupted', @manager.codex_sessions.first.status
    assert_equal 1, @manager.all_builds.size
  end

  def test_spawn_is_rejected_for_old_nonfailed_active_and_duplicate_entries
    older = failed_build
    latest = failed_build('example:nocheck')
    assert_raises(ArgumentError) { @manager.spawn_codex(older.id) }
    session = start_codex(latest)
    assert_raises(ArgumentError) { @manager.spawn_codex(latest.id) }
    assert_raises(ArgumentError) { @manager.enqueue('example') }
    assert_raises(ArgumentError) { @manager.delete_build(latest.id) }
    @manager.stop_codex(session.id)
    success = @manager.enqueue('example', environment: {'SWITCHBRANCH' => '1'})
    assert_raises(ArgumentError) { @manager.spawn_codex(latest.id) }
    wait_for { @manager.find(success.id).status == 'succeeded' }
    assert_raises(ArgumentError) { @manager.spawn_codex(success.id) }
    assert_raises(ArgumentError) { @manager.spawn_codex(latest.id) }
  end

  def test_button_visibility_search_pagination_and_subpath
    older = failed_build
    latest = failed_build('example:nocheck')
    page = request('GET', '/').body
    assert_includes page, "action=\"/buildd/builds/#{latest.id}/codex\""
    refute_includes page, "action=\"/buildd/builds/#{older.id}/codex\""
    assert_includes page, 'Skip rebuild on exit'
    assert_includes request('GET', "/builds/#{latest.id}/log").body, 'Spawn Codex'
    refute_includes request('GET', "/builds/#{older.id}/log").body, 'Spawn Codex'
    refute_includes request('GET', '/', editor: false).body, 'Spawn Codex'
    refute_includes request('GET', "/?q=#{older.id}").body, 'Spawn Codex'
    session = start_codex(latest)
    page = request('GET', '/').body
    assert_includes page, 'Open Codex'
    refute_includes page, 'Spawn Codex'
    assert_includes page, "/buildd/codex/#{session.id}"
    assert_equal 200, request('GET', "/codex/#{session.id}").status
    assert_includes request('GET', "/codex/#{session.id}").body, 'data-url="/buildd/codex/'
    terminal = request('GET', "/codex/#{session.id}").body
    assert_includes terminal, 'https://cdn.jsdelivr.net/npm/@xterm/xterm@6.0.0/lib/xterm.js'
    assert_includes terminal, 'https://cdn.jsdelivr.net/npm/@xterm/addon-fit@0.11.0/lib/addon-fit.js'
    assert_equal 3, terminal.scan(%r{(?:src|href)="https://cdn\.jsdelivr\.net/[^>]+integrity="sha384-[^"]+" crossorigin="anonymous"}).size
    refute_includes terminal, '/codex-xterm.'
  end

  def test_terminal_output_input_assets_and_actions_require_editor_and_csrf
    source = failed_build
    path = "/builds/#{source.id}/codex"
    assert_equal 403, request('POST', path, editor: false).status
    assert_equal 403, request('POST', path, csrf: false).status
    assert_equal 404, request('GET', path).status
    response = request('POST', path, params: {'skip_rebuild' => '1'})
    assert_equal 303, response.status
    assert_match(%r{\A/buildd/codex/[a-f0-9]{24}\z}, response['Location'])
    session = @manager.codex_sessions.first
    refute session.rebuild
    %W[/codex/#{session.id} /codex/status /codex-terminal.js].concat(
      %w[output recording frames].map { |action| "/codex/#{session.id}/#{action}" }
    ).each do |url|
      assert_equal 403, request('GET', url, editor: false).status, url
      assert_equal 403, request('HEAD', url, editor: false).status, url
    end
    %w[input rebuild stop].each do |action|
      url = "/codex/#{session.id}/#{action}"
      assert_equal 403, request('POST', url, csrf: false).status, url
      assert_equal 403, request('POST', url, editor: false).status, url
      assert_equal 404, request('GET', url).status, url
    end
    assert_equal 400, request('POST', "/codex/#{session.id}/input", body: '{bad json').status
    assert_equal 400, request('POST', "/codex/#{session.id}/input", body: '[]').status
    assert_equal 400, request('POST', "/codex/#{session.id}/input", body: '{"action":"input","data":null}').status
    assert_equal 400, request('GET', "/codex/#{session.id}/output?offset=-1").status
    assert_equal 303, request('POST', "/codex/#{session.id}/rebuild", params: {'rebuild' => '1'}).status
    assert @manager.codex_sessions.first.rebuild
  end

  def test_input_validation_and_systemd_unit_contract
    session = start_codex(rebuild: false)
    assert_raises(ArgumentError) { @manager.codex_input(session.id, 'action' => 'resize', 'rows' => -1, 'cols' => 10) }
    assert_raises(ArgumentError) { @manager.codex_input(session.id, 'action' => 'input', 'data' => 'bad base64') }
    assert_raises(ArgumentError) { input(session, 'x' * 16_385) }
    command = nil
    success = Struct.new(:success?).new(true)
    capture = ->(*argv) { command = argv; ['', success] }
    Open3.stub(:capture2e, capture) { SystemdCodexService.new.start(session, '/tmp/codex-worker') }
    assert_includes command, "--unit=#{session.unit_name}"
    assert_includes command, '--property=KillMode=control-group'
    assert_equal ['--codex-worker', '/tmp/codex-worker'], command.last(2)
    refute command.any? { |arg| arg.include?('PartOf=') || arg.include?('BindsTo=') }
  end
end
