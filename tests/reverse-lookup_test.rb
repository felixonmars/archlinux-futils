require 'minitest/autorun'
require 'minitest/mock'
require 'rubygems/package'
require 'tmpdir'
require 'zlib'

load File.expand_path('../reverse-lookup', __dir__)

class ReverseLookupTest < Minitest::Test
    Status = Struct.new(:exitstatus) do
        def success?
            exitstatus == 0
        end
    end

    def setup
        @directory = Dir.mktmpdir('reverse-lookup-test-')
        @commands = []
        @extractions = []
    end

    def teardown
        FileUtils.remove_entry(@directory)
    end

    def python_matches(content, name = 'foo-bar', file = 'sample.dist-info/METADATA')
        ReverseLookup.matching_lines('python', name, file, content)
    end

    def test_python_names_are_normalized_and_match_exactly
        metadata = <<~METADATA
            Requires-Dist: Foo_Bar
            Requires-Dist: foo.bar>=2
            Requires-Dist: foo---bar[extra]; python_version >= "3.10"
            Requires-Dist: foo-bar-tools
            Requires-Dist: fooxbar
        METADATA
        assert_equal metadata.lines.first(3).map(&:chomp), python_matches(metadata, 'Foo..Bar')
        assert_empty python_matches("Requires-Dist: fooxbar\n", 'foo.bar')
    end

    def test_python_headers_are_unfolded_and_description_is_ignored
        metadata = "Name: example\r\nRequires-Dist: foo-bar\r\n  (>=2)\r\n\r\nRequires-Dist: foo-bar-fake\r\nRequires-Dist: foo-bar\r\n"
        assert_equal ['Requires-Dist: foo-bar (>=2)'], python_matches(metadata)
    end

    def test_legacy_python_metadata
        assert_equal ['Requires-Dist: foo-bar'],
            python_matches("Requires-Dist: foo-bar\n", 'foo-bar', 'sample.egg-info/PKG-INFO')
    end

    def test_egg_extras_are_local_to_each_file_and_bare_names_match
        requirements = <<~REQUIREMENTS
            foo-bar
            [test]
            foo_bar>=2
            [:python_version < "3.10"]
            foo.bar
            []
            foo-bar[extra]
            foo-bar-tools
        REQUIREMENTS
        assert_equal ['foo-bar', 'foo_bar>=2 [test]', 'foo.bar [:python_version < "3.10"]', 'foo-bar[extra]'],
            python_matches(requirements, 'foo-bar', 'first.egg-info/requires.txt')
        assert_equal ['foo-bar'], python_matches("foo-bar\n", 'foo-bar', 'second.egg-info/requires.txt')
    end

    def test_ruby_runtime_development_and_legacy_dependencies
        gemspec = <<~GEMSPEC
            s.add_runtime_dependency(%q<rack>.freeze, [">= 2".freeze])
            spec.add_development_dependency('rack', '~> 3')
            spec.add_dependency "rack", ">= 1"
            s.add_runtime_dependency(%q<rack-test>.freeze, [">= 0".freeze])
            s.add_dependency('Rack')
            # s.add_dependency('rack')
            raise 'gemspec must not be executed'
        GEMSPEC
        assert_equal gemspec.lines.first(3).map(&:chomp),
            ReverseLookup.matching_lines('ruby', 'rack', 'sample.gemspec', gemspec)
    end

    def test_lua_runtime_build_test_and_platform_dependencies
        rockspec = <<~'ROCKSPEC'
            description = { summary = "braces } {", detailed = [=[
                dependencies = { "luafilesystem >= 99" }
            ]=] }
            -- dependencies = { "luafilesystem >= 98" }
            --[=[ dependencies = { "luafilesystem >= 97" } ]=]
            dependencies = {
                "lua >= 5.1", "luafilesystem >= 1.8", 'luafilesystem-extra',
                platforms = { ["windows"] = { "luafilesystem >= 1.7" } }
            }
            build_dependencies = { 'luafilesystem' }
            test_dependencies = { [[luafilesystem ~> 1.0]] }
            build = { modules = { dependencies = { "luafilesystem >= 96" } } }
            error("rockspec must not be executed")
        ROCKSPEC
        assert_equal [
            'dependencies: luafilesystem >= 1.8',
            'dependencies.platforms.windows: luafilesystem >= 1.7',
            'build_dependencies: luafilesystem',
            'test_dependencies: luafilesystem ~> 1.0'
        ], ReverseLookup.matching_lines('lua', 'luafilesystem', 'sample.rockspec', rockspec)
    end

    def test_lua_namespaces_and_exact_names
        rockspec = 'dependencies = { "owner/rock >= 1", "owner/rock-extra", "rock" }'
        assert_equal ['dependencies: owner/rock >= 1'],
            ReverseLookup.matching_lines('lua', 'owner/rock', 'sample.rockspec', rockspec)
    end

    def test_pc_variables_continuations_and_requirement_fields
        metadata = <<~'PC'
            suffix=+-3.0
            dependency=gtk${suffix}
            Name: sample
            Description: gtk+-3.0
            Version: 1
            # Requires: gtk+-3.0 >= 99
            Requires: ${dependency} >= 3.24, other=1.0 # gtk+-3.0 >= 98
            Requires.private: other, \
                ${dependency}>3.0
            Requires.internal: gtk+-3.0
            Requires.shared: gtk+-3.0 != 3.0
            Conflicts: gtk+-3.0
            Provides: gtk+-3.0
            Requires: gtk+-3.00
        PC
        assert_equal [
            'Requires: gtk+-3.0 >= 3.24, other=1.0',
            'Requires.private: other,     gtk+-3.0>3.0',
            'Requires.internal: gtk+-3.0',
            'Requires.shared: gtk+-3.0 != 3.0'
        ], ReverseLookup.matching_lines('pc', 'gtk+-3.0', 'sample.pc', metadata)
        assert_empty ReverseLookup.matching_lines('pc', '3.24', 'sample.pc', metadata)
    end

    def test_pc_variables_do_not_leak_between_files_and_escaped_variables_are_literal
        first = "dependency=foo\nRequires: ${dependency}\n"
        assert_equal ['Requires: foo'], ReverseLookup.matching_lines('pc', 'foo', 'first.pc', first)
        assert_empty ReverseLookup.matching_lines('pc', 'foo', 'second.pc', 'Requires: ${dependency}')
        assert_empty ReverseLookup.matching_lines('pc', 'foo', 'third.pc', "dependency=foo\nRequires: $${dependency}\n")
    end

    def test_ocaml_predicates_subpackages_and_comments
        metadata = <<~'META'
            # requires = "lwt fake"
            description = "requires = \"lwt\""
            requires = "lwt, unix lwt.unix lwt-react"
            requires(mt, -mt_vm) += "threads lwt"
            package "unix" (requires = "lwt.unix" requires(native) = "lwt dynlink")
            requires = # a comment between tokens
                "lwt"
        META
        assert_equal [
            'requires= "lwt, unix lwt.unix lwt-react"',
            'requires(mt,-mt_vm)+= "threads lwt"',
            'requires(native)= "lwt dynlink"',
            'requires= "lwt"'
        ], ReverseLookup.matching_lines('ocaml', 'lwt', 'META', metadata)
        assert_equal ['requires= "lwt, unix lwt.unix lwt-react"', 'requires= "lwt.unix"'],
            ReverseLookup.matching_lines('ocaml', 'lwt.unix', 'META', metadata)
        assert_empty ReverseLookup.matching_lines('ocaml', 'fake', 'META', metadata)
    end

    def test_highlighting_marks_only_dependency_names_in_each_format
        examples = [
            ['python', 'foo.bar', 'sample.dist-info/METADATA',
             'Requires-Dist: Foo_Bar[foo.bar]; extra == "foo.bar"',
             "Requires-Dist: \e[1;31mFoo_Bar\e[0m[foo.bar]; extra == \"foo.bar\""],
            ['python', 'foo.bar', 'sample.egg-info/requires.txt',
             "[foo.bar]\nfoo_bar[foo.bar]>=2",
             "\e[1;31mfoo_bar\e[0m[foo.bar]>=2 [foo.bar]"],
            ['ruby', 'dependency', 'sample.gemspec',
             'spec.add_dependency("dependency", ">= 1") # dependency',
             "spec.add_dependency(\"\e[1;31mdependency\e[0m\", \">= 1\") # dependency"],
            ['ruby', 'rack', 'sample.gemspec',
             's.add_runtime_dependency(%q<rack>.freeze, [">= 2".freeze]) # rack',
             "s.add_runtime_dependency(%q<\e[1;31mrack\e[0m>.freeze, [\">= 2\".freeze]) # rack"],
            ['lua', 'dependencies', 'sample.rockspec',
             'dependencies = { "dependencies >= 1", "dependencies-extra" }',
             "dependencies: \e[1;31mdependencies\e[0m >= 1"],
            ['pc', 'gtk+-3.0', 'sample.pc',
             'Requires: other=gtk+-3.0, gtk+-3.00, gtk+-3.0 >= 3.24, gtk+-3.0',
             "Requires: other=gtk+-3.0, gtk+-3.00, \e[1;31mgtk+-3.0\e[0m >= 3.24, \e[1;31mgtk+-3.0\e[0m"],
            ['ocaml', 'lwt', 'META',
             'requires(lwt) += "lwt, unix lwt.unix lwt"',
             "requires(lwt)+= \"\e[1;31mlwt\e[0m, unix lwt.unix \e[1;31mlwt\e[0m\""]
        ]
        examples.each do |language, name, file, content, expected|
            assert_equal [expected], ReverseLookup.matching_lines(language, name, file, content, color: true), language
            assert_equal [expected.gsub(/\e\[[\d;]*m/, '')],
                ReverseLookup.matching_lines(language, name, file, content), language
        end
    end

    def archive(filename, entries)
        path = File.join(@directory, filename)
        Zlib::GzipWriter.open(path) do |compressed|
            Gem::Package::TarWriter.new(compressed) do |tar|
                entries.each do |file, content|
                    tar.add_file_simple(file, 0644, content.bytesize) { |entry| entry.write(content) }
                end
            end
        end
        path
    end

    def run_lookup(language, name, entries, archives: {}, downloaded: archives, failure: nil, terminal: false, &on_command)
        capture = Open3.method(:capture3)
        commands = lambda do |*command, **_options|
            @commands << command
            on_command&.call(command)
            failure != command[2]
        end
        external = lambda do |*command|
            if command.first == 'pacman'
                @commands << command
                if failure == 'search'
                    ['', 'missing file database', Status.new(1)]
                else
                    [entries.map { |entry| entry.join("\0") + "\n" }.join, '', Status.new(entries.empty? ? 1 : 0)]
                end
            else
                @extractions << command
                capture.call(*command)
            end
        end
        indexes = [archives, downloaded]
        Dir.stub(:home, @directory) do
            ReverseLookup.stub(:system, commands) do
                ReverseLookup.stub(:cached_archives, -> { indexes.shift || downloaded }) do
                    Open3.stub(:capture3, external) do
                        stdout, stderr = capture_io do
                            $stdout.stub(:tty?, terminal) do
                                @result = ReverseLookup.main([language, name])
                            end
                        end
                        [@result, stdout, stderr]
                    end
                end
            end
        end
    end

    def test_shared_pipeline_reuses_archives_handles_epochs_and_filters_repositories
        file = 'usr/lib/python3.14/site-packages/client.dist-info/METADATA'
        content = "Requires-Dist: Foo_Bar>=1\n"
        path = archive('client-2:1-1-any.pkg.tar.gz', file => content)
        archives = Dir.stub(:glob, [path]) { ReverseLookup.cached_archives }
        entries = [
            ['extra', 'client', '2:1-1', file],
            ['extra-testing', 'client', '2:1-1', file],
            ['archlinuxcn', 'excluded', '1-1', file]
        ]
        result, stdout, stderr = run_lookup('python', 'foo.bar', entries, archives: archives)
        assert_equal 0, result, stderr
        assert_equal ["extra/client: Requires-Dist: Foo_Bar>=1", "extra-testing/client: Requires-Dist: Foo_Bar>=1"], stdout.lines.map(&:chomp)
        refute @commands.any? { |command| command.include?('-Swdd') }
        assert_equal 2, @extractions.size

        @commands.clear
        @extractions.clear
        result, cached_stdout, stderr = run_lookup('python', 'foo.bar', entries)
        assert_equal 0, result, stderr
        assert_equal stdout, cached_stdout
        assert_empty @extractions
        refute @commands.any? { |command| command.include?('-Swdd') }
    end

    def test_pipeline_highlights_terminal_output_and_keeps_redirected_output_plain
        file = 'usr/lib/pkgconfig/client.pc'
        content = 'Requires: irrelevant, target >= 1, target-tools'
        path = archive('client-1-1-any.pkg.tar.gz', file => content)
        entries = [['extra', 'client', '1-1', file]]

        result, stdout, stderr = run_lookup('pc', 'target', entries, archives: {'client-1-1' => path}, terminal: true)
        assert_equal 0, result, stderr
        assert_equal "extra/client: Requires: irrelevant, \e[1;31mtarget\e[0m >= 1, target-tools\n", stdout

        result, stdout, stderr = run_lookup('pc', 'target', entries)
        assert_equal 0, result, stderr
        assert_equal "extra/client: #{content}\n", stdout
    end

    def test_archive_index_handles_filenames_with_and_without_epochs
        paths = %w[
            /var/cache/pacman/pkg/ruby-ffi-compiler-1:1.4.2-1-any.pkg.tar.zst
            /var/cache/pacman/pkg/other-library-1.2-3-x86_64.pkg.tar.xz
        ]
        archives = Dir.stub(:glob, paths) { ReverseLookup.cached_archives }
        assert_equal paths[0], archives['ruby-ffi-compiler-1.4.2-1']
        assert_equal paths[1], archives['other-library-1.2-3']
    end

    def test_downloads_are_batched_by_repository_and_metadata_is_extracted
        first = 'usr/lib/ruby/gems/3.4.0/specifications/client.gemspec'
        second = 'usr/lib/ruby/gems/3.4.0/specifications/default/helper.gemspec'
        content = "s.add_runtime_dependency(%q<rack>.freeze, [\">= 2\".freeze])\n"
        stable = archive('client-1-1-any.pkg.tar.gz', first => content, second => content)
        testing = archive('client-2-1-any.pkg.tar.gz', first => content)
        helper = archive('helper-1-1-any.pkg.tar.gz', first => content)
        entries = [
            ['extra', 'client', '1-1', first],
            ['extra', 'client', '1-1', second],
            ['extra', 'helper', '1-1', first],
            ['extra-testing', 'client', '2-1', first]
        ]
        downloaded = {'client-1-1' => stable, 'client-2-1' => testing, 'helper-1-1' => helper}
        result, stdout, stderr = run_lookup('ruby', 'rack', entries, downloaded: downloaded)
        assert_equal 0, result, stderr
        assert_equal 4, stdout.lines.size
        assert_equal [
            ['sudo', 'pacman', '-Swdd', '--noconfirm', 'extra/client', 'extra/helper'],
            ['sudo', 'pacman', '-Swdd', '--noconfirm', 'extra-testing/client']
        ], @commands.select { |command| command.include?('-Swdd') }
        assert_equal 4, @extractions.size
    end

    def test_package_database_is_refreshed_before_file_search_and_downloads
        file = 'usr/lib/python3.14/site-packages/langgraph-1.2.13.dist-info/METADATA'
        content = 'Requires-Dist: langchain-core'
        current = archive('python-langgraph-1.2.13-1-any.pkg.tar.gz', file => content)
        previous = archive('python-langgraph-1.2.12-1-any.pkg.tar.gz',
            file.sub('1.2.13', '1.2.12') => content)
        downloaded = {'python-langgraph-1.2.12-1' => previous}

        result, stdout, stderr = run_lookup('python', 'langchain-core',
            [['extra', 'python-langgraph', '1.2.13-1', file]], downloaded: downloaded) do |command|
            downloaded['python-langgraph-1.2.13-1'] = current if command[2] == '-Sy'
        end
        assert_equal 0, result, stderr
        assert_equal "extra/python-langgraph: #{content}\n", stdout
        assert_equal [
            ['sudo', 'pacman', '-Sy'],
            ['sudo', 'pacman', '-Fy'],
            ['pacman', '-Fx', '--machinereadable', ReverseLookup::PATTERNS.fetch('python')]
        ], @commands.first(3)
        assert_equal current, @extractions.first[2]
    end

    def test_missing_downloaded_version_reports_database_mismatch
        file = 'usr/lib/python3.14/site-packages/langgraph-1.2.13.dist-info/METADATA'
        previous = archive('python-langgraph-1.2.12-1-any.pkg.tar.gz',
            file.sub('1.2.13', '1.2.12') => 'Requires-Dist: langchain-core')
        result, stdout, stderr = run_lookup('python', 'langchain-core',
            [['extra', 'python-langgraph', '1.2.13-1', file]],
            downloaded: {'python-langgraph-1.2.12-1' => previous})
        assert_equal 1, result
        assert_empty stdout
        assert_includes stderr, 'Missing cached archive for extra/python-langgraph 1.2.13-1'
        assert_includes stderr, 'package and file databases may be out of sync'
        assert_empty @extractions
        assert_empty Dir.glob("#{@directory}/.cache/reverse-lookup/*")
    end

    def test_downloads_do_not_require_a_consistent_runtime_environment
        file = 'usr/lib/pkgconfig/poppler-glib.pc'
        path = archive('poppler-glib-26.10.0-1-x86_64.pkg.tar.gz', file => 'Requires: poppler')
        result, _stdout, stderr = run_lookup('pc', 'poppler', [['extra-testing', 'poppler-glib', '26.10.0-1', file]],
            downloaded: {'poppler-glib-26.10.0-1' => path})
        assert_equal 0, result, stderr
        command = @commands.find { |arguments| arguments.include?('-Swdd') }.drop(1)

        dbpath = File.join(@directory, 'pacman')
        FileUtils.mkdir_p(["#{dbpath}/local", "#{dbpath}/sync"])
        File.write("#{dbpath}/local/ALPM_DB_VERSION", "9\n")
        description = <<~DESC
            %NAME%
            poppler-glib

            %VERSION%
            26.10.0-1

            %ARCH%
            x86_64

            %FILENAME%
            poppler-glib-26.10.0-1-x86_64.pkg.tar.zst

            %DEPENDS%
            poppler=26.10.0

        DESC
        database = archive('extra-testing.db', 'poppler-glib-26.10.0-1/desc' => description)
        FileUtils.mv(database, "#{dbpath}/sync/extra-testing.db")
        config = File.join(@directory, 'pacman.conf')
        File.write(config, "[options]\nArchitecture = auto\nSigLevel = Never\n\n[extra-testing]\nServer = file:///unused\n")
        options = ['--config', config, '--dbpath', dbpath, '--print', '--print-format', '%n']

        stdout, stderr, status = Open3.capture3('pacman', '-Sw', 'extra-testing/poppler-glib', *options)
        refute status.success?
        assert_includes stdout + stderr, "unable to satisfy dependency 'poppler=26.10.0'"

        stdout, stderr, status = Open3.capture3(*command, *options)
        assert status.success?, stderr
        assert_equal "poppler-glib\n", stdout
    end

    def test_failed_download_is_reported
        file = 'usr/lib/ruby/gems/3.4.0/specifications/client.gemspec'
        entries = [['extra', 'client', '1-1', file]]
        result, stdout, stderr = run_lookup('ruby', 'rack', entries, failure: '-Swdd')
        assert_equal 1, result
        assert_empty stdout
        assert_includes stderr, 'Failed to download extra/client'
        assert_empty @extractions
    end

    def test_new_modes_use_shared_archive_pipeline
        examples = [
            ['lua', 'luafilesystem', 'usr/lib/luarocks/rocks-5.4/client/1.0-1/client-1.0-1.rockspec',
             'dependencies = { "luafilesystem >= 1" }', 'dependencies: luafilesystem >= 1'],
            ['pc', 'gtk+-3.0', 'usr/lib32/pkgconfig/client.pc',
             'Requires.private: gtk+-3.0 >= 3.24', 'Requires.private: gtk+-3.0 >= 3.24'],
            ['ocaml', 'lwt.unix', 'usr/lib/ocaml/client/META',
             'requires(native) = "lwt.unix"', 'requires(native)= "lwt.unix"']
        ]
        examples.each do |language, name, file, content, expected|
            assert_match Regexp.new(ReverseLookup::PATTERNS.fetch(language)), file
            path = archive('client-1-1-any.pkg.tar.gz', file => content)
            result, stdout, stderr = run_lookup(language, name, [['extra', 'client', '1-1', file]], archives: {'client-1-1' => path})
            assert_equal 0, result, stderr
            assert_equal "extra/client: #{expected}\n", stdout
        end
        refute @commands.any? { |command| command.include?('-Swdd') }
    end

    def test_refresh_and_search_failures_are_reported
        %w[-Sy -Fy search].each do |failure|
            result, stdout, stderr = run_lookup('python', 'example', [], failure: failure)
            assert_equal 1, result
            assert_empty stdout
            assert_match(/Failed to (refresh|search)/, stderr)
        end
    end

    def test_no_matches_is_successful
        result, stdout, stderr = run_lookup('python', 'example', [])
        assert_equal 0, result, stderr
        assert_empty stdout
        assert_empty stderr
    end

    def test_failed_extraction_does_not_create_cache_entry
        file = 'usr/lib/python3.14/site-packages/client.dist-info/METADATA'
        path = archive('client-1-1-any.pkg.tar.gz', 'unrelated' => '')
        result, stdout, stderr = run_lookup('python', 'example', [['extra', 'client', '1-1', file]], archives: {'client-1-1' => path})
        assert_equal 1, result
        assert_empty stdout
        assert_includes stderr, 'Failed to extract extra/client'
        assert_empty Dir.glob("#{@directory}/.cache/reverse-lookup/*")
    end

    def test_help_and_invalid_arguments_do_not_run_commands
        ReverseLookup.stub(:run, ->(*) { flunk 'lookup should not run' }) do
            [[], ['python'], ['perl', 'example'], ['python', 'example;echo'], %w[python example extra]].each do |args|
                _stdout, stderr = capture_io { assert_equal 1, ReverseLookup.main(args) }
                assert_includes stderr, 'Usage:'
            end
            stdout, stderr = capture_io { assert_equal 0, ReverseLookup.main(['--help']) }
            assert_includes stdout, 'reverse-lookup ruby rack'
            assert_empty stderr
        end
    end
end
