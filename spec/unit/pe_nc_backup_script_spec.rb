# frozen_string_literal: true

require 'script_helper'

describe 'pe_nc_backup script' do
  include_context 'with a backup directory and fake classifier'

  describe 'a successful backup' do
    it 'writes the groups in the format ncio backup wrote and commits them' do
      expect(run_backup).to eq(0)
      content = File.read(File.join(repo, 'node_groups.json'))
      expect(content).to eq("#{JSON.pretty_generate(PeNcBackup::Filter.new.apply(classifier.groups))}\n")
      expect(JSON.parse(content)).to be_an(Array)
      expect(commit_count(repo)).to eq(1)
      expect(git(repo, 'status', '--porcelain')).to eq('')
    end

    it 'makes the same request ncio made, authenticated with the host certificate' do
      run_backup
      expect(classifier.requests).to eq([{ path: '/classifier-api/v1/groups', query: 'inherited=false', client_cn: certname }])
    end

    it 'commits nothing when the groups have not changed' do
      expect(run_backup).to eq(0)
      expect(run_backup).to eq(0)
      expect(commit_count(repo)).to eq(1)
      expect(log_io.string).to include('nothing to commit')
    end

    it 'commits once more when a group changes' do
      run_backup
      classifier.groups = groups.map { |g| (g['name'] == 'Production') ? g.merge('environment' => 'staging') : g }
      run_backup
      expect(commit_count(repo)).to eq(2)
      expect(git(repo, 'show', '--stat', 'HEAD')).to include('node_groups.json')
    end

    it 'uses the original commit message' do
      run_backup
      expect(last_commit_message(repo)).to match(%r{\AUpdate node groups by pe_nc_backup on #{Regexp.escape(certname)} at \d{4}-\d\d-\d\dT})
    end

    it 'commits as pe_nc_backup when the user has no git identity' do
      run_backup
      expect(git(repo, 'log', '-1', '--format=%an <%ae>').strip).to eq("pe_nc_backup <pe_nc_backup@#{certname}>")
    end

    it 'keeps the git identity of the user when there is one' do
      git(repo, 'config', 'user.name', 'Backup Bot')
      git(repo, 'config', 'user.email', 'bot@example.test')
      run_backup
      expect(git(repo, 'log', '-1', '--format=%an <%ae>').strip).to eq('Backup Bot <bot@example.test>')
    end

    it 'connects to the certname when classifier_host is not set' do
      cfg = config.merge('classifier_host' => nil)
      # The certname does not resolve, which proves the script tried to use it.
      expect(run_backup(cfg)).to eq(1)
      expect(log_io.string).to include("https://#{certname}:#{classifier.port}/classifier-api/v1/groups")
    end

    it 'falls back to puppet config print certname when no certname is set' do
      bindir = File.join(tmp, 'bin')
      FileUtils.mkdir_p(bindir)
      File.write(File.join(bindir, 'puppet'), "#!/bin/sh\necho #{certname}\n")
      File.chmod(0o755, File.join(bindir, 'puppet'))
      expect(run_backup(config.merge('certname' => nil, 'puppet_bindir' => bindir))).to eq(0)
      expect(classifier.requests.first[:client_cn]).to eq(certname)
    end

    it 'fails when the certname cannot be determined' do
      expect(run_backup(config.merge('certname' => nil, 'puppet_bindir' => File.join(tmp, 'nowhere')))).to eq(1)
      expect(stdout_io.string).to include('Unable to determine the certname')
    end

    it 'does not leave temporary files behind' do
      run_backup
      expect(Dir.children(path).sort - ['.pe_nc_backup.lock']).to eq(['repo'])
    end
  end

  describe 'noise controls and ordering' do
    it 'sorts the groups by id' do
      run_backup
      expect(backup_json.map { |g| g['name'] }).to eq(['All Nodes', 'Development', 'Production'])
    end

    it 'sorts every hash by key, at every depth' do
      classifier.groups = [FakeClassifier.group('All Nodes', '0', classes: { 'zz' => { 'b' => 1, 'a' => { 'y' => 1, 'x' => 2 } }, 'aa' => {} })]
      run_backup
      group = backup_json.first
      expect(group.keys).to eq(group.keys.sort)
      expect(group['classes'].keys).to eq(['aa', 'zz'])
      expect(group['classes']['zz'].keys).to eq(['a', 'b'])
      expect(group['classes']['zz']['a'].keys).to eq(['x', 'y'])
    end

    it 'keeps the order of arrays, since rule order matters' do
      rule = ['or', ['=', 'name', 'zeta'], ['=', 'name', 'alpha']]
      classifier.groups = [FakeClassifier.group('All Nodes', '0', rule: rule)]
      run_backup
      expect(backup_json.first['rule']).to eq(rule)
    end

    it 'writes byte-identical output, and commits nothing, when the API reorders the same data' do
      run_backup
      first = File.read(File.join(repo, 'node_groups.json'))
      classifier.groups = groups.reverse.map { |g| g.to_a.reverse.to_h }
      run_backup
      expect(File.read(File.join(repo, 'node_groups.json'))).to eq(first)
      expect(commit_count(repo)).to eq(1)
    end

    context 'with exclude_groups' do
      let(:extra_config) { { 'exclude_groups' => ['^Dev', 'Nothing matches this'] } }

      it 'leaves out the groups whose name matches any pattern' do
        expect(run_backup).to eq(0)
        expect(backup_json.map { |g| g['name'] }).to eq(['All Nodes', 'Production'])
        expect(log_io.string).to include('Retrieved 3 node groups, keeping 2')
      end

      it 'matches a pattern anywhere in the name unless it is anchored' do
        expect(run_backup(config.merge('exclude_groups' => ['duct']))).to eq(0)
        expect(backup_json.map { |g| g['name'] }).to eq(['All Nodes', 'Development'])
      end

      it 'commits nothing when only an excluded group changes' do
        run_backup
        classifier.groups = groups.map { |g| (g['name'] == 'Development') ? g.merge('environment' => 'other') : g }
        run_backup
        expect(commit_count(repo)).to eq(1)
      end
    end

    it 'refuses to write an empty backup when every group is excluded' do
      expect(run_backup(config.merge('exclude_groups' => ['.']))).to eq(1)
      expect(File.exist?(File.join(repo, 'node_groups.json'))).to be(false)
      expect(stdout_io.string).to include('exclude_groups and exclude_environments matched all 3 node groups')
    end

    it 'fails before fetching anything when a pattern is not a valid regex' do
      expect(run_backup(config.merge('exclude_groups' => ['(unclosed']))).to eq(1)
      expect(classifier.requests).to be_empty
      expect(stdout_io.string).to include('Invalid exclude_groups pattern')
    end

    context 'with exclude_environments' do
      # CD4PE's rolling deployments create groups whose environment is rolling_deployment_<n>.
      let(:groups) do
        [
          FakeClassifier.group('All Nodes', '0', parent: '0'),
          FakeClassifier.group('Production', '1'),
          FakeClassifier.group('Deployment 1234', '2', environment: 'rolling_deployment_1234'),
          FakeClassifier.group('Production one-off', '3', environment: 'production_rolling'),
        ]
      end
      let(:extra_config) { { 'exclude_environments' => ['^rolling_deployment_'] } }

      it 'leaves out the groups whose environment matches' do
        expect(run_backup).to eq(0)
        expect(backup_json.map { |g| g['name'] }).to eq(['All Nodes', 'Production', 'Production one-off'])
      end

      it 'excludes a group that matches either setting' do
        expect(run_backup(config.merge('exclude_groups' => ['one-off']))).to eq(0)
        expect(backup_json.map { |g| g['name'] }).to eq(['All Nodes', 'Production'])
      end

      it 'does not match environment patterns against names' do
        expect(run_backup(config.merge('exclude_environments' => ['^Production']))).to eq(0)
        expect(backup_json.size).to eq(4)
      end

      it 'commits nothing when a rolling deployment group comes and goes' do
        run_backup
        classifier.groups = groups + [FakeClassifier.group('Deployment 1235', '4', environment: 'rolling_deployment_1235')]
        run_backup
        classifier.groups = groups.reject { |g| g['id'] == '2' }
        run_backup
        expect(commit_count(repo)).to eq(1)
      end

      it 'fails before fetching anything when a pattern is not a valid regex' do
        expect(run_backup(config.merge('exclude_environments' => ['[']))).to eq(1)
        expect(classifier.requests).to be_empty
        expect(stdout_io.string).to include('Invalid exclude_environments pattern')
      end
    end

    context 'with strip_fields' do
      let(:extra_config) { { 'strip_fields' => ['serial_number', 'last_edited'] } }

      it 'removes the fields from every group' do
        run_backup
        backup_json.each do |g|
          expect(g).not_to include('serial_number', 'last_edited')
          expect(g).to include('name', 'id', 'rule', 'classes')
        end
      end

      it 'only strips top-level group fields' do
        classifier.groups = [FakeClassifier.group('All Nodes', '0', classes: { 'x' => { 'serial_number' => 7 } })]
        run_backup
        expect(backup_json.first['classes']).to eq('x' => { 'serial_number' => 7 })
      end

      it 'commits nothing when only a stripped field changes' do
        run_backup
        classifier.groups = groups.map { |g| g.merge('serial_number' => 99, 'last_edited' => '2026-11-23T00:00:00.000Z') }
        run_backup
        expect(commit_count(repo)).to eq(1)
      end
    end

    it 'commits when a stripped field changes if strip_fields is not set' do
      run_backup
      classifier.groups = groups.map { |g| g.merge('serial_number' => 99) }
      run_backup
      expect(commit_count(repo)).to eq(2)
    end
  end

  describe 'commit messages' do
    it 'lists every group as added on the first run' do
      run_backup
      expect(last_commit_message(repo)).to match(%r{\AUpdate node groups by pe_nc_backup on \S+ at \S+\n\nAdded: All Nodes, Development, Production\n\z})
    end

    it 'lists added, changed and removed groups by name' do
      run_backup
      classifier.groups = [
        groups[0],
        groups[1].merge('environment' => 'staging'),
        FakeClassifier.group('Web servers', 'd0000000-0000-4000-8000-000000000003'),
      ]
      run_backup
      expect(last_commit_message(repo).lines.drop(2).join).to eq("Added: Web servers\nChanged: Production\nRemoved: Development\n")
    end

    it 'counts the names beyond the first fifty' do
      classifier.groups = (1..60).map { |i| FakeClassifier.group('Group %02d' % i, 'id-%02d' % i) }
      run_backup
      added = last_commit_message(repo).lines.last
      expect(added).to start_with('Added: Group 01, Group 02,')
      expect(added).to end_with("Group 50 and 10 more\n")
    end

    it 'does not count a group as changed when only a stripped field differs from the old backup' do
      run_backup
      classifier.groups = groups.map { |g| (g['name'] == 'Production') ? g.merge('serial_number' => 9, 'description' => 'new') : g.merge('serial_number' => 9) }
      run_backup(config.merge('strip_fields' => ['serial_number']))
      expect(last_commit_message(repo).lines.drop(2).join).to eq("Changed: Production\n")
    end
  end

  describe 'split_files' do
    let(:extra_config) { { 'split_files' => true } }
    let(:group_files) { Dir.children(File.join(repo, 'groups')).sort }

    it 'writes one file per group, named after the group and its id' do
      expect(run_backup).to eq(0)
      expect(group_files).to eq([
                                  'All_Nodes-00000000-0000-4000-8000-000000000000.json',
                                  'Development-a0000000-0000-4000-8000-000000000001.json',
                                  'Production-b0000000-0000-4000-8000-000000000002.json',
                                ])
      expect(File.exist?(File.join(repo, 'node_groups.json'))).to be(false)
      expect(git(repo, 'ls-files').lines.size).to eq(3)
    end

    it 'writes each group as a sorted, pretty printed JSON object' do
      run_backup
      content = File.read(File.join(repo, 'groups', 'Production-b0000000-0000-4000-8000-000000000002.json'))
      expect(content).to eq("#{JSON.pretty_generate(PeNcBackup::Filter.new.normalise(groups[1]))}\n")
    end

    it 'commits nothing when nothing changed' do
      run_backup
      run_backup
      expect(commit_count(repo)).to eq(1)
    end

    it 'updates only the file of the group that changed' do
      run_backup
      classifier.groups = groups.map { |g| (g['name'] == 'Production') ? g.merge('environment' => 'staging') : g }
      run_backup
      expect(commit_count(repo)).to eq(2)
      expect(git(repo, 'show', '--name-status', '--format=', 'HEAD')).to eq("M\tgroups/Production-b0000000-0000-4000-8000-000000000002.json\n")
      expect(last_commit_message(repo)).to end_with("\n\nChanged: Production\n")
    end

    it 'deletes the file of a group that no longer exists' do
      run_backup
      classifier.groups = groups.reject { |g| g['name'] == 'Development' }
      run_backup
      expect(group_files).not_to include(a_string_starting_with('Development'))
      expect(git(repo, 'show', '--name-status', '--format=', 'HEAD')).to eq("D\tgroups/Development-a0000000-0000-4000-8000-000000000001.json\n")
      expect(last_commit_message(repo)).to end_with("\n\nRemoved: Development\n")
    end

    it 'renames the file when a group is renamed' do
      run_backup
      classifier.groups = groups.map { |g| (g['name'] == 'Development') ? g.merge('name' => 'Dev & Test') : g }
      run_backup
      expect(group_files).to include('Dev_Test-a0000000-0000-4000-8000-000000000001.json')
      expect(group_files).not_to include('Development-a0000000-0000-4000-8000-000000000001.json')
      expect(last_commit_message(repo)).to end_with("\n\nChanged: Dev & Test\n")
    end

    it 'adds a file for a new group' do
      run_backup
      classifier.groups = groups + [FakeClassifier.group('Web', 'c0000000-0000-4000-8000-000000000003')]
      run_backup
      expect(git(repo, 'show', '--name-status', '--format=', 'HEAD')).to eq("A\tgroups/Web-c0000000-0000-4000-8000-000000000003.json\n")
      expect(last_commit_message(repo)).to end_with("\n\nAdded: Web\n")
    end

    it 'makes names safe for the file system' do
      classifier.groups = [FakeClassifier.group('../../etc/passwd', 'x/y'), FakeClassifier.group('Ünïcode / spaces  ', 'u1'), FakeClassifier.group('...', 'dots')]
      run_backup
      expect(group_files).to eq(['etc_passwd-x_y.json', 'group-dots.json', 'n_code_spaces_-u1.json'])
    end

    it 'leaves files other than group JSON alone' do
      FileUtils.mkdir_p(File.join(repo, 'groups'))
      File.write(File.join(repo, 'groups', 'README'), "notes\n")
      run_backup
      expect(group_files).to include('README')
    end

    it 'removes the single file when switching to split files, in one commit' do
      run_backup(config.merge('split_files' => false))
      run_backup
      expect(commit_count(repo)).to eq(2)
      expect(git(repo, 'show', '--name-status', '--format=', 'HEAD').lines.map { |l| l[0] }.tally).to eq('A' => 3, 'D' => 1)
      expect(last_commit_message(repo).lines.size).to eq(1)
    end

    it 'removes the group files when switching back to a single file' do
      run_backup
      run_backup(config.merge('split_files' => false))
      expect(Dir.exist?(File.join(repo, 'groups')) ? group_files : []).to be_empty
      expect(git(repo, 'ls-files')).to eq("node_groups.json\n")
    end

    it 'writes and commits nothing when the fetch fails' do
      run_backup
      classifier.status = 500
      expect(run_backup).to eq(1)
      expect(commit_count(repo)).to eq(1)
      expect(git(repo, 'status', '--porcelain')).to eq('')
    end
  end

  describe 'file permissions' do
    def mode(file)
      File.lstat(file).mode & 0o777
    end

    it 'writes the backup, log and git objects private to the user, whatever the umask it was started with' do
      old = File.umask(0o022)
      begin
        PeNcBackup.main(config.merge('stdout_log' => false))
      ensure
        File.umask(old)
      end
      expect(mode(File.join(repo, 'node_groups.json'))).to eq(0o600)
      expect(mode(File.join(path, 'pe_nc_backup.log'))).to eq(0o600)
      objects = Dir.glob(File.join(repo, '.git', 'objects', '??', '*'))
      expect(objects).not_to be_empty
      expect(objects.map { |f| mode(f) & 0o077 }.uniq).to eq([0])
      expect(Dir.glob(File.join(repo, '.git', 'objects', '??')).map { |d| mode(d) }.uniq).to eq([0o700])
    end

    it 'puts the umask back afterwards, for callers in the same process' do
      old = File.umask(0o022)
      begin
        run_backup
        expect(File.umask).to eq(0o022)
      ensure
        File.umask(old)
      end
    end

    it 'writes split files and the groups directory privately' do
      run_backup(config.merge('split_files' => true))
      expect(mode(File.join(repo, 'groups'))).to eq(0o700)
      expect(Dir.glob(File.join(repo, 'groups', '*')).map { |f| mode(f) }.uniq).to eq([0o600])
    end

    it 'does not follow a symlink planted at the temporary file path' do
      victim = File.join(tmp, 'victim')
      File.write(victim, "precious\n")
      link = File.join(path, ".node_groups.json.#{Process.pid}.tmp")
      File.symlink(victim, link)
      expect(run_backup).to eq(1)
      expect(File.read(victim)).to eq("precious\n")
      expect(File.symlink?(link)).to be(true)
      expect(File.exist?(File.join(repo, 'node_groups.json'))).to be(false)
      expect(commit_count(repo)).to eq(0)
      expect(stdout_io.string).to include('already exists, refusing to write through it')
    end

    it 'turns off core.sharedRepository so git keeps its objects private' do
      git(repo, 'config', 'core.sharedRepository', 'world')
      expect(run_backup).to eq(0)
      expect(Open3.capture2e('git', 'config', '--local', 'core.sharedRepository', chdir: repo)[1].success?).to be(false)
      expect(log_io.string).to include('Unsetting core.sharedRepository=world')
      objects = Dir.glob(File.join(repo, '.git', 'objects', '??', '*'))
      expect(objects.map { |f| mode(f) & 0o077 }.uniq).to eq([0])
    end

    it 'leaves core.sharedRepository alone when it is already private' do
      git(repo, 'config', 'core.sharedRepository', 'false')
      run_backup
      expect(git(repo, 'config', '--local', 'core.sharedRepository').strip).to eq('false')
    end
  end

  describe 'a failed fetch' do
    before(:each) do
      File.write(File.join(repo, 'node_groups.json'), "[\n  {\"previous\": true}\n]\n")
      git(repo, 'add', 'node_groups.json')
      git(repo, '-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '-m', 'previous backup')
    end

    shared_examples 'a failed backup' do |message|
      it 'exits 1, leaves the previous backup alone and commits nothing' do
        expect(run_backup).to eq(1)
        expect(File.read(File.join(repo, 'node_groups.json'))).to eq("[\n  {\"previous\": true}\n]\n")
        expect(commit_count(repo)).to eq(1)
        expect(git(repo, 'status', '--porcelain')).to eq('')
        expect(Dir.children(path).sort - ['.pe_nc_backup.lock']).to eq(['repo'])
      end

      it 'logs the reason to every logger' do
        run_backup
        [log_io, stdout_io].each do |io|
          expect(io.string).to match(message)
          expect(io.string).to include('nothing was committed')
        end
      end
    end

    context 'with an HTTP error' do
      before(:each) do
        classifier.status = 500
        classifier.body = '{"kind":"application-error","msg":"boom"}'
      end

      it_behaves_like 'a failed backup', %r{returned HTTP 500: .*boom}
    end

    context 'with an authentication error' do
      before(:each) do
        classifier.status = 401
        classifier.body = '{"kind":"puppetlabs.rbac/user-unauthenticated","msg":"not allowed"}'
      end

      it_behaves_like 'a failed backup', %r{returned HTTP 401}
    end

    context 'with invalid JSON' do
      before(:each) { classifier.body = '[{"name": "All Nodes"' }

      it_behaves_like 'a failed backup', %r{returned invalid JSON}
    end

    context 'with an empty list of groups' do
      before(:each) { classifier.body = '[]' }

      it_behaves_like 'a failed backup', %r{did not return a non-empty JSON array}
    end

    context 'with something other than an array' do
      before(:each) { classifier.body = '{"groups": []}' }

      it_behaves_like 'a failed backup', %r{did not return a non-empty JSON array}
    end

    context 'when the classifier is too slow' do
      let(:extra_config) { { 'timeout' => 1 } }

      before(:each) { classifier.delay = 3 }

      it_behaves_like 'a failed backup', %r{timed out waiting for a response after 1 seconds}
    end

    context 'when nothing is listening' do
      let(:extra_config) { { 'classifier_port' => free_port } }

      def free_port
        server = TCPServer.new('127.0.0.1', 0)
        server.addr[1]
      ensure
        server&.close
      end

      it_behaves_like 'a failed backup', %r{failed: Errno::ECONNREFUSED}
    end

    context 'when the server certificate is not signed by the Puppet CA' do
      before(:each) do
        other = FakeClassifier.new(File.join(tmp, 'other'), certname, ca: :other)
        FileUtils.cp(File.join(other.ssl_dir, 'certs', 'ca.pem'), File.join(classifier.ssl_dir, 'certs', 'ca.pem'))
      end

      it_behaves_like 'a failed backup', %r{failed: OpenSSL::SSL::SSLError}
    end

    context 'when the host certificate is missing' do
      before(:each) { File.delete(File.join(classifier.ssl_dir, 'certs', "#{certname}.pem")) }

      it_behaves_like 'a failed backup', %r{cert file not found}
    end

    context 'when the private key is missing' do
      before(:each) { File.delete(File.join(classifier.ssl_dir, 'private_keys', "#{certname}.pem")) }

      it_behaves_like 'a failed backup', %r{key file not found}
    end

    context 'when the private key is not a key' do
      before(:each) { File.write(File.join(classifier.ssl_dir, 'private_keys', "#{certname}.pem"), "not a key\n") }

      it_behaves_like 'a failed backup', %r{failed: OpenSSL::PKey::PKeyError}
    end

    context 'when the CA certificate is missing' do
      before(:each) { File.delete(File.join(classifier.ssl_dir, 'certs', 'ca.pem')) }

      it_behaves_like 'a failed backup', %r{ca file not found}
    end
  end

  describe 'the backup repo' do
    it 'fails when the repo is not a git repo, and writes nothing' do
      FileUtils.rm_rf(File.join(repo, '.git'))
      expect(run_backup).to eq(1)
      expect(Dir.children(repo)).to be_empty
      expect(classifier.requests).to be_empty
      expect(stdout_io.string).to include('This does not appear to be a git repo')
    end

    it 'does not mistake a directory inside another git repo for the backup repo' do
      FileUtils.rm_rf(File.join(repo, '.git'))
      git(path, 'init', '--quiet')
      expect(run_backup).to eq(1)
      expect(Dir.children(repo)).to be_empty
    end

    it 'fails when the repo directory is missing' do
      FileUtils.rm_rf(repo)
      expect(run_backup).to eq(1)
      expect(stdout_io.string).to include('Backup repo directory does not exist')
    end

    it 'fails when the backup directory is missing' do
      expect(PeNcBackup.main(config.merge('path' => File.join(tmp, 'nope')), loggers)).to eq(1)
    end
  end

  describe 'logging' do
    it 'writes a log file in the backup directory when no loggers are passed in' do
      cfg = config.merge('stdout_log' => false, 'log_level' => 'info')
      expect(PeNcBackup.main(cfg)).to eq(0)
      expect(File.read(File.join(path, 'pe_nc_backup.log'))).to include('Committed changes to the node groups')
    ensure
      FileUtils.rm_f(File.join(path, 'pe_nc_backup.log'))
    end

    it 'honours the stdout log level' do
      cfg = config.merge('stdout_log' => true, 'log_level_stdout' => 'error')
      expect { PeNcBackup.main(cfg) }.not_to output.to_stdout_from_any_process
      FileUtils.rm_f(File.join(path, 'pe_nc_backup.log'))
    end

    it 'logs unexpected errors and exits 1' do
      allow(PeNcBackup::Runner).to receive(:new).and_raise(ArgumentError, 'surprise')
      expect(run_backup).to eq(1)
      expect(stdout_io.string).to include('Unexpected error: ArgumentError: surprise')
    end
  end
end
