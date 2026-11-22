# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'tmpdir'

# Runs the exec that tightens an existing, world-readable backup left by an
# earlier release, against a real directory tree.
describe 'pe_nc_backup', type: :class do
  let(:facts) { on_supported_os.values.first }
  let(:tmp) { Dir.mktmpdir('pe_nc_backup_perms') }
  let(:path) { File.join(tmp, 'pe_nc_backup') }
  let(:repo) { File.join(path, 'repo') }
  let(:params) { { path: path } }
  let(:exec) { catalogue.resource('Exec', 'pe_nc_backup make the backup private') }

  after(:each) { FileUtils.rm_rf(tmp) }

  def sh(command)
    Open3.capture2e('/bin/sh', '-c', command)[1].success?
  end

  def mode(file)
    File.lstat(file).mode & 0o777
  end

  # What 2.x left behind under root's umask: 0755 directories, 0644 files.
  before(:each) do
    old = File.umask(0o022)
    begin
      FileUtils.mkdir_p([File.join(repo, '.git', 'objects', 'ab'), File.join(path, 'bin')])
      File.write(File.join(repo, 'node_groups.json'), "[]\n")
      File.write(File.join(repo, '.git', 'objects', 'ab', 'cdef'), 'x')
      File.write(File.join(path, 'pe_nc_backup.log'), "log\n")
      File.write(File.join(path, 'pe_nc_backup.log.0'), "old log\n")
      File.write(File.join(path, 'bin', 'pe_nc_backup'), "#!/bin/sh\n")
      File.chmod(0o755, File.join(path, 'bin', 'pe_nc_backup'))
    ensure
      File.umask(old)
    end
  end

  it 'tightens the repo and logs once, then has nothing left to do' do
    expect(sh(exec[:onlyif])).to be(true)
    expect(sh(exec[:command])).to be(true)
    expect(mode(repo)).to eq(0o700)
    expect(mode(File.join(repo, '.git', 'objects', 'ab'))).to eq(0o700)
    expect(mode(File.join(repo, 'node_groups.json'))).to eq(0o600)
    expect(mode(File.join(repo, '.git', 'objects', 'ab', 'cdef'))).to eq(0o600)
    expect(mode(File.join(path, 'pe_nc_backup.log'))).to eq(0o600)
    expect(mode(File.join(path, 'pe_nc_backup.log.0'))).to eq(0o600)
    expect(sh(exec[:onlyif])).to be(false)
  end

  it 'leaves the script runnable' do
    sh(exec[:command])
    expect(mode(File.join(path, 'bin', 'pe_nc_backup'))).to eq(0o755)
  end

  it 'runs again if only a log file is readable' do
    sh(exec[:command])
    File.chmod(0o644, File.join(path, 'pe_nc_backup.log'))
    expect(sh(exec[:onlyif])).to be(true)
  end
end
