# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'stringio'
require 'rubygems/package'
require 'rubygems/installer'
require_relative '../lib/rubygems_plugin'

class SharedCacheTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir('rbenv-gem-shared')
    @orig_env = ENV.to_h
    ENV['HOME'] = File.join(@tmp, 'home')
    ENV['RBENV_ROOT'] = File.join(@tmp, 'rbenv')
    FileUtils.mkdir_p ENV['HOME']
    @shared_cache = File.join(ENV['HOME'], '.gem', 'rbenv_shared', 'cache')
  end

  def teardown
    ENV.replace(@orig_env)
    FileUtils.rm_rf @tmp
  end

  def cache_dir(version, api)
    File.join(ENV['RBENV_ROOT'], 'versions', version, 'lib', 'ruby', 'gems', api, 'cache').tap {|d| FileUtils.mkdir_p d }
  end

  def write_gem_file(dir, name, content = name)
    File.join(dir, name).tap {|path| File.write path, content }
  end

  def run_shared(*args)
    out = StringIO.new
    Gem::DefaultUserInteraction.use_ui(Gem::StreamUI.new(StringIO.new, out, out, false)) do
      Gem::Commands::SharedCommand.new.invoke(*args)
    end
    out.string
  end

  def test_migrate_cache_moves_gem_files_to_shared_dir_and_symlinks
    path = write_gem_file(cache_dir('3.4.12', '3.4.0'), 'rake-13.3.0.gem')

    run_shared '--migrate-cache'

    shared = File.join(@shared_cache, 'rake-13.3.0.gem')
    assert File.file?(shared)
    assert File.symlink?(path)
    assert_equal shared, File.readlink(path)
  end

  def test_migrate_cache_dedupes_across_rubies
    a = write_gem_file(cache_dir('3.3.13', '3.3.0'), 'rake-13.3.0.gem', 'from 3.3')
    b = write_gem_file(cache_dir('3.4.12', '3.4.0'), 'rake-13.3.0.gem', 'from 3.4')

    run_shared '--migrate-cache'

    assert File.symlink?(a)
    assert File.symlink?(b)
    assert_equal 1, Dir.children(@shared_cache).size
    assert_equal File.read(a), File.read(b)
  end

  def test_migrate_cache_skips_files_already_symlinked
    FileUtils.mkdir_p @shared_cache
    shared = write_gem_file(@shared_cache, 'rake-13.3.0.gem')
    path = File.join(cache_dir('3.4.12', '3.4.0'), 'rake-13.3.0.gem')
    File.symlink shared, path

    run_shared '--migrate-cache'

    assert File.symlink?(path)
    assert_equal shared, File.readlink(path)
  end

  def test_migrate_cache_ignores_non_gem_files
    other = write_gem_file(cache_dir('3.4.12', '3.4.0'), 'README')

    run_shared '--migrate-cache'

    assert File.file?(other)
    refute File.symlink?(other)
    refute File.exist?(File.join(@shared_cache, 'README'))
  end

  def test_clean_removes_shared_cache_files_not_referenced
    FileUtils.mkdir_p @shared_cache
    used = write_gem_file(@shared_cache, 'used-1.0.gem')
    unused = write_gem_file(@shared_cache, 'unused-1.0.gem')
    File.symlink used, File.join(cache_dir('3.4.12', '3.4.0'), 'used-1.0.gem')

    run_shared '--clean'

    assert File.exist?(used)
    refute File.exist?(unused)
  end

  def test_clean_does_not_treat_cache_dir_as_unused_shared_gem
    FileUtils.mkdir_p @shared_cache

    run_shared '--clean'

    assert File.directory?(@shared_cache)
  end

  def test_post_install_shares_cache_file
    gem_home = File.join(@tmp, 'gem_home')
    ENV['GEM_HOME'] = gem_home
    ENV['GEM_PATH'] = gem_home
    Gem.clear_paths

    gem_file = build_gem('dummyshared', '1.0.0')
    Gem::DefaultUserInteraction.use_ui(Gem::SilentUI.new) do
      Gem::Installer.at(gem_file, install_dir: gem_home, ignore_dependencies: true, wrappers: false).install
    end

    cache_file = File.join(gem_home, 'cache', 'dummyshared-1.0.0.gem')
    assert File.symlink?(cache_file), "#{cache_file} should be a symlink"
    assert_equal File.join(@shared_cache, 'dummyshared-1.0.0.gem'), File.readlink(cache_file)
    assert File.file?(cache_file)
  end

  private

  def build_gem(name, version)
    dir = File.join(@tmp, 'build')
    FileUtils.mkdir_p File.join(dir, 'lib')
    File.write File.join(dir, 'lib', "#{name}.rb"), "module #{name.capitalize}; end\n"
    spec = Gem::Specification.new do |s|
      s.name = name
      s.version = version
      s.summary = 'dummy'
      s.authors = ['test']
      s.files = ["lib/#{name}.rb"]
    end
    Dir.chdir(dir) do
      Gem::DefaultUserInteraction.use_ui(Gem::SilentUI.new) do
        Gem::Package.build(spec)
      end
    end
    File.join(dir, "#{name}-#{version}.gem")
  end
end
