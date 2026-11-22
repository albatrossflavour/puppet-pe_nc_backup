# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require_relative '../support/fake_classifier'

# Takes backups with the script Puppet renders, then runs the restore task as
# the task runner would (JSON on stdin, the shared library under _installdir)
# against the fake classifier.
describe 'pe_nc_backup', type: :class do
  let(:facts) { on_supported_os.values.first }
  let(:confirmed) { { 'dry_run' => false, 'confirm' => 'replace-entire-classifier', 'max_count_drop' => 50 } }
  let(:tmp) { Dir.mktmpdir('pe_nc_backup_restore') }
  let(:classifier) { FakeClassifier.new(tmp, 'localhost') }
  let(:path) { File.join(tmp, 'pe_nc_backup') }
  let(:repo) { File.join(path, 'repo') }
  let(:script) { File.join(path, 'bin', 'pe_nc_backup') }
  let(:installdir) { File.join(tmp, 'install') }
  let(:task) { File.expand_path('../../tasks/restore.rb', __dir__) }
  let(:params) { { path: path, certname: 'localhost', ssl_dir: classifier.ssl_dir, classifier_port: classifier.port, classifier_timeout: 5 } }
  let(:env) do
    gitconfig = File.join(tmp, 'gitconfig')
    File.write(gitconfig, "[init]\n\tdefaultBranch = main\n")
    { 'GIT_CONFIG_GLOBAL' => gitconfig, 'GIT_CONFIG_NOSYSTEM' => '1', 'HOME' => tmp }
  end
  let(:task_params) do
    { 'path' => path, 'certname' => 'localhost', 'ssl_dir' => classifier.ssl_dir, 'classifier_port' => classifier.port, '_installdir' => installdir }
  end
  let(:groups) do
    [
      FakeClassifier.group('All Nodes', '00000000-0000-4000-8000-000000000000', parent: '00000000-0000-4000-8000-000000000000'),
      FakeClassifier.group('PE Infrastructure', '8a0b8d8e-0000-4000-8000-000000000001'),
      FakeClassifier.group('Production environment', 'c0ffee00-0000-4000-8000-000000000002'),
      FakeClassifier.group('Web servers', 'd0000000-0000-4000-8000-000000000003', parent: 'c0ffee00-0000-4000-8000-000000000002'),
    ]
  end
  # Someone deletes the web group and changes production in the console.
  let(:damaged) do
    groups.reject { |g| g['name'] == 'Web servers' }.map { |g| (g['name'] == 'Production environment') ? g.merge('environment' => 'oops') : g }
  end

  def interpreter
    shebang = File.open(script, &:readline)[2..].strip
    ENV['E2E_RUBY'] || (File.executable?(shebang) ? shebang : RbConfig.ruby)
  end

  def clean_env(&block)
    defined?(Bundler) ? Bundler.with_unbundled_env(&block) : yield
  end

  def git(*args)
    out, status = Open3.capture2e(env, 'git', *args, chdir: repo)
    raise "git #{args.join(' ')} failed: #{out}" unless status.success?

    out
  end

  def backup
    out, status = clean_env { Open3.capture2e(env, interpreter, script, path) }
    raise "backup failed: #{out}" unless status.success?
  end

  def run_task(label, extra = {})
    out, err, status = clean_env { Open3.capture3(env, interpreter, task, stdin_data: JSON.generate(task_params.merge(extra))) }
    result = JSON.parse(out)
    if ENV['E2E_VERBOSE']
      puts "\n--- restore task, #{label}: exit #{status.exitstatus}"
      puts JSON.pretty_generate(result).lines.map { |l| "    #{l}" }.join
      puts err.lines.map { |l| "    #{l}" }.join
    end
    [status.exitstatus, result]
  end

  def live
    classifier.groups.to_h { |g| [g['name'], g['environment']] }
  end

  before(:each) do
    classifier.groups = groups
    classifier.start
    FileUtils.mkdir_p([File.dirname(script), repo, File.join(installdir, 'pe_nc_backup', 'files')])
    File.write(script, catalogue.resource('File', 'pe_nc_backup script')[:content])
    File.chmod(0o755, script)
    FileUtils.cp(File.expand_path('../../files/pe_nc_backup.rb', __dir__), File.join(installdir, 'pe_nc_backup', 'files'))
    git('init', '--quiet')
    backup
    classifier.groups = damaged
  end

  after(:each) do
    classifier.stop
    FileUtils.rm_rf(tmp)
  end

  it 'dry runs by default, then restores the backup, and can undo the restore' do
    status, result = run_task('dry run', 'max_count_drop' => 50)
    expect(status).to eq(0)
    expect(result).to include('status' => 'dry-run', 'changes' => { 'added' => ['Web servers'], 'removed' => [], 'changed' => ['Production environment'] })
    expect(classifier.imports).to be_empty
    expect(git('rev-list', '--count', 'HEAD').to_i).to eq(1)

    status, result = run_task('real restore', confirmed)
    expect(status).to eq(0)
    expect(result['status']).to eq('restored')
    expect(live).to eq(groups.to_h { |g| [g['name'], g['environment']] })
    expect(git('log', '-1', '--format=%s')).to start_with('Pre-restore backup by pe_nc_backup::restore on localhost')

    status, = run_task('undo', confirmed.merge('commit' => result['pre_restore_commit']))
    expect(status).to eq(0)
    expect(live).to eq(damaged.to_h { |g| [g['name'], g['environment']] })
    puts git('log', '--format=    %h %s') if ENV['E2E_VERBOSE']
  end

  it 'refuses a backup that is not a valid hierarchy' do
    File.write(File.join(repo, 'node_groups.json'), JSON.pretty_generate(groups.reject { |g| g['name'] == 'Production environment' }))
    git('-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qam', 'orphaned web servers')
    status, result = run_task('orphaned group', confirmed)
    expect(status).to eq(1)
    expect(result['_error']['msg']).to include('parent that is not in the backup: Web servers')
    expect(classifier.imports).to be_empty
  end

  it 'refuses a large drop in the number of groups' do
    classifier.groups = damaged + (1..10).map { |i| FakeClassifier.group("Extra #{i}", "x#{i}") }
    status, result = run_task('large drop', confirmed.merge('max_count_drop' => 10))
    expect(status).to eq(1)
    expect(result['_error']['msg']).to include('is more than max_count_drop (10%)')
    expect(classifier.imports).to be_empty
  end

  it 'leaves the pre-restore backup in place when the import fails part way, and restores from it' do
    classifier.import_partial = true
    status, result = run_task('import fails part way', confirmed)
    expect(status).to eq(1)
    pre = result['_error']['msg'][%r{commit ([0-9a-f]{40})}, 1]
    expect(pre).to eq(git('rev-parse', 'HEAD').strip)
    expect(JSON.parse(git('show', "#{pre}:node_groups.json")).map { |g| g['name'] }).to contain_exactly(*damaged.map { |g| g['name'] })
    classifier.import_partial = false
    status, = run_task('restore the pre-restore backup', confirmed.merge('commit' => pre))
    expect(status).to eq(0)
    expect(live).to eq(damaged.to_h { |g| [g['name'], g['environment']] })
  end

  it 'creates only private files' do
    files = -> { Dir.glob(File.join(path, '**', '*'), File::FNM_DOTMATCH).select { |f| File.file?(f) } }
    before = files.call
    run_task('real restore', confirmed)
    created = files.call - before
    expect(created).not_to be_empty
    # git writes loose objects read-only, so they are 0400 rather than 0600.
    expect(created.reject { |f| (File.lstat(f).mode & 0o077).zero? }).to eq([])
    expect(File.lstat(File.join(repo, 'node_groups.json')).mode & 0o777).to eq(0o600)
  end
end
