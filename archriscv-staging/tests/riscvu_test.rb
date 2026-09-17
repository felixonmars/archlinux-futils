# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'

class RiscvuTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir('riscvu-test-')
    @capture = File.join(@root, 'build-args')
    @mktemp_capture = File.join(@root, 'mktemp-args')
    @overlay = File.join(@root, 'overlay')
    @branch_capture = File.join(@root, 'overlay-branch')
    @harness = File.join(@root, 'harness.sh')
    # Run the real script with shell stand-ins for all package and remote actions.
    # Skip local configuration so tests never read builder credentials.
    File.write(@harness, <<~'BASH')
      source() {
        case "$1" in
          /usr/local/bin/riscvenv|/usr/share/makepkg/util/message.sh) ;;
          *) builtin source "$@" ;;
        esac
      }
      colorize() { :; }
      error() { printf '%s\n' "$*" >&2; }
      warning() { printf '%s\n' "$*" >&2; }
      mktemp() {
        printf '%s\0' "$@" > "$RISCVU_TEST_MKTEMP_CAPTURE"
        command mktemp -d --tmpdir="$RISCVU_TEST_TMPDIR"
      }
      pkgctl() {
        [[ "$1 $2" == 'repo clone' ]] || return 1
        mkdir -- "$3"
        printf 'pkgname=example\npkgver=1\npkgrel=1\n' > "$3/PKGBUILD"
      }
      sudo() { [[ "$*" == 'pacman -Sy' ]]; }
      pacman() {
        [[ "$1" == '-Sl' ]] || return 1
        if [[ "$2" == core ]]; then
          printf 'core example 1-1\n'
        fi
      }
      git() {
        if [[ "$1" == -C ]]; then
          command git "$@"
        else
          [[ "$*" == 'checkout --detach 1-1' ]]
        fi
      }
      ssh() { printf 'ssh %s\n' "$*"; }
      felixbuild-server-select() { printf 'test-builder\n'; }
      felixbuild() {
        printf '%s\0' "$@" > "$RISCVU_TEST_CAPTURE"
        if [[ -d "$RVPATCHREPO" ]]; then
          command git -C "$RVPATCHREPO" branch --show-current > "$RISCVU_TEST_BRANCH_CAPTURE"
        fi
        printf 'Running %s\n' "$*"
        return "$RISCVU_TEST_EXIT"
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

  def run_build(keepchroot: nil, noupload: nil, switchbranch: nil, exit_status: 0, add_exit_status: 0, nocheck: true)
    Open3.capture3(
      {'KEEPCHROOT' => keepchroot, 'NOUPLOAD' => noupload, 'SWITCHBRANCH' => switchbranch, 'FORCE_PKGVER' => nil,
       'RVPATCHREPO' => @overlay, 'RISCVU_TEST_BRANCH_CAPTURE' => @branch_capture,
       'RISCVU_TEST_CAPTURE' => @capture, 'RISCVU_TEST_EXIT' => exit_status.to_s,
       'RISCVU_TEST_ADD_EXIT' => add_exit_status.to_s, 'RISCVU_TEST_MKTEMP_CAPTURE' => @mktemp_capture,
       'RISCVU_TEST_TMPDIR' => @root},
      'bash', @harness, File.expand_path('../riscvu', __dir__), nocheck ? 'example:nocheck' : 'example', '--testing',
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
    FileUtils.mkdir_p(@overlay)
    overlay_git('init', '--initial-branch=main')
    overlay_git('-c', 'user.name=Test', '-c', 'user.email=test@example.com', '-c', 'commit.gpgsign=false',
      'commit', '--allow-empty', '-m', 'Test fixture')
  end

  def test_selected_overlay_branch_uses_pkgbase_before_building_in_both_upload_modes
    create_overlay
    overlay_git('branch', 'example')
    [nil, '1'].each do |noupload|
      [false, true].each do |nocheck|
        overlay_git('switch', 'main')
        build(keepchroot: nil, noupload: noupload, switchbranch: '1', nocheck: nocheck)
        assert_equal 'example', File.read(@branch_capture).strip
        assert_equal 'example', overlay_git('branch', '--show-current')
      end
    end
  end

  def test_unselected_overlay_branch_keeps_the_current_checkout
    create_overlay
    [nil, '0', '', 'true'].each do |switchbranch|
      build(keepchroot: nil, noupload: nil, switchbranch: switchbranch)
      assert_equal 'main', File.read(@branch_capture).strip
    end
  end

  def test_missing_overlay_branch_stops_before_building
    create_overlay
    output, error, status = run_build(switchbranch: '1')
    assert_equal 1, status.exitstatus, "#{output}\n#{error}"
    assert_includes error, 'invalid reference: example'
    refute File.exist?(@capture)
    assert_equal 'main', overlay_git('branch', '--show-current')
    assert_empty Dir.glob(File.join(@root, 'tmp.*'))
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
