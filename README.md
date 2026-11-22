# pe_nc_backup

[![CI](https://github.com/jessereynolds/puppet-pe_nc_backup/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/jessereynolds/puppet-pe_nc_backup/actions/workflows/ci.yml)

## Table of Contents

1. [Description](#description)
2. [Setup](#setup)
    * [Setup requirements](#setup-requirements)
    * [Beginning with pe_nc_backup](#beginning-with-pe_nc_backup)
3. [Usage](#usage)
    * [Scheduling with systemd](#scheduling-with-systemd)
    * [Reducing noise](#reducing-noise)
    * [One file per group](#one-file-per-group)
    * [Restoring a backup](#restoring-a-backup)
4. [Reference](#reference)
5. [Limitations](#limitations)
6. [Development](#development)

## Description

This module records changes to your Puppet Enterprise node classification over time. On a schedule, it fetches every node group from the node classifier API and commits any change to a local git repo, so you can see what changed and when, and restore an earlier state.

The groups are written as prettified JSON in the same shape `ncio backup` produced, so `ncio restore` works on backups taken by this and earlier releases.

## Setup

### Setup Requirements

* git must be installed on the PE primary server running `pe_nc_backup`
* the backup runs as `pe-puppet` by default, which needs to read the primary's certificate and private key in `/etc/puppetlabs/puppet/ssl`

### Beginning with pe_nc_backup

Classify the PE primary server with:

```puppet
include pe_nc_backup
```

This installs the backup script in `/opt/pe_nc_backup/bin`, creates the git repo in `/opt/pe_nc_backup/repo`, and runs the backup from a cron job every five minutes. It logs to `/opt/pe_nc_backup/pe_nc_backup.log`.

## Usage

```puppet
class { 'pe_nc_backup':
  path        => '/opt/pe_nc_backup',
  cron_hour   => '*',
  cron_minute => '*/15',
}
```

If the primary's certname is not its FQDN, set `certname`. If the console services are not on the primary, point `classifier_host` (and `classifier_port` if needed) at them.

The script can also be run by hand, as the backup user:

```shell
sudo -u pe-puppet /opt/pe_nc_backup/bin/pe_nc_backup /opt/pe_nc_backup
```

It exits non-zero if anything fails, logs the reason to the log file and to stdout, and never commits a partial or empty backup.

### Scheduling with systemd

On hosts hardened to CIS benchmarks, cron is often limited to users in `cron.allow`. A systemd timer avoids that:

```puppet
class { 'pe_nc_backup':
  schedule_type => 'systemd',
  on_calendar   => '*:0/5',
}
```

This installs `pe_nc_backup.service` and `pe_nc_backup.timer` and removes the cron job. Setting `schedule_type` back to `cron` disables the timer and removes the units. The script's stdout goes to the journal, so `journalctl -u pe_nc_backup` shows each run.

### Reducing noise

Every edit in the console bumps a group's `serial_number` and `last_edited`, and some groups change often for reasons you may not care about. Two parameters keep that out of the history:

```puppet
class { 'pe_nc_backup':
  strip_fields   => ['serial_number', 'last_edited'],
  exclude_groups => ['^PE Patch Management'],
}
```

`exclude_groups` takes regular expressions in Ruby syntax, matched against group names. `exclude_environments` does the same against each group's environment, which suits the short-lived groups CD4PE rolling deployments create:

```puppet
class { 'pe_nc_backup':
  exclude_environments => ['^rolling_deployment_'],
}
```

Leaving out a group that other groups inherit from means the backup can no longer be restored as a whole hierarchy.

Groups are always written sorted by id, with every object's keys sorted, so the same data produces the same file and no commit. The first run after upgrading to 3.0.0 may commit once to reorder the existing file.

### One file per group

```puppet
class { 'pe_nc_backup':
  split_files => true,
}
```

This writes each group to `groups/<name>-<id>.json` instead of a single `node_groups.json`, so `git log` shows which groups changed. Files for groups that no longer exist are removed. Whichever layout is in use, the commit message lists the groups added, changed, and removed.

### Restoring a backup

`ncio restore` posts a backup to the classifier's import-hierarchy endpoint, which replaces every node group. Set `manage_ncio => true` to have the module install the gem. Then, as root on the primary:

```shell
CERTNAME=$(puppet config print certname)
SSLDIR=/etc/puppetlabs/puppet/ssl
/opt/puppetlabs/puppet/bin/ncio --uri "https://${CERTNAME}:4433/classifier-api/v1" \
  --cert "${SSLDIR}/certs/${CERTNAME}.pem" --key "${SSLDIR}/private_keys/${CERTNAME}.pem" \
  restore --file /opt/pe_nc_backup/repo/node_groups.json
```

With `split_files`, join the files back into one array first:

```shell
jq -s . /opt/pe_nc_backup/repo/groups/*.json > /tmp/node_groups.json
```

A backup taken with `exclude_groups` or `strip_fields` leaves things out, so check it is complete enough before restoring from it.

## Reference

See [REFERENCE.md](REFERENCE.md).

## Limitations

Tested on PE 2019.8.z, PE 2021.7.z, and PE 2023.2. The unit and end-to-end tests run on Puppet 7, 8, and 9.

## Development

Contributions welcome!

* Fork it
* make a PR from a feature branch
* include tests if you can

Executing the tests:

```shell
bundle install
bundle exec rake syntax lint metadata_lint rubocop
bundle exec rake spec
```

`rake spec` runs the class specs, unit tests for the backup script in `files/pe_nc_backup.rb`, and an end-to-end test that renders the script through Puppet and runs it against a fake classifier over HTTPS into a real git repo. Set `E2E_VERBOSE=1` to see each run's output, and `E2E_RUBY` to run the script under a different Ruby.

Set `PUPPET_GEM_VERSION` to test against a particular Puppet release. Puppet 8.11 and later, including Puppet 9, are only published to the authenticated puppetcore gem source, so those need `PUPPET_FORGE_TOKEN` set. The GitHub Actions workflow skips its Puppet 9 job when that secret is missing.

## Release

```shell
git commit
git tag x.y.z
git push --tags
pdk build
pdk release publish
```

Look for the new version on the [Forge page](https://forge.puppet.com/jesse/pe_nc_backup).
