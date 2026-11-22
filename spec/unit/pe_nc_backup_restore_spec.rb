# frozen_string_literal: true

require 'script_helper'

describe 'pe_nc_backup restore' do
  include_context 'with a backup directory and fake classifier'

  let(:root_id) { PeNcBackup::ROOT_ID }
  # The handful of groups here make every change a big percentage, so the
  # count check gets its own tests below with the default limit.
  let(:extra_config) { { 'max_count_drop' => 50 } }
  let(:confirmed) { { 'dry_run' => false, 'confirm' => 'replace-entire-classifier' } }
  let(:changed_live) do
    [
      groups[0],
      groups[1].merge('environment' => 'staging'),
      FakeClassifier.group('Added later', 'e0000000-0000-4000-8000-000000000004'),
      FakeClassifier.group('Also added', 'f0000000-0000-4000-8000-000000000005'),
    ]
  end

  def restore(params = {})
    PeNcBackup::Restore.new(config.merge(params), PeNcBackup::Log.new(loggers)).restore
  end

  def head
    git(repo, 'rev-parse', 'HEAD').strip
  end

  # Commits raw content as node_groups.json, for backups the script would never write.
  def commit_backup(content)
    content = "#{JSON.pretty_generate(content)}\n" unless content.is_a?(String)
    File.write(File.join(repo, 'node_groups.json'), content)
    git(repo, 'add', '--all')
    git(repo, '-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '-m', 'crafted')
    head
  end

  def live_names
    classifier.groups.map { |g| g['name'] }.sort
  end

  before(:each) do
    expect(run_backup).to eq(0)
    classifier.groups = changed_live
  end

  describe 'a dry run' do
    it 'is the default, and reports what would change without changing anything' do
      before_head = head
      result = restore('confirm' => 'replace-entire-classifier')
      expect(result).to include('status' => 'dry-run', 'dry_run' => true, 'commit' => before_head, 'backup_groups' => 3, 'live_groups' => 4)
      expect(result['changes']).to eq('added' => ['Development'], 'removed' => ['Added later', 'Also added'], 'changed' => ['Production'])
      expect(classifier.imports).to be_empty
      expect(head).to eq(before_head)
      expect(git(repo, 'status', '--porcelain')).to eq('')
      expect(live_names).to eq(['Added later', 'All Nodes', 'Also added', 'Production'])
    end

    it 'ignores server-managed fields when comparing' do
      classifier.groups = groups.map { |g| g.merge('serial_number' => 42, 'last_edited' => 'later', 'deleted' => { 'x' => 1 }) }
      expect(restore['changes']).to eq('added' => [], 'removed' => [], 'changed' => [])
    end
  end

  describe 'the confirm gate' do
    it 'refuses a real restore without confirm, before touching anything' do
      expect { restore('dry_run' => false) }.to raise_error(PeNcBackup::Error, %r{Set confirm to 'replace-entire-classifier'})
      expect(classifier.imports).to be_empty
      expect(commit_count(repo)).to eq(1)
    end

    it 'refuses the wrong confirmation' do
      expect { restore('dry_run' => false, 'confirm' => 'yes') }.to raise_error(PeNcBackup::Error, %r{Set confirm})
      expect(classifier.imports).to be_empty
    end
  end

  describe 'a real restore' do
    it 'saves the live classifier first, imports the backup, and checks the result' do
      target = head
      result = restore(confirmed)
      expect(result).to include('status' => 'restored', 'commit' => target)
      expect(classifier.imports.size).to eq(1)
      expect(classifier.imports.first[:client_cn]).to eq(certname)
      expect(live_names).to eq(['All Nodes', 'Development', 'Production'])
      expect(classifier.groups.find { |g| g['name'] == 'Production' }['environment']).to eq('production')

      pre = result['pre_restore_commit']
      expect(pre).to eq(head)
      expect(git(repo, 'log', '-1', '--format=%s', pre)).to start_with("Pre-restore backup by pe_nc_backup::restore on #{certname} at ")
      expect(git(repo, 'log', '-1', '--format=%s', pre)).to end_with("before restoring #{target[0, 12]}\n")
      saved = JSON.parse(git(repo, 'show', "#{pre}:node_groups.json"))
      expect(saved.map { |g| g['name'] }.sort).to eq(['Added later', 'All Nodes', 'Also added', 'Production'])
    end

    it 'can undo itself by restoring the pre-restore commit' do
      pre = restore(confirmed)['pre_restore_commit']
      restore(confirmed.merge('commit' => pre))
      expect(live_names).to eq(['Added later', 'All Nodes', 'Also added', 'Production'])
    end

    it 'restores an older commit, not just HEAD' do
      first = head
      classifier.groups = groups + [FakeClassifier.group('Third', 'c0000000-0000-4000-8000-000000000009')]
      run_backup
      classifier.groups = changed_live
      restore(confirmed.merge('commit' => first))
      expect(live_names).to eq(['All Nodes', 'Development', 'Production'])
    end

    it 'restores from the split layout, keeping that layout for the pre-restore backup' do
      classifier.groups = groups
      run_backup(config.merge('split_files' => true))
      classifier.groups = changed_live
      pre = restore(confirmed)['pre_restore_commit']
      expect(live_names).to eq(['All Nodes', 'Development', 'Production'])
      expect(git(repo, 'ls-tree', '-r', '--name-only', pre).lines.map(&:strip)).to all(start_with('groups/'))
    end

    it 'puts back serial_number and last_edited when the backup was taken without them' do
      classifier.groups = groups
      run_backup(config.merge('strip_fields' => ['serial_number', 'last_edited']))
      classifier.groups = changed_live
      expect(restore(confirmed)['status']).to eq('restored')
      expect(live_names).to eq(['All Nodes', 'Development', 'Production'])
    end

    it 'fails when the classifier does not match what was sent' do
      classifier.after_import = ->(gs) { gs.map { |g| (g['name'] == 'Development') ? g.merge('environment' => 'surprise') : g } }
      expect { restore(confirmed) }.to raise_error(PeNcBackup::Error, %r{does not match the backup: changed Development.*before this restore is in commit [0-9a-f]{40}})
    end

    it 'never commits a pre-restore backup when the backup is invalid' do
      commit_backup('not json')
      expect { restore(confirmed) }.to raise_error(PeNcBackup::Error)
      expect(commit_count(repo)).to eq(2)
      expect(classifier.imports).to be_empty
    end
  end

  describe 'HTTP behaviour' do
    it 'sends the import once, with no retry, when it times out' do
      classifier.import_delay = 3
      expect { restore(confirmed.merge('read_timeout' => 1)) }
        .to raise_error(PeNcBackup::Error, %r{POST .*import-hierarchy timed out waiting for a response after 1 seconds.*before this restore is in commit})
      sleep 2.5
      expect(classifier.imports.size).to eq(1)
    end

    it 'sends the import once when the classifier returns an error' do
      classifier.import_status = 503
      expect { restore(confirmed) }.to raise_error(PeNcBackup::Error, %r{returned HTTP 503: application-error: import refused})
      expect(classifier.imports.size).to eq(1)
    end

    it 'reports PE kind and msg but never the groups it sent' do
      classifier.import_status = 400
      classifier.import_body = JSON.generate('kind' => 'schema-violation', 'msg' => 'bad', 'details' => { 'submitted' => [{ 'secret' => 'hunter2' }] })
      expect { restore(confirmed) }.to raise_error(PeNcBackup::Error) { |e|
        expect(e.message).to include('returned HTTP 400: schema-violation: bad')
        expect(e.message).not_to include('hunter2')
      }
    end

    it 'does not show a body that is not a PE error' do
      classifier.import_status = 502
      classifier.import_body = '<html>secret proxy page</html>'
      expect { restore(confirmed) }.to raise_error(PeNcBackup::Error) { |e| expect(e.message).not_to include('secret proxy') }
    end

    it 'times out reading the live groups' do
      classifier.delay = 3
      expect { restore('read_timeout' => 1) }.to raise_error(PeNcBackup::Error, %r{GET .* timed out waiting for a response after 1 seconds})
    end

    it 'leaves the pre-restore backup in place when the import fails part way' do
      classifier.import_partial = true
      error = nil
      expect { restore(confirmed) }.to raise_error(PeNcBackup::Error) { |e| error = e }
      pre = error.message[%r{commit ([0-9a-f]{40})}, 1]
      expect(pre).to eq(head)
      expect(classifier.groups.size).to eq(1)
      classifier.import_partial = false
      restore(confirmed.merge('commit' => pre))
      expect(live_names).to eq(['Added later', 'All Nodes', 'Also added', 'Production'])
    end
  end

  describe 'validation' do
    def all_nodes(**extra)
      FakeClassifier.group('All Nodes', root_id, parent: root_id, **extra)
    end

    def child(name, id, parent: root_id)
      FakeClassifier.group(name, id, parent: parent)
    end

    shared_examples 'a refused restore' do |message|
      it 'refuses, even as a dry run, and sends and commits nothing' do
        commit_backup(backup)
        expect { restore }.to raise_error(PeNcBackup::Error, message)
        expect { restore(confirmed) }.to raise_error(PeNcBackup::Error, message)
        expect(classifier.imports).to be_empty
        expect(commit_count(repo)).to eq(2)
      end
    end

    context 'with invalid JSON' do
      let(:backup) { '[{"name": ' }

      it_behaves_like 'a refused restore', %r{node_groups.json in [0-9a-f]+ is not valid JSON}
    end

    context 'with an empty array' do
      let(:backup) { [] }

      it_behaves_like 'a refused restore', %r{is not a non-empty JSON array}
    end

    context 'with an object instead of an array' do
      let(:backup) { { 'groups' => [] } }

      it_behaves_like 'a refused restore', %r{is not a non-empty JSON array}
    end

    context 'with an entry that is not an object' do
      let(:backup) { [all_nodes, 'x'] }

      it_behaves_like 'a refused restore', %r{1 entries that are not node group objects}
    end

    context 'with a group missing a required field' do
      let(:backup) { [all_nodes, child('Web', 'w1').tap { |g| g.delete('environment') }] }

      it_behaves_like 'a refused restore', %r{Node group Web is missing environment}
    end

    context 'with a duplicate id' do
      let(:backup) { [all_nodes, child('Web', 'w1'), child('Web again', 'w1')] }

      it_behaves_like 'a refused restore', %r{ids appear more than once: w1}
    end

    context 'with no root group' do
      let(:backup) { [all_nodes(parent: 'w1'), child('Web', 'w1')] }

      it_behaves_like 'a refused restore', %r{exactly one root group}
    end

    context 'with two root groups' do
      let(:backup) { [all_nodes, FakeClassifier.group('Other root', 'r2', parent: 'r2')] }

      it_behaves_like 'a refused restore', %r{exactly one root group.*Other root}
    end

    context 'with a root group that is not All Nodes' do
      let(:backup) { [FakeClassifier.group('Imposter', 'r9', parent: 'r9'), child('Web', 'w1', parent: 'r9')] }

      it_behaves_like 'a refused restore', %r{exactly one root group, All Nodes}
    end

    context 'with a parent that is not in the backup' do
      let(:backup) { [all_nodes, child('Web', 'w1', parent: 'gone')] }

      it_behaves_like 'a refused restore', %r{parent that is not in the backup: Web}
    end

    context 'with an inheritance cycle' do
      let(:backup) { [all_nodes, child('A', 'a', parent: 'b'), child('B', 'b', parent: 'a')] }

      it_behaves_like 'a refused restore', %r{inheritance cycle}
    end

    context 'with an option-like commit' do
      it 'refuses it' do
        expect { restore('commit' => '--output=/tmp/x') }.to raise_error(PeNcBackup::Error, %r{Invalid commit})
      end
    end

    context 'with a commit that does not exist' do
      it 'refuses it' do
        expect { restore('commit' => 'deadbeef') }.to raise_error(PeNcBackup::Error, %r{No commit 'deadbeef'})
      end
    end

    context 'with a commit that holds no backup' do
      it 'refuses it' do
        git(repo, 'rm', '-q', 'node_groups.json')
        git(repo, '-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '-m', 'empty')
        expect { restore }.to raise_error(PeNcBackup::Error, %r{holds no node group backup})
      end
    end
  end

  describe 'the group count check' do
    let(:extra_config) { {} }

    before(:each) do
      classifier.groups = groups + (1..7).map { |i| FakeClassifier.group("Extra #{i}", "x#{i}") }
    end

    it 'refuses a restore that would drop more than 10% of the groups' do
      expect { restore(confirmed) }.to raise_error(PeNcBackup::Error, %r{3 node groups and the classifier has 10, a drop of 70.0% is more than max_count_drop \(10%\)})
      expect(classifier.imports).to be_empty
      expect(commit_count(repo)).to eq(1)
    end

    it 'allows it with force' do
      expect(restore(confirmed.merge('force' => true))['status']).to eq('restored')
    end

    it 'allows it with a higher max_count_drop' do
      expect(restore(confirmed.merge('max_count_drop' => 70))['status']).to eq('restored')
    end

    it 'checks a drop of exactly the limit as allowed' do
      classifier.groups = groups + [FakeClassifier.group('Extra', 'x1')]
      expect(restore(confirmed.merge('max_count_drop' => 25))['status']).to eq('restored')
    end
  end

  describe 'the task entry point' do
    let(:out) { StringIO.new }
    let(:err) { StringIO.new }

    it 'prints the result as JSON and exits 0' do
      expect(PeNcBackup::RestoreTask.main(config.merge('_installdir' => '/x'), out, err)).to eq(0)
      expect(JSON.parse(out.string)).to include('status' => 'dry-run')
    end

    it 'prints a task error and exits 1' do
      expect(PeNcBackup::RestoreTask.main(config.merge('dry_run' => false), out, err)).to eq(1)
      expect(JSON.parse(out.string)['_error']).to include('kind' => 'pe_nc_backup/restore-failed', 'msg' => a_string_including('Set confirm'))
    end

    it 'restores the umask it was given' do
      old = File.umask(0o022)
      PeNcBackup::RestoreTask.main(config, out, err)
      expect(File.umask).to eq(0o022)
    ensure
      File.umask(old)
    end
  end
end
