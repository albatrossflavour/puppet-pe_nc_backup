# Changelog

All notable changes to this project will be documented in this file.

## Release 3.0.0

**Breaking**

- Requires Puppet 7, 8, or 9, puppetlabs-stdlib 9 or 10, and puppetlabs-vcsrepo 6, 7, or 8. Supported platforms are now RHEL 8 and 9 and Ubuntu 22.04 and 24.04
- The backup no longer uses the ncio gem, and the module no longer installs it. Set `manage_ncio => true` to keep it for `ncio restore`
- Groups are written sorted by id with sorted keys, so the first run after upgrading may commit once to reorder the existing backup
- The script now fails, writing nothing, if the repo directory is missing or is not the top of a git repo

**Features**

- The node groups are fetched directly over HTTPS with the host's certificate, trusting only the Puppet CA, with a timeout (`classifier_timeout`)
- `classifier_host` and `classifier_port` for installs where the console services are not on the primary
- `certname` for primaries whose certname is not their FQDN (#10)
- `schedule_type => 'systemd'` runs the backup from a systemd timer (`on_calendar`) instead of cron, which avoids needing a `cron.allow` entry on hardened hosts and works on hosts with no cron installed
- `user` and `group` set who owns and runs the backup
- `manage_git` installs git before the repo is created
- `exclude_groups`, `exclude_environments`, and `strip_fields` keep groups and fields you do not care about out of the history
- `split_files` writes one file per group under `groups/`
- Commit messages list the groups added, changed, and removed
- Commits as `pe_nc_backup` when the backup user has no git identity
- CI moved to GitHub Actions

**Bugfixes**

- The script exits non-zero on any failure and logs errors to every logger, not just the log file
- A failed or partial fetch is never written to the repo or committed
- `$CHILD_STATUS` was used without requiring `English`

## Release 1.0.1

- Fix issue with ssldir determination introduced in 1.0.0
- Set new ssl_dir parameter to /etc/puppetlabs/puppet/ssl - may be overridden
- Now uses a template for the backup script so that ssl_dir can be passed in (Thanks @albatrossflavour!)

## Release 1.0.0

- Attempt to improve reliability of ssldir determination

## Release 0.1.1 2017-09-11

Actually tested on production now.

**Bugfixes**

- Creates the bin directory
- Handles initial commit of json file correctly
- Works in the correct directory

## Release 0.1.0 2017-09-11

**Features**

- Initial version

**Bugfixes**

**Known Issues**

