# pe_nc_backup
#
# Main entry point to pe_nc_backup
#
# @summary Creates backups of Puppet Enterprise's Node Classifier as json in a git repo.
#
# @example
#   include pe_nc_backup
#
# @param path path to directory to store the backup git repo, backup script, and log file.
#   The parent directory must already exist.
# @param ssl_dir The path to the Puppet Agent's ssl directory on the PE primary server.
# @param log_level The verbosity of the Ruby logger writing to the log file. Possible values: 'debug',
#   'info', 'warn', 'error', 'fatal'.
# @param log_level_stdout The verbosity of the Ruby logger writing to STDOUT. Possible values: 'debug',
#   'info', 'warn', 'error', 'fatal'.
# @param stdout_log Whether to enable the STDOUT logger.
# @param cron_hour The hour for the cron job. Only used when `schedule_type` is `cron`.
# @param cron_minute The minute for the cron job. Only used when `schedule_type` is `cron`.
# @param schedule_type How to run the backup: `cron` (the default, as in earlier releases) or `systemd`, which
#   installs a service and timer instead. The systemd timer avoids needing a cron.allow entry for the user on
#   hardened hosts. Switching type removes the other one.
# @param on_calendar When the systemd timer runs, as a systemd OnCalendar expression. Only used when
#   `schedule_type` is `systemd`. The default matches the cron default of every five minutes.
# @param user The user that owns the backup directory and runs the backup. It must be able to read the
#   host's certificate and private key under `ssl_dir`.
# @param group The group that owns the backup directory.
# @param exclude_groups Regular expressions (Ruby syntax) matched against each node group's name. Matching
#   groups are left out of the backup. Leaving out a group that others inherit from means the backup can no
#   longer be restored as a whole hierarchy.
# @param strip_fields Fields removed from every node group before it is written, for example
#   `['serial_number', 'last_edited']` to stop routine console activity producing commits.
# @param certname The certname of the PE primary server, which names the certificate and key the backup
#   authenticates with. Set this when the certname is not the node's own, for example when it differs from the FQDN.
# @param classifier_host The host serving the node classifier API. Defaults to the certname, which suits a
#   standard install where the console services run on the primary server.
# @param classifier_port The port of the node classifier API.
# @param classifier_timeout Seconds to wait when connecting to and reading from the node classifier API.
# @param manage_ncio Whether to install the ncio gem. The backup no longer uses it, but `ncio restore` is
#   still a convenient way to restore a backup.
#
class pe_nc_backup (
  String                                          $path               = '/opt/pe_nc_backup',
  String                                          $ssl_dir            = '/etc/puppetlabs/puppet/ssl',
  Enum['debug', 'info', 'warn', 'error', 'fatal'] $log_level          = 'info',
  Enum['debug', 'info', 'warn', 'error', 'fatal'] $log_level_stdout   = 'error',
  Boolean                                         $stdout_log         = true,
  String                                          $cron_hour          = '*',
  String                                          $cron_minute        = '*/5',
  Optional[Stdlib::Host]                          $classifier_host    = undef,
  Integer[1, 65535]                               $classifier_port    = 4433,
  Integer[1]                                      $classifier_timeout = 60,
  Boolean                                         $manage_ncio        = false,
  String[1]                                       $certname           = $trusted['certname'],
  Enum['cron', 'systemd']                         $schedule_type      = 'cron',
  String[1]                                       $on_calendar        = '*:0/5',
  String[1]                                       $user               = 'pe-puppet',
  String[1]                                       $group              = 'pe-puppet',
  Array[String[1]]                                $exclude_groups     = [],
  Array[String[1]]                                $strip_fields       = [],
) {
  $git_repo_dir = "${path}/repo"
  $bin_dir      = "${path}/bin"
  $command      = "${bin_dir}/pe_nc_backup ${path}"
  $service_file = '/etc/systemd/system/pe_nc_backup.service'
  $timer_file   = '/etc/systemd/system/pe_nc_backup.timer'

  file {
    default:
      owner => $user,
      group => $group,
      mode  => '0644',
    ;
    [$path, $bin_dir]:
      ensure => directory,
    ;
    'pe_nc_backup script':
      ensure  => file,
      path    => "${bin_dir}/pe_nc_backup",
      mode    => '0755',
      content => epp('pe_nc_backup/pe_nc_backup.epp', {
        config => {
          path             => $path,
          certname         => $certname,
          ssl_dir          => $ssl_dir,
          classifier_host  => $classifier_host,
          classifier_port  => $classifier_port,
          timeout          => $classifier_timeout,
          log_level        => $log_level,
          log_level_stdout => $log_level_stdout,
          stdout_log       => $stdout_log,
          exclude_groups   => $exclude_groups,
          strip_fields     => $strip_fields,
        },
      })
    ;
  }

  vcsrepo { $git_repo_dir:
    ensure   => present,
    provider => git,
    user     => $user,
    require  => File[$path],
  }

  if $manage_ncio {
    package { 'ncio':
      ensure   => installed,
      provider => puppet_gem,
    }
  }

  # Plain file resources and a daemon-reload exec keep the module free of a
  # puppet/systemd dependency for two unit files.
  exec { 'pe_nc_backup systemctl daemon-reload':
    command     => 'systemctl daemon-reload',
    path        => ['/usr/bin', '/bin'],
    refreshonly => true,
  }

  if $schedule_type == 'systemd' {
    file {
      default:
        ensure => file,
        owner  => 'root',
        group  => 'root',
        mode   => '0644',
        notify => Exec['pe_nc_backup systemctl daemon-reload'],
      ;
      $service_file:
        content => epp('pe_nc_backup/pe_nc_backup.service.epp', {
          user    => $user,
          group   => $group,
          command => $command,
        }),
      ;
      $timer_file:
        content => epp('pe_nc_backup/pe_nc_backup.timer.epp', {
          on_calendar => $on_calendar,
        }),
      ;
    }

    service { 'pe_nc_backup.timer':
      ensure    => running,
      enable    => true,
      require   => [File['pe_nc_backup script'], Vcsrepo[$git_repo_dir], Exec['pe_nc_backup systemctl daemon-reload']],
      subscribe => File[$service_file, $timer_file],
    }

    cron { 'pe_nc_backup':
      ensure => absent,
      user   => $user,
    }
  } else {
    cron { 'pe_nc_backup':
      command => $command,
      user    => $user,
      hour    => $cron_hour,
      minute  => $cron_minute,
      require => [File['pe_nc_backup script'], Vcsrepo[$git_repo_dir],],
    }

    # Only does anything when switching back from systemd.
    exec { 'pe_nc_backup disable timer':
      command => 'systemctl disable --now pe_nc_backup.timer',
      onlyif  => "test -f ${timer_file}",
      path    => ['/usr/bin', '/bin'],
    }

    file { [$service_file, $timer_file]:
      ensure  => absent,
      require => Exec['pe_nc_backup disable timer'],
      notify  => Exec['pe_nc_backup systemctl daemon-reload'],
    }
  }
}
