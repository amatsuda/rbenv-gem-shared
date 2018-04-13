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

  FileUtils.mkdir_p File.expand_path('~/.gem/rbenv_shared')
  shared_gem_path = File.expand_path "~/.gem/rbenv_shared/#{spec.full_name}"

  if File.exist?(shared_gem_path)
    FileUtils.rm_rf spec.full_gem_path
  else
    FileUtils.mv spec.full_gem_path, shared_gem_path
  end

  FileUtils.ln_s shared_gem_path, spec.full_gem_path

  true
end
