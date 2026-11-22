# frozen_string_literal: true

# Backs up the Puppet Enterprise node classifier's groups to a local git repo.
#
# This file is inlined into the pe_nc_backup script by templates/pe_nc_backup.epp,
# which then calls PeNcBackup.main with the settings from the pe_nc_backup class.
# Keeping the logic here lets the specs load and test it directly.

require 'English'
require 'etc'
require 'fileutils'
require 'json'
require 'logger'
require 'net/http'
require 'open3'
require 'openssl'
require 'time'

# Backs up the PE node classifier to git.
module PeNcBackup
  # A failure that stops the backup. The message is logged and the script exits 1.
  class Error < StandardError; end

  BACKUP_FILE = 'node_groups.json'
  GROUPS_DIR = 'groups'
  # Names listed per heading in a commit message before the rest are counted.
  MAX_NAMES = 50

  # Sends every message to all of the configured loggers.
  class Log
    SEVERITIES = {
      debug: Logger::DEBUG,
      info: Logger::INFO,
      warn: Logger::WARN,
      error: Logger::ERROR,
      fatal: Logger::FATAL,
    }.freeze

    def initialize(loggers)
      @loggers = loggers
    end

    SEVERITIES.each do |name, level|
      define_method(name) do |message|
        @loggers.each { |logger| logger.add(level, message) }
      end
    end
  end

  # Talks to the node classifier API: fetching every group, and importing a hierarchy for a restore.
  class Classifier
    attr_reader :uri

    # timeout bounds connecting, and reading unless read_timeout is given.
    def initialize(host:, port:, cert:, key:, ca:, timeout:, read_timeout: nil)
      @uri = URI::HTTPS.build(host: host, port: port, path: '/classifier-api/v1/groups', query: 'inherited=false')
      @import_uri = URI::HTTPS.build(host: host, port: port, path: '/classifier-api/v1/import-hierarchy')
      @cert = cert
      @key = key
      @ca = ca
      @timeout = timeout
      @read_timeout = read_timeout || timeout
    end

    # @return [Array<Hash>] the node groups, in the order the API returned them
    def groups
      response = send_request(Net::HTTP::Get.new(@uri, 'Accept' => 'application/json'), @uri)
      raise Error, failure('GET', @uri, response, body: true) unless response.code == '200'

      parse(response.body)
    end

    # Replaces the entire node group hierarchy. Sent once and never retried.
    def import(groups)
      request = Net::HTTP::Post.new(@import_uri, 'Content-Type' => 'application/json', 'Accept' => 'application/json')
      request.body = JSON.generate(groups)
      response = send_request(request, @import_uri)
      # PE echoes the submitted groups in some errors, so only kind and msg are reported.
      raise Error, failure('POST', @import_uri, response, body: false) unless response.code == '204'

      true
    end

    private

    def send_request(request, uri)
      http.request(request)
    rescue Net::OpenTimeout => e
      raise Error, "#{request.method} #{uri} timed out connecting after #{@timeout} seconds (#{e.class})"
    rescue Net::ReadTimeout, Net::WriteTimeout => e
      raise Error, "#{request.method} #{uri} timed out waiting for a response after #{@read_timeout} seconds (#{e.class})"
    rescue OpenSSL::OpenSSLError, SystemCallError, SocketError, IOError => e
      raise Error, "#{request.method} #{uri} failed: #{e.class}: #{e.message}"
    end

    # PE errors are JSON with a kind and msg. Anything else is shown only when body is true.
    def failure(method, uri, response, body:)
      message = "#{method} #{uri} returned HTTP #{response.code}"
      error = JSON.parse(response.body.to_s)
      return "#{message}: #{error['kind']}: #{error['msg']}" if error.is_a?(Hash) && (error['kind'] || error['msg'])

      body ? "#{message}: #{response.body.to_s[0, 500]}" : message
    rescue JSON::ParserError
      body ? "#{message}: #{response.body.to_s[0, 500]}" : message
    end

    def http
      http = Net::HTTP.new(@uri.host, @uri.port)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.verify_hostname = true if http.respond_to?(:verify_hostname=)
      http.max_retries = 0
      http.cert_store = ca_store
      http.cert = OpenSSL::X509::Certificate.new(File.read(@cert))
      http.key = OpenSSL::PKey.read(File.read(@key))
      http.open_timeout = @timeout
      http.read_timeout = @read_timeout
      http.write_timeout = @read_timeout if http.respond_to?(:write_timeout=)
      http
    end

    # Trusts the Puppet CA and nothing else. A store of our own also keeps the
    # CA out of OpenSSL's shared default store, which Puppet's SSLContext patch
    # would otherwise add it to when this runs in the same process as Puppet.
    def ca_store
      store = OpenSSL::X509::Store.new
      store.add_file(@ca)
      store
    end

    def parse(body)
      groups = JSON.parse(body)
      unless groups.is_a?(Array) && !groups.empty? && groups.all? { |g| g.is_a?(Hash) }
        raise Error, "GET #{@uri} did not return a non-empty JSON array of node groups"
      end

      groups
    rescue JSON::ParserError => e
      raise Error, "GET #{@uri} returned invalid JSON: #{e.message}"
    end
  end

  # Drops excluded groups and stripped fields, then sorts the groups by id and
  # every hash by key, so unchanged data always serialises to the same bytes.
  # Arrays keep their order, since order matters in a rule.
  class Filter
    def initialize(exclude_groups: [], exclude_environments: [], strip_fields: [])
      @exclude = { 'name' => compile(exclude_groups, 'exclude_groups'), 'environment' => compile(exclude_environments, 'exclude_environments') }
      @strip = strip_fields
    end

    def apply(groups)
      kept = groups.reject { |group| excluded?(group) }
      raise Error, "exclude_groups and exclude_environments matched all #{groups.size} node groups, refusing to write an empty backup" if kept.empty?

      kept.map { |group| normalise(group) }.sort_by { |group| [group['id'].to_s, group['name'].to_s] }
    end

    # Strips and sorts one group, without excluding anything.
    def normalise(group)
      sort_keys(group.reject { |key, _| @strip.include?(key) })
    end

    private

    def compile(patterns, setting)
      patterns.map { |pattern| Regexp.new(pattern) }
    rescue RegexpError => e
      raise Error, "Invalid #{setting} pattern: #{e.message}"
    end

    # Excluded when the group's name matches an exclude_groups pattern or its
    # environment matches an exclude_environments pattern.
    def excluded?(group)
      @exclude.any? { |field, patterns| patterns.any? { |re| re.match?(group[field].to_s) } }
    end

    def sort_keys(value)
      case value
      when Hash then value.keys.sort.to_h { |key| [key, sort_keys(value[key])] }
      when Array then value.map { |item| sort_keys(item) }
      else value
      end
    end
  end

  # Runs git in the backup repo without going through a shell.
  class Repo
    attr_reader :dir

    def initialize(dir)
      @dir = dir
    end

    # True only when dir is the top level of a git work tree, so a plain
    # directory inside some other repo does not count.
    def git?
      out, status = git('rev-parse', '--show-toplevel')
      status.success? && File.realpath(out.strip) == File.realpath(@dir)
    rescue SystemCallError
      false
    end

    # Stages paths (including deletions) and commits them if anything changed.
    #
    # @return [Boolean] true if a commit was made, false if there was nothing to commit
    def commit(paths, message, identity_email)
      # git rejects a pathspec it knows nothing about, such as groups/ before split_files is first used.
      paths = paths.select { |path| File.exist?(File.join(@dir, path)) || !git('ls-files', '--', path).first.empty? }
      return false if paths.empty?

      out, status = git('add', '--all', '--', *paths)
      raise Error, "Unable to git add #{paths.join(' ')}: #{out.strip}" unless status.success?

      _, status = git('diff', '--cached', '--quiet', '--', *paths)
      return false if status.success?

      out, status = git(*identity(identity_email), 'commit', '--quiet', '--file=-', '--', *paths, stdin: message)
      raise Error, "Unable to make git commit: #{out.strip}" unless status.success?

      true
    end

    def git(*args, stdin: nil)
      Open3.capture2e('git', *args, chdir: @dir, stdin_data: stdin.to_s)
    end

    private

    # Commits as pe_nc_backup when the user running the backup has no git identity.
    def identity(email)
      out, status = git('config', 'user.email')
      return [] if status.success? && !out.strip.empty?

      ['-c', 'user.name=pe_nc_backup', '-c', "user.email=#{email}"]
    end
  end

  # One backup run: fetch the groups, write them to the repo, and commit.
  class Runner
    def initialize(config, log)
      @config = config
      @log = log
      @path = config['path']
      @repo = Repo.new(File.join(@path, 'repo'))
    end

    # @return [Integer] the exit code, 0 for success and 1 for any failure
    def run
      @log.info("pe_nc_backup started at #{Time.now}")
      with_lock { backup }
      0
    rescue Error => e
      @log.error(e.message)
      @log.error('Errors were encountered backing up the node classifier, nothing was committed')
      1
    end

    private

    # Keeps a backup run and a restore from working on the repo at the same time.
    def with_lock
      File.open(File.join(@path, '.pe_nc_backup.lock'), File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      end
    end

    def backup
      check_repo
      filter = Filter.new(exclude_groups: @config['exclude_groups'] || [], exclude_environments: @config['exclude_environments'] || [],
                          strip_fields: @config['strip_fields'] || [])
      certname = resolve_certname
      fetched = classifier(certname).groups
      groups = filter.apply(fetched)
      @log.info("Retrieved #{fetched.size} node groups, keeping #{groups.size}")
      previous = read_previous(filter)
      write_backup(groups)
      commit(certname, changes(previous, groups))
      @log.info("Backup script complete at #{Time.now}")
    end

    def check_repo
      raise Error, "Backup repo directory does not exist at #{@repo.dir}" unless File.directory?(@repo.dir)
      raise Error, "This does not appear to be a git repo here at #{@repo.dir}" unless @repo.git?

      private_repo
    end

    # core.sharedRepository makes git write group or world readable objects
    # whatever the umask, so the backup turns it off.
    def private_repo
      out, status = @repo.git('config', '--local', 'core.sharedRepository')
      return unless status.success? && !['false', 'umask', '0'].include?(out.strip.downcase)

      @log.warn("Unsetting core.sharedRepository=#{out.strip} so the backup stays private")
      out, status = @repo.git('config', '--local', '--unset-all', 'core.sharedRepository')
      raise Error, "Unable to unset core.sharedRepository: #{out.strip}" unless status.success?
    end

    def resolve_certname
      certname = @config['certname'].to_s
      if certname.empty?
        out, status = Open3.capture2e(File.join(@config.fetch('puppet_bindir', '/opt/puppetlabs/puppet/bin'), 'puppet'), 'config', 'print', 'certname')
        raise Error, "Unable to determine the certname: #{out.strip}" unless status.success?

        certname = out.strip
      end
      @log.info("determined certname to be: #{certname}")
      certname
    rescue SystemCallError => e
      raise Error, "Unable to determine the certname: #{e.message}"
    end

    def classifier(certname, read_timeout: nil)
      ssl_dir = @config['ssl_dir']
      files = {
        cert: File.join(ssl_dir, 'certs', "#{certname}.pem"),
        key: File.join(ssl_dir, 'private_keys', "#{certname}.pem"),
        ca: File.join(ssl_dir, 'certs', 'ca.pem'),
      }
      files.each do |kind, file|
        raise Error, "#{kind} file not found at #{file}" unless File.file?(file)
      end

      host = @config['classifier_host'].to_s.empty? ? certname : @config['classifier_host']
      classifier = Classifier.new(host: host, port: Integer(@config.fetch('classifier_port', 4433)),
                                  timeout: Integer(@config.fetch('timeout', 60)), read_timeout: read_timeout, **files)
      @log.info("Fetching node groups from #{classifier.uri}")
      classifier
    end

    # Writes to a temporary file outside the repo and moves it into place, so
    # the repo never holds a partly written file.
    # The temporary file is created 0600 with O_EXCL, so it never follows or
    # replaces something already at that path, such as a planted symlink.
    def write_file(relative, content)
      target = File.join(@repo.dir, relative)
      FileUtils.mkdir_p(File.dirname(target))
      tmp = File.join(@path, ".#{File.basename(relative)}.#{Process.pid}.tmp")
      begin
        File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |f| f.write(content) }
      rescue Errno::EEXIST
        raise Error, "Temporary file #{tmp} already exists, refusing to write through it"
      end
      created = tmp
      FileUtils.mv(tmp, target)
    ensure
      FileUtils.rm_f(created) if created
    end

    # Writes node_groups.json, or one file per group under groups/ with
    # split_files, and removes whichever of the two layouts is not in use.
    def write_backup(groups)
      if @config['split_files']
        wanted = groups.to_h { |group| [split_name(group), group] }
        wanted.each { |name, group| write_file(File.join(GROUPS_DIR, name), "#{JSON.pretty_generate(group)}\n") }
        (split_files - wanted.keys.map { |name| File.join(@repo.dir, GROUPS_DIR, name) }).each { |file| File.delete(file) }
        FileUtils.rm_f(File.join(@repo.dir, BACKUP_FILE))
      else
        write_file(BACKUP_FILE, "#{JSON.pretty_generate(groups)}\n")
        split_files.each { |file| File.delete(file) }
      end
    end

    def split_files
      Dir.glob(File.join(@repo.dir, GROUPS_DIR, '*.json'))
    end

    # groups/<name>-<id>.json, with anything but letters, digits, dot, dash
    # and underscore in the name replaced. The id keeps names unique.
    def split_name(group)
      name = group['name'].to_s.gsub(%r{[^A-Za-z0-9._-]+}, '_').sub(%r{\A[._]+}, '')[0, 100]
      id = group['id'].to_s.gsub(%r{[^A-Za-z0-9._-]+}, '_')
      "#{name.empty? ? 'group' : name}-#{id}.json"
    end

    # The groups in the repo before this run, by id, normalised the same way
    # as the new ones. Unreadable files are skipped, as if the group were new.
    def read_previous(filter)
      files = [File.join(@repo.dir, BACKUP_FILE)] + split_files
      files.each_with_object({}) do |file, previous|
        next unless File.file?(file)

        data = JSON.parse(File.read(file))
        Array(data.is_a?(Hash) ? [data] : data).each do |group|
          previous[group['id']] = filter.normalise(group) if group.is_a?(Hash)
        end
      rescue JSON::ParserError
        next
      end
    end

    def changes(previous, groups)
      current = groups.to_h { |group| [group['id'], group] }
      {
        'Added' => (current.keys - previous.keys).map { |id| current[id]['name'] },
        'Changed' => (current.keys & previous.keys).reject { |id| current[id] == previous[id] }.map { |id| current[id]['name'] },
        'Removed' => (previous.keys - current.keys).map { |id| previous[id]['name'] },
      }
    end

    def commit(certname, changes, subject: nil)
      message = "#{subject || "Update node groups by pe_nc_backup on #{certname} at #{Time.now.iso8601}"}\n"
      body = changes.reject { |_, names| names.empty? }.map do |heading, names|
        names = names.map(&:to_s).sort
        more = (names.size > MAX_NAMES) ? " and #{names.size - MAX_NAMES} more" : ''
        "#{heading}: #{names.first(MAX_NAMES).join(', ')}#{more}\n"
      end
      message += "\n#{body.join}" unless body.empty?
      if @repo.commit([BACKUP_FILE, GROUPS_DIR], message, "pe_nc_backup@#{certname}")
        @log.info('Committed changes to the node groups')
      else
        @log.info('No changes to the node groups, nothing to commit')
      end
    end
  end

  ROOT_ID = '00000000-0000-4000-8000-000000000000'
  CONFIRM = 'replace-entire-classifier'
  # Set by the classifier, so ignored when comparing groups.
  SERVER_FIELDS = ['serial_number', 'last_edited', 'deleted'].freeze
  # The fields a restore cannot do without. serial_number and last_edited are
  # filled in from the live classifier when a backup was taken without them.
  REQUIRED_FIELDS = ['id', 'name', 'parent', 'environment', 'environment_trumps', 'classes', 'variables'].freeze

  # Restores the node classifier from a commit in the backup repo, through
  # POST /classifier-api/v1/import-hierarchy, which replaces every node group.
  # A dry run (the default) only reports what would change.
  class Restore < Runner
    # @return [Hash] what was done, for the task's output
    def restore
      with_lock { restore_locked }
    end

    private

    def restore_locked
      check_repo
      sha = resolve_commit(@config['commit'] || 'HEAD')
      backup = load_groups(sha)
      certname = resolve_certname
      api = classifier(certname, read_timeout: Integer(@config['read_timeout'] || 600))
      live = api.groups
      validate(backup, live)
      to_send = fill_server_fields(backup, live)
      result = { 'commit' => sha, 'backup_groups' => to_send.size, 'live_groups' => live.size, 'changes' => differences(to_send, live) }
      @log.info("Commit #{sha} holds #{to_send.size} node groups, the classifier has #{live.size}: #{summary(result['changes'])}")
      return result.merge('status' => 'dry-run', 'dry_run' => true) unless @config['dry_run'] == false

      unless @config['confirm'] == CONFIRM
        raise Error, "A restore replaces every node group. Set confirm to '#{CONFIRM}' as well as dry_run to false to go ahead"
      end

      result['pre_restore_commit'] = pre_restore_backup(live, certname, sha)
      begin
        @log.info("Importing #{to_send.size} node groups from #{sha}")
        api.import(to_send)
        check_restored(api.groups, to_send)
      rescue Error => e
        raise Error, "#{e.message}. The classifier as it was before this restore is in commit #{result['pre_restore_commit']}, " \
                     'which this task can restore'
      end
      result.merge('status' => 'restored', 'dry_run' => false)
    end

    def resolve_commit(commit)
      raise Error, "Invalid commit '#{commit}'" if commit.start_with?('-') || commit.match?(%r{[[:space:][:cntrl:]]})

      out, status = @repo.git('rev-parse', '--verify', '--quiet', '--end-of-options', "#{commit}^{commit}")
      raise Error, "No commit '#{commit}' in #{@repo.dir}" unless status.success?

      out.strip
    end

    # Rebuilds the groups array from either layout in the commit.
    def load_groups(sha)
      out, status = @repo.git('ls-tree', '-r', '--name-only', sha, '--', BACKUP_FILE, GROUPS_DIR)
      raise Error, "Unable to read commit #{sha}: #{out.strip}" unless status.success?

      files = out.lines.map(&:strip)
      if files.include?(BACKUP_FILE)
        groups = read_json(sha, BACKUP_FILE)
        raise Error, "#{BACKUP_FILE} in #{sha} is not a non-empty JSON array of node groups" unless groups.is_a?(Array) && !groups.empty?

        groups
      else
        split = files.grep(%r{\A#{GROUPS_DIR}/[^/]+\.json\z}o)
        raise Error, "Commit #{sha} holds no node group backup" if split.empty?

        split.map { |file| read_json(sha, file) }
      end
    end

    def read_json(sha, file)
      out, status = @repo.git('show', "#{sha}:#{file}")
      raise Error, "Unable to read #{file} from #{sha}" unless status.success?

      JSON.parse(out)
    rescue JSON::ParserError => e
      raise Error, "#{file} in #{sha} is not valid JSON: #{e.message}"
    end

    def validate(groups, live)
      bad = groups.reject { |group| group.is_a?(Hash) }
      raise Error, "The backup has #{bad.size} entries that are not node group objects" unless bad.empty?

      groups.each do |group|
        missing = REQUIRED_FIELDS.reject { |field| group.key?(field) }
        raise Error, "Node group #{group['name'] || group['id'] || '(unnamed)'} is missing #{missing.join(', ')}" unless missing.empty?
      end
      validate_hierarchy(groups)
      validate_count(groups.size, live.size)
    end

    def validate_hierarchy(groups)
      by_id = groups.group_by { |group| group['id'] }
      dupes = by_id.select { |_, list| list.size > 1 }.keys
      raise Error, "Node group ids appear more than once: #{dupes.join(', ')}" unless dupes.empty?

      roots = groups.select { |group| group['id'] == group['parent'] }
      unless roots.size == 1 && roots.first['id'] == ROOT_ID
        raise Error, "The backup must have exactly one root group, All Nodes (#{ROOT_ID}) as its own parent, found #{roots.map { |g| g['name'] }.inspect}"
      end

      orphans = groups.reject { |group| by_id.key?(group['parent']) }
      raise Error, "Node groups have a parent that is not in the backup: #{orphans.map { |g| g['name'] }.join(', ')}" unless orphans.empty?

      groups.each do |group|
        seen = []
        node = group
        until node['id'] == ROOT_ID
          raise Error, "Node group #{group['name']} is in an inheritance cycle" if seen.include?(node['id'])

          seen << node['id']
          node = by_id[node['parent']].first
        end
      end
    end

    def validate_count(count, live_count)
      allowed = Integer(@config['max_count_drop'] || 10)
      return if @config['force'] || live_count.zero? || count >= live_count * (100 - allowed) / 100.0

      drop = ((live_count - count) * 100.0 / live_count).round(1)
      raise Error, "The backup has #{count} node groups and the classifier has #{live_count}, a drop of #{drop}% " \
                   "is more than max_count_drop (#{allowed}%). Set force to restore anyway"
    end

    # The 2016.1 import-hierarchy docs say every field must be given and none
    # are defaulted, so fields a backup stripped are taken from the live group,
    # or set as a new group's would be.
    def fill_server_fields(groups, live)
      live_by_id = live.to_h { |group| [group['id'], group] }
      now = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S.%LZ')
      groups.map do |group|
        current = live_by_id[group['id']] || {}
        group.merge('serial_number' => group.fetch('serial_number') { current.fetch('serial_number', 1) },
                    'last_edited' => group.fetch('last_edited') { current.fetch('last_edited', now) })
      end
    end

    def comparable(groups)
      groups.to_h { |group| [group['id'], group.reject { |key, _| SERVER_FIELDS.include?(key) }] }
    end

    def differences(wanted, current)
      wanted = comparable(wanted)
      current = comparable(current)
      {
        'added' => (wanted.keys - current.keys).map { |id| wanted[id]['name'] }.sort,
        'removed' => (current.keys - wanted.keys).map { |id| current[id]['name'] }.sort,
        'changed' => (wanted.keys & current.keys).reject { |id| wanted[id] == current[id] }.map { |id| wanted[id]['name'] }.sort,
      }
    end

    def summary(changes)
      parts = changes.reject { |_, names| names.empty? }.map { |kind, names| "#{kind} #{names.join(', ')}" }
      parts.empty? ? 'no differences' : parts.join('; ')
    end

    # Commits the live classifier, unfiltered, in the repo's current layout.
    def pre_restore_backup(live, certname, sha)
      @config = @config.merge('split_files' => !File.exist?(File.join(@repo.dir, BACKUP_FILE)) && !split_files.empty?)
      filter = Filter.new
      groups = filter.apply(live)
      previous = read_previous(filter)
      write_backup(groups)
      commit(certname, changes(previous, groups),
             subject: "Pre-restore backup by pe_nc_backup::restore on #{certname} at #{Time.now.iso8601}, before restoring #{sha[0, 12]}")
      out, status = @repo.git('rev-parse', 'HEAD')
      raise Error, "Unable to find the pre-restore backup commit: #{out.strip}" unless status.success?

      @log.info("Saved the classifier as it was in commit #{out.strip}")
      out.strip
    end

    def check_restored(after, sent)
      changes = differences(sent, after)
      return if changes.values.all?(&:empty?)

      raise Error, "The import was accepted but the classifier does not match the backup: #{summary(changes)}"
    end
  end

  # The pe_nc_backup::restore task: params in, a JSON result or error out.
  module RestoreTask
    DEFAULTS = { 'path' => '/opt/pe_nc_backup', 'ssl_dir' => '/etc/puppetlabs/puppet/ssl', 'classifier_port' => 4433, 'timeout' => 60 }.freeze

    def self.main(params, out = $stdout, err = $stderr)
      old_umask = File.umask(0o077)
      config = DEFAULTS.merge(params.reject { |key, value| key.start_with?('_') || value.nil? })
      drop_privileges(config['path'])
      log = Log.new([Logger.new(err)])
      out.puts JSON.pretty_generate(Restore.new(config, log).restore)
      0
    rescue Error, SystemCallError => e
      out.puts JSON.pretty_generate('_error' => { 'kind' => 'pe_nc_backup/restore-failed', 'msg' => e.message, 'details' => {} })
      1
    rescue StandardError => e
      out.puts JSON.pretty_generate('_error' => { 'kind' => 'pe_nc_backup/restore-failed', 'msg' => "Unexpected error: #{e.class}: #{e.message}", 'details' => {} })
      1
    ensure
      File.umask(old_umask) if old_umask
    end

    # Tasks run as root, but the repo belongs to the backup user, and a commit
    # made as root would leave objects the backup can no longer write to.
    def self.drop_privileges(path)
      return unless Process.uid.zero?

      owner = File.stat(path)
      return if owner.uid.zero?

      Process::GID.change_privilege(owner.gid)
      Process::UID.change_privilege(owner.uid)
      ENV['HOME'] = Etc.getpwuid(owner.uid).dir
    rescue Errno::ENOENT
      raise Error, "Directory does not exist at #{path}"
    end
  end

  # Builds the loggers from the config.
  def self.loggers(config)
    logger = Logger.new(File.join(config['path'], 'pe_nc_backup.log'), 10, 1_024_000)
    logger.level = config.fetch('log_level', 'info')
    loggers = [logger]
    if config.fetch('stdout_log', true)
      stdout = Logger.new($stdout)
      stdout.level = config.fetch('log_level_stdout', 'error')
      loggers << stdout
    end
    loggers
  end

  # Runs a backup and returns the exit code.
  # Node groups often hold secrets in class parameters, so everything the
  # backup creates (log, backup files, git objects) is private to its user.
  def self.main(config, loggers = nil)
    old_umask = File.umask(0o077)
    raise Error, "Directory does not exist at #{config['path']}" unless File.directory?(config['path'].to_s)

    log = Log.new(loggers || self.loggers(config))
    begin
      Runner.new(config, log).run
    rescue StandardError => e
      log.fatal("Unexpected error: #{e.class}: #{e.message}")
      1
    end
  rescue Error => e
    warn e.message
    1
  ensure
    File.umask(old_umask) if old_umask
  end
end
