# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require_relative '../support/fake_classifier'

# Renders the backup script through Puppet, then runs it as its own process
# against a fake classifier over HTTPS and into a real git repo.
describe 'pe_nc_backup', type: :class do
  let(:facts) { on_supported_os.values.first }

  let(:tmp) { Dir.mktmpdir('pe_nc_backup_e2e') }
  let(:classifier) { FakeClassifier.new(tmp, 'localhost') }
  let(:env) do
    gitconfig = File.join(tmp, 'gitconfig')
    File.write(gitconfig, "[init]\n\tdefaultBranch = main\n")
    { 'GIT_CONFIG_GLOBAL' => gitconfig, 'GIT_CONFIG_NOSYSTEM' => '1', 'HOME' => tmp }
  end
  let(:path) { File.join(tmp, 'pe_nc_backup') }
  let(:repo) { File.join(path, 'repo') }
  let(:script) { File.join(path, 'bin', 'pe_nc_backup') }
  let(:base_params) do
    {
      path: path,
      certname: 'localhost',
      ssl_dir: classifier.ssl_dir,
      classifier_port: classifier.port,
      classifier_timeout: 5,
      log_level_stdout: 'info',
    }
  end
  let(:params) { base_params }
  let(:groups) do
    [
      FakeClassifier.group('All Nodes', '00000000-0000-4000-8000-000000000000', parent: '00000000-0000-4000-8000-000000000000'),
      FakeClassifier.group('PE Infrastructure', '8a0b8d8e-0000-4000-8000-000000000001'),
      FakeClassifier.group('Production environment', 'c0ffee00-0000-4000-8000-000000000002'),
    ]
  end

  # The interpreter: E2E_RUBY if set, the script's own shebang (the
  # puppet-agent Ruby) if it is installed, otherwise the Ruby running the specs.
  def interpreter
    shebang = File.open(script, &:readline)[2..].strip
    ENV['E2E_RUBY'] || (File.executable?(shebang) ? shebang : RbConfig.ruby)
  end

  def install_script
    FileUtils.mkdir_p([File.dirname(script), repo])
    File.write(script, catalogue.resource('File', 'pe_nc_backup script')[:content])
    File.chmod(0o755, script)
    git('init', '--quiet')
  end

  def git(*args)
    out, status = Open3.capture2e(env, 'git', *args, chdir: repo)
    raise "git #{args.join(' ')} failed: #{out}" unless status.success?

    out
  end

  def commits
    git('rev-list', '--count', 'HEAD').to_i
  rescue RuntimeError
    0
  end

  # The script runs as cron or systemd would run it, outside the spec's bundle.
  def clean_env(&block)
    defined?(Bundler) ? Bundler.with_unbundled_env(&block) : yield
  end

  # Runs the script the way cron does, with the backup path as the only argument.
  def backup(label)
    out, status = clean_env { Open3.capture2e(env, interpreter, script, path) }
    if ENV['E2E_VERBOSE']
      puts "\n--- #{label}: exit #{status.exitstatus}, #{commits} commit(s), interpreter #{interpreter}"
      puts out.lines.map { |l| "    #{l}" }.join
    end
    [status.exitstatus, out]
  end

  before(:each) do
    classifier.groups = groups
    classifier.start
    install_script
  end

  after(:each) do
    classifier.stop
    FileUtils.rm_rf(tmp)
  end

  it 'commits on the first run, nothing on the second, and exactly once after a change' do
    expect(backup('first run')).to match([0, %r{Committed changes to the node groups}])
    expect(commits).to eq(1)
    first = File.read(File.join(repo, 'node_groups.json'))
    expect(JSON.parse(first).map { |g| g['name'] }).to contain_exactly('All Nodes', 'PE Infrastructure', 'Production environment')

    expect(backup('second run, nothing changed')).to match([0, %r{nothing to commit}])
    expect(commits).to eq(1)
    expect(File.read(File.join(repo, 'node_groups.json'))).to eq(first)

    classifier.groups = groups.map { |g| (g['name'] == 'Production environment') ? g.merge('classes' => { 'role::web' => {} }) : g }
    expect(backup('third run, one group changed')).to match([0, %r{Committed changes to the node groups}])
    expect(commits).to eq(2)
    expect(git('diff', '--stat', 'HEAD~1', 'HEAD')).to match(%r{node_groups.json \| \d+ \+})
    expect(git('status', '--porcelain')).to eq('')
    puts git('log', '--format=    %h %s%n%w(0,6,6)%b') if ENV['E2E_VERBOSE']
  end

  context 'with split_files, strip_fields and exclude_groups' do
    let(:params) { base_params.merge(split_files: true, strip_fields: ['serial_number', 'last_edited'], exclude_groups: ['^PE ']) }

    def head_files
      git('show', '--name-status', '--format=', 'HEAD')
    end

    it 'writes a file per kept group and commits only real changes' do
      expect(backup('first run')).to match([0, %r{Retrieved 3 node groups, keeping 2}])
      expect(Dir.children(File.join(repo, 'groups')).sort).to eq(['All_Nodes-00000000-0000-4000-8000-000000000000.json', 'Production_environment-c0ffee00-0000-4000-8000-000000000002.json'])

      classifier.groups = groups.map { |g| g.merge('serial_number' => 2, 'last_edited' => '2026-11-23T01:00:00.000Z') }
      expect(backup('second run, only stripped fields changed')).to match([0, %r{nothing to commit}])
      expect(commits).to eq(1)

      classifier.groups = groups.map { |g| g['name'].start_with?('PE ') ? g.merge('description' => 'changed') : g }
      expect(backup('third run, only an excluded group changed')).to match([0, %r{nothing to commit}])
      expect(commits).to eq(1)

      classifier.groups = groups.map { |g| (g['name'] == 'Production environment') ? g.merge('environment' => 'staging') : g }
      expect(backup('fourth run, one group changed')).to match([0, %r{Committed}])
      expect(commits).to eq(2)
      expect(head_files).to eq("M\tgroups/Production_environment-c0ffee00-0000-4000-8000-000000000002.json\n")
      expect(git('log', '-1', '--format=%b')).to eq("Changed: Production environment\n\n")

      classifier.groups = groups.reject { |g| g['name'] == 'Production environment' }
      expect(backup('fifth run, a group deleted')).to match([0, %r{Committed}])
      expect(commits).to eq(3)
      expect(head_files).to eq("D\tgroups/Production_environment-c0ffee00-0000-4000-8000-000000000002.json\n")
      puts git('log', '--format=    %h %s%n%w(0,6,6)%b') if ENV['E2E_VERBOSE']
    end
  end

  it 'exits non-zero and commits nothing when the classifier fails' do
    expect(backup('first run')).to match([0, anything])
    classifier.status = 503
    classifier.body = 'Service Unavailable'
    status, out = backup('classifier returning 503')
    expect(status).to eq(1)
    expect(out).to match(%r{returned HTTP 503})
    expect(commits).to eq(1)
    expect(git('status', '--porcelain')).to eq('')
  end
end
