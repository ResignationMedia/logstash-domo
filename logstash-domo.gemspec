Gem::Specification.new do |s|
  s.name          = 'logstash-domo'
  s.version       = '1.0.0-alpha.1'
  s.licenses      = ['Apache-2.0']
  s.summary       = 'Manage redis queues that power the logstash-output-domo gem.'
  s.homepage      = 'https://github.com/ResignationMedia/logstash-domo'
  s.authors       = ['Chris Brundage', 'Rarefied Atmosphere, Inc.']
  s.email         = 'chris.brundage@atmosphere.tv'
  s.platform      = 'java'
  s.require_paths = %w(lib vendor/jar-dependencies)

  # Files
  s.files = Dir['lib/**/*','spec/**/*','*.gemspec','*.md', 'rakelib/**/*',
                'CONTRIBUTORS','Gemfile','LICENSE','NOTICE.TXT',
                'vendor/jar-dependencies/**/*.jar', 'vendor/jar-dependencies/**/*.rb']

  # Tests
  s.test_files = s.files.grep(%r{^(test|spec|features)/})

  # Jar dependencies
  s.requirements << "jar 'com.squareup.okhttp3:okhttp', '3.7.0'"
  s.requirements << "jar 'com.squareup.okhttp3:logging-interceptor', '3.7.0'"
  s.requirements << "jar 'com.google.code.gson:gson', '2.8.0'"
  s.requirements << "jar 'org.jetbrains.kotlin:kotlin-stdlib', '1.3.0'"
  s.requirements << "jar 'org.apache.commons:commons-io', '1.3.2'"
  s.requirements << "jar 'org.slf4j:slf4j-api', '1.7.21'"
  s.requirements << "jar 'com.squareup.okio:okio', '2.1.0'"

  # Gem dependencies
  s.add_runtime_dependency "concurrent-ruby", "~> 1.0"
  s.add_runtime_dependency "jar-dependencies"
  s.add_runtime_dependency "redis", ">= 3.0.0", "< 5.0"
  s.add_runtime_dependency "redlock", "~> 1.0"
  s.add_runtime_dependency "nokogiri", "~> 1.10", ">= 1.10.1"
  s.add_runtime_dependency "rake"

  # Development dependencies
  s.add_development_dependency "logstash-core-plugin-api", "~> 2.0"
  s.add_development_dependency "logstash-codec-plain"
  s.add_development_dependency "logstash-devutils"
end
