# frozen_string_literal: true

require 'spec_helper'
require 'json'

# Pulls the settings Puppet baked into the backup script back out of it.
def script_config(catalogue)
  content = catalogue.resource('File', 'pe_nc_backup script')[:content]
  JSON.parse(content[%r{<<~'CONFIG'\)\n(.*?)\nCONFIG\n}m, 1])
end

describe 'pe_nc_backup' do
  on_supported_os.each do |os, os_facts|
    context "on #{os}" do
      let(:facts) { os_facts }
      let(:node) { 'primary.example.com' }

      context 'with defaults' do
        it { is_expected.to compile.with_all_deps }

        it { is_expected.to contain_file('/opt/pe_nc_backup').with(ensure: 'directory', owner: 'pe-puppet', group: 'pe-puppet') }
        it { is_expected.to contain_file('/opt/pe_nc_backup/bin').with(ensure: 'directory', owner: 'pe-puppet', group: 'pe-puppet') }

        it {
          is_expected.to contain_file('pe_nc_backup script').with(
            ensure: 'file',
            path: '/opt/pe_nc_backup/bin/pe_nc_backup',
            owner: 'pe-puppet',
            group: 'pe-puppet',
            mode: '0755',
          )
        }

        it { is_expected.to contain_file('pe_nc_backup script').with_content(%r{\A#!/opt/puppetlabs/puppet/bin/ruby\n}) }
        it { is_expected.to contain_file('pe_nc_backup script').with_content(%r{^module PeNcBackup$}) }
        it { is_expected.to contain_file('pe_nc_backup script').with_content(%r{^exit PeNcBackup.main\(config\)$}) }
        it { is_expected.to contain_file('pe_nc_backup script').without_content(%r{bin/ncio|ncio --uri}) }

        it { is_expected.to contain_vcsrepo('/opt/pe_nc_backup/repo').with(ensure: 'present', provider: 'git', user: 'pe-puppet').that_requires('File[/opt/pe_nc_backup]') }

        it { is_expected.not_to contain_package('ncio') }

        it {
          is_expected.to contain_cron('pe_nc_backup').with(
            command: '/opt/pe_nc_backup/bin/pe_nc_backup /opt/pe_nc_backup',
            user: 'pe-puppet',
            hour: '*',
            minute: '*/5',
          ).that_requires(['File[pe_nc_backup script]', 'Vcsrepo[/opt/pe_nc_backup/repo]'])
        }

        it 'bakes the default settings into the script' do
          expect(script_config(catalogue)).to include(
            'path' => '/opt/pe_nc_backup',
            'certname' => 'primary.example.com',
            'ssl_dir' => '/etc/puppetlabs/puppet/ssl',
            'classifier_host' => nil,
            'classifier_port' => 4433,
            'timeout' => 60,
            'log_level' => 'info',
            'log_level_stdout' => 'error',
            'stdout_log' => true,
          )
        end

        it 'renders a script that is valid Ruby' do
          content = catalogue.resource('File', 'pe_nc_backup script')[:content]
          expect(RubyVM::InstructionSequence.compile(content)).to be_truthy
        end
      end

      context 'with a custom path, ssl_dir and logging' do
        let(:params) do
          {
            path: '/srv/ncbackup',
            ssl_dir: '/etc/puppetlabs/puppet/ssl-other',
            log_level: 'debug',
            log_level_stdout: 'warn',
            stdout_log: false,
            cron_hour: '2',
            cron_minute: '15',
          }
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_file('pe_nc_backup script').with_path('/srv/ncbackup/bin/pe_nc_backup') }
        it { is_expected.to contain_vcsrepo('/srv/ncbackup/repo') }
        it { is_expected.to contain_cron('pe_nc_backup').with(command: '/srv/ncbackup/bin/pe_nc_backup /srv/ncbackup', hour: '2', minute: '15') }

        it 'bakes the settings into the script' do
          expect(script_config(catalogue)).to include(
            'path' => '/srv/ncbackup',
            'ssl_dir' => '/etc/puppetlabs/puppet/ssl-other',
            'log_level' => 'debug',
            'log_level_stdout' => 'warn',
            'stdout_log' => false,
          )
        end
      end

      context 'with a remote classifier' do
        let(:params) { { classifier_host: 'console.example.com', classifier_port: 8443, classifier_timeout: 10 } }

        it { is_expected.to compile.with_all_deps }

        it 'bakes the classifier settings into the script' do
          expect(script_config(catalogue)).to include('classifier_host' => 'console.example.com', 'classifier_port' => 8443, 'timeout' => 10)
        end
      end

      context 'with a certname that differs from the node name' do
        let(:params) { { certname: 'puppet.internal.example.com' } }

        it { is_expected.to compile.with_all_deps }

        it 'bakes the certname into the script' do
          expect(script_config(catalogue)).to include('certname' => 'puppet.internal.example.com')
        end
      end

      context 'with manage_ncio' do
        let(:params) { { manage_ncio: true } }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_package('ncio').with(ensure: 'installed', provider: 'puppet_gem') }
      end

      context 'with invalid parameters' do
        [
          { classifier_port: 0 },
          { classifier_port: 70_000 },
          { classifier_host: 'not a host' },
          { classifier_timeout: 0 },
          { manage_ncio: 'yes' },
          { certname: '' },
          { log_level: 'verbose' },
        ].each do |bad|
          context "with #{bad}" do
            let(:params) { bad }

            it { is_expected.to compile.and_raise_error(%r{parameter '#{bad.keys.first}'}) }
          end
        end
      end
    end
  end
end
