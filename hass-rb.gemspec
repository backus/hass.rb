# frozen_string_literal: true

require File.expand_path('lib/hass/version', __dir__)

Gem::Specification.new do |spec|
  spec.name        = 'hass.rb'
  spec.version     = HA::VERSION
  spec.authors     = %w[John Backus]
  spec.email       = %w[johncbackus@gmail.com]

  spec.summary     = 'Home Assistant API client and CLI'
  spec.description = spec.summary
  spec.homepage    = 'https://github.com/backus/hass.rb'

  spec.files         = `git ls-files`.split("\n")
  spec.require_paths = %w[lib]
  spec.executables   = %w[hass]

  spec.add_dependency 'anima',    '~> 0.3'
  spec.add_dependency 'concord',  '~> 0.1'
  spec.add_dependency 'http',     '~> 5.1'
  spec.add_dependency 'slop',     '~> 4.10'
end
