# frozen_string_literal: true

require_relative "lib/runconvert"

Gem::Specification.new do |s|
  s.name = "runconvert"
  s.version = RunConvert::VERSION
  s.summary = "Official RunConvert SDK for Ruby: convert files between 240+ formats"
  s.authors = ["RunConvert"]
  s.homepage = "https://www.runconvert.com/docs"
  s.license = "MIT"
  s.required_ruby_version = ">= 2.7"
  s.files = Dir["lib/**/*.rb", "README.md", "LICENSE", "CHANGELOG.md"]
  s.metadata = {
    "source_code_uri" => "https://github.com/runconvert/runconvert-ruby",
    "documentation_uri" => "https://www.runconvert.com/docs",
    "changelog_uri" => "https://github.com/runconvert/runconvert-ruby/blob/main/CHANGELOG.md",
    "rubygems_mfa_required" => "true"
  }
end
