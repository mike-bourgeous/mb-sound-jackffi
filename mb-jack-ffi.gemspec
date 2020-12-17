# coding: utf-8

Gem::Specification.new do |spec|
  spec.name          = "mb-jack-ffi"
  spec.version       = '0.0.0.usegit'
  spec.authors       = ["Mike Bourgeous"]
  spec.email         = ["mike@mikebourgeous.com"]

  spec.summary       = %q{A Ruby FFI interface to the JACK Audio Connection Kit}
  spec.homepage      = "https://github.com/mike-bourgeous/mb-jack-ffi"

  # Prevent pushing this gem to RubyGems.org. To allow pushes either set the 'allowed_push_host'
  # to allow pushing to a single host or delete this section to allow pushing to any host.
  if spec.respond_to?(:metadata)
    spec.metadata["allowed_push_host"] = "https://rubygems.org"
  else
    raise "RubyGems 2.0 or newer is required to protect against " \
      "public gem pushes."
  end

  spec.files         = `git ls-files -z`.split("\x0").reject do |f|
    f.match(%r{^(test|spec|features)/})
  end
  spec.require_paths = ["lib"]

  spec.add_development_dependency "bundler", "~> 2.1.0"
  spec.add_development_dependency "rake", "~> 13.0"

  spec.add_runtime_dependency 'numo-narray', '~> 0.9.1'
  spec.add_runtime_dependency 'ffi', '~> 1.13.0'
end
