# frozen_string_literal: true

require 'digest'
require 'etc'
require 'fileutils'
require 'json'
require 'net/http'
require 'open3'
require 'set'
require 'tmpdir'
require 'uri'

class RiscvPackageMetadata
  class InvalidMetadata < StandardError; end
  class MissingSource < StandardError; end
  class PatchFailed < StandardError; end
  class RateLimited < StandardError
    attr_reader :retry_at

    def initialize(retry_at)
      @retry_at = retry_at
      super('GitLab request limit; metadata will be retried after the cooldown')
    end
  end

  CACHE_VERSION = 2
  ERROR_RETRY_SECONDS = 900
  DEPENDENCY_FIELDS = {'depends' => nil, 'makedepends' => 'make', 'checkdepends' => 'check'}.freeze
  EXTRACT_SCRIPT = <<~'BASH'
    source /usr/share/makepkg/srcinfo.sh || exit
    CARCH=riscv64
    CHOST=riscv64-unknown-linux-gnu
    startdir=$PWD
    srcdir=$PWD/src
    pkgdir=$PWD/pkg
    source ./PKGBUILD >&2 || exit
    [[ -n ${pkgname[*]} ]] || exit 1
    [[ " ${arch[*]} " == *' any '* || " ${arch[*]} " == *' riscv64 '* ]] || arch+=(riscv64)

    # Use makepkg's attribute extraction without generating thousands of
    # irrelevant source/checksum fields for large split packages.
    metadata_fields=(arch depends makedepends checkdepends provides
                     depends_riscv64 makedepends_riscv64 checkdepends_riscv64 provides_riscv64)
    srcinfo_open_section pkgbase "${pkgbase:-${pkgname[0]}}"
    for metadata_field in "${metadata_fields[@]}"; do
      pkgbuild_extract_to_srcinfo '' "$metadata_field" 1
    done
    for metadata_package in "${pkgname[@]}"; do
      srcinfo_open_section pkgname "$metadata_package"
      for metadata_field in "${metadata_fields[@]}"; do
        pkgbuild_extract_to_srcinfo "$metadata_package" "$metadata_field" 1
      done
    done
    exit 0
  BASH

  attr_reader :errors

  def initialize(versions:, patch_repo:, cache_dir: '/var/cache/riscv-compare-version')
    @versions = versions
    @patch_repo = patch_repo
    @cache_dir = cache_dir
    @results = {}
    @errors = {}
    @next_request_at = 0
    @retry_at = 0
    FileUtils.mkdir_p(@cache_dir)
  end

  def [](pkgbase)
    return @results[pkgbase] if @results.key?(pkgbase)

    version = @versions.fetch(pkgbase)
    patch_dir = File.join(@patch_repo, pkgbase)
    patch_files = Dir.glob("#{patch_dir}/**/*").select { |path| File.file?(path) }.sort
    patch_hash = Digest::SHA256.new
    patch_files.each { |path| patch_hash << path.delete_prefix(patch_dir) << Digest::SHA256.file(path).hexdigest }
    key = [CACHE_VERSION, version, patch_hash.hexdigest]
    cache_path = File.join(@cache_dir, "#{pkgbase}.json")
    cached = JSON.parse(File.read(cache_path)) if File.file?(cache_path)
    retry_at = cached && (cached['retry_at'] || cached.fetch('time', 0) + ERROR_RETRY_SECONDS)
    # Also recognize failures cached before the explicit patch_failed flag existed.
    patch_failed = cached && (cached['patch_failed'] || cached['error'].to_s.start_with?('patch failed:'))
    if cached && cached['key'] == key && (!cached['error'] || patch_failed || Time.now.to_i < retry_at)
      @errors[pkgbase] = cached['error'] if cached['error']
      return @results[pkgbase] = cached['metadata']
    end

    begin
      metadata = load_metadata(pkgbase, version, patch_dir)
      record = {'key' => key, 'metadata' => metadata}
    rescue StandardError => e
      @errors[pkgbase] = e.message
      warn "#{pkgbase}: dependency metadata unavailable: #{e.message}"
      record = {'key' => key, 'error' => e.message, 'time' => Time.now.to_i}
      record['patch_failed'] = true if e.is_a?(PatchFailed)
      record['retry_at'] = [e.retry_at, Time.now.to_i + ERROR_RETRY_SECONDS].max if e.is_a?(RateLimited)
    end
    File.write("#{cache_path}.tmp", JSON.generate(record))
    File.rename("#{cache_path}.tmp", cache_path)
    @results[pkgbase] = record['metadata']
  rescue JSON::ParserError
    FileUtils.rm_f(cache_path)
    retry
  end

  def prefetch(pkgbases)
    pkgbases.uniq.each { |pkgbase| self[pkgbase] }
  end

  def self.parse(srcinfo, pkgbase, version: nil)
    global = {}
    packages = {}
    section = global
    srcinfo.each_line do |line|
      field, value = line.strip.split(/\s*=\s*/, 2)
      next unless value && !field.start_with?('#')

      if field == 'pkgname'
        section = packages[value] = {}
      else
        (section[field] ||= []) << value unless value.empty?
        section[field] ||= []
      end
    end
    raise InvalidMetadata, 'invalid .SRCINFO' unless global['pkgbase'] == [pkgbase] && !packages.empty?
    if version
      source_version = "#{global.fetch('pkgver', []).first}-#{global.fetch('pkgrel', []).first}"
      epoch = global.fetch('epoch', ['0']).first
      source_version = "#{epoch}:#{source_version}" if epoch.to_i.positive?
      raise InvalidMetadata, 'stale .SRCINFO version' unless source_version == version
    end

    # A global arch=(x86_64) gets extended by felixbuild; explicit split-package
    # arch overrides still restrict which outputs makepkg builds on riscv64.
    packages.select! { |_name, attrs| !attrs.key?('arch') || attrs['arch'].empty? || (attrs['arch'] & %w[any riscv64]).any? }
    dependencies = Set.new
    provides = packages.keys.to_set
    unless packages.empty?
      [global, *packages.values.map { |attrs| global.merge(attrs) }].each do |attrs|
        DEPENDENCY_FIELDS.each do |field, type|
          (attrs.fetch(field, []) + attrs.fetch("#{field}_riscv64", [])).each { |dep| dependencies << [dep, type] }
        end
      end
      packages.each_value do |attrs|
        effective = global.merge(attrs)
        (effective.fetch('provides', []) + effective.fetch('provides_riscv64', [])).each do |dep|
          provides << dep.split(/[<>=]/).first
        end
      end
    end
    {'pkgnames' => packages.keys, 'provides' => provides.to_a, 'dependencies' => dependencies.to_a}
  end

  private

  def fetch(url, redirects = 3)
    raise RateLimited.new(@retry_at) if Time.now.to_i < @retry_at

    delay = @next_request_at - Process.clock_gettime(Process::CLOCK_MONOTONIC)
    sleep(delay) if delay.positive?
    @next_request_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1.1
    uri = URI(url)
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: 10, read_timeout: 30) do |http|
      http.get(uri.request_uri)
    end
    if response.is_a?(Net::HTTPRedirection) && redirects.positive?
      return fetch(URI.join(url, response.fetch('location')).to_s, redirects - 1)
    end
    if response.code == '429'
      delay = response['retry-after'].to_i
      delay = 60 unless delay.positive?
      @retry_at = [@retry_at, Time.now.to_i + delay].max
      raise RateLimited.new(@retry_at)
    end
    raise MissingSource, "HTTP 404 fetching #{uri.path}" if response.code == '404'
    raise "HTTP #{response.code} fetching #{uri.path}" unless response.is_a?(Net::HTTPSuccess)

    response.body
  end

  def load_metadata(pkgbase, version, patch_dir)
    project = "https://gitlab.archlinux.org/archlinux/packaging/packages/#{URI.encode_www_form_component(pkgbase)}"
    tag = URI.encode_www_form_component(version.tr(':', '-'))
    patched = File.file?("#{patch_dir}/PKGBUILD") || File.file?("#{patch_dir}/riscv64.patch")
    unless patched
      begin
        return self.class.parse(fetch("#{project}/-/raw/#{tag}/.SRCINFO"), pkgbase, version: version)
      rescue MissingSource, InvalidMetadata
        # Older releases may not carry .SRCINFO; generate it from that release.
      end
    end

    Dir.mktmpdir('riscv-package-metadata-') do |dir|
      archive = File.join(dir, 'source.tar.gz')
      File.binwrite(archive, fetch("#{project}/-/archive/#{tag}/#{pkgbase}-#{tag}.tar.gz"))
      run('tar', '-xzf', archive, '--strip-components=1', '-C', dir)
      FileUtils.cp_r("#{patch_dir}/.", dir) if File.directory?(patch_dir)
      run('patch', '--batch', '--forward', '-p0', '-i', 'riscv64.patch', chdir: dir) if File.file?("#{dir}/riscv64.patch")
      command = ['bash', '--noprofile', '--norc', '-c', EXTRACT_SCRIPT]
      if Process.uid.zero?
        user = Etc.getpwnam('nobody')
        FileUtils.chown_R(user.uid, user.gid, dir)
        command.unshift('setpriv', "--reuid=#{user.uid}", "--regid=#{user.gid}", '--clear-groups', '--no-new-privs')
      end
      self.class.parse(run('timeout', '60', *command, chdir: dir), pkgbase)
    end
  end

  def run(*command, **options)
    stdout, stderr, status = Open3.capture3(*command, **options)
    unless status.success?
      error_class = command.first == 'patch' ? PatchFailed : RuntimeError
      raise error_class, "#{command.first} failed: #{(stderr.empty? ? stdout : stderr).strip[0, 500]}"
    end

    stdout
  end
end
