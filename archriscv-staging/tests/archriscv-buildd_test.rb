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
ENV['ARCHRISCV_BUILDD_BUILDER_USER'] = 'builder'
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
      puts "\e[1m\e[32m==>\e(B\e[m\e[1m Building on test-builder\e(B\e[m"
      if ARGV.first.start_with?('wait')
        puts 'waiting for release'
        sleep 0.05 until File.exist?(File.join(ENV.fetch('ARCHRISCV_TEST_ROOT'), 'release'))
      elsif ARGV.first.start_with?('prompt')
        print 'Upload log? [y/N] '
        answer = STDIN.gets.to_s.strip
        puts "answer=#{answer}"
        exit 1
      end
      puts 'build completed'
    RUBY
    File.chmod(0o755, BUILD_COMMAND)
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

  def test_stop_still_terminates_build_after_restart
    build = @manager.enqueue('wait-stop')
    wait_for { @manager.find(build.id).status == 'running' }
    restart
    @manager.stop_build(build.id)
    assert_equal 'interrupted', @manager.find(build.id).status
    assert_equal 'stopped by user', @manager.find(build.id).note
    refute @service.active?(build)
  end

  def test_queued_build_recovers_without_duplicate_launch
    build = @manager.enqueue('wait-queued')
    # The daemon can die before observing the worker's first status update.
    assert_equal 'queued', JSON.parse(File.read(STATE_FILE))['builds'].first['status']
    restart
    assert_equal 1, @service.starts[build.id]
    @manager.stop_build(build.id)
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
