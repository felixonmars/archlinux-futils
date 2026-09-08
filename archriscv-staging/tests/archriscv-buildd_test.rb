# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'minitest/autorun'
require 'rbconfig'
require 'stringio'
require 'tmpdir'

TEST_ROOT = Dir.mktmpdir('archriscv-buildd-test-')
ENV['ARCHRISCV_BUILDD_STATE_DIR'] = TEST_ROOT
ENV['ARCHRISCV_BUILDD_LOG_DIR'] = File.join(TEST_ROOT, 'logs')
ENV['ARCHRISCV_BUILDD_BUILD_COMMAND'] = File.join(TEST_ROOT, 'build-command')
ENV['ARCHRISCV_BUILDD_REFRESH_COMMAND'] = File.join(TEST_ROOT, 'refresh-command')
ENV['ARCHRISCV_BUILDD_BUILDER_USER'] = 'builder'
ENV['ARCHRISCV_BUILDD_BUILDER_CACHE_DIR'] = File.join(TEST_ROOT, 'builder-cache')
ENV['ARCHRISCV_BUILDD_WORKDIR'] = TEST_ROOT
ENV['ARCHRISCV_TEST_ROOT'] = TEST_ROOT
ENV.delete('SERVER')
load File.expand_path('../archriscv-buildd', __dir__)

Minitest.after_run { FileUtils.remove_entry(TEST_ROOT) }

# Exercise real worker subprocesses without requiring system-level systemd access.
class TestBuildService
  attr_reader :starts

  def initialize
    @pids = {}
    @starts = Hash.new(0)
  end

  def start(build, directory)
    @starts[build.id] += 1
    @pids[build.id] = Process.spawn(RbConfig.ruby, File.expand_path('../archriscv-buildd', __dir__),
      '--worker', directory, out: File::NULL, err: File::NULL)
  end

  def active?(build)
    pid = @pids[build.id]
    return false unless pid
    return true unless Process.waitpid(pid, Process::WNOHANG)

    @pids.delete(build.id)
    false
  rescue Errno::ECHILD
    @pids.delete(build.id)
    false
  end

  def stop(build)
    return unless active?(build)

    Process.kill('TERM', @pids.fetch(build.id))
    Process.waitpid(@pids.delete(build.id))
  end

  def interrupt(build)
    BuildTerminal.interrupt(@pids.fetch(build.id))
  end

  def cleanup
    @pids.keys.each { |id| stop(Build.new(id: id, command_line: '', argv: [], pkgbase: '', log_path: '')) }
  end
end

class BuildRestartTest < Minitest::Test
  def setup
    Dir.children(TEST_ROOT).each { |name| FileUtils.rm_rf(File.join(TEST_ROOT, name)) }
    File.write(BUILD_COMMAND, <<~'RUBY')
      #!/usr/bin/env ruby
      require 'json'
      STDOUT.sync = true
      puts JSON.generate(server: ENV['SERVER'], argv: ARGV, workdir: Dir.pwd)
      cache_path = File.join(ENV.fetch('ARCHRISCV_BUILDD_BUILDER_CACHE_DIR'), "#{ARGV.first.sub(/:nocheck\z/, '')}-riscv64")
      puts "builder-cache=#{File.exist?(cache_path)}"
      puts "\e[1m\e[32m==>\e(B\e[m\e[1m Building on test-builder\e(B\e[m"
      if ARGV.first.start_with?('interrupt')
        interrupted = false
        trap('INT') { interrupted = true }
        puts 'waiting for Ctrl-C'
        sleep 0.05 until interrupted
        puts 'interrupt received'
        print 'Upload log? [y/N] '
        puts "answer=#{STDIN.gets.to_s.strip}"
        exit 1
      elsif ARGV.first.start_with?('wait')
        puts 'waiting for release'
        sleep 0.05 until File.exist?(File.join(ENV.fetch('ARCHRISCV_TEST_ROOT'), 'release'))
        exit 1 if File.exist?(File.join(ENV.fetch('ARCHRISCV_TEST_ROOT'), 'fail-dependency'))
      elsif ARGV.first.start_with?('prompt')
        print 'Upload log? [y/N] '
        answer = STDIN.gets.to_s.strip
        puts "answer=#{answer}"
        exit 1
      end
      puts 'build completed'
    RUBY
    File.chmod(0o755, BUILD_COMMAND)
    File.write(REFRESH_COMMAND, <<~'RUBY')
      #!/usr/bin/env ruby
      require 'json'
      File.write(File.join(ENV.fetch('ARCHRISCV_TEST_ROOT'), 'refresh-args.json'), JSON.generate(ARGV))
      abort 'refresh failed' if ARGV.include?('--extra-safe-deps=fail')
      puts '# refresh stats'
      puts 'candidate-one', 'candidate-two', 'candidate-one'
    RUBY
    File.chmod(0o755, REFRESH_COMMAND)
    @service = TestBuildService.new
    @managers = []
    @manager = new_manager
  end

  def teardown
    @managers.each(&:shutdown)
    @service.cleanup
  end

  def new_manager
    manager = BuildManager.new(service: @service)
    @managers << manager
    manager
  end

  def wait_for
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 8
    loop do
      value = yield
      return value if value
      flunk 'timed out waiting for worker' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.05
    end
  end

  def finished(id)
    wait_for do
      build = @manager.find(id)
      build if build&.terminal?
    end
  end

  def restart
    @manager.shutdown
    @manager = new_manager
    @manager.start
  end

  def refresh_request(extra_safe_deps = nil)
    body = extra_safe_deps.nil? ? '' : "extra_safe_deps=#{CGI.escape(extra_safe_deps)}"
    post_request('/refresh', body)
  end

  def post_request(path, body = '')
    req = WEBrick::HTTPRequest.new(WEBrick::Config::HTTP)
    req.parse(StringIO.new("POST #{path} HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}"))
    res = WEBrick::HTTPResponse.new(WEBrick::Config::HTTP)
    WebApp.new(@manager).call(req, res)
    res
  end

  def test_refresh_passes_extra_safe_dependencies_as_one_literal_argument
    assert_equal 303, refresh_request(' llvm, python ').status
    assert_equal ['--extra-safe-deps=llvm, python'], JSON.parse(File.read(File.join(TEST_ROOT, 'refresh-args.json')))
    assert_equal %w[candidate-one candidate-two], @manager.refresh_pending

    marker = File.join(TEST_ROOT, 'shell-command-ran')
    input = "llvm; touch #{marker}"
    assert_equal 303, refresh_request(input).status
    assert_equal ["--extra-safe-deps=#{input}"], JSON.parse(File.read(File.join(TEST_ROOT, 'refresh-args.json')))
    refute File.exist?(marker)
  end

  def test_refresh_without_extra_safe_dependencies_preserves_default_invocation
    [nil, '', " \t "].each do |input|
      assert_equal 303, refresh_request(input).status
      assert_empty JSON.parse(File.read(File.join(TEST_ROOT, 'refresh-args.json')))
    end
    assert_equal %w[candidate-one candidate-two], @manager.refresh_pending
  end

  def test_refresh_errors_leave_pending_packages_intact
    refresh_request
    response = refresh_request('fail')
    assert_equal 400, response.status
    assert_includes response.body, 'refresh failed'
    assert_equal %w[candidate-one candidate-two], @manager.refresh_pending
  end

  def test_skip_upload_and_retry_preserves_builder_and_cache_by_default
    FileUtils.mkdir_p(BUILDER_CACHE_DIR)
    cache = File.join(BUILDER_CACHE_DIR, 'prompt-retry-riscv64')
    File.write(cache, 'builder@cached-host')
    build = @manager.enqueue('prompt-retry:nocheck', target_builder: 'pinned-host')
    wait_for { @manager.find(build.id).status == 'waiting_upload' }

    assert_equal 303, post_request("/builds/#{build.id}/retry").status
    retried = @manager.all_builds.find { |entry| entry.id != build.id }
    wait_for { @manager.find(retried.id).status == 'waiting_upload' }
    assert_equal 'builder@pinned-host', retried.target_builder
    assert_equal 'prompt-retry:nocheck', retried.command_line
    assert_equal 'builder@cached-host', File.read(cache)
    assert_includes File.read(retried.log_path), 'builder-cache=true'
    assert_includes File.read(retried.log_path), '"server":"builder@pinned-host"'
    wait_for { @manager.find(build.id).nil? }
  end

  def test_skip_upload_and_retry_with_new_builder_clears_only_its_cache_and_target
    FileUtils.mkdir_p(BUILDER_CACHE_DIR)
    cache = File.join(BUILDER_CACHE_DIR, 'prompt-retry-riscv64')
    other_cache = File.join(BUILDER_CACHE_DIR, 'other-riscv64')
    x86_cache = File.join(BUILDER_CACHE_DIR, 'prompt-retry-x86_64')
    [cache, other_cache, x86_cache].each { |path| File.write(path, 'builder@cached-host') }
    build = @manager.enqueue('prompt-retry:nocheck', target_builder: 'pinned-host')
    wait_for { @manager.find(build.id).status == 'waiting_upload' }
    ENV['SERVER'] = 'builder@environment-host'

    assert_equal 303, post_request("/builds/#{build.id}/retry", 'new_builder=1').status
    retried = @manager.all_builds.find { |entry| entry.id != build.id }
    wait_for { @manager.find(retried.id).status == 'waiting_upload' }
    assert_nil retried.target_builder
    assert_equal 'prompt-retry:nocheck', retried.command_line
    refute File.exist?(cache)
    [other_cache, x86_cache].each { |path| assert_equal 'builder@cached-host', File.read(path) }
    assert_includes File.read(retried.log_path), 'builder-cache=false'
    assert_includes File.read(retried.log_path), '"server":null'
    assert_equal 'builder@environment-host', ENV['SERVER']
    restart
    assert_nil @manager.find(retried.id).target_builder
    assert_equal 1, @service.starts[retried.id]
    wait_for { @manager.find(build.id).nil? }
  ensure
    ENV.delete('SERVER')
  end

  def test_retry_with_new_builder_allows_missing_cache
    build = @manager.enqueue('prompt-no-cache')
    wait_for { @manager.find(build.id).status == 'waiting_upload' }
    assert_equal 303, post_request("/builds/#{build.id}/retry", 'new_builder=1').status
    retried = @manager.all_builds.find { |entry| entry.id != build.id }
    refute_nil retried
    assert_nil retried.target_builder
  end

  def test_new_builder_cache_error_does_not_enqueue_a_retry
    build = @manager.enqueue('prompt-cache-error')
    wait_for { @manager.find(build.id).status == 'waiting_upload' }
    @manager.answer_upload(build.id, upload: true)
    finished(build.id)
    cache = File.join(BUILDER_CACHE_DIR, 'prompt-cache-error-riscv64')
    FileUtils.mkdir_p(cache)

    response = post_request("/builds/#{build.id}/retry", 'new_builder=1')
    assert_equal 400, response.status
    assert_includes response.body, 'Is a directory'
    assert_equal [build.id], @manager.all_builds.map(&:id)
    assert Dir.exist?(cache)
  end

  def test_live_upload_panel_already_contains_retry_and_new_builder_checkbox
    build = @manager.enqueue('wait-live-prompt')
    wait_for { @manager.find(build.id).status == 'running' }
    res = WEBrick::HTTPResponse.new(WEBrick::Config::HTTP)
    WebApp.new(@manager).send(:show_log, nil, res, build.id)
    assert_includes res.body, 'id="decision"'
    assert_includes res.body, "action=\"/builds/#{build.id}/retry\""
    assert_includes res.body, 'Skip upload + retry'
    assert_includes res.body, '<input type="checkbox" name="new_builder" value="1"> New builder'
    refute_match(/name="new_builder"[^>]*checked/, res.body)
    assert_includes res.body, "action=\"/builds/#{build.id}/defer\""
    assert_includes res.body, 'name="wait_for"'
    assert_includes res.body, '>Defer</button>'
  end

  def test_defer_skips_log_and_retries_once_after_a_new_matching_success
    old_dependency = @manager.enqueue('wait-dependency')
    File.write(File.join(TEST_ROOT, 'release'), '')
    finished(old_dependency.id)
    source = @manager.enqueue('prompt-deferred:nocheck', target_builder: 'pinned-host')
    wait_for { @manager.find(source.id).status == 'waiting_upload' }

    response = post_request("/builds/#{source.id}/defer", 'wait_for=wait-dependency')
    assert_equal 303, response.status
    pending = @manager.deferred_retries.fetch(0)
    retry_id = pending.fetch('build').fetch('id')
    wait_for { @manager.find(source.id).nil? }
    refute File.exist?(source.log_path)
    assert_equal 'wait-dependency', pending['wait_for']
    assert_equal 0, @service.starts[retry_id]

    unrelated = @manager.enqueue('unrelated')
    finished(unrelated.id)
    File.write(File.join(TEST_ROOT, 'fail-dependency'), '')
    failed_dependency = @manager.enqueue('wait-dependency')
    assert_equal 'failed', finished(failed_dependency.id).status
    restart
    assert_equal 1, @manager.deferred_retries.size
    assert_equal 0, @service.starts[retry_id]
    File.unlink(File.join(TEST_ROOT, 'fail-dependency'))

    dependency = @manager.enqueue('wait-dependency:nocheck')
    finished(dependency.id)
    wait_for { @manager.find(retry_id)&.status == 'waiting_upload' }
    assert_empty @manager.deferred_retries
    result = @manager.find(retry_id)
    assert_equal 'prompt-deferred:nocheck', result.command_line
    assert_equal 'builder@pinned-host', result.target_builder
    assert_includes File.read(result.log_path), '"server":"builder@pinned-host"'
    restart
    assert_equal 1, @service.starts[retry_id]
    assert_empty @manager.deferred_retries
  end

  def test_running_build_survives_restart_with_target_and_environment
    build = @manager.enqueue('wait-package:nocheck', target_builder: ' articuno ')
    wait_for { File.exist?(build.log_path) && File.read(build.log_path).include?('waiting for release') }
    restart
    assert @service.active?(build)
    assert_equal 'running', @manager.find(build.id).status
    assert_equal 1, @service.starts[build.id]
    assert_equal 'builder@articuno', @manager.find(build.id).target_builder
    File.write(File.join(TEST_ROOT, 'release'), '')
    result = finished(build.id)
    assert_equal 'succeeded', result.status
    assert_equal 0, result.exit_status
    assert_equal 'test-builder', result.build_host
    log = File.read(build.log_path)
    assert_includes log, '"server":"builder@articuno"'
    assert_includes log, '"argv":["wait-package:nocheck"]'
    assert_includes log, "\"workdir\":#{TEST_ROOT.to_json}"
    assert_includes log, 'build completed'
    assert_nil ENV['SERVER']
  end

  def test_completion_while_dashboard_is_offline_is_recovered
    build = @manager.enqueue('wait-offline')
    wait_for { @manager.find(build.id).status == 'running' }
    @manager.shutdown
    File.write(File.join(TEST_ROOT, 'release'), '')
    wait_for { !@service.active?(build) }
    restart
    assert_equal 'succeeded', @manager.find(build.id).status
    assert_equal 1, @service.starts[build.id]
  end

  def test_missing_host_from_older_worker_is_recovered_and_retained
    build = Build.new(id: 'older-worker', command_line: 'tinymist', argv: ['riscvu', 'tinymist'],
      pkgbase: 'tinymist', log_path: File.join(LOG_DIR, 'older-worker.log'), status: 'running',
      unit_name: 'archriscv-buildd-build-older-worker.service')
    worker_directory = File.join(WORKER_DIR, build.id)
    FileUtils.mkdir_p(worker_directory)
    snapshot = build.to_h
    write_json(File.join(worker_directory, 'status.json'), snapshot)
    write_json(STATE_FILE, 'builds' => [snapshot], 'refresh_pending' => [])
    File.write(build.log_path, "\e]3008;start=build;hostname=lanturn\e\\" \
      "\e[1m\e[32m==>\e(B\e[m\e[1m Building on houndour\e(B\e[m\r\n" \
      "\e]3008;end=build\e\\")
    @manager = new_manager

    assert_equal 'houndour', @manager.find(build.id).build_host
    res = WEBrick::HTTPResponse.new(WEBrick::Config::HTTP)
    WebApp.new(@manager).send(:show_log, nil, res, build.id)
    assert_includes res.body, '<span id="build-host" class="tag is-light">houndour</span>'
    assert_nil JSON.parse(File.read(File.join(worker_directory, 'status.json')))['build_host']

    # The old worker keeps publishing snapshots without a hostname.
    snapshot['status'] = 'waiting_upload'
    write_json(File.join(worker_directory, 'status.json'), snapshot)
    File.write(build.log_path, 'later output without the announcement')
    assert_equal 'waiting_upload', @manager.find(build.id).status
    assert_equal 'houndour', @manager.find(build.id).build_host
    @manager = new_manager
    assert_equal 'houndour', @manager.find(build.id).build_host
  end

  def test_upload_prompt_can_be_answered_after_restart
    build = @manager.enqueue('prompt-upload')
    wait_for { @manager.find(build.id).status == 'waiting_upload' }
    restart
    assert_equal 'waiting_upload', @manager.find(build.id).status
    @manager.answer_upload(build.id, upload: true)
    result = finished(build.id)
    assert_equal 'upload', result.upload_decision
    assert_equal 'failed', result.status
    assert_equal 1, result.exit_status
    assert_includes File.read(build.log_path), 'answer=y'
  end

  def test_saved_skip_decision_is_consumed_while_dashboard_is_offline
    build = @manager.enqueue('prompt-skip')
    wait_for { @manager.find(build.id).status == 'waiting_upload' }
    @manager.shutdown
    write_json(File.join(WORKER_DIR, build.id, 'upload.json'), 'decision' => 'skip')
    wait_for { !@service.active?(build) }
    restart
    assert_nil @manager.find(build.id)
    refute File.exist?(build.log_path)
    refute Dir.exist?(File.join(WORKER_DIR, build.id))
  end

  def test_stop_sends_ctrl_c_and_allows_upload_after_restart
    build = @manager.enqueue('interrupt-stop')
    wait_for { File.exist?(build.log_path) && File.read(build.log_path).include?('waiting for Ctrl-C') }
    restart
    assert_equal 303, post_request("/builds/#{build.id}/stop").status
    wait_for { @manager.find(build.id).status == 'waiting_upload' }
    assert @service.active?(build)
    assert_nil @manager.find(build.id).note
    restart
    @manager.answer_upload(build.id, upload: true)
    result = finished(build.id)
    assert_equal 'upload', result.upload_decision
    assert_includes File.read(build.log_path), 'interrupt received'
    assert_includes File.read(build.log_path), 'answer=y'
    assert_equal 1, @service.starts[build.id]
  end

  def test_queued_build_recovers_without_duplicate_launch
    build = @manager.enqueue('wait-queued')
    # The daemon can die before observing the worker's first status update.
    assert_equal 'queued', JSON.parse(File.read(STATE_FILE))['builds'].first['status']
    restart
    assert_equal 1, @service.starts[build.id]
  end

  def test_legacy_active_build_is_interrupted_and_history_is_unlimited
    @manager.shutdown
    historical = Array.new(10_001) do |index|
      Build.new(id: "old-#{index}", command_line: 'old', argv: ['true'], pkgbase: 'old',
        log_path: File.join(LOG_DIR, "old-#{index}.log"), status: 'succeeded').to_h
    end
    historical.last['status'] = 'running'
    write_json(STATE_FILE, 'builds' => historical, 'refresh_pending' => [])
    restart
    assert_equal 'interrupted', @manager.find('old-10000').status
    build = @manager.enqueue('new-package')
    finished(build.id)
    assert_equal 10_002, @manager.all_builds.size
    restart
    assert_equal 10_002, @manager.all_builds.size
  end

  def test_live_log_resumes_from_last_event_id
    build = @manager.enqueue('log-resume')
    finished(build.id)
    File.write(build.log_path, "first\nsecond\n")
    req = WEBrick::HTTPRequest.new(WEBrick::Config::HTTP)
    req.parse(StringIO.new("GET /builds/#{build.id}/events?offset=0 HTTP/1.1\r\nHost: localhost\r\nLast-Event-ID: 6\r\n\r\n"))
    res = WEBrick::HTTPResponse.new(WEBrick::Config::HTTP)
    WebApp.new(@manager).call(req, res)
    output = StringIO.new
    res.body.call(output)
    refute_includes output.string, 'first'
    assert_includes output.string, 'data: "second\n"'
    assert_includes output.string, 'id: 13'
    @manager.shutdown
    output = StringIO.new
    res.body.call(output)
    assert_empty output.string
  end
end
