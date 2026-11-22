# frozen_string_literal: true

require 'spec_helper'
require 'json'

describe 'pe_nc_backup::restore task metadata' do
  let(:metadata) { JSON.parse(File.read(File.expand_path('../../tasks/restore.json', __dir__))) }

  it 'ships the shared library with the task' do
    expect(metadata['files']).to eq(['pe_nc_backup/files/pe_nc_backup.rb'])
    expect(File.exist?(File.expand_path('../../files/pe_nc_backup.rb', __dir__))).to be(true)
  end

  it 'warns that a restore replaces the whole hierarchy' do
    expect(metadata['description']).to include('REPLACES THE ENTIRE NODE GROUP HIERARCHY', 'dry run', 'replace-entire-classifier')
  end

  it 'gives every parameter a valid Puppet type and a description' do
    metadata['parameters'].each do |name, spec|
      expect(spec['description']).not_to be_empty, name
      expect { Puppet::Pops::Types::TypeParser.singleton.parse(spec['type']) }.not_to raise_error, name
    end
  end

  it 'has a parameter for every setting the restore reads' do
    expect(metadata['parameters'].keys).to include('commit', 'dry_run', 'confirm', 'force', 'max_count_drop', 'read_timeout')
  end
end
