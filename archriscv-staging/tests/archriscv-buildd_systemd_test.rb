# frozen_string_literal: true

# Run explicitly on a systemd host with permission to manage system services.
# Uses an isolated dashboard, temporary state, and a fake build command.
require 'fileutils'
require 'json'
require 'minitest/autorun'
require 'net/http'
require 'open3'
require 'rbconfig'
require 'socket'
require 'tmpdir'

class SystemdBuildRestartTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir('archriscv-buildd-systemd-test-', '/var/tmp')
    @unit = "archriscv-buildd-test-#{Process.pid}.service"
    @daemon = File.expand_path('../archriscv-buildd', __dir__)
    @build_units = []
    socket = TCPServer.new('127.0.0.1', 0)
    @port = socket.addr[1]
    socket.close
    @command = File.join(@root, 'fake-build')
    File.write(@command, <<~'RUBY')
      #!/usr/bin/env ruby
      require 'rbconfig'
      require 'shellwords'
      STDOUT.sync = true
      root = ENV.fetch('ARCHRISCV_SYSTEMD_TEST_ROOT')
      name = ARGV.first
      File.write(File.join(root, "#{name}.pid"), Process.pid)
      puts "==> Building on test-builder"
      puts "target=#{ENV['SERVER']}"
      if name.start_with?('ssh-owner')
        exit 1 unless system('ssh', '-F', File.join(root, 'ssh_config'), 'test-peer', 'true')
        File.write(File.join(root, "#{name}.ready"), '')
        sleep 0.05 until File.exist?(File.join(root, "#{name}.release"))
      elsif name.start_with?('ssh-client')
        command = [RbConfig.ruby, '-e',
          'File.write(ARGV[0], ""); sleep 0.05 until File.exist?(ARGV[1]); puts "shared session finished"',
          File.join(root, "#{name}.ready"), File.join(root, "#{name}.release")].shelljoin
        exit 1 unless system('ssh', '-F', File.join(root, 'ssh_config'), 'test-peer', command)
      elsif name.start_with?('ssh-interrupt')
        command = [RbConfig.ruby, '-e',
          'STDOUT.sync = true; trap("INT") { File.write(ARGV[0], ""); exit 130 }; puts "waiting for remote Ctrl-C"; sleep 300',
          File.join(root, 'remote-interrupted')].shelljoin
        system('ssh', '-F', File.join(root, 'ssh_config'), '-tt', 'test-peer', command)
        print 'Upload log? [y/N] '
        puts "answer=#{STDIN.gets.to_s.strip}"
        exit 1
      elsif name.start_with?('interrupt')
        interrupted = false
        trap('INT') { interrupted = true }
        child = Process.spawn('sleep', '300')
        File.write(File.join(root, "#{name}.descendant"), child)
        puts 'waiting for Ctrl-C'
        sleep 0.05 until interrupted
        puts 'interrupt received'
        print 'Upload log? [y/N] '
        puts "answer=#{STDIN.gets.to_s.strip}"
        exit 1
      elsif name.start_with?('wait')
        child = Process.spawn('sleep', '300')
        File.write(File.join(root, "#{name}.descendant"), child)
        puts 'waiting for release'
        sleep 0.05 until File.exist?(File.join(root, "#{name}.release"))
      elsif name.start_with?('prompt')
        print 'Upload log? [y/N] '
        puts "answer=#{STDIN.gets.to_s.strip}"
        exit 1
      end
      puts 'build completed'
    RUBY
    File.chmod(0o755, @command)
    start_dashboard
  end

  def teardown
    if @ssh_unit
      Open3.capture2e('ssh', '-F', File.join(@root, 'ssh_config'), '-O', 'exit', 'test-peer')
      Open3.capture2e('systemctl', 'stop', @ssh_unit)
    end
    if @root && File.exist?(File.join(@root, 'state.json'))
      @build_units.concat(builds.filter_map { |build| build['unit_name'] })
    end
    [@unit, *@build_units].compact.uniq.each { |unit| Open3.capture2e('systemctl', 'stop', unit) }
    @stream_thread&.join(3)
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def run_command(*argv)
    output, status = Open3.capture2e(*argv)
    assert status.success?, "#{argv.join(' ')} failed: #{output}"
    output.strip
  end

  def wait_for
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
    loop do
      value = yield
      return value if value
      flunk 'timed out waiting for systemd build' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.1
    end
  end

  def request(path, params = nil)
    uri = URI("http://127.0.0.1:#{@port}#{path}")
    Net::HTTP.start(uri.host, uri.port, nil, open_timeout: 2, read_timeout: 10) do |http|
      if params
        req = Net::HTTP::Post.new(uri)
        req.set_form_data(params)
        http.request(req)
      else
        http.get(uri.request_uri)
      end
    end
  end

  def wait_for_dashboard
    wait_for do
      request('/').code == '200'
    rescue Errno::ECONNREFUSED, EOFError, Net::ReadTimeout
      false
    end
  end

  def start_dashboard
    run_command('systemd-run', '--quiet', '--collect', '--service-type=exec', "--unit=#{@unit}",
      '--property=KillMode=control-group', '--property=TimeoutStopSec=5s',
      "--setenv=ARCHRISCV_BUILDD_STATE_DIR=#{@root}", "--setenv=ARCHRISCV_BUILDD_LOG_DIR=#{@root}/logs",
      "--setenv=ARCHRISCV_BUILDD_BUILD_COMMAND=#{@command}", "--setenv=ARCHRISCV_BUILDD_WORKDIR=#{@root}",
      '--setenv=ARCHRISCV_BUILDD_BUILDER_USER=builder',
      "--setenv=ARCHRISCV_SYSTEMD_TEST_ROOT=#{@root}", '--setenv=ARCHRISCV_BUILDD_BIND=127.0.0.1',
      "--setenv=ARCHRISCV_BUILDD_PORT=#{@port}", '--', RbConfig.ruby, @daemon)
    wait_for_dashboard
  end

  def restart_dashboard
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    run_command('systemctl', 'restart', @unit)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5,
      'dashboard shutdown hung, possibly on an open log stream'
    wait_for_dashboard
  end

  def builds
    JSON.parse(File.read(File.join(@root, 'state.json'))).fetch('builds')
  end

  def find(id)
    builds.find { |build| build['id'] == id }
  end

  def enqueue(name, target = '')
    response = request('/builds', 'command' => name, 'target_builder' => target)
    assert_equal '303', response.code, response.body
    build = builds.reverse.find { |entry| entry['pkgbase'] == name }
    @build_units << build.fetch('unit_name')
    build
  end

  def status(id, expected)
    wait_for { (build = find(id)) && build['status'] == expected && build }
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def start_test_sshd
    socket = TCPServer.new('127.0.0.1', 0)
    port = socket.addr[1]
    socket.close
    key = File.join(@root, 'ssh_key')
    run_command('ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', key)
    File.write(File.join(@root, 'sshd_config'), <<~CONFIG)
      Port #{port}
      ListenAddress 127.0.0.1
      HostKey #{key}
      PidFile #{@root}/sshd.pid
      AuthorizedKeysFile #{key}.pub
      StrictModes no
      PasswordAuthentication no
      KbdInteractiveAuthentication no
      UsePAM no
      PermitRootLogin prohibit-password
      MaxSessions 64
    CONFIG
    File.write(File.join(@root, 'ssh_config'), <<~CONFIG)
      Host test-peer
        HostName 127.0.0.1
        Port #{port}
        User root
        IdentityFile #{key}
        IdentitiesOnly yes
        StrictHostKeyChecking no
        UserKnownHostsFile /dev/null
        BatchMode yes
        ConnectTimeout 5
        ControlMaster auto
        ControlPath #{@root}/ssh-control
        ControlPersist 60
    CONFIG
    @ssh_unit = "archriscv-buildd-test-sshd-#{Process.pid}.service"
    run_command('systemd-run', '--quiet', '--collect', '--service-type=exec', "--unit=#{@ssh_unit}",
      '--', '/usr/bin/sshd', '-D', '-e', '-f', File.join(@root, 'sshd_config'))
    wait_for do
      TCPSocket.new('127.0.0.1', port).close
      true
    rescue Errno::ECONNREFUSED
      false
    end
  end

  def test_shared_ssh_master_survives_owning_build_completion_and_stop
    start_test_sshd
    %w[finish stop].each do |action|
      owner = enqueue("ssh-owner-#{action}")
      wait_for { File.exist?(File.join(@root, "ssh-owner-#{action}.ready")) }
      config = File.join(@root, 'ssh_config')
      master_pid = run_command('ssh', '-F', config, '-O', 'check', 'test-peer')[/pid=(\d+)/, 1].to_i
      assert_operator master_pid, :>, 0
      assert_includes File.read("/proc/#{master_pid}/cgroup"), owner['unit_name']

      client = enqueue("ssh-client-#{action}")
      wait_for { File.exist?(File.join(@root, "ssh-client-#{action}.ready")) }
      if action == 'finish'
        File.write(File.join(@root, "ssh-owner-#{action}.release"), '')
        status(owner['id'], 'succeeded')
      else
        run_command('systemctl', 'stop', owner['unit_name'])
        status(owner['id'], 'interrupted')
      end
      wait_for { !Open3.capture2e('systemctl', 'is-active', owner['unit_name']).last.success? }

      assert process_alive?(master_pid), 'ending the owner killed a shared SSH master'
      assert_equal master_pid, run_command('ssh', '-F', config, '-O', 'check', 'test-peer')[/pid=(\d+)/, 1].to_i
      assert_equal 'running', find(client['id'])['status']
      File.write(File.join(@root, "ssh-client-#{action}.release"), '')
      status(client['id'], 'succeeded')
      assert_includes request("/builds/#{client['id']}/raw").body, 'shared session finished'
      run_command('ssh', '-F', config, '-O', 'exit', 'test-peer')
      wait_for { !process_alive?(master_pid) }
    end

    interrupted = enqueue('ssh-interrupt')
    wait_for { request("/builds/#{interrupted['id']}/raw").body.include?('waiting for remote Ctrl-C') }
    client = enqueue('ssh-client-interrupt')
    wait_for { File.exist?(File.join(@root, 'ssh-client-interrupt.ready')) }
    restart_dashboard
    assert_equal '303', request("/builds/#{interrupted['id']}/stop", {}).code
    status(interrupted['id'], 'waiting_upload')
    assert File.exist?(File.join(@root, 'remote-interrupted')), 'Ctrl-C did not reach the remote terminal'
    assert_equal 'running', find(client['id'])['status']
    assert_equal '303', request("/builds/#{interrupted['id']}/upload", 'decision' => 'yes').code
    assert_equal 'upload', status(interrupted['id'], 'failed')['upload_decision']
    File.write(File.join(@root, 'ssh-client-interrupt.release'), '')
    status(client['id'], 'succeeded')
    assert_includes request("/builds/#{client['id']}/raw").body, 'shared session finished'
  end

  def test_builds_and_controls_survive_real_systemd_restarts
    build = enqueue('wait-running', 'packager@articuno')
    status(build['id'], 'running')
    wait_for { File.exist?(File.join(@root, 'wait-running.descendant')) }
    worker_pid = run_command('systemctl', 'show', '--property=MainPID', '--value', build['unit_name'])
    child_pid = File.read(File.join(@root, 'wait-running.pid')).to_i
    descendant_pid = File.read(File.join(@root, 'wait-running.descendant')).to_i
    assert_operator worker_pid.to_i, :>, 0

    connected = Queue.new
    @stream_thread = Thread.new do
      Net::HTTP.start('127.0.0.1', @port, nil, read_timeout: 10) do |http|
        http.request_get("/builds/#{build['id']}/events") do |response|
          response.read_body { |chunk| connected << true if chunk.include?('event: log') }
        end
      end
    rescue EOFError, IOError, Errno::ECONNRESET
      nil
    end
    wait_for { !connected.empty? }
    restart_dashboard
    assert_equal worker_pid, run_command('systemctl', 'show', '--property=MainPID', '--value', build['unit_name'])
    assert process_alive?(child_pid)
    assert process_alive?(descendant_pid)
    assert_equal 'running', find(build['id'])['status']
    assert_includes request('/').body, 'field has-addons build-inputs'

    run_command('systemctl', 'stop', @unit)
    assert process_alive?(child_pid)
    File.write(File.join(@root, 'wait-running.release'), '')
    wait_for { JSON.parse(File.read(File.join(@root, 'workers', build['id'], 'status.json')))['status'] == 'succeeded' }
    start_dashboard
    assert_equal 'succeeded', find(build['id'])['status']
    assert_includes request("/builds/#{build['id']}/raw").body, 'target=packager@articuno'
    wait_for { !process_alive?(descendant_pid) }

    prompt = enqueue('prompt-upload', 'test-builder')
    status(prompt['id'], 'waiting_upload')
    restart_dashboard
    assert_equal '303', request("/builds/#{prompt['id']}/upload", 'decision' => 'yes').code
    result = status(prompt['id'], 'failed')
    assert_equal 'upload', result['upload_decision']
    assert_equal 1, result['exit_status']
    assert_includes request("/builds/#{prompt['id']}/raw").body, 'answer=y'

    assert_equal '303', request("/builds/#{prompt['id']}/retry", {}).code
    retry_build = builds.reverse.find { |entry| entry['pkgbase'] == 'prompt-upload' && entry['id'] != prompt['id'] }
    @build_units << retry_build['unit_name']
    assert_equal 'builder@test-builder', retry_build['target_builder']
    status(retry_build['id'], 'waiting_upload')
    restart_dashboard
    assert_equal '303', request("/builds/#{retry_build['id']}/upload", 'decision' => 'no').code
    wait_for { find(retry_build['id']).nil? }
    refute File.exist?(retry_build['log_path'])

    stopped = enqueue('interrupt-stop')
    status(stopped['id'], 'running')
    wait_for { request("/builds/#{stopped['id']}/raw").body.include?('waiting for Ctrl-C') }
    child_pid = File.read(File.join(@root, 'interrupt-stop.pid')).to_i
    descendant_pid = File.read(File.join(@root, 'interrupt-stop.descendant')).to_i
    restart_dashboard
    assert_equal '303', request("/builds/#{stopped['id']}/stop", {}).code
    status(stopped['id'], 'waiting_upload')
    assert process_alive?(child_pid)
    assert_nil find(stopped['id'])['note']
    restart_dashboard
    assert_equal '303', request("/builds/#{stopped['id']}/upload", 'decision' => 'yes').code
    assert_equal 'upload', status(stopped['id'], 'failed')['upload_decision']
    assert_includes request("/builds/#{stopped['id']}/raw").body, 'answer=y'
    wait_for { !process_alive?(child_pid) && !process_alive?(descendant_pid) }

    crashed = enqueue('wait-crash')
    status(crashed['id'], 'running')
    run_command('systemctl', 'kill', '--kill-whom=all', '--signal=KILL', crashed['unit_name'])
    restart_dashboard
    assert_equal 'interrupted', find(crashed['id'])['status']
    assert_includes find(crashed['id'])['note'], 'without recording a result'
  end
end
