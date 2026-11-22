# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'openssl'
require 'webrick'
require 'webrick/https'

# A local stand-in for the PE node classifier API, served over HTTPS by
# WEBrick. It builds its own CA, signs a server certificate for localhost and a
# client certificate for the given certname, and lays them out like a Puppet
# ssl directory. Client certificates are required, as they are on PE.
class FakeClassifier
  attr_reader :ssl_dir, :port, :requests
  attr_accessor :groups, :status, :body, :delay

  # ca names the CA key to sign with, so a test can build a second CA that the
  # first one does not trust.
  def initialize(dir, certname, ca: :default)
    @ca_name = ca
    @ssl_dir = File.join(dir, 'ssl')
    @certname = certname
    @groups = []
    @status = 200
    @body = nil
    @delay = 0
    @requests = []
    build_ssl
  end

  def start
    @server = WEBrick::HTTPServer.new(
      BindAddress: '127.0.0.1',
      Port: 0,
      SSLEnable: true,
      SSLCertificate: @server_cert,
      SSLPrivateKey: @server_key,
      SSLCertificateStore: store,
      SSLVerifyClient: OpenSSL::SSL::VERIFY_PEER | OpenSSL::SSL::VERIFY_FAIL_IF_NO_PEER_CERT,
      Logger: WEBrick::Log.new(File::NULL),
      AccessLog: [],
    )
    @port = @server.listeners.first.addr[1]
    @server.mount_proc('/classifier-api/v1/groups') { |req, res| respond(req, res) }
    @thread = Thread.new { @server.start }
    self
  end

  def stop
    @server&.shutdown
    @thread&.join(5)
  end

  # A minimal but realistic node group, shaped like the classifier API returns.
  def self.group(name, id, parent: '00000000-0000-4000-8000-000000000000', **extra)
    {
      'name' => name,
      'id' => id,
      'parent' => parent,
      'environment' => 'production',
      'environment_trumps' => false,
      'description' => "#{name} group",
      'rule' => ['and', ['=', ['trusted', 'extensions', 'pp_role'], name.downcase]],
      'variables' => {},
      'classes' => {},
      'config_data' => {},
      'serial_number' => 1,
      'last_edited' => '2026-11-22T00:00:00.000Z',
      'deleted' => {},
    }.merge(extra.transform_keys(&:to_s))
  end

  # RSA key generation dominates the run time, so each key is made once per process.
  def self.key(slot)
    @keys ||= {}
    @keys[slot] ||= OpenSSL::PKey::RSA.new(2048)
  end

  private

  def respond(req, res)
    @requests << { path: req.path, query: req.query_string, client_cn: client_cn(req) }
    sleep(@delay) if @delay.positive?
    res.status = @status
    res['Content-Type'] = 'application/json'
    res.body = @body || JSON.generate(@groups)
  end

  def client_cn(req)
    cert = req.client_cert
    cert && cert.subject.to_a.find { |k, _| k == 'CN' }&.at(1)
  end

  def store
    s = OpenSSL::X509::Store.new
    s.add_cert(@ca_cert)
    s
  end

  def build_ssl
    FileUtils.mkdir_p([File.join(@ssl_dir, 'certs'), File.join(@ssl_dir, 'private_keys')])
    ca_key = self.class.key([:ca, @ca_name])
    @ca_cert = sign('Fake Puppet CA', ca_key, ca_key, nil, ca: true)
    @server_key = self.class.key(:server)
    @server_cert = sign('localhost', @server_key, ca_key, @ca_cert, san: 'DNS:localhost,IP:127.0.0.1')
    client_key = self.class.key(:client)
    client_cert = sign(@certname, client_key, ca_key, @ca_cert)
    File.write(File.join(@ssl_dir, 'certs', 'ca.pem'), @ca_cert.to_pem)
    File.write(File.join(@ssl_dir, 'certs', "#{@certname}.pem"), client_cert.to_pem)
    File.write(File.join(@ssl_dir, 'private_keys', "#{@certname}.pem"), client_key.to_pem)
  end

  def sign(cn, key, ca_key, ca_cert, ca: false, san: nil)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = rand(2**64)
    cert.subject = OpenSSL::X509::Name.parse("/CN=#{cn}")
    cert.issuer = ca_cert ? ca_cert.subject : cert.subject
    cert.public_key = key.public_key
    cert.not_before = Time.now - 60
    cert.not_after = Time.now + 3600
    ext = OpenSSL::X509::ExtensionFactory.new
    ext.subject_certificate = cert
    ext.issuer_certificate = ca_cert || cert
    cert.add_extension(ext.create_extension('basicConstraints', ca ? 'CA:TRUE' : 'CA:FALSE', true))
    cert.add_extension(ext.create_extension('keyUsage', ca ? 'keyCertSign,cRLSign' : 'digitalSignature,keyEncipherment', true))
    cert.add_extension(ext.create_extension('subjectKeyIdentifier', 'hash'))
    cert.add_extension(ext.create_extension('subjectAltName', san)) if san
    cert.sign(ca_key, OpenSSL::Digest.new('SHA256'))
    cert
  end
end
