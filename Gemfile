source ENV['GEM_SOURCE'] || 'https://rubygems.org'

def location_for(place_or_version, fake_version = nil)
  git_url_regex = %r{\A(?<url>(https?|git)[:@][^#]*)(#(?<branch>.*))?}
  file_url_regex = %r{\Afile:\/\/(?<path>.*)}

  if place_or_version && (git_url = place_or_version.match(git_url_regex))
    [fake_version, { git: git_url[:url], branch: git_url[:branch], require: false }].compact
  elsif place_or_version && (file_url = place_or_version.match(file_url_regex))
    ['>= 0', { path: File.expand_path(file_url[:path]), require: false }]
  else
    [place_or_version, { require: false }]
  end
end

# puppetlabs_spec_helper and the lint plugins are left loose so that bundler
# can pick versions that suit the Puppet release under test: 9.x needs
# puppet >= 8, and 8.x is the newest that still installs alongside puppet 7.
group :development do
  gem "voxpupuli-puppet-lint-plugins", '>= 5.0', require: false
  gem "facterdb", '~> 3.1',                      require: false
  gem "metadata-json-lint", '~> 4.0',            require: false
  gem "puppetlabs_spec_helper", '>= 7.2', '< 10', require: false
  gem "rspec-puppet-facts", '~> 5.0',            require: false
  gem "dependency_checker", '~> 1.0.0',          require: false
  gem "parallel_tests", '~> 4.0',                require: false
  gem "pry", '~> 0.10',                          require: false
  gem "simplecov-console", '~> 0.9',             require: false
  gem "puppet-strings", '>= 4.0',                require: false
  gem "rubocop", '~> 1.50.0',                    require: false
  gem "rubocop-performance", '= 1.16.0',         require: false
  gem "rubocop-rspec", '= 2.19.0',               require: false
  gem "webrick", '~> 1.8',                       require: false
  gem "bigdecimal",                             require: false
end

puppet_version = ENV.fetch('PUPPET_GEM_VERSION', nil)
facter_version = ENV.fetch('FACTER_GEM_VERSION', nil)
hiera_version = ENV.fetch('HIERA_GEM_VERSION', nil)

gems = {}

# Puppet 8.11 and later, including Puppet 9, are only published to the
# authenticated puppetcore gem source. When PUPPET_FORGE_TOKEN is set, take
# puppet and facter from there; otherwise use the default source as before.
if ENV['PUPPET_FORGE_TOKEN'].to_s.empty?
  gems['puppet'] = location_for(puppet_version)
  gems['facter'] = location_for(facter_version) if facter_version
else
  puppetcore = 'https://rubygems-puppetcore.puppet.com'
  gems['puppet'] = [puppet_version || '>= 8.11', { require: false, source: puppetcore }].compact
  gems['facter'] = [facter_version || '~> 4.11', { require: false, source: puppetcore }].compact
end
gems['hiera'] = location_for(hiera_version) if hiera_version

gems.each do |gem_name, gem_params|
  gem gem_name, *gem_params
end

# Evaluate Gemfile.local and ~/.gemfile if they exist
extra_gemfiles = [
  "#{__FILE__}.local",
  File.join(Dir.home, '.gemfile'),
]

extra_gemfiles.each do |gemfile|
  if File.file?(gemfile) && File.readable?(gemfile)
    eval(File.read(gemfile), binding)
  end
end
# vim: syntax=ruby
