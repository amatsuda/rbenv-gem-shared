# frozen-string-literal: true

require 'rubygems'
require 'rubygems/command'
require 'rubygems/command_manager'

using Module.new {
  refine Object do
    def git_repo?(dir)
      `cd #{dir} && git rev-parse --is-inside-work-tree 2> /dev/null`.chomp == 'true'
    end

    def within_same_git_repo?(dir1, dir2)
      (dir1 == dir2) || (git_toplevel(dir1) == git_toplevel(dir2))
    end

    private

    def git_toplevel(dir)
      `cd #{dir} && git rev-parse --show-toplevel`.chomp
    end
  end
}

module RbenvGemShared
  module_function

  def shared_dir
    File.expand_path('~/.gem/rbenv_shared')
  end

  def shared_cache_dir
    File.join(shared_dir, 'cache')
  end

  def rbenv_root
    ENV['RBENV_ROOT'] || File.expand_path('~/.rbenv')
  end

  def rbenv_gem_homes_glob
    File.join(rbenv_root, 'versions', '*', 'lib', 'ruby', 'gems', '*')
  end

  # Move `path` (a gem directory or a cached .gem file) to `shared_path` and leave a symlink in its place.
  # If the shared copy already exists, the local one is simply replaced with the symlink.
  def share(path, shared_path, fileutils = FileUtils)
    return if File.symlink?(path)

    fileutils.mkdir_p File.dirname(shared_path)

    if File.exist?(shared_path)
      fileutils.rm_rf path
    else
      fileutils.mv path, shared_path
    end

    fileutils.ln_s shared_path, path
  end

  def share_cache_file(cache_file, fileutils = FileUtils)
    share cache_file, File.join(shared_cache_dir, File.basename(cache_file)), fileutils
  end

  # Did RubyGems install this gem into a gem home, as `<gem_home>/gems/<full_name>`? Bundler runs
  # the install hooks for a `path:` gem too, whose directory is the source checkout itself (and
  # whose installer has no gem home): sharing that removed the checkout's directory. A Rails app
  # made by `rails new --dev` names only `rails` by path, and the framework gems come from the
  # same checkout without being dependencies of their own, so the Bundler and Git checks below
  # let them through.
  def installed_into_gem_home?(installer, spec)
    gem_home = installer.respond_to?(:gem_home) && installer.gem_home
    return false unless gem_home

    File.expand_path(spec.full_gem_path) == File.expand_path(File.join(gem_home, 'gems', spec.full_name))
  end
end

# move the installed gem to the shared dir and symlink to it
Gem.post_install do |installer|
  spec = installer.spec
  fileutils = defined?(::Bundler::FileUtils) ? ::Bundler::FileUtils : FileUtils

  # The cached .gem package is identical across Ruby versions, so share it unconditionally
  RbenvGemShared.share_cache_file spec.cache_file, fileutils if File.file?(spec.cache_file)

  if spec.respond_to? :have_extensions?
    next true if spec.send :have_extensions?
  else
    next true unless spec.extensions.empty?
  end

  next true if spec.name == 'bundler'

  # Never a gem's source directory: only what RubyGems installed into a gem home is moved
  next true unless RbenvGemShared.installed_into_gem_home?(installer, spec)

  # Skip if installed via Bundler `path:` or `git:` option
  if defined?(Bundler) && Bundler.definition && (bundler_definition = Bundler.definition.dependencies.detect {|d| d.name == spec.name })
    next true if bundler_definition.source.is_a?(Bundler::Source::Path) || bundler_definition.source.is_a?(Bundler::Source::Git)
  end

  # Skip if current dir and the target dir are inside same Git repo
  next true if git_repo?(Dir.pwd) && git_repo?(spec.full_gem_path) && within_same_git_repo?(Dir.pwd, spec.full_gem_path)

  # Skip if the installed gem is in a Git repo and appears to be a sub component of another gem (e.g. rails, rspec, kaminari, aws-sdk, ...)
  next true if git_repo?(Dir.pwd) && git_repo?(spec.full_gem_path) && within_same_git_repo?(spec.full_gem_path, File.expand_path('..', spec.full_gem_path))

  RbenvGemShared.share spec.full_gem_path, File.join(RbenvGemShared.shared_dir, spec.full_name), fileutils

  true
end

class Gem::Commands::SharedCommand < Gem::Command
  def initialize
    super 'shared', 'Manage gems shared across rbenv Ruby versions'

    add_option('--clean', 'Remove shared gems and cached .gem files not symlinked from any rbenv Ruby') do |_, options|
      options[:clean] = true
    end

    add_option('--migrate-cache', 'Move cached .gem files of all rbenv Rubies into the shared dir and symlink to them') do |_, options|
      options[:migrate_cache] = true
    end
  end

  def execute
    if options[:clean]
      clean
    elsif options[:migrate_cache]
      migrate_cache
    else
      say 'Usage: gem shared --clean | --migrate-cache'
    end
  end

  private

  def clean
    shared_dir = RbenvGemShared.shared_dir
    unless File.directory?(shared_dir)
      say "Shared gem directory does not exist: #{shared_dir}"
      return
    end

    clean_gems shared_dir
    clean_cache RbenvGemShared.shared_cache_dir
  end

  def clean_gems(shared_dir)
    shared_gems = Dir.children(shared_dir).select {|name| File.directory?(File.join(shared_dir, name)) } - ['cache']
    referenced = referenced_basenames(File.join(RbenvGemShared.rbenv_gem_homes_glob, 'gems', '*'), shared_dir)

    remove_unused shared_gems - referenced, shared_dir, 'shared gems'
  end

  def clean_cache(shared_cache_dir)
    return unless File.directory?(shared_cache_dir)

    shared_files = Dir.children(shared_cache_dir).select {|name| File.file?(File.join(shared_cache_dir, name)) }
    referenced = referenced_basenames(File.join(RbenvGemShared.rbenv_gem_homes_glob, 'cache', '*.gem'), shared_cache_dir)

    remove_unused shared_files - referenced, shared_cache_dir, 'shared cache files'
  end

  # Basenames of symlink targets under `shared_root` for every symlink matching `glob`
  def referenced_basenames(glob, shared_root)
    Dir.glob(glob).each_with_object([]) do |path, referenced|
      next unless File.symlink?(path)
      target = File.expand_path(File.readlink(path), File.dirname(path))
      referenced << File.basename(target) if target.start_with?("#{shared_root}/")
    end
  end

  def remove_unused(unused, dir, label)
    if unused.empty?
      say "No unused #{label} found."
      return
    end

    unused.each do |name|
      path = File.join(dir, name)
      say "Removing #{path}"
      FileUtils.rm_rf path
    end
  end

  def migrate_cache
    count = 0
    Dir.glob(File.join(RbenvGemShared.rbenv_gem_homes_glob, 'cache', '*.gem')).sort.each do |path|
      next if File.symlink?(path)
      next unless File.file?(path)

      say "Sharing #{path}"
      RbenvGemShared.share_cache_file path
      count += 1
    end
    say "Shared #{count} cached .gem file(s) into #{RbenvGemShared.shared_cache_dir}"
  end
end

Gem::CommandManager.instance.register_command :shared
