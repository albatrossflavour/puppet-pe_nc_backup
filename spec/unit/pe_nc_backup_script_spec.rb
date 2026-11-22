# frozen_string_literal: true

require 'script_helper'

describe 'pe_nc_backup script' do
  include_context 'with a backup directory and fake classifier'

  describe 'a successful backup' do
    it 'writes the groups in the format ncio backup wrote and commits them' do
      expect(run_backup).to eq(0)
      content = File.read(File.join(repo, 'node_groups.json'))
      expect(content).to eq("#{JSON.pretty_generate(JSON.parse(classifier.body || JSON.generate(classifier.groups)))}\n")
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
      expect(Dir.children(path).sort).to eq(['repo'])
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
        expect(Dir.children(path).sort).to eq(['repo'])
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

      it_behaves_like 'a failed backup', %r{timed out after 1 seconds}
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
