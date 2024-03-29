# frozen-string-literal: true

require 'rubygems'

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

# move the installed gem to the shared dir and symlink to it
Gem.post_install do |installer|
  spec = installer.spec
  if spec.respond_to? :have_extensions?
    next true if spec.send :have_extensions?
  else
    next true unless spec.extensions.empty?
  end

  next true if spec.name == 'bundler'

  # Skip if installed via Bundler `path:` or `git:` option
  if defined?(Bundler) && Bundler.definition && (bundler_definition = Bundler.definition.dependencies.detect {|d| d.name == spec.name })
    next true if bundler_definition.source.is_a?(Bundler::Source::Path) || bundler_definition.source.is_a?(Bundler::Source::Git)
  end

  # Skip if current dir and the target dir are inside same Git repo
  next true if git_repo?(Dir.pwd) && git_repo?(spec.full_gem_path) && within_same_git_repo?(Dir.pwd, spec.full_gem_path)

  # Skip if the installed gem is in a Git repo and appears to be a sub component of another gem (e.g. rails, rspec, kaminari, aws-sdk, ...)
  next true if git_repo?(Dir.pwd) && git_repo?(spec.full_gem_path) && within_same_git_repo?(spec.full_gem_path, File.expand_path('..', spec.full_gem_path))

  fileutils = defined?(::Bundler::FileUtils) ? ::Bundler::FileUtils : FileUtils

  fileutils.mkdir_p File.expand_path('~/.gem/rbenv_shared')
  shared_gem_path = File.expand_path "~/.gem/rbenv_shared/#{spec.full_name}"

  if File.exist?(shared_gem_path)
    fileutils.rm_rf spec.full_gem_path
  else
    fileutils.mv spec.full_gem_path, shared_gem_path
  end

  fileutils.ln_s shared_gem_path, spec.full_gem_path

  true
end
