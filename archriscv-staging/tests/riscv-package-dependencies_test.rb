# frozen_string_literal: true

require 'minitest/autorun'
require 'pycall'
require_relative '../riscv-package-metadata'

class RiscvPackageDependenciesTest < Minitest::Test
  def setup
    alpm = PyCall.import_module('pyalpm')
    @dependencies = RiscvPackageDependencies.new { |a, b| alpm.vercmp(a, b) }
  end

  def add(name, repo: 'extra', version: '1-1', provides: [], base: name)
    @dependencies.add(name, {'db' => repo, 'version' => version, 'provides' => provides, 'base' => base})
  end

  def classify(*dependencies, own_provides: [], broken: [], outdated: [])
    @dependencies.classify(dependencies, own_provides: own_provides,
      broken: broken.to_set, outdated: outdated.to_set).map(&:to_a)
  end

  def test_repo_order_takes_precedence_over_alphabet_and_health
    add('aaa-extra', provides: ['virtual=2'])
    add('zzz-core', repo: 'core', provides: ['virtual=2'], base: 'core-base')

    assert_equal 'zzz-core', @dependencies.resolve('virtual>=2')['name']
    assert_equal 'core-base', @dependencies.resolve('virtual>=2')['base']
    assert_equal [[], [['virtual>=2', nil]], []],
      classify(['virtual>=2', nil], broken: ['zzz-core'])
  end

  def test_alphabetical_first_provider_is_selected_regardless_of_insertion_order
    add('zzz', provides: ['virtual'])
    add('aaa', provides: ['virtual'])

    assert_equal 'aaa', @dependencies.resolve('virtual')['name']
    assert_equal [[], [], []], classify(['virtual', nil], broken: ['zzz'], outdated: ['zzz'])
    assert_equal [[], [['virtual', nil]], []], classify(['virtual', nil], broken: ['aaa'])
  end

  def test_selected_outdated_provider_is_not_overridden_by_a_later_broken_provider
    add('aaa', provides: ['virtual'])
    add('zzz', provides: ['virtual'])

    assert_equal [[], [], [['virtual', 'make']]],
      classify(['virtual', 'make'], broken: ['zzz'], outdated: ['aaa'])
  end

  def test_version_filter_skips_incompatible_candidates_before_selecting
    add('aaa-core', repo: 'core', provides: ['virtual=1'])
    add('aaa-extra', provides: ['virtual=1.5'])
    add('bbb-extra', provides: ['virtual=2'])
    add('ccc-extra', provides: ['virtual=3'])

    assert_equal 'bbb-extra', @dependencies.resolve('virtual>=2')['name']
    assert_equal [[], [], []], classify(['virtual>=2', nil], broken: ['aaa-core', 'aaa-extra'])
    assert_equal [[], [['virtual>=2', nil]], []],
      classify(['virtual>=2', nil], broken: ['bbb-extra'])
  end

  def test_unversioned_provides_does_not_inherit_the_package_version
    add('aaa', version: '99-1', provides: ['virtual'])
    add('bbb', version: '1-1', provides: ['virtual=2'])

    assert_equal 'aaa', @dependencies.resolve('virtual')['name']
    assert_equal 'bbb', @dependencies.resolve('virtual>=2')['name']
    assert_nil @dependencies.resolve('virtual>=3')
    assert_equal [[['virtual>=3', 'check']], [], []], classify(['virtual>=3', 'check'])
  end

  def test_literal_package_takes_precedence_over_virtual_providers
    add('aaa', repo: 'core', provides: ['virtual=3'])
    add('virtual', version: '2-1')

    assert_equal 'virtual', @dependencies.resolve('virtual>=2')['name']
    assert_equal [[], [], []], classify(['virtual>=2', nil], broken: ['aaa'])
    assert_equal 'aaa', @dependencies.resolve('virtual>=3')['name']
  end

  def test_literal_package_versions_from_both_repositories_are_considered
    add('package', version: '2-1')
    add('package', repo: 'core', version: '1-1')

    assert_equal 'core', @dependencies.resolve('package')['db']
    assert_equal 'extra', @dependencies.resolve('package>=2')['db']
  end

  def test_self_provision_does_not_override_an_incompatible_literal_version
    add('virtual', version: '1-1', provides: ['virtual=3'])
    add('provider', provides: ['virtual=2'])

    assert_equal 'provider', @dependencies.resolve('virtual>=2')['name']
    assert_nil @dependencies.resolve('virtual>=3')
  end

  def test_removal_checks_each_requirement_and_provided_version
    packages = {
      'old' => {'version' => '2-1', 'provides' => ['virtual=2', 'unversioned', 'old=9'], 'depends' => ['self-only']},
      'replacement' => {'version' => '99-1', 'provides' => ['old=2', 'virtual=1', 'unversioned'], 'depends' => []},
      'consumer' => {'version' => '1-1', 'provides' => [], 'depends' => ['old>=2', 'virtual>=2', 'unversioned', 'unversioned>=1', 'old>=9', 'unrelated']}
    }
    packages.each do |name, metadata|
      @dependencies.add(name, metadata.merge('db' => 'extra', 'base' => name))
    end

    requirements = @dependencies.removal_requirements('old', packages)
    assert_equal ['consumer'], requirements.map { |requirement| requirement['name'] }.uniq
    assert_equal ['old>=2', 'virtual>=2', 'unversioned', 'unversioned>=1', 'old>=9'],
      requirements.map { |requirement| requirement['dependency'] }
    assert_equal %w[covered blocked covered unsatisfied unsatisfied],
      requirements.map { |requirement| requirement['status'] }
    assert_equal ['replacement', nil, 'replacement', nil, nil],
      requirements.map { |requirement| requirement['replacement']&.fetch('name') }
  end

  def test_removal_excludes_the_package_as_both_literal_and_virtual_provider
    add('old', version: '2-1', provides: ['virtual=2'])
    add('replacement', provides: ['old=2', 'virtual=2'])

    assert_equal 'old', @dependencies.resolve('old>=2')['name']
    assert_equal 'replacement', @dependencies.resolve('old>=2', excluding: 'old')['name']
    assert_equal 'replacement', @dependencies.resolve('virtual>=2', excluding: 'old')['name']
    assert_nil @dependencies.resolve('old>=3', excluding: 'old')
  end

  def test_removal_with_no_reverse_dependencies
    packages = {'old' => {'version' => '1-1', 'provides' => [], 'depends' => ['old']}}

    assert_empty @dependencies.removal_requirements('old', packages)
  end

  def test_comparisons_use_alpm_epoch_pkgrel_and_soname_semantics
    add('package', version: '1:2.0-3.1', provides: ['virtual=1:2.0-3.1', 'libfoo.so=2-64'])

    %w[package virtual].each do |name|
      %W[#{name}=1:2.0 #{name}>=1:2.0-3 #{name}>1:2.0-3 #{name}>9.0
         #{name}<=1:2.0-3.1 #{name}<1:2.0-4].each do |dependency|
        assert_equal 'package', @dependencies.resolve(dependency)&.fetch('name'), dependency
      end
      %W[#{name}=1:2.0-3 #{name}<1:2.0-3.1 #{name}>1:2.0-3.1
         #{name}>=1:2.0-4 #{name}<=9.0].each do |dependency|
        assert_nil @dependencies.resolve(dependency), dependency
      end
    end
    assert_equal 'package', @dependencies.resolve('libfoo.so=2-64')['name']
    assert_nil @dependencies.resolve('libfoo.so=1-64')
  end

  def test_dependency_labels_keep_constraints_and_dependency_types
    add('outdated', version: '2-1')
    add('broken', version: '2-1')

    assert_equal [[['absent>=2', nil], ['absent>=2', 'make'], ['absent<1', 'check']],
                  [['broken=2', 'check']], [['outdated<=2', 'make']]],
      classify(['absent>=2', nil], ['absent>=2', 'make'], ['absent<1', 'check'],
        ['broken=2', 'check'], ['outdated<=2', 'make'], broken: ['broken'], outdated: ['broken', 'outdated'])
  end

  def test_own_split_outputs_must_satisfy_the_requested_version
    add('split-lib', version: '1-1', provides: ['virtual=1'])
    own_provides = ['split-lib=2-1', 'virtual=2', 'unversioned']

    assert_equal [[['split-lib>=3', nil], ['virtual>=3', 'make'], ['unversioned>=1', 'check']], [], []],
      classify(['split-lib=2', nil], ['virtual>=2', 'make'], ['unversioned', 'check'],
        ['split-lib>=3', nil], ['virtual>=3', 'make'], ['unversioned>=1', 'check'],
        own_provides: own_provides, broken: ['split-lib'], outdated: ['split-lib'])
  end

  def test_own_provides_do_not_override_the_selected_sync_candidate
    add('provider', provides: ['virtual=2'])

    assert_equal [[], [['virtual>=2', nil]], []],
      classify(['virtual>=2', nil], own_provides: ['virtual=2'], broken: ['provider'])
  end
end
