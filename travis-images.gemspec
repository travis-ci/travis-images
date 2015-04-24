Gem::Specification.new do |spec|
  spec.name          = 'travis-images'
  spec.version       = '0.0.1'
  spec.authors       = ['Travis CI GmbH']
  spec.email         = ['contact+travis-images@travis-ci.org']
  spec.summary       = %q(Travis Images!)
  spec.description   = spec.summary + '  No really!'
  spec.homepage      = 'https://github.com/travis-ci/travis-images'
  spec.license       = 'MIT'

  spec.files         = `git ls-files -z`.split("\x0")
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = %w(lib)

  spec.add_development_dependency 'bundler', '~> 1.7'
  spec.add_development_dependency 'rake', '~> 10.0'
end
