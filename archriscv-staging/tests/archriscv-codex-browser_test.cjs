'use strict';

// Run with Playwright and Chromium; Ruby serves the real routes with isolated
// recordings and a fake input bridge. No Codex process or package build is run.
const {chromium} = require(process.argv[2] || 'playwright-core');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawn} = require('node:child_process');

(async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-browser-'));
  const id = 'a'.repeat(24);
  const recording = path.join(directory, 'codex', id);
  fs.mkdirSync(recording, {recursive: true});
  let state = {status: 'exited', activity: null};
  function setState(next) {
    state = {...state, ...next};
    fs.writeFileSync(path.join(directory, 'state.new'), JSON.stringify(state));
    fs.renameSync(path.join(directory, 'state.new'), path.join(directory, 'fixture.json'));
  }
  setState({});
  fs.writeFileSync(path.join(recording, 'output'), '');
  fs.writeFileSync(path.join(recording, 'frames'), '');
  fs.writeFileSync(path.join(recording, 'status.json'), '{}');
  function resize(cols, rows) {
    fs.appendFileSync(path.join(recording, 'frames'), JSON.stringify({cols, rows}) + '\n');
  }
  function output(text) {
    const bytes = Buffer.from(text);
    let offset = fs.statSync(path.join(recording, 'output')).size;
    fs.appendFileSync(path.join(recording, 'output'), bytes);
    for (let i = 0; i < bytes.length; i += 65536) {
      const length = Math.min(65536, bytes.length - i);
      offset += length;
      fs.appendFileSync(path.join(recording, 'frames'), JSON.stringify({offset, bytes: length}) + '\n');
    }
  }
  resize(110, 40);
  for (let i = 0; i < 600; i++) output(`\x1b[${i % 2 ? 31 : 32}mhistory ${i} ${'wrapped '.repeat(i % 20)}\x1b[0m\r\n`);
  output('\x1b[38;1Hworking…\x1b[K'.repeat(70000));
  resize(87, 39);
  output('\x1b[8;5Hsaved\x1b7\x1b[2;35r\x1b[12;4Hactive\x1b[?25l\x1b[6n\x1b[33');

  const server = spawn('ruby', ['-e', `
    ENV['ARCHRISCV_BUILDD_STATE_DIR'] = ARGV.fetch(1)
    load ARGV.fetch(0)
    directory = ARGV.fetch(1)
    id = 'a' * 24
    manager = BuildManager.allocate
    manager.define_singleton_method(:codex_sessions) do
      state = JSON.parse(File.read(File.join(directory, 'fixture.json')))
      entry = CodexSession.new(id: id, build_id: 'fixture', pkgbase: 'fixture', status: state.fetch('status'),
        rebuild: false, exit_status: state['status'] == 'running' ? nil : 0)
      entry.activity = state['activity']
      [entry]
    end
    manager.define_singleton_method(:codex_input) do |_id, message|
      target = File.join(directory, 'codex', id)
      if message['action'] == 'resize'
        File.open(File.join(target, 'frames'), 'a') { |f| f.puts(JSON.generate(message.slice('cols', 'rows'))) }
      else
        File.open(File.join(directory, 'input'), 'a') { |f| f.puts(JSON.generate(message)) }
      end
    end
    auth = GitHubAuth.new(editors: 'tester', public_url: 'http://localhost/buildd/')
    auth.define_singleton_method(:session) { |_| {login: 'tester', csrf: 'test'} }
    app = WebApp.new(manager, auth: auth)
    server = WEBrick::HTTPServer.new(BindAddress: '127.0.0.1', Port: 0, AccessLog: [], Logger: WEBrick::Log.new(File::NULL))
    auth.instance_variable_set(:@origin, "http://127.0.0.1:#{server.listeners.first.addr[1]}")
    server.mount_proc('/') do |req, res|
      if req.path == '/buildd/'
        res['Content-Type'] = 'text/html'
        res.body = '<h1>Build dashboard</h1>'
      else
        req.instance_variable_set(:@path, req.path.sub(%r{\\A/buildd}, ''))
        app.call(req, res)
      end
    end
    trap('TERM') { Thread.new { server.shutdown } }
    STDOUT.sync = true
    puts server.listeners.first.addr[1]
    server.start
  `, path.resolve(__dirname, '../archriscv-buildd'), directory], {stdio: ['ignore', 'pipe', 'inherit']});
  let browser;
  try {
    const port = await new Promise((resolve, reject) => {
      server.stdout.once('data', data => resolve(Number(data.toString().trim())));
      server.once('exit', code => reject(new Error(`Ruby fixture exited: ${code}`)));
    });
    browser = await chromium.launch({executablePath: '/usr/bin/chromium', headless: true});
    const page = await browser.newPage({viewport: {width: 1280, height: 1000}});
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.route('https://cdnjs.snrat.com/**', route => route.abort());
    await page.addInitScript(() => {
      let constructor;
      Object.defineProperty(window, 'Terminal', {
        get: () => constructor,
        set: value => { constructor = class extends value { constructor(options) { super(options); window.testTerminal ||= this; } }; }
      });
    });
    const url = `http://127.0.0.1:${port}/buildd/codex/${id}`;
    async function ready() {
      await page.waitForFunction(() => document.querySelector('#codex-terminal')?.getAttribute('aria-busy') === 'false');
      assert.equal(await page.locator('#codex-error').textContent(), '');
    }
    // Build the reference from original bytes at resize boundaries, independently
    // of the server's chunking/coalescing and the browser's streamed NDJSON parser.
    async function compare() {
      const bytes = fs.readFileSync(path.join(recording, 'output'));
      let offset = 0;
      let end = 0;
      const events = [];
      const journal = path.join(recording, 'frames');
      if (fs.existsSync(journal)) {
        for (const line of fs.readFileSync(journal, 'utf8').trim().split('\n')) {
          const event = JSON.parse(line);
          if (event.cols) {
            if (end > offset) events.push({data: bytes.subarray(offset, end).toString('base64')});
            offset = end;
            events.push(event);
          } else end = event.offset;
        }
        if (end > offset) events.push({data: bytes.subarray(offset, end).toString('base64')});
      } else {
        events.push(await page.evaluate(() => ({cols: window.testTerminal.cols, rows: window.testTerminal.rows})));
        events.push({data: bytes.toString('base64')});
      }
      await page.evaluate(async events => {
        const reference = new Terminal({cols: 100, rows: 30, scrollback: 100000});
        for (const event of events) {
          if (event.cols) reference.resize(event.cols, event.rows);
          else await new Promise(resolve => reference.write(Uint8Array.from(atob(event.data), c => c.charCodeAt(0)), resolve));
        }
        function contents(terminal) {
          const buffer = terminal.buffer.normal;
          return {cols: terminal.cols, rows: terminal.rows, x: buffer.cursorX, y: buffer.cursorY,
            lines: Array.from({length: buffer.length}, (_, y) => {
              const line = buffer.getLine(y);
              return [line.isWrapped, line.translateToString(true), Array.from({length: terminal.cols}, (_, x) => {
                const cell = line.getCell(x);
                return [cell.getChars(), cell.getWidth(), cell.getFgColor(), cell.getBgColor(), cell.isBold()];
              })];
            })};
        }
        window.expectedTerminal = JSON.stringify(contents(reference));
        window.terminalContents = contents;
        reference.dispose();
      }, events);
      await page.waitForFunction(() => JSON.stringify(window.terminalContents(window.testTerminal)) === window.expectedTerminal);
    }
    let started = performance.now();
    await page.goto(url);
    await ready();
    const touchPolicy = await page.evaluate(() => {
      const terminal = document.querySelector('#codex-terminal');
      const viewport = terminal.querySelector('.xterm-viewport');
      return {
        body: getComputedStyle(document.body).overscrollBehaviorY,
        page: getComputedStyle(document.querySelector('.codex-page')).overscrollBehavior,
        terminal: getComputedStyle(terminal).overscrollBehavior,
        viewport: getComputedStyle(viewport).overscrollBehaviorY,
        touchAction: getComputedStyle(viewport).touchAction
      };
    });
    assert.deepEqual(touchPolicy, {
      body: 'none', page: 'contain', terminal: 'contain', viewport: 'contain', touchAction: 'pan-y'
    });
    console.log(`Synthetic ${fs.statSync(path.join(recording, 'output')).size}-byte replay: ${Math.round(performance.now() - started)} ms including page/CDN loading`);
    await compare();
    assert.equal(await page.evaluate(() => window.testTerminal.buffer.active.viewportY === window.testTerminal.buffer.active.baseY), true);
    await page.evaluate(() => window.testTerminal.scrollToTop());
    assert.equal(await page.evaluate(() => window.testTerminal.buffer.active.viewportY), 0);
    assert.equal(page.url(), url, 'historical logs stay open while scrolling');
    let resumeCursor = 0;
    await page.route('**/recording?*', async route => {
      await page.unroute('**/recording?*');
      const response = await route.fetch();
      const first = (await response.text()).split('\n')[0];
      assert.equal(JSON.parse(first).more, true);
      resumeCursor = JSON.parse(first).cursor;
      await route.fulfill({status: 200, contentType: 'application/x-ndjson', body: first + '\n'});
    });
    const resumed = page.waitForRequest(request => request.url().includes('/recording?cursor=') &&
      Number(new URL(request.url()).searchParams.get('cursor')) > 0);
    await page.reload();
    assert.equal(Number(new URL((await resumed).url()).searchParams.get('cursor')), resumeCursor);
    await ready();
    await compare();

    setState({status: 'running', activity: 'working'});
    await page.reload();
    await ready();
    await page.waitForFunction(() => window.testTerminal.cols !== 87);
    await compare();
    assert.equal(fs.existsSync(path.join(directory, 'input')), false, 'recorded cursor queries must not be sent back to Codex');
    output('m\x1b8continued\x1b[0m\r\n');
    output(Buffer.from([0xe4, 0xb8]));
    await compare();
    output(Buffer.from([0xad]));
    output('\x1b]2;unfinished');
    await compare();
    output('\x07\x1b[6n');
    await page.waitForFunction(() => document.querySelector('#codex-error').textContent === '');
    await compare();
    await page.waitForTimeout(100);
    assert.match(fs.readFileSync(path.join(directory, 'input'), 'utf8'), /data/);
    await page.locator('.xterm-helper-textarea').focus();
    await page.keyboard.type('hello');
    await page.waitForTimeout(300);
    const input = fs.readFileSync(path.join(directory, 'input'), 'utf8').trim().split('\n').map(line => Buffer.from(JSON.parse(line).data, 'base64').toString()).join('');
    assert.match(input, /hello/);

    setState({activity: 'waiting_for_input'});
    await page.waitForFunction(() => document.querySelector('#codex-status').textContent.includes('waiting for input'));
    setState({activity: 'working'});
    await page.waitForFunction(() => document.querySelector('#codex-status').textContent.includes('working'));
    await page.route('**/frames?*', async route => { await page.unroute('**/frames?*'); await route.fulfill({status: 503, body: 'unavailable'}); });
    await page.waitForResponse(response => response.url().includes('/frames?') && response.status() === 503);
    assert.equal(page.url(), url);
    await page.waitForFunction(() => document.querySelector('#codex-error').textContent === '');
    await page.setViewportSize({width: 1000, height: 750});
    await page.reload();
    await ready();
    await compare();
    for (const status of ['exited', 'stopped', 'failed', 'interrupted']) {
      setState({status, activity: null});
      await page.waitForURL('**/buildd/');
      await page.goto(url);
      await ready();
      await compare();
      assert.equal(page.url(), url);
      setState({status: 'running', activity: 'working'});
      await page.reload();
      await ready();
    }
    await page.route('**/recording?*', async route => {
      setState({status: 'exited', activity: null});
      await page.unroute('**/recording?*');
      await route.continue();
    });
    await page.reload();
    await page.waitForURL('**/buildd/');
    setState({status: 'running', activity: 'working'});
    await page.goto(url);
    await ready();
    await page.route('**/frames?*', route => route.fulfill({status: 403, body: 'expired'}));
    await page.waitForFunction(() => document.querySelector('#codex-error').textContent.includes('Session expired'));
    assert.equal(page.url(), url);
    await page.unroute('**/frames?*');
    setState({status: 'exited', activity: null});
    fs.renameSync(path.join(recording, 'frames'), path.join(recording, 'frames.saved'));
    await page.goto(url);
    await ready();
    await compare();
    fs.renameSync(path.join(recording, 'frames.saved'), path.join(recording, 'frames'));

    if (process.argv[3]) {
      for (const name of ['output', 'frames']) fs.copyFileSync(path.join(process.argv[3], name), path.join(recording, name));
      let requests = 0;
      page.on('request', request => { if (request.url().includes('/recording?')) requests++; });
      started = performance.now();
      await page.goto(url);
      await ready();
      const elapsed = Math.round(performance.now() - started);
      assert.equal(requests, 1);
      await compare();
      console.log(`Captured ${fs.statSync(path.join(recording, 'output')).size}-byte replay: ${elapsed} ms, one recording request, exact screen/cursor/colors`);
      const cdp = await page.context().newCDPSession(page);
      await cdp.send('Emulation.setCPUThrottlingRate', {rate: 4});
      started = performance.now();
      await page.reload();
      await ready();
      console.log(`Captured replay with 4x CPU slowdown: ${Math.round(performance.now() - started)} ms`);
      await cdp.send('Emulation.setCPUThrottlingRate', {rate: 1});
      await cdp.detach();
      await compare();
    }
    assert.deepEqual(errors, []);
    console.log('Chromium: replay, historical geometry, colors, cursor, saved cursor/margins, split UTF-8/CSI/OSC, scrollback, input, reconnect, labels, exit races, legacy output, and HTTP/auth failures passed.');
  } finally {
    await browser?.close();
    const exited = new Promise(resolve => server.once('exit', resolve));
    server.kill('SIGTERM');
    await exited;
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
