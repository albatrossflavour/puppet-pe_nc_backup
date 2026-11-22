# frozen_string_literal: true

# Helpers for the specs that exercise the backup script itself, without Puppet.

require 'json'
require 'logger'
require 'open3'
require 'stringio'
require 'tmpdir'
require_relative 'support/fake_classifier'
require_relative '../files/pe_nc_backup'

module ScriptHelper
  CERTNAME = 'primary.example.test'

  # Runs git in dir and returns stdout, failing the example if git fails.
  def git(dir, *args)
    out, status = Open3.capture2e('git', *args, chdir: dir)
    raise "git #{args.join(' ')} failed: #{out}" unless status.success?

    out
  end

  def commit_count(repo)
    git(repo, 'rev-list', '--count', 'HEAD').to_i
  rescue RuntimeError
    0
  end

  def last_commit_message(repo)
    git(repo, 'log', '-1', '--format=%B')
  end

  # Isolates git from the user's own configuration (signing, hooks, identity).
  def isolate_git(dir)
    gitconfig = File.join(dir, 'gitconfig')
    File.write(gitconfig, "[init]\n\tdefaultBranch = main\n")
    { 'GIT_CONFIG_GLOBAL' => gitconfig, 'GIT_CONFIG_NOSYSTEM' => '1', 'HOME' => dir }
  end
end

RSpec.shared_context 'with a backup directory and fake classifier' do
  include ScriptHelper

  let(:tmp) { Dir.mktmpdir('pe_nc_backup_spec') }

  around(:each) do |example|
    saved = ENV.to_h
    ENV.update(isolate_git(tmp))
    example.run
  ensure
    ENV.replace(saved)
    FileUtils.rm_rf(tmp)
  end

  let(:path) { File.join(tmp, 'backup') }
  let(:repo) { File.join(path, 'repo') }
  let(:certname) { ScriptHelper::CERTNAME }
  let(:classifier) { FakeClassifier.new(tmp, certname) }
  let(:log_io) { StringIO.new }
  let(:stdout_io) { StringIO.new }
  let(:loggers) { [Logger.new(log_io), Logger.new(stdout_io)] }
  let(:extra_config) { {} }
  let(:config) do
    {
      'path' => path,
      'certname' => certname,
      'ssl_dir' => classifier.ssl_dir,
      'classifier_host' => '127.0.0.1',
      'classifier_port' => classifier.port,
      'timeout' => 5,
    }.merge(extra_config)
  end
  let(:groups) do
    [
      FakeClassifier.group('All Nodes', '00000000-0000-4000-8000-000000000000', parent: '00000000-0000-4000-8000-000000000000'),
      FakeClassifier.group('Production', 'b0000000-0000-4000-8000-000000000002'),
      FakeClassifier.group('Development', 'a0000000-0000-4000-8000-000000000001'),
    ]
  end

  before(:each) do
    FileUtils.mkdir_p(repo)
    git(repo, 'init', '--quiet')
    classifier.groups = groups
    classifier.start
  end

  after(:each) { classifier.stop }

  def run_backup(cfg = config)
    PeNcBackup.main(cfg, loggers)
  end

  def backup_json(file = PeNcBackup::BACKUP_FILE)
    JSON.parse(File.read(File.join(repo, file)))
  end
end
