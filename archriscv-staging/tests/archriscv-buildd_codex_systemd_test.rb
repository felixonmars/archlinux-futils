# frozen_string_literal: true

# Run explicitly on a host with a user systemd manager:
# ruby archriscv-buildd_codex_systemd_test.rb --name test_codex_systemd_restart_and_exit
# All commands and state are isolated; no real Codex or package build is run.
require_relative 'archriscv-buildd_codex_test'

class CodexSystemdTest < Minitest::Test
  def setup
    @fixture = CodexIntegrationTest.new('systemd')
    @fixture.setup
    %w[systemctl systemd-run].each do |command|
      path = File.join(CODEX_TEST_ROOT, 'bin', command)
      File.write(path, "#!/bin/sh\nexec /usr/bin/#{command} --user \"$@\"\n")
      File.chmod(0o755, path)
    end
    @build_service = SystemdBuildService.new
    @codex_service = SystemdCodexService.new
    @manager = BuildManager.new(service: @build_service, codex_service: @codex_service)
    @fixture.instance_variable_set(:@manager, @manager)
  end

  def teardown
    @manager&.shutdown
    @manager&.codex_sessions&.each { |entry| @codex_service.stop(entry) if @codex_service.active?(entry) }
    @manager&.all_builds&.each { |entry| @build_service.stop(entry) if @build_service.active?(entry) }
    @fixture&.teardown
  end

  def test_codex_systemd_restart_and_exit
    source = @fixture.failed_build('systemd-codex-example')
    session = @fixture.start_codex(source)
    assert @codex_service.active?(session)
    pid, status = Open3.capture2e('systemctl', 'show', '--property=MainPID', '--value', session.unit_name)
    assert status.success?, pid
    assert_operator pid.to_i, :>, 0
    @manager.shutdown
    @manager = BuildManager.new(service: @build_service, codex_service: @codex_service)
    @fixture.instance_variable_set(:@manager, @manager)
    @manager.start
    assert @codex_service.active?(session)
    current, = Open3.capture2e('systemctl', 'show', '--property=MainPID', '--value', session.unit_name)
    assert_equal pid, current
    @fixture.input(session, '/exit')
    retry_id = @fixture.wait_for { @manager.codex_sessions.first.rebuild_id }
    retry_build = @fixture.wait_for { build = @manager.find(retry_id); build if build.terminal? }
    assert_equal 'succeeded', retry_build.status
    assert_equal '1', retry_build.environment['SWITCHBRANCH']
    @fixture.wait_for { !@codex_service.active?(session) }
    assert_equal 2, @manager.all_builds.size
    @manager.shutdown
    @manager = BuildManager.new(service: @build_service, codex_service: @codex_service)
    @fixture.instance_variable_set(:@manager, @manager)
    @manager.start
    assert_equal retry_id, @manager.codex_sessions.first.rebuild_id
    assert_equal 2, @manager.all_builds.size
  end
end
