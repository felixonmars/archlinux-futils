# frozen_string_literal: true

require 'minitest/autorun'
require 'minitest/mock'
require 'stringio'
load File.expand_path('../archriscv-buildd', __dir__)

class FakeGitHubAuth < GitHubAuth
  attr_accessor :login_name, :failure
  attr_reader :requests

  def initialize(**options)
    super
    @login_name = 'AllowedUser'
    @requests = []
  end

  private

  def github_json(uri, request)
    @requests << [uri, request]
    raise failure if failure

    uri.host == 'api.github.com' ? {'id' => 123, 'login' => login_name} : {'access_token' => 'github-token'}
  end
end

class BuildAuthTest < Minitest::Test
  def setup
    @auth = FakeGitHubAuth.new(client_id: 'client-id', client_secret: 'client-secret',
      public_url: 'https://buildd.example.com', editors: 'other,alloweduser')
    @build = Build.new(id: 'test', command_line: 'test', argv: ['test'], pkgbase: 'test',
      log_path: '/nonexistent-buildd-auth-test.log', status: 'waiting_upload')
    @manager = Struct.new(:all_builds, :refresh_pending, :deferred_retries, :calls).new([@build], [], [], [])
    @manager.define_singleton_method(:find) { |id| all_builds.find { |build| build.id == id } }
    @manager.define_singleton_method(:enqueue) do |command, **options|
      calls << [command, options]
      all_builds.first
    end
    @app = WebApp.new(@manager, auth: @auth)
  end

  def request(method, path, cookie: nil, params: {}, headers: {}, app: @app)
    body = URI.encode_www_form(params)
    headers = {'Host' => 'buildd.example.com', 'Content-Type' => 'application/x-www-form-urlencoded',
      'Content-Length' => body.bytesize.to_s}.merge(headers)
    headers['Cookie'] = cookie if cookie
    req = WEBrick::HTTPRequest.new(WEBrick::Config::HTTP)
    req.parse(StringIO.new("#{method} #{path} HTTP/1.1\r\n" +
      headers.map { |key, value| "#{key}: #{value}\r\n" }.join + "\r\n#{body}"))
    res = WEBrick::HTTPResponse.new(WEBrick::Config::HTTP)
    app.call(req, res)
    res
  end

  def cookie(response)
    response['Set-Cookie'].split(';').first
  end

  def begin_login
    response = request('GET', '/auth/github', headers: {'Host' => 'untrusted.example'})
    assert_equal 303, response.status
    query = URI.decode_www_form(URI(response['Location']).query).to_h
    [response, query]
  end

  def login(name = 'AllowedUser')
    @auth.login_name = name
    start, query = begin_login
    response = request('GET', "/auth/github/callback?code=test-code&state=#{query.fetch('state')}", cookie: cookie(start))
    assert_equal 303, response.status
    cookie(response)
  end

  def csrf(session_cookie)
    request('GET', '/', cookie: session_cookie).body[/name="_csrf" value="([^"]+)"/, 1]
  end

  def test_login_uses_state_pkce_fixed_callback_and_no_scopes
    start, query = begin_login
    assert_equal 'client-id', query['client_id']
    assert_equal 'https://buildd.example.com/auth/github/callback', query['redirect_uri']
    assert_equal '', query['scope']
    assert_equal 'S256', query['code_challenge_method']
    assert_operator query['state'].length, :>=, 32
    %w[HttpOnly SameSite=Lax Secure Path=/].each { |flag| assert_includes start['Set-Cookie'], flag }

    response = request('GET', "/auth/github/callback?code=test-code&state=#{query['state']}", cookie: cookie(start))
    assert_equal 303, response.status
    assert_equal '/', response['Location']
    refute_equal cookie(start), cookie(response)
    assert_equal 'no-store', response['Cache-Control']
    token_request, user_request = @auth.requests
    token_params = URI.decode_www_form(token_request[1].body).to_h
    assert_equal 'test-code', token_params['code']
    assert_equal 'client-secret', token_params['client_secret']
    assert_equal query['redirect_uri'], token_params['redirect_uri']
    challenge = [OpenSSL::Digest::SHA256.digest(token_params.fetch('code_verifier'))].pack('m0').tr('+/', '-_').delete('=')
    assert_equal query['code_challenge'], challenge
    assert_equal 'https://api.github.com/user', user_request[0].to_s
    assert_equal 'Bearer github-token', user_request[1]['Authorization']
    refute_includes response['Set-Cookie'], 'github-token'
    refute_includes request('GET', '/', cookie: cookie(start)).body, 'Editor'
    assert_includes request('GET', '/', cookie: cookie(response)).body, 'AllowedUser &middot; Editor'
  end

  def test_callback_requires_matching_browser_state_and_is_single_use
    start, query = begin_login
    path = "/auth/github/callback?code=test-code&state=#{query['state']}"
    assert_equal 400, request('GET', path).status
    assert_equal 400, request('GET', '/auth/github/callback?code=test-code&state=wrong', cookie: cookie(start)).status
    other, = begin_login
    assert_equal 400, request('GET', path, cookie: cookie(other)).status
    assert_empty @auth.requests
    assert_equal 303, request('GET', path, cookie: cookie(start)).status
    assert_equal 400, request('GET', path, cookie: cookie(start)).status
    assert_equal 2, @auth.requests.length
  end

  def test_expired_and_cancelled_logins_never_grant_access
    start, query = begin_login
    Time.stub(:now, Time.now + 601) do
      assert_equal 400, request('GET', "/auth/github/callback?code=x&state=#{query['state']}", cookie: cookie(start)).status
    end
    start, query = begin_login
    response = request('GET', "/auth/github/callback?error=access_denied&state=#{query['state']}", cookie: cookie(start))
    assert_equal 400, response.status
    assert_empty @auth.requests
    assert_equal 403, request('POST', '/builds', cookie: cookie(start), params: {command: 'test'}).status
  end

  def test_anonymous_unapproved_and_forged_sessions_cannot_mutate_any_route
    viewer = login('UnlistedUser')
    paths = %w[/builds /refresh /refresh/add /refresh/clear /deferred/test/cancel] +
      %w[upload retry defer memory-killer stop kill delete].map { |action| "/builds/test/#{action}" }
    [nil, viewer, "#{GitHubAuth::COOKIE}=forged"].each do |session_cookie|
      paths.each do |path|
        assert_equal 403, request('POST', path, cookie: session_cookie, params: {command: 'test', _csrf: csrf(viewer)}).status
      end
    end
    html = request('GET', '/', cookie: viewer).body
    assert_includes html, 'UnlistedUser &middot; View only'
    refute_includes html, 'action="/builds"'
    refute_includes request('GET', '/builds/test/log', cookie: viewer).body, 'action="/builds/test/upload"'
    assert_empty @manager.calls
  end

  def test_editor_forms_have_csrf_tokens_and_every_edit_requires_one
    editor = login
    token = csrf(editor)
    refute_nil token
    ['/', '/builds/test/log'].each do |path|
      response = request('GET', path, cookie: editor)
      forms = response.body.scan(/<form[^>]*method="post"[^>]*>(.*?)<\/form>/m).flatten
      refute_empty forms
      forms.each { |form| assert_includes form, %(name="_csrf" value="#{token}") }
      assert_equal 'no-store', response['Cache-Control']
      assert_equal 'Cookie', response['Vary']
      assert_equal 'DENY', response['X-Frame-Options']
    end
    assert_equal 403, request('POST', '/builds', cookie: editor, params: {command: 'test'}).status
    assert_equal 403, request('POST', '/builds', cookie: editor, params: {command: 'test', _csrf: 'wrong'}).status
    assert_equal 403, request('POST', '/builds', cookie: editor, params: {command: 'test', _csrf: token}, headers: {'Origin' => 'https://evil.example'}).status
    assert_equal 403, request('PUT', '/builds', cookie: editor, params: {_csrf: token}).status
    assert_empty @manager.calls
    assert_equal 303, request('POST', '/builds', cookie: editor, params: {command: 'test', _csrf: token}, headers: {'Origin' => 'https://buildd.example.com'}).status
    assert_equal 201, request('POST', '/builds', cookie: editor, params: {command: 'test'}, headers: {'X-CSRF-Token' => token, 'Accept' => 'application/json'}).status
    assert_equal 2, @manager.calls.length
  end

  def test_logout_expiry_and_allowlist_removal_revoke_editing
    editor = login
    token = csrf(editor)
    assert_equal 403, request('POST', '/auth/logout', cookie: editor).status
    response = request('POST', '/auth/logout', cookie: editor, params: {_csrf: token})
    assert_equal 303, response.status
    assert_includes response['Set-Cookie'], 'Max-Age=0'
    assert_equal 403, request('POST', '/builds', cookie: editor, params: {_csrf: token}).status
    editor = login
    token = csrf(editor)
    Time.stub(:now, Time.now + GitHubAuth::SESSION_SECONDS + 1) do
      assert_equal 403, request('POST', '/builds', cookie: editor, params: {_csrf: token}).status
    end
    @auth.instance_variable_set(:@editors, [])
    assert_equal 403, request('POST', '/builds', cookie: editor, params: {_csrf: token}).status
    assert_empty @manager.calls
  end

  def test_shared_app_keeps_concurrent_request_permissions_separate
    editor = login
    viewer = login('UnlistedUser')
    entered = Queue.new
    release = Queue.new
    original = @manager.all_builds
    @manager.define_singleton_method(:all_builds) do
      if Thread.current[:editor_request]
        entered << true
        release.pop
      end
      original
    end
    thread = Thread.new do
      Thread.current[:editor_request] = true
      request('GET', '/', cookie: editor)
    end
    entered.pop
    response = request('GET', '/', cookie: viewer)
    refute_includes response.body, 'action="/builds"'
    release << true
    assert_includes thread.value.body, 'action="/builds"'
    refute_includes request('GET', '/').body, 'action="/builds"'
  ensure
    release << true if release
    thread&.join
  end

  def test_unconfigured_login_fails_closed_and_bad_configuration_is_rejected
    app = WebApp.new(@manager, auth: GitHubAuth.new(client_id: '', client_secret: '', public_url: '', editors: 'AllowedUser'))
    assert_equal 200, request('GET', '/', app: app).status
    assert_equal 400, request('GET', '/auth/github', app: app).status
    assert_equal 403, request('POST', '/builds', app: app).status
    assert_raises(ArgumentError) { GitHubAuth.new(client_id: 'id', client_secret: '', public_url: '') }
    %w[http://public.example https://example.com/../path https://example.com//path https://user:pass@example.com https://example.com?x=1].each do |url|
      assert_raises(ArgumentError) { GitHubAuth.new(client_id: 'id', client_secret: 'secret', public_url: url) }
    end
  end

  def test_subpath_preserves_callback_cookie_forms_links_redirects_and_origin_checks
    @auth = FakeGitHubAuth.new(client_id: 'client-id', client_secret: 'client-secret',
      public_url: 'https://buildd.example.com/buildd/', editors: 'alloweduser')
    @app = WebApp.new(@manager, auth: @auth)
    # The production proxy strips /buildd/ before forwarding each request.
    start, query = begin_login
    assert_equal 'https://buildd.example.com/buildd/auth/github/callback', query['redirect_uri']
    assert_includes start['Set-Cookie'], 'Path=/buildd/;'
    response = request('GET', "/auth/github/callback?code=test-code&state=#{query['state']}", cookie: cookie(start))
    assert_equal 303, response.status
    assert_equal '/buildd/', response['Location']
    assert_includes response['Set-Cookie'], 'Path=/buildd/;'
    editor = cookie(response)
    token = csrf(editor)
    @manager.refresh_pending << 'pending-package'
    @manager.deferred_retries << {'build' => {'id' => 'later', 'command_line' => 'later'}, 'wait_for' => 'dependency'}
    ['/', '/builds/test/log'].each do |path|
      html = request('GET', path, cookie: editor).body
      urls = html.scan(/(?:href|action|formaction)="(\/[^"]*)"/).flatten
      refute_empty urls
      urls.each { |url| assert url.start_with?('/buildd/'), url }
      assert_includes html, 'action="/buildd/auth/logout"'
    end
    html = request('GET', '/').body
    assert_includes html, 'href="/buildd/auth/github"'
    assert_includes html, 'href="/buildd/builds/test/log"'
    assert_equal '/buildd/', request('POST', '/builds', cookie: editor,
      params: {command: 'test', _csrf: token}, headers: {'Origin' => 'https://buildd.example.com'})['Location']
    assert_equal 403, request('POST', '/builds', cookie: editor,
      params: {command: 'test', _csrf: token}, headers: {'Origin' => 'https://evil.example'}).status
    assert_equal 1, @manager.calls.length
    error = request('GET', '/auth/github/callback?state=bad')
    assert_includes error.body, 'href="/buildd/auth/github"'
    logout = request('POST', '/auth/logout', cookie: editor, params: {_csrf: token})
    assert_equal '/buildd/', logout['Location']
    assert_includes logout['Set-Cookie'], 'Path=/buildd/;'
    assert_includes logout['Set-Cookie'], 'Max-Age=0'
  end

  def test_public_url_alone_keeps_subpath_views_available_without_login
    auth = GitHubAuth.new(client_id: '', client_secret: '', public_url: 'https://buildd.example.com/buildd/')
    app = WebApp.new(@manager, auth: auth)
    html = request('GET', '/', app: app).body
    assert_includes html, 'href="/buildd/builds/test/log"'
    refute_includes html, 'Sign in with GitHub'
    assert_equal 403, request('POST', '/builds', app: app).status
  end

  def test_github_failure_does_not_create_session
    @auth.failure = GitHubAuth::Error.new('GitHub login is unavailable. Please try again.')
    start, query = begin_login
    response = request('GET', "/auth/github/callback?code=x&state=#{query['state']}", cookie: cookie(start))
    assert_equal 400, response.status
    assert_nil response['Set-Cookie']
    refute_includes response.body, 'client-secret'
    assert_equal 403, request('POST', '/builds', cookie: cookie(start)).status
  end

  def test_real_exchange_uses_https_and_sanitizes_transport_errors
    auth = GitHubAuth.new(client_id: 'id', client_secret: 'secret', public_url: 'https://buildd.example.com')
    responses = [
      {'access_token' => 'access-token'},
      {'id' => 123, 'login' => 'AllowedUser'}
    ]
    calls = []
    http = Object.new
    http.define_singleton_method(:request) do |req|
      calls << req
      response = Net::HTTPOK.new('1.1', '200', 'OK')
      response.body = JSON.generate(responses.shift)
      response.instance_variable_set(:@read, true)
      response
    end
    transport = lambda do |host, port, **options, &block|
      assert_includes %w[github.com api.github.com], host
      assert_equal 443, port
      assert_equal true, options[:use_ssl]
      assert_equal 5, options[:open_timeout]
      assert_equal 10, options[:read_timeout]
      block.call(http)
    end
    Net::HTTP.stub(:start, transport) do
      assert_equal({'id' => 123, 'login' => 'AllowedUser'}, auth.send(:github_user, 'code', 'verifier'))
    end
    calls.each do |req|
      assert_equal APP_NAME, req['User-Agent']
      assert_equal 'application/json', req['Accept']
    end
    assert_equal 'Bearer access-token', calls.last['Authorization']
    Net::HTTP.stub(:start, ->(*) { raise Net::ReadTimeout, 'private upstream details' }) do
      error = assert_raises(GitHubAuth::Error) { auth.send(:github_user, 'code', 'verifier') }
      refute_includes error.message, 'private upstream details'
    end

    [Net::HTTPBadRequest, Net::HTTPOK].each do |response_type|
      http.define_singleton_method(:request) do |_|
        response = response_type.new('1.1', '400', 'Bad response')
        response.body = 'invalid-json-with-private-details'
        response.instance_variable_set(:@read, true)
        response
      end
      Net::HTTP.stub(:start, transport) do
        error = assert_raises(GitHubAuth::Error) { auth.send(:github_user, 'code', 'verifier') }
        refute_includes error.message, 'private-details'
      end
    end
  end
end
