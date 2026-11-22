# frozen_string_literal: true

# Backs up the Puppet Enterprise node classifier's groups to a local git repo.
#
# This file is inlined into the pe_nc_backup script by templates/pe_nc_backup.epp,
# which then calls PeNcBackup.main with the settings from the pe_nc_backup class.
# Keeping the logic here lets the specs load and test it directly.

require 'English'
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

  # Fetches the node groups from the classifier API, the same request ncio backup made.
  class Classifier
    attr_reader :uri

    def initialize(host:, port:, cert:, key:, ca:, timeout:)
      @uri = URI::HTTPS.build(host: host, port: port, path: '/classifier-api/v1/groups', query: 'inherited=false')
      @cert = cert
      @key = key
      @ca = ca
      @timeout = timeout
    end

    # @return [Array<Hash>] the node groups, in the order the API returned them
    def groups
      response = http.request(Net::HTTP::Get.new(@uri, 'Accept' => 'application/json'))
      unless response.code == '200'
        raise Error, "GET #{@uri} returned HTTP #{response.code}: #{response.body.to_s[0, 500]}"
      end

      parse(response.body)
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      raise Error, "GET #{@uri} timed out after #{@timeout} seconds (#{e.class})"
    rescue OpenSSL::OpenSSLError, SystemCallError, SocketError, IOError => e
      raise Error, "GET #{@uri} failed: #{e.class}: #{e.message}"
    end

    private

    def http
      http = Net::HTTP.new(@uri.host, @uri.port)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.cert_store = ca_store
      http.cert = OpenSSL::X509::Certificate.new(File.read(@cert))
      http.key = OpenSSL::PKey.read(File.read(@key))
      http.open_timeout = @timeout
      http.read_timeout = @timeout
      http.write_timeout = @timeout if http.respond_to?(:write_timeout=)
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
      0
    rescue Error => e
      @log.error(e.message)
      @log.error('Errors were encountered backing up the node classifier, nothing was committed')
      1
    end

    private

    def check_repo
      raise Error, "Backup repo directory does not exist at #{@repo.dir}" unless File.directory?(@repo.dir)
      raise Error, "This does not appear to be a git repo here at #{@repo.dir}" unless @repo.git?
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

    def classifier(certname)
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
                                  timeout: Integer(@config.fetch('timeout', 60)), **files)
      @log.info("Fetching node groups from #{classifier.uri}")
      classifier
    end

    # Writes to a temporary file outside the repo and moves it into place, so
    # the repo never holds a partly written file.
    def write_file(relative, content)
      target = File.join(@repo.dir, relative)
      FileUtils.mkdir_p(File.dirname(target))
      tmp = File.join(@path, ".#{File.basename(relative)}.#{Process.pid}.tmp")
      File.write(tmp, content)
      FileUtils.mv(tmp, target)
    ensure
      FileUtils.rm_f(tmp) if tmp
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

    def commit(certname, changes)
      message = "Update node groups by pe_nc_backup on #{certname} at #{Time.now.iso8601}\n"
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
  def self.main(config, loggers = nil)
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
  end
end
