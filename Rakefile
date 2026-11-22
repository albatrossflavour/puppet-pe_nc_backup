# frozen_string_literal: true

require 'bundler'
require 'puppet_litmus/rake_tasks' if Gem.loaded_specs.key? 'puppet_litmus'
require 'puppetlabs_spec_helper/rake_tasks'
require 'metadata-json-lint/rake_task'
require 'puppet-strings/tasks' if Gem.loaded_specs.key? 'puppet-strings'

PuppetLint.configuration.send('disable_relative')
PuppetLint.configuration.fail_on_warnings = true
PuppetLint.configuration.ignore_paths = ['.vendor/**/*.pp', '.bundle/**/*.pp', 'pkg/**/*.pp', 'spec/**/*.pp', 'tests/**/*.pp', 'types/**/*.pp', 'vendor/**/*.pp']
