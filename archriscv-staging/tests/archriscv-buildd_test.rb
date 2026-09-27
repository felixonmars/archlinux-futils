# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'minitest/autorun'
require 'minitest/mock'
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
ENV.delete('KEEPCHROOT')
ENV.delete('SWITCHBRANCH')
load File.expand_path('../archriscv-buildd', __dir__)
Object.send(:remove_const, :MEMORY_KILLER_LIST)
MEMORY_KILLER_LIST = File.join(TEST_ROOT, 'packages', 'memory-killer.txt')
Object.send(:remove_const, :OVERLAY_REPO)
OVERLAY_REPO = File.join(TEST_ROOT, 'overlay')

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
    Process.waitpid(@pids.fetch(build.id))
    @pids.delete(build.id)
  end

  def interrupt(build)
    BuildTerminal.interrupt(@pids.fetch(build.id))
  end

  def cleanup
    @pids.keys.each { |id| stop(Build.new(id: id, command_line: '', argv: [], pkgbase: '', log_path: '')) }
  end
end

class BuildDurationTest < Minitest::Test
  def setup
    @started_at = Time.utc(2026, 9, 10, 1)
    @build = Build.new(id: 'duration', command_line: 'example', argv: ['riscvu', 'example'],
      pkgbase: 'example', log_path: '', started_at: @started_at, status: 'running')
  end

  def test_running_duration_advances_until_the_worker_finishes
    Time.stub(:now, @started_at + 62) { assert_equal '1m02s', duration(@build) }
    Time.stub(:now, @started_at + 63) { assert_equal '1m03s', duration(@build) }
    @build.finished_at = @started_at + 64
    Time.stub(:now, @started_at + 120) { assert_equal '1m04s', duration(Build.from_h(@build.to_h)) }
  end

  def test_duration_stays_frozen_after_upload_prompt_and_serialization
    @build = Build.from_h(@build.to_h.merge('upload_prompt_at' => (@started_at + 3661).iso8601))
    Time.stub(:now, @started_at + 7200) do
      %w[waiting_upload running failed interrupted succeeded].each do |status|
        @build.status = status
        @build.finished_at = @started_at + 5400 if @build.terminal?
        assert_equal '1h01m01s', duration(Build.from_h(@build.to_h)), status
      end
    end
  end
end

class BuildDashboardTest < Minitest::Test
  def setup
    @builds = []
    manager = Struct.new(:all_builds, :refresh_pending, :deferred_retries).new(@builds, [], [])
    @app = WebApp.new(manager)
  end

  def add_build(id, command_line: 'example', status: 'failed', pkgbase: command_line.sub(/:nocheck\z/, ''))
    timestamp = Time.utc(2026, 9, 20) + @builds.size
    build = Build.new(id: id, command_line: command_line, argv: ['riscvu', command_line],
      pkgbase: pkgbase, log_path: File.join(TEST_ROOT, "#{id}.log"), status: status,
      created_at: timestamp, started_at: timestamp,
      finished_at: ACTIVE_STATUSES.include?(status) ? nil : timestamp + 1)
    @builds << build
    build
  end

  def dashboard(query = '')
    req = WEBrick::HTTPRequest.new(WEBrick::Config::HTTP)
    req.parse(StringIO.new("GET /#{query} HTTP/1.1\r\nHost: localhost\r\n\r\n"))
    res = WEBrick::HTTPResponse.new(WEBrick::Config::HTTP)
    @app.call(req, res)
    assert_equal 200, res.status
    res.body
  end

  def latest_build_ids(html)
    html.scan(/<article class="build-card .*?<\/article>/m).filter_map do |card|
      card[/href="\/builds\/([^"\/]+)\/log"/, 1] if card.include?('class="tag is-info latest-build"')
    end
  end

  def test_latest_marker_identifies_one_completed_build_per_pkgbase_for_every_terminal_status
    TERMINAL_STATUSES.each do |status|
      add_build("#{status}-old", command_line: "package-#{status}", status: status)
      add_build("#{status}-latest", command_line: "package-#{status}", status: status)
    end

    assert_equal TERMINAL_STATUSES.reverse.map { |status| "#{status}-latest" }, latest_build_ids(dashboard)
  end

  def test_latest_marker_follows_recent_build_completion_order
    latest = add_build('finished-last')
    add_build('created-last')
    latest.finished_at += 60

    assert_equal ['finished-last'], latest_build_ids(dashboard)
  end

  def test_latest_marker_is_suppressed_by_any_active_build_until_it_finishes
    ACTIVE_STATUSES.each do |status|
      add_build("#{status}-old", command_line: "package-#{status}")
      add_build("#{status}-active", command_line: "package-#{status}:nocheck", status: status, pkgbase: nil)
    end
    add_build('unrelated', command_line: 'unrelated')

    assert_equal ['unrelated'], latest_build_ids(dashboard)

    @builds.select(&:active?).each do |build|
      build.status = 'succeeded'
      build.finished_at = build.started_at + 60
    end
    assert_equal ACTIVE_STATUSES.reverse.map { |status| "#{status}-active" } + ['unrelated'], latest_build_ids(dashboard)
  end

  def test_latest_marker_groups_nocheck_builds_and_legacy_builds_by_pkgbase
    add_build('checked')
    add_build('unchecked', command_line: 'example:nocheck', pkgbase: nil)
    add_build('other', command_line: 'other', pkgbase: nil)

    assert_equal %w[other unchecked], latest_build_ids(dashboard)
  end

  def test_search_does_not_mark_an_older_build_when_the_latest_does_not_match
    add_build('older', status: 'failed')
    add_build('latest', status: 'succeeded')

    html = dashboard('?q=failed')
    assert_includes html, 'href="/builds/older/log"'
    refute_includes html, 'href="/builds/latest/log"'
    assert_empty latest_build_ids(html)
    assert_equal ['latest'], latest_build_ids(dashboard('?q=succeeded'))
  end

  def test_search_matches_latest_tag_case_insensitively_and_excludes_active_retries
    add_build('older')
    add_build('newest', status: 'succeeded')
    ACTIVE_STATUSES.each do |status|
      add_build("#{status}-old", command_line: "package-#{status}")
      add_build("#{status}-active", command_line: "package-#{status}:nocheck", status: status)
    end

    %w[latest LaTeSt late].each do |query|
      html = dashboard("?q=#{query}")
      assert_equal ['newest'], latest_build_ids(html)
      refute_includes html, 'href="/builds/older/log"'
      ACTIVE_STATUSES.each { |status| refute_includes html, "href=\"/builds/#{status}-old/log\"" }
    end
  end

  def test_latest_search_preserves_existing_metadata_matches
    add_build('older', command_line: 'latest-package')
    add_build('newest', command_line: 'latest-package')
    add_build('other', command_line: 'other')

    html = dashboard('?q=latest')
    assert_includes html, 'href="/builds/older/log"'
    assert_equal %w[other newest], latest_build_ids(html)
  end

  def test_search_combines_status_and_latest_tag_in_any_order
    add_build('older')
    add_build('newest')
    add_build('fixed-old', command_line: 'fixed')
    add_build('fixed-new', command_line: 'fixed', status: 'succeeded')
    ACTIVE_STATUSES.each do |status|
      add_build("#{status}-old", command_line: "package-#{status}")
      add_build("#{status}-active", command_line: "package-#{status}:nocheck", status: status)
    end

    ['fail latest', 'latest fail', "  FaIl\t  LaTeSt  "].each do |query|
      html = dashboard("?q=#{CGI.escape(query)}")
      assert_equal ['newest'], latest_build_ids(html)
      %w[older fixed-old fixed-new].each { |id| refute_includes html, "href=\"/builds/#{id}/log\"" }
      ACTIVE_STATUSES.each { |status| refute_includes html, "href=\"/builds/#{status}-old/log\"" }
    end
  end

  def test_search_requires_every_term_to_match_across_metadata_fields
    build = add_build('target', command_line: 'target-package:nocheck')
    build.build_host = 'builder-one'
    build.note = 'missing dependency'
    build.exit_status = 2
    add_build('other', command_line: 'other', status: 'succeeded')

    query = 'target nocheck fail BUILDER missing 2 latest'
    assert_equal ['target'], latest_build_ids(dashboard("?q=#{CGI.escape(query)}"))
    html = dashboard("?q=#{CGI.escape("#{query} absent")}")
    assert_empty latest_build_ids(html)
    refute_includes html, 'href="/builds/target/log"'
    assert_includes html, 'No matching completed builds.'
  end

  def test_latest_search_filters_before_pagination_and_preserves_the_query
    (RECENT_PAGE_SIZE + 1).times do |index|
      add_build("older-#{index}", command_line: "package-#{index}")
      add_build("newest-#{index}", command_line: "package-#{index}")
    end

    ['latest', 'fail latest'].each do |search|
      query = CGI.escape(search)
      html = dashboard("?q=#{query}")
      assert_equal RECENT_PAGE_SIZE, latest_build_ids(html).size
      assert_includes html, "href=\"/?page=2&amp;q=#{query}\""
      html = dashboard("?page=2&q=#{query}")
      assert_equal ['newest-0'], latest_build_ids(html)
      refute_match(%r{href="/builds/older-}, html)
      assert_includes html, "href=\"/?page=1&amp;q=#{query}\""
    end
  end

  def test_latest_failed_shortcut_is_next_to_search_and_opens_the_first_page
    (RECENT_PAGE_SIZE + 1).times do |index|
      add_build("failed-#{index}", command_line: "package-#{index}")
    end
    add_build('succeeded', command_line: 'other', status: 'succeeded')

    html = dashboard('?page=2&q=package')
    shortcut = html.match(%r{<button[^>]*>Search</button></div>\s*<div class="control"><a class="button is-small is-light" href="([^"]+)">Latest failed</a>})
    refute_nil shortcut
    assert_equal '/?q=latest+failed', shortcut[1]

    html = dashboard(shortcut[1].delete_prefix('/'))
    assert_equal RECENT_PAGE_SIZE.downto(1).map { |index| "failed-#{index}" }, latest_build_ids(html)
    refute_includes html, 'href="/builds/succeeded/log"'
    assert_includes html, 'value="latest failed"'
    assert_includes html, 'href="/?page=2&amp;q=latest+failed"'
  end

  def test_pagination_does_not_mark_an_older_build_when_the_latest_is_on_another_page
    add_build('older')
    RECENT_PAGE_SIZE.times { |index| add_build("filler-#{index}", command_line: 'filler') }
    add_build('latest')

    assert_equal ['latest', "filler-#{RECENT_PAGE_SIZE - 1}"], latest_build_ids(dashboard)
    html = dashboard('?page=2')
    assert_includes html, 'href="/builds/older/log"'
    refute_includes html, 'href="/builds/latest/log"'
    assert_empty latest_build_ids(html)
  end
end

class BuildPushBranchTest < Minitest::Test
  def setup
    Dir.children(TEST_ROOT).each { |name| FileUtils.rm_rf(File.join(TEST_ROOT, name)) }
    FileUtils.mkdir_p(OVERLAY_REPO)
    @remote = File.join(TEST_ROOT, 'remote.git')
    git('init', '--bare', @remote)
    git('init', '--initial-branch=master')
    git('remote', 'add', 'origin', @remote)
    git('config', 'alias.pushbranch', '!f() { git push origin "refs/heads/$1:refs/heads/$1" && git branch -D -- "$1"; }; f')
    File.write(File.join(OVERLAY_REPO, 'overlay.txt'), 'master')
    git('add', 'overlay.txt')
    git('commit', '-m', 'Initial overlay')
    git('switch', '-c', 'example')
    File.write(File.join(OVERLAY_REPO, 'overlay.txt'), 'package changes')
    git('commit', '-am', 'Package overlay')
    @package_commit = git('rev-parse', 'example')
    build = Build.new(id: 'push-test', command_line: 'example:nocheck', argv: ['riscvu', 'example:nocheck'],
      pkgbase: 'example', log_path: File.join(TEST_ROOT, 'build.log'), status: 'succeeded',
      environment: {'SWITCHBRANCH' => '1'})
    write_json(STATE_FILE, 'builds' => [build.to_h])
    @manager = BuildManager.new(service: TestBuildService.new)
    @build = @manager.find(build.id)
  end

  def git(*args)
    output, status = Open3.capture2e('git', '-c', 'user.name=Test', '-c', 'user.email=test@example.com',
      '-c', 'commit.gpgsign=false', *args, chdir: OVERLAY_REPO)
    assert status.success?, "git #{args.join(' ')} failed: #{output}"
    output.strip
  end

  def assert_pushed
    assert_empty git('branch', '--list', 'example')
    assert_equal "#{@package_commit}\trefs/heads/example", git('ls-remote', 'origin', 'refs/heads/example')
  end

  def assert_not_pushed
    assert_equal @package_commit, git('rev-parse', 'example')
    assert_empty git('ls-remote', 'origin', 'refs/heads/example')
  end

  def test_push_switches_the_package_branch_to_master_before_pushing_and_deleting_it
    assert_equal 'example', @manager.push_branch(@build.id)
    assert_equal 'master', git('branch', '--show-current')
    assert_pushed
  end

  def test_push_branch_button_disappears_after_the_local_branch_is_deleted
    @build.pkgbase = nil
    app = WebApp.new(@manager)
    app.instance_variable_set(:@read_only, false)
    assert @manager.overlay_branch_exists?('example')
    refute @manager.overlay_branch_exists?('missing')
    git('tag', 'tag-only')
    refute @manager.overlay_branch_exists?('tag-only')
    assert_includes app.send(:push_branch_button, @build), 'action="/builds/push-test/push-branch"'

    @manager.push_branch(@build.id)

    assert_pushed
    refute @manager.overlay_branch_exists?('example')
    assert_empty app.send(:push_branch_button, @build)
  end

  def test_push_leaves_an_unrelated_checkout_and_its_changes_untouched
    git('switch', '-c', 'unrelated', 'master')
    File.write(File.join(OVERLAY_REPO, 'overlay.txt'), 'unrelated local changes')

    assert_equal 'example', @manager.push_branch(@build.id)
    assert_equal 'unrelated', git('branch', '--show-current')
    assert_equal 'unrelated local changes', File.read(File.join(OVERLAY_REPO, 'overlay.txt'))
    assert_pushed
  end

  def test_push_leaves_a_detached_checkout_untouched
    git('switch', '--detach', 'master')
    original = git('rev-parse', 'HEAD')

    assert_equal 'example', @manager.push_branch(@build.id)
    assert_empty git('branch', '--show-current')
    assert_equal original, git('rev-parse', 'HEAD')
    assert_pushed
  end

  def test_push_uses_the_pkgbase_without_nocheck_for_legacy_builds
    @build.pkgbase = nil

    assert_equal 'example', @manager.push_branch(@build.id)
    assert_equal 'master', git('branch', '--show-current')
    assert_pushed
  end

  def test_failed_switch_preserves_local_changes_and_does_not_push
    File.write(File.join(OVERLAY_REPO, 'overlay.txt'), 'uncommitted package changes')

    error = assert_raises(ArgumentError) { @manager.push_branch(@build.id) }
    assert_includes error.message, 'git switch master failed:'
    assert_equal 'example', git('branch', '--show-current')
    assert_equal 'uncommitted package changes', File.read(File.join(OVERLAY_REPO, 'overlay.txt'))
    assert_not_pushed
  end

  def test_master_attached_to_another_worktree_is_not_forced_or_detached
    worktree = File.join(TEST_ROOT, 'master-worktree')
    git('worktree', 'add', worktree, 'master')

    error = assert_raises(ArgumentError) { @manager.push_branch(@build.id) }
    assert_includes error.message, 'git switch master failed:'
    assert_includes error.message, worktree
    assert_equal 'example', git('branch', '--show-current')
    assert_includes git('worktree', 'list', '--porcelain'), "branch refs/heads/master"
    assert_not_pushed
  end

  def test_failed_push_keeps_the_local_package_branch_and_reports_git_output
    git('config', 'remote.origin.pushurl', File.join(TEST_ROOT, 'missing.git'))

    error = assert_raises(ArgumentError) { @manager.push_branch(@build.id) }
    assert_includes error.message, 'git pushbranch example failed:'
    assert_includes error.message, 'missing.git'
    assert_equal 'master', git('branch', '--show-current')
    assert_not_pushed
  end

  def test_push_rejects_unsuccessful_builds_and_builds_without_the_checkbox
    (ACTIVE_STATUSES + %w[failed interrupted]).each do |status|
      @build.status = status
      error = assert_raises(ArgumentError) { @manager.push_branch(@build.id) }
      assert_includes error.message, 'only succeeded builds with Switch overlay branch enabled'
    end
    @build.status = 'succeeded'
    [{}, {'SWITCHBRANCH' => '0'}, {'SWITCHBRANCH' => 'true'}].each do |environment|
      @build.environment = environment
      assert_raises(ArgumentError) { @manager.push_branch(@build.id) }
    end

    assert_equal 'example', git('branch', '--show-current')
    assert_not_pushed
  end

  def test_push_rejects_an_unknown_build_or_invalid_package_branch
    assert_raises(ArgumentError) { @manager.push_branch('missing') }
    ['master', '--force', 'example; touch marker', 'example:nocheck'].each do |pkgbase|
      @build.pkgbase = pkgbase
      error = assert_raises(ArgumentError) { @manager.push_branch(@build.id) }
      assert_includes error.message, 'invalid package overlay branch'
    end

    assert_equal 'example', git('branch', '--show-current')
    assert_not_pushed
  end

  def test_push_rejects_a_package_that_is_queued_again
    pending = @build.to_h.merge('id' => 'pending', 'status' => 'queued')
    write_json(STATE_FILE, 'builds' => [@build.to_h, pending])
    @manager = BuildManager.new(service: TestBuildService.new)

    error = assert_raises(ArgumentError) { @manager.push_branch(@build.id) }
    assert_includes error.message, 'example is already queued or building'
    assert_equal 'example', git('branch', '--show-current')
    assert_not_pushed
  end
end

class BuildRestartTest < Minitest::Test
  def setup
    Dir.children(TEST_ROOT).each { |name| FileUtils.rm_rf(File.join(TEST_ROOT, name)) }
    File.write(BUILD_COMMAND, <<~'RUBY')
      #!/usr/bin/env ruby
      require 'json'
      STDOUT.sync = true
      puts JSON.generate(server: ENV['SERVER'], noupload: ENV['NOUPLOAD'], keepchroot: ENV['KEEPCHROOT'], switchbranch: ENV['SWITCHBRANCH'], argv: ARGV, workdir: Dir.pwd)
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
      elsif ARGV.first.start_with?('stubborn')
        trap('INT') { puts 'Ctrl-C ignored' }
        trap('TERM', 'IGNORE')
        child = fork { sleep }
        puts "stubborn processes=#{Process.pid},#{child}"
        sleep
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

  def editor_app(manager = @manager)
    auth = GitHubAuth.new(editors: 'tester')
    session = {login: 'tester', csrf: 'test-csrf'}
    auth.define_singleton_method(:session) { |_| session }
    app = WebApp.new(manager, auth: auth)
    # Private rendering helpers are also exercised outside the request dispatcher.
    app.instance_variable_set(:@session, session)
    app.instance_variable_set(:@read_only, false)
    app
  end

  def post_request(path, body = '', accept: 'text/html')
    req = WEBrick::HTTPRequest.new(WEBrick::Config::HTTP)
    req.parse(StringIO.new("POST #{path} HTTP/1.1\r\nHost: localhost\r\nAccept: #{accept}\r\nX-CSRF-Token: test-csrf\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}"))
    res = WEBrick::HTTPResponse.new(WEBrick::Config::HTTP)
    editor_app.call(req, res)
    res
  end

  def test_json_submission_returns_created_build_id
    response = post_request('/builds', 'command=example', accept: 'application/json')
    assert_equal 201, response.status
    assert_equal 'application/json', response['Content-Type']
    build = @manager.find(JSON.parse(response.body).fetch('id'))
    assert_equal 'example', build.command_line
    assert_equal 0, finished(build.id).exit_status
  end

  def test_event_stream_includes_final_output_and_exit_status
    build = @manager.enqueue('example')
    finished(build.id)
    req = WEBrick::HTTPRequest.new(WEBrick::Config::HTTP)
    req.parse(StringIO.new("GET /builds/#{build.id}/events HTTP/1.1\r\nHost: localhost\r\n\r\n"))
    res = WEBrick::HTTPResponse.new(WEBrick::Config::HTTP)
    editor_app.call(req, res)
    output = StringIO.new
    res.body.call(output)
    assert_includes output.string, 'build completed'
    assert_includes output.string, 'exit=0'
    assert_includes output.string, '"exit_status":0'
    assert_includes output.string, '"done":true'
  end

  def test_submission_passes_environment_to_worker_and_preserves_it_after_restart
    response = post_request('/builds', 'command=example&NOUPLOAD=1&SERVER=custom-host&KEEPCHROOT=1&SWITCHBRANCH=1', accept: 'application/json')
    assert_equal 201, response.status
    build = finished(JSON.parse(response.body).fetch('id'))
    assert_includes File.read(build.log_path), '"server":"custom-host"'
    assert_includes File.read(build.log_path), '"noupload":"1"'
    assert_includes File.read(build.log_path), '"keepchroot":"1"'
    restart
    assert_equal({'NOUPLOAD' => '1', 'SERVER' => 'custom-host', 'KEEPCHROOT' => '1', 'SWITCHBRANCH' => '1'}, @manager.find(build.id).environment)
    assert_includes File.read(build.log_path), '"switchbranch":"1"'
    assert_nil ENV['SERVER']
    other = finished(@manager.enqueue('other-example').id)
    assert_includes File.read(other.log_path), '"server":null'
    assert_includes File.read(other.log_path), '"keepchroot":null'
    assert_nil ENV['KEEPCHROOT']
  end

  def test_environment_overrides_are_restricted_and_literal
    assert_raises(ArgumentError) { @manager.enqueue('example', environment: {'PATH' => '/tmp'}) }
    assert_raises(ArgumentError) { @manager.enqueue('example', environment: {'SERVER' => 'host; touch /tmp/marker'}) }
    assert_raises(ArgumentError) { @manager.enqueue('example', environment: {'NOUPLOAD' => "1\0"}) }
    build = finished(@manager.enqueue('example', environment: {'NOUPLOAD' => '$(false)', 'SERVER' => ''}).id)
    assert_includes File.read(build.log_path), '"noupload":"$(false)"'
    assert_includes File.read(build.log_path), '"server":""'
  end

  def test_retry_preserves_environment_and_new_builder_clears_server
    build = @manager.enqueue('prompt-env', environment: {'NOUPLOAD' => '1', 'SERVER' => 'custom-host', 'KEEPCHROOT' => '1', 'SWITCHBRANCH' => '1'})
    wait_for { @manager.find(build.id).status == 'waiting_upload' }
    assert_equal 303, post_request("/builds/#{build.id}/retry").status
    retried = @manager.all_builds.find { |entry| entry.id != build.id }
    wait_for { @manager.find(retried.id).status == 'waiting_upload' }
    assert_equal build.environment, retried.environment
    assert_includes File.read(retried.log_path), '"server":"custom-host"'
    assert_includes File.read(retried.log_path), '"noupload":"1"'
    wait_for { @manager.find(build.id).nil? }
    assert_equal 303, post_request("/builds/#{retried.id}/retry", 'new_builder=1').status
    fresh = @manager.all_builds.find { |entry| entry.id != retried.id }
    wait_for { @manager.find(fresh.id).status == 'waiting_upload' }
    assert_equal({'NOUPLOAD' => '1', 'KEEPCHROOT' => '1', 'SWITCHBRANCH' => '1'}, fresh.environment)
    assert_includes File.read(fresh.log_path), '"server":null'
    assert_includes File.read(fresh.log_path), '"noupload":"1"'
    assert_includes File.read(fresh.log_path), '"keepchroot":"1"'
  end

  def test_keep_chroot_checkbox_can_be_enabled_and_disabled_on_retry
    build = @manager.enqueue('prompt-keep-chroot')
    wait_for { @manager.find(build.id).status == 'waiting_upload' }
    app = editor_app
    assert_includes app.send(:start_build_form), 'name="KEEPCHROOT" value="1"> Keep chroot'
    assert_includes app.send(:decision_panel, @manager.find(build.id)), 'name="KEEPCHROOT" value="1"> Keep chroot'

    response = post_request("/builds/#{build.id}/retry", 'keep_chroot_present=1&KEEPCHROOT=1')
    assert_equal 303, response.status
    kept = @manager.all_builds.find { |entry| entry.id != build.id }
    wait_for { @manager.find(kept.id).status == 'waiting_upload' }
    kept = @manager.find(kept.id)
    assert_equal '1', kept.environment['KEEPCHROOT']
    assert_includes File.read(kept.log_path), '"keepchroot":"1"'
    assert_includes app.send(:retry_button, kept), 'name="KEEPCHROOT" value="1" checked> Keep chroot'
    wait_for { @manager.find(build.id).nil? }

    response = post_request("/builds/#{kept.id}/retry", 'keep_chroot_present=1')
    assert_equal 303, response.status
    normal = @manager.all_builds.find { |entry| entry.id != kept.id }
    wait_for { @manager.find(normal.id).status == 'waiting_upload' }
    normal = @manager.find(normal.id)
    assert_equal '0', normal.environment['KEEPCHROOT']
    assert_includes File.read(normal.log_path), '"keepchroot":"0"'
    refute_match(/name="KEEPCHROOT"[^>]*checked/, app.send(:retry_button, normal))
  end

  def test_keep_chroot_is_selected_per_build_and_ignores_daemon_environment
    ENV['KEEPCHROOT'] = '1'
    app = editor_app
    assert_includes app.send(:start_build_form), 'name="KEEPCHROOT" value="1"> Keep chroot'
    default = finished(@manager.enqueue('keep-default').id)
    refute default.environment.key?('KEEPCHROOT')
    assert_includes File.read(default.log_path), '"keepchroot":null'

    response = post_request('/builds', 'command=normal&keep_chroot_present=1', accept: 'application/json')
    assert_equal 201, response.status
    normal = finished(JSON.parse(response.body).fetch('id'))
    assert_equal '0', normal.environment['KEEPCHROOT']
    assert_includes File.read(normal.log_path), '"keepchroot":"0"'

    response = post_request('/builds', 'command=kept&keep_chroot_present=1&KEEPCHROOT=1', accept: 'application/json')
    assert_equal 201, response.status
    kept = finished(JSON.parse(response.body).fetch('id'))
    assert_includes File.read(kept.log_path), '"keepchroot":"1"'
    ENV.delete('KEEPCHROOT')
    restart
    refute @manager.find(default.id).environment.key?('KEEPCHROOT')
    assert_equal '0', @manager.find(normal.id).environment['KEEPCHROOT']
    assert_equal '1', @manager.find(kept.id).environment['KEEPCHROOT']
  ensure
    ENV.delete('KEEPCHROOT')
  end

  def test_overlay_branch_checkbox_is_per_build_and_can_be_disabled_on_retry
    ENV['SWITCHBRANCH'] = '1'
    default = finished(@manager.enqueue('branch-default').id)
    assert_includes File.read(default.log_path), '"switchbranch":null'
    response = post_request('/builds', 'command=prompt-branch&switch_branch_present=1&SWITCHBRANCH=1', accept: 'application/json')
    assert_equal 201, response.status
    build = @manager.find(JSON.parse(response.body).fetch('id'))
    wait_for { @manager.find(build.id).status == 'waiting_upload' }
    assert_includes File.read(build.log_path), '"switchbranch":"1"'
    refute build.environment.key?('KEEPCHROOT')
    app = editor_app
    assert_match(/Keep chroot.*name="SWITCHBRANCH" value="1"> Switch overlay branch/m, app.send(:start_build_form))
    assert_includes app.send(:decision_panel, @manager.find(build.id)), 'name="SWITCHBRANCH" value="1" checked> Switch overlay branch'
    assert_empty WebApp.new(@manager).send(:switch_branch_checkbox)
    restart
    assert_equal '1', @manager.find(build.id).environment['SWITCHBRANCH']
    assert_equal 303, post_request("/builds/#{build.id}/retry", 'switch_branch_present=1').status
    retry_build = @manager.all_builds.find { |entry| entry.pkgbase == build.pkgbase && entry.id != build.id }
    wait_for { @manager.find(retry_build.id).status == 'waiting_upload' }
    assert_equal '0', retry_build.environment['SWITCHBRANCH']
    assert_includes File.read(retry_build.log_path), '"switchbranch":"0"'
    refute_match(/name="SWITCHBRANCH"[^>]*checked/, app.send(:retry_button, retry_build))
  ensure
    ENV.delete('SWITCHBRANCH')
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

  def test_anonymous_pages_keep_status_and_logs_but_reject_all_actions
    builds = (ACTIVE_STATUSES + TERMINAL_STATUSES).map do |status|
      Build.new(id: status, command_line: "package-#{status}", argv: ['riscvu', "package-#{status}"],
        pkgbase: "package-#{status}", log_path: File.join(TEST_ROOT, 'view.log'), status: status)
    end
    File.write(builds.first.log_path, 'build output')
    deferred = {'build' => {'id' => 'later', 'command_line' => 'deferred-package'}, 'wait_for' => 'dependency'}
    manager = Struct.new(:all_builds, :refresh_pending, :deferred_retries).new(builds, ['pending-package'], [deferred])
    manager.define_singleton_method(:find) { |id| all_builds.find { |build| build.id == id } }
    view = WebApp.new(manager)
    request = lambda do |method, path, app = view|
      req = WEBrick::HTTPRequest.new(WEBrick::Config::HTTP)
      req.parse(StringIO.new("#{method} #{path} HTTP/1.1\r\nHost: localhost:9181\r\nContent-Length: 0\r\n\r\n"))
      res = WEBrick::HTTPResponse.new(WEBrick::Config::HTTP)
      app.call(req, res)
      res
    end

    ['/', '/builds/waiting_upload/log', '/builds/failed/log'].each do |path|
      response = request.call('GET', path)
      assert_equal 200, response.status
      refute_match(/method="post"|type="checkbox"|formaction=/, response.body)
    end
    dashboard = request.call('GET', '/').body
    %w[deferred-package dependency].each { |name| assert_includes dashboard, name }
    refute_includes dashboard, 'Pending refresh'
    refute_includes dashboard, 'pending-package'
    assert_includes dashboard, 'name="q"'
    assert_includes dashboard, 'href="/builds/running/log"'
    assert_includes dashboard, 'action="/" method="get"'
    log_page = request.call('GET', '/builds/running/log').body
    assert_includes log_page, 'src="../../log-viewer.js?v=3"'
    assert_includes log_page, 'new EventSource(`events?offset=${offset}`)'
    assert_equal 'build output', request.call('GET', '/builds/running/raw').body.read
    assert_equal 200, request.call('GET', '/builds/running/events').status
    chunk = request.call('GET', '/builds/running/log-chunk?before=5')
    assert_equal 200, chunk.status
    assert_equal({'text' => 'build', 'before' => 0, 'offset' => 5}, JSON.parse(chunk.body))
    assert_equal 200, request.call('GET', '/log-viewer.js').status
    assert_equal 200, request.call('HEAD', '/').status

    actions = %w[/builds /refresh /refresh/add /refresh/clear /deferred/later/cancel] +
      %w[upload retry defer memory-killer push-branch stop kill delete].map { |action| "/builds/waiting_upload/#{action}" }
    actions.each { |path| assert_equal 403, request.call('POST', path).status }
    %w[PUT PATCH DELETE].each { |method| assert_equal 403, request.call(method, '/').status }
    assert_equal 403, request.call('GET', '/builds/running/stop').status
    assert_includes request.call('GET', '/', editor_app(manager)).body, 'method="post"'
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

  def test_memory_killer_action_records_pkgbase_once_and_keeps_upload_pending
    build = @manager.enqueue('prompt-memory:nocheck')
    wait_for { @manager.find(build.id).status == 'waiting_upload' }
    FileUtils.mkdir_p(BUILDER_CACHE_DIR)
    cache = File.join(BUILDER_CACHE_DIR, 'prompt-memory-riscv64')
    other_cache = File.join(BUILDER_CACHE_DIR, 'other-riscv64')
    [cache, other_cache].each { |path| File.write(path, 'builder@small-host') }

    response = post_request("/builds/#{build.id}/memory-killer")
    assert_equal 303, response.status
    assert_includes CGI.unescape(response['Location']), 'prompt-memory added to the memory killer list'
    assert_equal "prompt-memory\n", File.read(MEMORY_KILLER_LIST)
    refute File.exist?(cache)
    assert_equal 'builder@small-host', File.read(other_cache)
    current = @manager.find(build.id)
    assert_equal 'waiting_upload', current.status
    assert_nil current.upload_decision
    refute File.exist?(File.join(WORKER_DIR, build.id, 'upload.json'))
    assert_equal [build.id], @manager.all_builds.map(&:id)

    restart
    assert_equal 303, post_request("/builds/#{build.id}/memory-killer").status
    assert_equal "prompt-memory\n", File.read(MEMORY_KILLER_LIST)
    assert_equal 303, post_request("/builds/#{build.id}/retry").status
    retried = @manager.all_builds.find { |entry| entry.id != build.id }
    wait_for { @manager.find(retried.id).status == 'waiting_upload' }
    assert_includes File.read(retried.log_path), 'builder-cache=false'
  end

  def test_memory_killer_action_preserves_comments_and_handles_missing_final_newline
    build = @manager.enqueue('prompt-memory')
    wait_for { @manager.find(build.id).status == 'waiting_upload' }
    FileUtils.mkdir_p(File.dirname(MEMORY_KILLER_LIST))
    File.write(MEMORY_KILLER_LIST, "# Existing packages\nother-package")
    assert_equal 303, post_request("/builds/#{build.id}/memory-killer").status
    assert_equal "# Existing packages\nother-package\nprompt-memory\n", File.read(MEMORY_KILLER_LIST)

    contents = "# Existing packages\n  prompt-memory # already listed\n"
    File.write(MEMORY_KILLER_LIST, contents)
    assert_equal 303, post_request("/builds/#{build.id}/memory-killer").status
    assert_equal contents, File.read(MEMORY_KILLER_LIST)
  end

  def test_memory_killer_action_rejects_nonwaiting_builds_unknown_ids_and_get_requests
    build = @manager.enqueue('wait-memory')
    wait_for { @manager.find(build.id).status == 'running' }
    response = post_request("/builds/#{build.id}/memory-killer")
    assert_equal 400, response.status
    assert_includes response.body, 'build is not waiting for an upload decision'
    assert_equal 400, post_request('/builds/missing/memory-killer').status

    req = WEBrick::HTTPRequest.new(WEBrick::Config::HTTP)
    req.parse(StringIO.new("GET /builds/#{build.id}/memory-killer HTTP/1.1\r\nHost: localhost\r\n\r\n"))
    res = WEBrick::HTTPResponse.new(WEBrick::Config::HTTP)
    editor_app.call(req, res)
    assert_equal 404, res.status
    refute File.exist?(MEMORY_KILLER_LIST)
  end

  def test_memory_killer_write_error_leaves_upload_pending
    build = @manager.enqueue('prompt-memory')
    wait_for { @manager.find(build.id).status == 'waiting_upload' }
    FileUtils.mkdir_p(MEMORY_KILLER_LIST)

    response = post_request("/builds/#{build.id}/memory-killer")
    assert_equal 400, response.status
    assert_includes response.body, 'Is a directory'
    assert_equal 'waiting_upload', @manager.find(build.id).status
    refute File.exist?(File.join(WORKER_DIR, build.id, 'upload.json'))
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
    editor_app.send(:show_log, nil, res, build.id)
    assert_includes res.body, 'id="decision"'
    assert_includes res.body, "action=\"/builds/#{build.id}/retry\""
    assert_includes res.body, 'Skip upload + retry'
    assert_includes res.body, '<input type="checkbox" name="new_builder" value="1"> New builder'
    refute_match(/name="new_builder"[^>]*checked/, res.body)
    assert_includes res.body, "action=\"/builds/#{build.id}/defer\""
    assert_includes res.body, 'name="wait_for"'
    assert_includes res.body, '>Defer</button>'
    assert_includes res.body, "action=\"/builds/#{build.id}/memory-killer\""
    assert_includes res.body, '>Require 32G+ RAM</button>'
  end

  def test_defer_skips_log_and_retries_once_after_a_new_matching_success
    old_dependency = @manager.enqueue('wait-dependency')
    File.write(File.join(TEST_ROOT, 'release'), '')
    finished(old_dependency.id)
    source = @manager.enqueue('prompt-deferred:nocheck', target_builder: 'pinned-host', environment: {'KEEPCHROOT' => '1', 'SWITCHBRANCH' => '1'})
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
    assert_equal({'KEEPCHROOT' => '1', 'SWITCHBRANCH' => '1'}, result.environment)
    assert_includes File.read(result.log_path), '"keepchroot":"1"'
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
      "==> Making package: tinymist 1.4.1-1 (date)\r\n" \
      "\e]3008;end=build\e\\")
    @manager = new_manager

    assert_equal 'houndour', @manager.find(build.id).build_host
    assert_equal '1.4.1-1', @manager.find(build.id).package_version
    res = WEBrick::HTTPResponse.new(WEBrick::Config::HTTP)
    editor_app.send(:show_log, nil, res, build.id)
    assert_match(/<span id="build-host" class="tag is-light"(?: title="[^"]*")?>houndour<\/span>/, res.body)
    assert_nil JSON.parse(File.read(File.join(worker_directory, 'status.json')))['build_host']

    # The old worker keeps publishing snapshots without a hostname.
    snapshot['status'] = 'waiting_upload'
    write_json(File.join(worker_directory, 'status.json'), snapshot)
    File.write(build.log_path, 'later output without the announcement')
    assert_equal 'waiting_upload', @manager.find(build.id).status
    assert_equal 'houndour', @manager.find(build.id).build_host
    @manager = new_manager
    assert_equal 'houndour', @manager.find(build.id).build_host
    assert_equal '1.4.1-1', @manager.find(build.id).package_version
  end

  def test_older_worker_duration_stays_frozen_after_restart_and_completion
    prompt_at = Time.utc(2026, 9, 10, 1)
    build = Build.new(id: 'older-prompt', command_line: 'example', argv: ['riscvu', 'example'],
      pkgbase: 'example', log_path: File.join(LOG_DIR, 'older-prompt.log'), status: 'waiting_upload',
      started_at: prompt_at - 125, upload_prompt_seen: true,
      unit_name: 'archriscv-buildd-build-older-prompt.service')
    directory = File.join(WORKER_DIR, build.id)
    FileUtils.mkdir_p(directory)
    path = File.join(directory, 'status.json')
    snapshot = build.to_h
    snapshot.delete('upload_prompt_at')
    write_json(path, snapshot)
    File.utime(prompt_at, prompt_at, path)
    write_json(STATE_FILE, 'builds' => [snapshot])
    @manager = new_manager
    assert_equal '2m05s', duration(@manager.find(build.id))

    # Old workers keep publishing snapshots without the prompt timestamp.
    snapshot['status'] = 'running'
    snapshot['upload_decision'] = 'upload'
    write_json(path, snapshot)
    @manager = new_manager
    assert_equal '2m05s', duration(@manager.find(build.id))
    snapshot['status'] = 'failed'
    snapshot['finished_at'] = (prompt_at + 3600).iso8601
    write_json(path, snapshot)
    assert_equal '2m05s', duration(@manager.find(build.id))
    @manager = new_manager
    assert_equal '2m05s', duration(@manager.find(build.id))
  end

  def test_upload_prompt_can_be_answered_after_restart
    build = @manager.enqueue('prompt-upload')
    wait_for { @manager.find(build.id).status == 'waiting_upload' }
    current = @manager.find(build.id)
    prompt_at = current.upload_prompt_at
    refute_nil prompt_at
    assert_operator prompt_at, :>=, current.started_at
    assert_nil current.finished_at
    elapsed = duration(current)
    restart
    assert_equal 'waiting_upload', @manager.find(build.id).status
    assert_equal prompt_at, @manager.find(build.id).upload_prompt_at
    assert_equal elapsed, duration(@manager.find(build.id))
    @manager.answer_upload(build.id, upload: true)
    result = finished(build.id)
    assert_equal 'upload', result.upload_decision
    assert_equal 'failed', result.status
    assert_equal 1, result.exit_status
    assert_equal prompt_at, result.upload_prompt_at
    assert_equal elapsed, duration(result)
    assert_includes File.read(build.log_path), 'answer=y'
    restart
    assert_equal elapsed, duration(@manager.find(build.id))
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
    assert @manager.find(build.id).stop_requested
    refute JSON.parse(File.read(File.join(WORKER_DIR, build.id, 'status.json')))['stop_requested']
    restart
    assert @manager.find(build.id).stop_requested
    @manager.answer_upload(build.id, upload: true)
    result = finished(build.id)
    assert_equal 'upload', result.upload_decision
    assert_includes File.read(build.log_path), 'interrupt received'
    assert_includes File.read(build.log_path), 'answer=y'
    assert_equal 1, @service.starts[build.id]
  end

  def test_kill_after_stop_terminates_a_build_and_descendant_that_ignore_signals
    build = @manager.enqueue('stubborn-kill')
    pids = wait_for do
      next unless File.exist?(build.log_path)

      File.read(build.log_path)[/stubborn processes=([\d,]+)/, 1]&.split(',')
    end
    other = @manager.enqueue('wait-other')
    wait_for { @manager.find(other.id).status == 'running' }
    app = editor_app
    controls = app.send(:stop_button, @manager.find(build.id))
    assert_includes controls, 'data-kill-button style="display:none"'
    assert_equal 400, post_request("/builds/#{build.id}/kill").status
    assert @service.active?(build)

    assert_equal 303, post_request("/builds/#{build.id}/stop").status
    wait_for { File.read(build.log_path).include?('Ctrl-C ignored') }
    assert_equal 'running', @manager.find(build.id).status
    restart
    current = @manager.find(build.id)
    assert current.stop_requested
    controls = app.send(:stop_button, current)
    assert_includes controls, "formaction=\"/builds/#{build.id}/kill\""
    refute_includes controls, 'data-kill-button style="display:none"'
    assert_empty WebApp.new(@manager).send(:stop_button, current)

    assert_equal 303, post_request("/builds/#{build.id}/kill").status
    result = finished(build.id)
    assert_equal 'interrupted', result.status
    assert_equal 137, result.exit_status, "#{result.note}\n#{File.read(build.log_path)}"
    refute @service.active?(build)
    pids.each do |pid|
      state = File.read("/proc/#{pid}/status")[/^State:\s+(\S)/, 1] if File.exist?("/proc/#{pid}/status")
      assert_includes [nil, 'Z', 'X'], state, "build process #{pid} is still running"
    end
    assert_equal 'running', @manager.find(other.id).status
    assert @service.active?(other)
    assert File.exist?(build.log_path)
    assert_empty app.send(:stop_button, result)
    assert_equal 400, post_request("/builds/#{build.id}/kill").status

    req = WEBrick::HTTPRequest.new(WEBrick::Config::HTTP)
    req.parse(StringIO.new("GET /builds/#{build.id}/events?offset=#{File.size(build.log_path)} HTTP/1.1\r\nHost: localhost\r\n\r\n"))
    response = WEBrick::HTTPResponse.new(WEBrick::Config::HTTP)
    editor_app.call(req, response)
    output = StringIO.new
    response.body.call(output)
    assert_includes output.string, '"stop_requested":true'
  end

  def test_kill_remains_available_when_sending_ctrl_c_fails
    build = @manager.enqueue('wait-no-terminal')
    wait_for { @manager.find(build.id).status == 'running' }
    @service.define_singleton_method(:interrupt) { |_| raise 'cannot access build terminal' }
    response = post_request("/builds/#{build.id}/stop")
    assert_equal 400, response.status
    assert_includes response.body, 'cannot access build terminal'
    restart
    assert @manager.find(build.id).stop_requested

    req = WEBrick::HTTPRequest.new(WEBrick::Config::HTTP)
    req.parse(StringIO.new("GET /builds/#{build.id}/kill HTTP/1.1\r\nHost: localhost\r\n\r\n"))
    response = WEBrick::HTTPResponse.new(WEBrick::Config::HTTP)
    editor_app.call(req, response)
    assert_equal 404, response.status
    assert @service.active?(build)
    assert_equal 400, post_request('/builds/missing/kill').status

    assert_equal 303, post_request("/builds/#{build.id}/kill").status
    assert_equal 'interrupted', finished(build.id).status
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
    editor_app.call(req, res)
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
