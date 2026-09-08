# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'minitest/autorun'
require 'minitest/mock'
require 'tmpdir'

TEST_ROOT = Dir.mktmpdir('archriscv-telegram-bot-test-')
ENV['ARCHRISCV_BOT_STATE_DIR'] = File.join(TEST_ROOT, 'state')
ENV['ARCHRISCV_BOT_CACHE_DIR'] = File.join(TEST_ROOT, 'cache')
ENV['ARCHRISCV_BOT_ONCE'] = '1'
ENV['ARCHRISCV_BOT_DRY_RUN'] = '0'
ENV['ARCHRISCV_BOT_NOTIFY_EXISTING'] = '0'
ENV['TELEGRAM_BOT_TOKEN'] = 'test-token'
ENV['TELEGRAM_CHAT_ID'] = 'test-chat'
load File.expand_path('../archriscv-telegram-bot', __dir__)

Minitest.after_run { FileUtils.remove_entry(TEST_ROOT) }

class TelegramBotTest < Minitest::Test
  def setup
    FileUtils.rm_rf(STATE_DIR)
    @bot = Object.new
    @state = { 'latestlogs' => {}, 'lastupdates' => {}, 'failures' => {}, 'resolved' => {} }
  end

  def events(*paths)
    parse_index(paths.map.with_index { |path, i| "2026-09-08 12:00:#{format('%02d', i)} #{path}\n" }.join)
  end

  def test_plain_and_color_only_logs_still_classify
    assert_equal 'patch failed', detect_issue("==> Applying RISC-V patches...\nHunk #1 FAILED at 7.\n")
    assert_equal 'build() failed', detect_issue("\e[1;31m==> ERROR:\e[0m A failure occurred in build().\n")
  end

  def test_charset_resets_in_new_logs_do_not_break_failure_patterns
    lines = {
      'patch failed' => ['==>', ' Applying RISC-V patches...'],
      'checksum mismatch' => ['==> ERROR:', ' One or more files did not pass the validity check!'],
      'prepare() failed' => ['==> ERROR:', ' A failure occurred in prepare().'],
      'build() failed' => ['==> ERROR:', ' A failure occurred in build().'],
      'check() failed' => ['==> ERROR:', ' A failure occurred in check().'],
      'package() failed' => ['==> ERROR:', ' A failure occurred in package().'],
      'dependency missing' => ['==> ERROR:', ' Could not resolve all dependencies.']
    }
    lines.each do |expected, (prefix, message)|
      log = "\e[1m\e[31m#{prefix}\e(B\e[m\e[1m#{message}\e(B\e[m\r\n"
      assert_equal expected, detect_issue(log)
    end
  end

  def test_osc_metadata_cannot_hide_or_supply_failure_patterns
    log = "\e]3008;start=example\e\\" \
      "\e[1m\e[31m==> ERROR:\e(B\e[m\e[1m One or more files did not pass the validity check!\e(B\e[m\r\n" \
      "\e]0;==> ERROR: A failure occurred in build().\a" \
      "\e]3008;end=example\e\\"
    assert_equal 'checksum mismatch', detect_issue(log)
  end

  def test_requeued_event_survives_index_rotation_and_is_removed_only_after_success
    item = events('./.status/logs/example/example-1-1.log').first
    @state['latestlogs']['seed'] = {}
    @state['pending'] = { 'latestlogs' => [item[:raw]] }
    @bot.send(:save_state, @state)
    @bot.define_singleton_method(:fetch) do |url, *args, **kwargs|
      url.end_with?('.txt') ? '' : "==> ERROR: A failure occurred in build().\n"
    end
    notifications = []
    fail_send = true
    @bot.define_singleton_method(:send_message) do |text, **kwargs|
      raise 'Telegram unavailable' if fail_send

      notifications << text
      123
    end

    capture_io { @bot.send(:run_bot) }
    assert_equal [item[:raw]], JSON.parse(File.read(STATE_FILE)).dig('pending', 'latestlogs')
    fail_send = false
    @bot.send(:run_bot)
    saved = JSON.parse(File.read(STATE_FILE))
    assert_empty saved.dig('pending', 'latestlogs')
    assert saved['latestlogs'].key?(item[:raw])
    assert_equal 123, saved.dig('failures', 'example', 'message_id')
    @bot.send(:run_bot)
    assert_equal 1, notifications.size
    assert_includes notifications.first, 'issue: build() failed'
  end

  def test_failed_event_does_not_block_later_events_and_is_retried_after_restart
    items = events('unreadable.log', 'working.log')
    processed = []
    _out, err = capture_io do
      @bot.send(:process_events, @state, 'latestlogs', items) do |item|
        raise 'HTTP 403' if item[:path] == 'unreadable.log'

        processed << item[:path]
      end
    end
    assert_includes err, 'unreadable.log: RuntimeError: HTTP 403'
    assert_equal ['working.log'], processed
    saved = JSON.parse(File.read(STATE_FILE))
    assert_equal [items.last[:raw]], saved['latestlogs'].keys

    @bot.send(:process_events, saved, 'latestlogs', items) { |item| processed << item[:path] }
    assert_equal ['working.log', 'unreadable.log'], processed
    assert_equal 2, JSON.parse(File.read(STATE_FILE))['latestlogs'].size
  end

  def test_completed_events_are_saved_before_a_later_event_fails
    items = events('working.log', 'unreadable.log')
    capture_io do
      @bot.send(:process_events, @state, 'latestlogs', items) do |item|
        next if item[:path] == 'working.log'

        assert JSON.parse(File.read(STATE_FILE))['latestlogs'].key?(items.first[:raw])
        raise 'HTTP 403'
      end
    end
    refute JSON.parse(File.read(STATE_FILE))['latestlogs'].key?(items.last[:raw])
  end

  def test_failed_fixed_notification_remains_pending
    item = events('./repo/extra/example-1-1-riscv64.pkg.tar.zst').first
    @state['latestlogs']['seed'] = {}
    @state['failures']['example'] = { 'issue' => 'build() failed', 'message_id' => 42 }
    @bot.send(:save_state, @state)
    @bot.define_singleton_method(:fetch) do |url, *args, **kwargs|
      if url.end_with?('latestlogs.txt')
        ''
      elsif url.end_with?('lastupdate.txt')
        item[:raw]
      end
    end
    @bot.define_singleton_method(:`) { |_command| 'example' }
    attempts = []
    fail_send = true
    @bot.define_singleton_method(:send_message) do |text, **kwargs|
      attempts << [text, kwargs]
      raise 'Telegram unavailable' if fail_send

      43
    end

    capture_io { @bot.send(:run_bot) }
    saved = JSON.parse(File.read(STATE_FILE))
    refute saved['lastupdates'].key?(item[:raw])
    assert saved['failures'].key?('example')

    fail_send = false
    @bot.send(:run_bot)
    saved = JSON.parse(File.read(STATE_FILE))
    assert saved['lastupdates'].key?(item[:raw])
    refute saved['failures'].key?('example')
    assert_equal item[:stamp], saved['resolved']['example']['resolved_at']
    assert_equal 2, attempts.size
    assert_equal({ reply_to_message_id: 42 }, attempts.last[1])
  end

  def test_unreadable_log_does_not_block_package_updates
    item = events('./.status/logs/example/example-1-1.log').first
    update = events('./repo/extra/other-1-1-riscv64.pkg.tar.zst').first
    @state['latestlogs']['seed'] = {}
    @bot.send(:save_state, @state)
    @bot.define_singleton_method(:fetch) do |url, *args, **kwargs|
      case url
      when /latestlogs.txt\z/ then item[:raw]
      when /lastupdate.txt\z/ then update[:raw]
      else raise 'HTTP 403'
      end
    end
    @bot.define_singleton_method(:`) { |_command| 'other' }

    capture_io { @bot.send(:run_bot) }
    saved = JSON.parse(File.read(STATE_FILE))
    refute saved['latestlogs'].key?(item[:raw])
    assert saved['lastupdates'].key?(update[:raw])
  end

  def response(klass, code, body)
    result = klass.new('1.1', code, '')
    result.instance_variable_set(:@read, true)
    result.body = JSON.generate(body)
    result
  end

  def with_telegram(responses)
    requests = []
    sleeps = []
    now = 100.0
    @bot.define_singleton_method(:sleep) { |seconds| sleeps << seconds; now += seconds }
    http = Object.new
    http.define_singleton_method(:request) do |request|
      requests << JSON.parse(request.body)
      responses.shift or raise 'unexpected HTTP request'
    end
    start = lambda { |*args, **kwargs, &block| block.call(http) }
    Process.stub(:clock_gettime, ->(_clock) { now }) do
      Net::HTTP.stub(:start, start) { yield requests, sleeps }
    end
  end

  def test_rate_limit_waits_and_retries_same_notification
    limited = response(Net::HTTPTooManyRequests, '429', parameters: { retry_after: 8 })
    sent = response(Net::HTTPOK, '200', result: { message_id: 123 })
    with_telegram([limited, sent]) do |requests, sleeps|
      capture_io do
        assert_equal 123, @bot.send(:send_message, 'fixed', reply_to_message_id: 42)
      end
      assert_equal [8], sleeps
      assert_equal 2, requests.size
      assert_equal requests.first, requests.last
      assert_equal 42, requests.last['reply_to_message_id']
    end
  end

  def test_messages_are_paced_for_group_limit
    sent = response(Net::HTTPOK, '200', result: { message_id: 123 })
    with_telegram([sent, sent]) do |requests, sleeps|
      2.times { @bot.send(:send_message, 'failed') }
      assert_equal 2, requests.size
      assert_equal 1, sleeps.size
      assert_in_delta 3.1, sleeps.first
    end
  end

  def test_persistent_rate_limit_has_bounded_retries
    limited = response(Net::HTTPTooManyRequests, '429', parameters: { retry_after: 8 })
    with_telegram([limited] * 4) do |requests, sleeps|
      capture_io do
        error = assert_raises(RuntimeError) { @bot.send(:send_message, 'failed') }
        assert_includes error.message, 'HTTP 429'
      end
      assert_equal 4, requests.size
      assert_equal [8, 8, 8], sleeps
    end
  end
end
