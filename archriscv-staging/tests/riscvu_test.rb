# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'timeout'
require 'tmpdir'

class RiscvuTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir('riscvu-test-')
    @capture = File.join(@root, 'build-args')
    @mktemp_capture = File.join(@root, 'mktemp-args')
    @overlay = File.join(@root, 'overlay')
    create_overlay
    @branch_capture = File.join(@root, 'overlay-branch')
    @harness = File.join(@root, 'harness.sh')
    # Run both real scripts with shell stand-ins for all package and remote actions.
    # Skip local configuration so tests never read builder credentials.
    File.write(@harness, <<~'BASH')
      source() {
        case "$1" in
          /usr/local/bin/riscvenv|/usr/share/makepkg/util/message.sh) ;;
          *) builtin source "$@" ;;
        esac
      }
      .() { source "$@"; }
      colorize() { :; }
      msg() { :; }
      msg2() { :; }
      error() { printf '%s\n' "$*" >&2; }
      warning() { printf '%s\n' "$*" >&2; }
      mktemp() {
        printf '%s\0' "$@" > "$RISCVU_TEST_MKTEMP_CAPTURE"
        command mktemp -d --tmpdir="$RISCVU_TEST_TMPDIR"
      }
      pkgctl() {
        [[ "$1 $2" == 'repo clone' ]] || return 1
        mkdir -- "$3"
        printf 'pkgname=%s\npkgver=1\npkgrel=1\n' "$3" > "$3/PKGBUILD"
      }
      sudo() { [[ "$*" == 'pacman -Sy' ]]; }
      pacman() {
        [[ "$1" == '-Sl' ]] || return 1
        if [[ "$2" == core ]]; then
          printf 'core %s 1-1\n' "$PKGBASE"
        fi
      }
      git() {
        if [[ "$1" == -C ]]; then
          command git "$@"
        else
          [[ "$*" == 'checkout --detach 1-1' ]]
        fi
      }
      wait_for_test_gate() {
        [[ -n "$1" ]] || return 0
        touch "$1.ready"
        while [[ ! -e "$1" ]]; do sleep 0.01; done
      }
      ssh() {
        printf 'ssh %s\n' "$*"
        if [[ "$1" == -tt ]]; then
          return "$RISCVU_TEST_EXIT"
        fi
      }
      rsync() {
        if [[ "$2" == "$RVPATCHREPO/$PKGNAME/" ]]; then
          wait_for_test_gate "$RISCVU_TEST_COPY_GATE"
          cat "$RVPATCHREPO/$PKGNAME/branch" > "$RISCVU_TEST_BRANCH_CAPTURE"
        fi
      }
      felixbuild-server-select() {
        if [[ "$RISCVU_TEST_SELECT_EXIT" != 0 ]]; then
          printf 'No eligible servers for %s (riscv64) after applying package restrictions\n' "$PKGBASE" >&2
          return "$RISCVU_TEST_SELECT_EXIT"
        fi
        printf 'test-builder\n'
      }
      felixbuild() {
        printf '%s\0' "$@" > "$RISCVU_TEST_CAPTURE"
        printf 'Running %s\n' "$*"
        (builtin source "$RISCVU_TEST_FELIXBUILD" "$@")
      }
      riscvadd() {
        if [[ "$RISCVU_TEST_ADD_EXIT" != 0 ]]; then
          printf 'gpg: signing failed: Timeout\n' >&2
        fi
        return "$RISCVU_TEST_ADD_EXIT"
      }
      builtin source "$@"
    BASH
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def run_build(keepchroot: nil, noupload: nil, switchbranch: nil, exit_status: 0, add_exit_status: 0, nocheck: true,
      pkgbase: 'example', select_exit_status: 0, environment: {})
    Open3.capture3(
      {'KEEPCHROOT' => keepchroot, 'NOUPLOAD' => noupload, 'SWITCHBRANCH' => switchbranch, 'FORCE_PKGVER' => nil,
       'RVPATCHREPO' => @overlay, 'RISCVU_TEST_BRANCH_CAPTURE' => @branch_capture,
       'RISCVU_TEST_CAPTURE' => @capture, 'RISCVU_TEST_EXIT' => exit_status.to_s,
       'RISCVU_TEST_SELECT_EXIT' => select_exit_status.to_s,
       'RISCVU_TEST_ADD_EXIT' => add_exit_status.to_s, 'RISCVU_TEST_MKTEMP_CAPTURE' => @mktemp_capture,
       'RISCVU_TEST_TMPDIR' => @root, 'RISCVU_TEST_FELIXBUILD' => File.expand_path('../../felixbuild', __dir__)}.merge(environment),
      'bash', @harness, File.expand_path('../riscvu', __dir__), "#{pkgbase}#{':nocheck' if nocheck}", '--testing',
      stdin_data: "n\n", chdir: @root)
  end

  def build(keepchroot:, noupload:, switchbranch: nil, exit_status: 0, add_exit_status: 0, nocheck: true)
    output, error, status = run_build(keepchroot: keepchroot, noupload: noupload, switchbranch: switchbranch,
      exit_status: exit_status, add_exit_status: add_exit_status, nocheck: nocheck)
    assert_equal(exit_status.zero? && add_exit_status.zero? ? 0 : 1, status.exitstatus, "#{output}\n#{error}")
    assert_equal ['-d', '--tmpdir=/var/tmp'], File.binread(@mktemp_capture).split("\0")
    assert_empty Dir.glob(File.join(@root, 'tmp.*')), 'temporary checkout was not cleaned up'
    args = File.binread(@capture).split("\0")
    assert_equal %w[test-builder pkgctl build --arch riscv64], args.first(5)
    assert_equal(nocheck ? %w[--testing --nocheck] : %w[--testing], args.last(nocheck ? 2 : 1))
    [args, output, error]
  end

  def overlay_git(*args)
    output, error, status = Open3.capture3('git', '-C', @overlay, *args)
    assert status.success?, "#{output}\n#{error}"
    output.strip
  end

  def create_overlay
    FileUtils.mkdir_p(File.join(@overlay, 'example'))
    File.write(File.join(@overlay, 'example/branch'), "master\n")
    overlay_git('init', '--initial-branch=master')
    overlay_git('add', '.')
    overlay_git('-c', 'user.name=Test', '-c', 'user.email=test@example.com', '-c', 'commit.gpgsign=false',
      'commit', '-m', 'Test fixture')
    overlay_git('clone', '--bare', @overlay, File.join(@root, 'origin.git'))
    overlay_git('remote', 'add', 'origin', File.join(@root, 'origin.git'))
    overlay_git('fetch', 'origin')
    overlay_git('branch', '--set-upstream-to=origin/master')
  end

  def create_overlay_branch(name)
    overlay_git('switch', '-c', name, 'master')
    FileUtils.mkdir_p(File.join(@overlay, name))
    File.write(File.join(@overlay, name, 'branch'), "#{name}\n")
    overlay_git('add', '.')
    overlay_git('-c', 'user.name=Test', '-c', 'user.email=test@example.com', '-c', 'commit.gpgsign=false',
      'commit', '-m', 'Branch fixture')
  end

  def test_selected_overlay_branch_is_exported_with_checkout_on_master_in_both_upload_modes
    create_overlay_branch('example')
    [nil, '1'].each do |noupload|
      [false, true].each do |nocheck|
        build(keepchroot: nil, noupload: noupload, switchbranch: '1', nocheck: nocheck)
        assert_equal 'example', File.read(@branch_capture).strip
        assert_equal 'master', overlay_git('branch', '--show-current')
      end
    end
  end

  def test_unselected_overlay_branch_uses_master
    create_overlay_branch('example')
    [nil, '0', '', 'true'].each do |switchbranch|
      build(keepchroot: nil, noupload: nil, switchbranch: switchbranch)
      assert_equal 'master', File.read(@branch_capture).strip
      assert_equal 'master', overlay_git('branch', '--show-current')
    end
  end

  def test_master_is_pulled_before_exporting
    create_overlay_branch('example')
    overlay_git('push', 'origin', 'example:master')
    build(keepchroot: nil, noupload: nil)
    assert_equal 'example', File.read(@branch_capture).strip
    assert_equal 'master', overlay_git('branch', '--show-current')
    assert_equal overlay_git('rev-parse', 'example'), overlay_git('rev-parse', 'master')
  end

  def test_pull_failure_stops_before_building
    overlay_git('remote', 'set-url', 'origin', File.join(@root, 'missing.git'))
    output, error, status = run_build
    assert_equal 1, status.exitstatus, "#{output}\n#{error}"
    refute File.exist?(@capture)
    assert_empty Dir.glob(File.join(@root, 'tmp.*'))
  end

  def test_missing_overlay_branch_stops_before_building
    output, error, status = run_build(switchbranch: '1')
    assert_equal 1, status.exitstatus, "#{output}\n#{error}"
    assert_includes error, 'not a valid object name: refs/heads/example'
    refute File.exist?(@capture)
    assert_equal 'master', overlay_git('branch', '--show-current')
    assert_empty Dir.glob(File.join(@root, 'tmp.*'))
  end

  def test_server_selection_failure_stops_before_building_in_both_upload_modes
    [nil, '1'].each do |noupload|
      output, error, status = run_build(noupload: noupload, select_exit_status: 1)
      assert_equal 1, status.exitstatus, "#{output}\n#{error}"
      assert_includes error, 'No eligible servers for example (riscv64)'
      refute File.exist?(@capture)
      refute_includes output, '.nocheck'
      assert_empty Dir.glob(File.join(@root, 'tmp.*'))
    end
  end

  def test_concurrent_builds_copy_independent_overlay_snapshots
    create_overlay_branch('example')
    create_overlay_branch('other')
    copy_gate = File.join(@root, 'copy')
    second_branch = File.join(@root, 'second-branch')
    first = Thread.new do
      run_build(switchbranch: '1', environment: {'RISCVU_TEST_COPY_GATE' => copy_gate})
    end
    Timeout.timeout(10) { sleep 0.01 until File.exist?("#{copy_gate}.ready") }
    second = Thread.new do
      run_build(switchbranch: '1', noupload: '1', pkgbase: 'other', environment: {
        'RISCVU_TEST_BRANCH_CAPTURE' => second_branch})
    end
    output, error, status = Timeout.timeout(10) { second.value }
    assert status.success?, "#{output}\n#{error}"
    assert_equal 'other', File.read(second_branch).strip
    FileUtils.touch(copy_gate)
    output, error, status = Timeout.timeout(10) { first.value }
    assert status.success?, "#{output}\n#{error}"
    assert_equal 'example', File.read(@branch_capture).strip
    assert_equal 'master', overlay_git('branch', '--show-current')
    assert_empty Dir.glob(File.join(@root, 'tmp.*'))
  ensure
    FileUtils.touch(copy_gate) if copy_gate
    Timeout.timeout(10) { [first, second].compact.each(&:join) }
  end

  def test_signing_failures_stop_before_updating_nocheck_status
    [nil, '1'].each do |noupload|
      [false, true].each do |nocheck|
        [1, 2, 124].each do |add_exit_status|
          _, output, error = build(keepchroot: nil, noupload: noupload,
            add_exit_status: add_exit_status, nocheck: nocheck)
          assert_includes error, 'gpg: signing failed: Timeout'
          refute_includes output, '.nocheck'
          refute_includes error, 'Marking'
        end
      end
    end
  end

  def test_default_and_disabled_builds_keep_automatic_worker_selection
    [nil, '0', '', 'true'].each do |keepchroot|
      [nil, '1'].each do |noupload|
        args, = build(keepchroot: keepchroot, noupload: noupload)
        assert_equal %w[test-builder pkgctl build --arch riscv64 --testing --nocheck], args
      end
    end
  end

  def test_kept_chroots_use_unique_workers_for_every_attempt_in_both_upload_modes
    workers = []
    [nil, '1'].each do |noupload|
      [0, 1].each do |exit_status|
        args, output = build(keepchroot: '1', noupload: noupload, exit_status: exit_status)
        assert_equal '--worker', args[5]
        worker = args[6]
        assert_match(/\Akeep-example-[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/, worker)
        assert_includes output, worker, 'the retained worker must be discoverable in the build log'
        workers << worker
      end
    end
    assert_equal workers.size, workers.uniq.size
  end
end
