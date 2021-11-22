# frozen-string-literal: true

require 'rubygems'

# move the installed gem to the shared dir and symlink to it
Gem.post_install do |installer|
  spec = installer.spec
  if spec.respond_to? :have_extensions?
    next true if spec.send :have_extensions?
  else
    next true unless spec.extensions.empty?
  end

  next true if spec.name == 'bundler'

  if defined?(Bundler) && Bundler.definition && (bundler_definition = Bundler.definition.dependencies.detect {|d| d.name == spec.name })
    next true if bundler_definition.source.is_a? Bundler::Source::Path
  end

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
