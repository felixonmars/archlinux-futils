# frozen_string_literal: true

# Exercise the JavaScript emitted by the Ruby template using Node.js.
require 'minitest/autorun'
require 'stringio'
require 'tmpdir'
load File.expand_path('../archriscv-buildd', __dir__)

class AnsiLogTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir('archriscv-buildd-ansi-test-')
    @build = Build.new(id: 'ansi-test', command_line: 'test', argv: ['test'], pkgbase: 'test',
      log_path: File.join(@directory, 'test.log'), status: 'succeeded')
    manager = Object.new
    build = @build
    manager.define_singleton_method(:find) { |_| build }
    manager.define_singleton_method(:shutting_down?) { false }
    @app = WebApp.new(manager)
    res = WEBrick::HTTPResponse.new(WEBrick::Config::HTTP)
    @app.send(:show_log, nil, res, @build.id)
    script = res.body[/<script>(.*?)<\/script>/m, 1]
    @parser = script[script.index('let ansiFg =')...script.index('function appendLog')]
    @log_callback = script[/events\.addEventListener\('log', \(event\) => (.*?)\);/, 1]
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def render_cases(cases)
    program = @parser + <<~JS
      const cases = #{JSON.generate(cases)};
      const results = cases.map((chunks) => {
        ansiFg = null;
        ansiBold = false;
        ansiTail = '';
        return chunks.map(ansiToHTML).join('');
      });
      process.stdout.write(JSON.stringify(results));
    JS
    output, errors, status = Open3.capture3('node', stdin_data: program)
    assert status.success?, errors
    JSON.parse(output)
  end

  def test_charset_resets_leave_no_suffix_and_preserve_color
    input = "\e[1m\e[32m==>\e(B\e[m\e[1m Cloning tinymist ...\e(B\e[m\r\n"
    expected = '<span style="color:#9ece6a;font-weight:700">==&gt;</span>' \
      "<span style=\"font-weight:700\"> Cloning tinymist ...</span>\r\n"
    assert_equal [expected], render_cases([[input]])
    assert_equal "==> Cloning tinymist ...\r\n", input.gsub(ANSI_PATTERN, '')
  end

  def test_every_chunk_boundary_in_escape_sequences
    inputs = [
      ["before\e(BafterB", 'beforeafterB'],
      ["\e)0\e*B\e+B\e%G\e#8text", 'text'],
      ["\e7\e[31mred\e(B\e[m\e8 normal", 'red normal'],
      ["\e]0;window title\ahello\e]0;other title\e\\ world", 'hello world'],
      ["\e[?25l\e[2K<hello>\e[?25h", '&lt;hello&gt;']
    ]
    cases = []
    expected = []
    inputs.each do |input, text|
      (0..input.length).each do |split|
        cases << [input[0...split], input[split..]]
        expected << text
      end
      cases << input.chars
      expected << text
    end
    assert_equal expected, render_cases(cases).map { |html| html.gsub(/<[^>]*>/, '') }
  end

  def test_osc_sequences_do_not_swallow_the_builder_announcement
    input = "\e]3008;start=build;hostname=lanturn\e\\" \
      "\e[32m==>\e(B\e[m Building on houndour\r\n" \
      "\e]3008;end=build\e\\"
    assert_equal "==> Building on houndour\r\n", input.gsub(ANSI_PATTERN, '')
    assert_equal 'houndour', input.gsub(ANSI_PATTERN, '').match(HOST_PATTERN)[1]
    assert_equal ["==&gt; Building on houndour\r\n"], render_cases([[input]]).map { |html| html.gsub(/<[^>]*>/, '') }
  end

  def test_live_log_transport_preserves_partial_escapes_and_newlines
    chunks = ["\e[32mfirst\e(", "B\e[m second\r\n", "progress\r42%\r\n\r\n", "\e(", 'BtailB']
    encoded = chunks.map do |chunk|
      output = StringIO.new
      @app.send(:sse, output, 'log', JSON.generate(chunk), id: 1)
      # EventSource combines data lines with LF and removes the final LF.
      output.string.lines.filter_map { |line| line.delete_prefix('data: ').chomp if line.start_with?('data: ') }.join("\n")
    end
    program = @parser + <<~JS
      const rendered = [];
      const received = [];
      function appendLog(text) {
        received.push(text);
        rendered.push(ansiToHTML(text));
      }
      for (const data of #{JSON.generate(encoded)}) {
        const event = {data};
        #{@log_callback};
      }
      process.stdout.write(JSON.stringify({received, html: rendered.join('')}));
    JS
    output, errors, status = Open3.capture3('node', stdin_data: program)
    assert status.success?, errors
    result = JSON.parse(output)
    assert_equal chunks, result['received']
    assert_equal "first second\r\nprogress\r42%\r\n\r\ntailB", result['html'].gsub(/<[^>]*>/, '')
  end
end
