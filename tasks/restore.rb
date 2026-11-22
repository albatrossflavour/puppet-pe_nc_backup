#!/opt/puppetlabs/puppet/bin/ruby
# frozen_string_literal: true

# pe_nc_backup::restore. The logic is in files/pe_nc_backup.rb, shared with the
# backup script, which the task runner puts under _installdir.
require 'json'

params = JSON.parse($stdin.read)
require File.join(params.fetch('_installdir'), 'pe_nc_backup', 'files', 'pe_nc_backup.rb')
exit PeNcBackup::RestoreTask.main(params)
