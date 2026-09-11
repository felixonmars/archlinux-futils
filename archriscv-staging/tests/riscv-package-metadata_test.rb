# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../riscv-package-metadata'

class RiscvPackageMetadataTest < Minitest::Test
  SRCINFO = <<~SRCINFO
    pkgbase = split
      pkgver = 2.0
      pkgrel = 3
      epoch = 1
      arch = x86_64
      depends = runtime>=2
      makedepends = compiler<5
      checkdepends = tester=3
      provides = global=1
      provides_riscv64 = target=2
    pkgname = split-lib
      provides = virtual=4
      provides = unversioned
      depends = split-tool=1:2.0-3
    pkgname = split-tool
    pkgname = split-x86
      arch = x86_64
      provides = excluded=1
  SRCINFO

  def test_versions_survive_parsing_for_package_names_and_provides
    metadata = RiscvPackageMetadata.parse(SRCINFO, 'split', version: '1:2.0-3')

    assert_equal %w[split-lib split-tool], metadata['pkgnames']
    assert_equal %w[split-lib=1:2.0-3 split-tool=1:2.0-3 virtual=4 unversioned target=2 global=1].to_set,
      metadata['provides'].to_set
    assert_equal [['runtime>=2', nil], ['compiler<5', 'make'], ['tester=3', 'check'],
                  ['split-tool=1:2.0-3', nil]].to_set, metadata['dependencies'].to_set
  end

  def test_stale_source_version_is_still_rejected
    error = assert_raises(RiscvPackageMetadata::InvalidMetadata) do
      RiscvPackageMetadata.parse(SRCINFO, 'split', version: '1:2.0-4')
    end
    assert_equal 'stale .SRCINFO version', error.message
  end

  def test_extraction_from_pkgbuild_preserves_versions_and_architecture_overrides
    Dir.mktmpdir('riscv-metadata-test-') do |dir|
      File.write(File.join(dir, 'PKGBUILD'), <<~'PKGBUILD')
        pkgbase=split
        pkgname=(split-lib split-tool split-x86)
        pkgver=2.0
        pkgrel=3.1
        epoch=1
        arch=(x86_64)
        provides=("global=$pkgver")
        provides_riscv64=('target=2')
        makedepends=('compiler>=5')
        package_split-lib() {
          provides=('virtual=4')
          depends=("split-tool=$epoch:$pkgver-$pkgrel")
        }
        package_split-tool() {
          provides=()
        }
        package_split-x86() {
          arch=(x86_64)
          provides=('excluded=1')
        }
      PKGBUILD
      stdout, stderr, status = Open3.capture3('bash', '--noprofile', '--norc', '-c',
        RiscvPackageMetadata::EXTRACT_SCRIPT, chdir: dir)
      assert status.success?, stderr
      metadata = RiscvPackageMetadata.parse(stdout, 'split')

      assert_equal %w[split-lib split-tool], metadata['pkgnames']
      assert_equal %w[split-lib=1:2.0-3.1 split-tool=1:2.0-3.1 virtual=4 target=2].to_set,
        metadata['provides'].to_set
      assert_includes metadata['dependencies'], ['split-tool=1:2.0-3.1', nil]
      assert_includes metadata['dependencies'], ['compiler>=5', 'make']
    end
  end

  def test_cache_with_versionless_provides_is_refreshed
    Dir.mktmpdir('riscv-metadata-cache-test-') do |dir|
      File.write(File.join(dir, 'split.json'), JSON.generate({
        'key' => [2, '1:2.0-3', Digest::SHA256.hexdigest('')],
        'metadata' => {'pkgnames' => ['split-lib'], 'provides' => ['split-lib', 'virtual'], 'dependencies' => []}
      }))
      metadata = RiscvPackageMetadata.new(versions: {'split' => '1:2.0-3'}, patch_repo: dir, cache_dir: dir)
      metadata.define_singleton_method(:load_metadata) do |pkgbase, version, _patch_dir|
        RiscvPackageMetadata.parse(SRCINFO, pkgbase, version: version)
      end

      assert_includes metadata['split']['provides'], 'virtual=4'
      assert_includes metadata['split']['provides'], 'split-lib=1:2.0-3'
      assert_empty metadata.errors
    end
  end
end
