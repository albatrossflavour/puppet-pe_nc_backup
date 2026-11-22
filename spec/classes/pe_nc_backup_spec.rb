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

        it { is_expected.to contain_exec('pe_nc_backup systemctl daemon-reload').with(command: 'systemctl daemon-reload', refreshonly: true) }

        it 'cleans up after systemd scheduling, only if it was used' do
          is_expected.to contain_exec('pe_nc_backup disable timer').with(
            command: 'systemctl disable --now pe_nc_backup.timer',
            onlyif: 'test -f /etc/systemd/system/pe_nc_backup.timer',
          )
          ['/etc/systemd/system/pe_nc_backup.service', '/etc/systemd/system/pe_nc_backup.timer'].each do |unit|
            is_expected.to contain_file(unit).with_ensure('absent')
                                             .that_requires('Exec[pe_nc_backup disable timer]')
                                             .that_notifies('Exec[pe_nc_backup systemctl daemon-reload]')
          end
        end

        it { is_expected.not_to contain_service('pe_nc_backup.timer') }

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
            'exclude_groups' => [],
            'strip_fields' => [],
            'split_files' => false,
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

      context 'with systemd scheduling' do
        let(:params) { { schedule_type: 'systemd' } }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_cron('pe_nc_backup').with(ensure: 'absent', user: 'pe-puppet') }
        it { is_expected.not_to contain_exec('pe_nc_backup disable timer') }

        it {
          is_expected.to contain_file('/etc/systemd/system/pe_nc_backup.service')
            .with(ensure: 'file', owner: 'root', group: 'root', mode: '0644')
            .that_notifies('Exec[pe_nc_backup systemctl daemon-reload]')
        }

        it {
          is_expected.to contain_file('/etc/systemd/system/pe_nc_backup.timer')
            .with(ensure: 'file', owner: 'root', group: 'root', mode: '0644')
            .that_notifies('Exec[pe_nc_backup systemctl daemon-reload]')
        }

        it 'runs the script as pe-puppet from a oneshot service' do
          content = catalogue.resource('File', '/etc/systemd/system/pe_nc_backup.service')[:content]
          expect(content).to include("Type=oneshot\n", "User=pe-puppet\n", "Group=pe-puppet\n", "ExecStart=/opt/pe_nc_backup/bin/pe_nc_backup /opt/pe_nc_backup\n")
        end

        it 'runs every five minutes by default, like the cron job' do
          content = catalogue.resource('File', '/etc/systemd/system/pe_nc_backup.timer')[:content]
          expect(content).to include("OnCalendar=*:0/5\n", "WantedBy=timers.target\n")
        end

        it {
          is_expected.to contain_service('pe_nc_backup.timer').with(ensure: 'running', enable: true)
                                                              .that_requires(['File[pe_nc_backup script]', 'Vcsrepo[/opt/pe_nc_backup/repo]', 'Exec[pe_nc_backup systemctl daemon-reload]'])
                                                              .that_subscribes_to(['File[/etc/systemd/system/pe_nc_backup.service]', 'File[/etc/systemd/system/pe_nc_backup.timer]'])
        }
      end

      context 'with systemd scheduling, a custom calendar, user and path' do
        let(:params) { { schedule_type: 'systemd', on_calendar: 'hourly', user: 'ncbackup', group: 'ncbackup', path: '/srv/nc' } }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_file('/etc/systemd/system/pe_nc_backup.timer').with_content(%r{^OnCalendar=hourly$}) }
        it { is_expected.to contain_file('/etc/systemd/system/pe_nc_backup.service').with_content(%r{^User=ncbackup\nGroup=ncbackup\nExecStart=/srv/nc/bin/pe_nc_backup /srv/nc$}) }
        it { is_expected.to contain_file('/srv/nc').with(owner: 'ncbackup', group: 'ncbackup') }
        it { is_expected.to contain_vcsrepo('/srv/nc/repo').with_user('ncbackup') }
        it { is_expected.to contain_cron('pe_nc_backup').with(ensure: 'absent', user: 'ncbackup') }
      end

      context 'with cron scheduling and a custom user' do
        let(:params) { { user: 'ncbackup', group: 'wheel' } }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_cron('pe_nc_backup').with(ensure: nil, user: 'ncbackup', minute: '*/5') }
        it { is_expected.to contain_file('/opt/pe_nc_backup').with(owner: 'ncbackup', group: 'wheel') }
        it { is_expected.to contain_file('pe_nc_backup script').with(owner: 'ncbackup', group: 'wheel', mode: '0755') }
        it { is_expected.to contain_vcsrepo('/opt/pe_nc_backup/repo').with_user('ncbackup') }
      end

      context 'with cron settings while scheduling with systemd' do
        let(:params) { { schedule_type: 'systemd', cron_hour: '3', cron_minute: '0' } }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_cron('pe_nc_backup').with(ensure: 'absent', hour: nil, minute: nil) }
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

      context 'with noise controls' do
        let(:params) { { exclude_groups: ['^PE ', 'Test$'], strip_fields: ['serial_number', 'last_edited'] } }

        it { is_expected.to compile.with_all_deps }

        it 'bakes the patterns and fields into the script unchanged' do
          expect(script_config(catalogue)).to include('exclude_groups' => ['^PE ', 'Test$'], 'strip_fields' => ['serial_number', 'last_edited'])
        end

        it 'renders a script that is valid Ruby' do
          expect(RubyVM::InstructionSequence.compile(catalogue.resource('File', 'pe_nc_backup script')[:content])).to be_truthy
        end
      end

      context 'with a pattern containing quotes and a heredoc terminator' do
        let(:params) { { exclude_groups: ["it's \"quoted\"\nCONFIG\n\\d+"] } }

        it 'survives the trip into the script' do
          expect(script_config(catalogue)['exclude_groups']).to eq(["it's \"quoted\"\nCONFIG\n\\d+"])
        end
      end

      context 'with split_files' do
        let(:params) { { split_files: true } }

        it { is_expected.to compile.with_all_deps }
        it { expect(script_config(catalogue)).to include('split_files' => true) }
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
          { schedule_type: 'anacron' },
          { on_calendar: '' },
          { user: '' },
          { exclude_groups: 'PE' },
          { strip_fields: [''] },
          { split_files: 'true' },
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
