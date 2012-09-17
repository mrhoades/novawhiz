require 'openstack'
require 'net/ssh/simple'
class NovaWhiz

  attr_accessor :os

  def initialize(opts)
    @os = OpenStack::Connection.create(
      :username => opts[:username],
      :api_key => opts[:password],
      :authtenant => opts[:authtenant],
      :auth_url => opts[:auth_url],
      :service_type => "compute")
  end

  def flavor_id(name)
    flavors = @os.flavors.select { |f| f[:name] == name }
    raise "ambiguous/unknown flavor: #{name}" unless flavors.length == 1
    flavors.first[:id]
  end

  def image_id(reg)
    images = @os.images.select { |i| i[:name] =~ reg }
    raise "ambiguous/unknown image: #{reg} : #{images.inspect}" unless images.length == 1
    images.first[:id]
  end

  def new_key(name)
    key = @os.create_keypair :name => name
    key[:private_key]
  end

  def public_ip(server)
    server.accessipv4
  end

  def wait(timeout, interval=10)
    while timeout > 0 do
      return if yield
      sleep interval
      timeout -= interval
    end
  end

  def server_by_name(name)
    @os.servers.each do |s|
      return @os.server(s[:id]) if s[:name] == name
    end
    nil
  end

  def delete_keypair_if_exists(name)
    kp_names = @os.keypairs.values.map { |v| v[:name] }
    @os.delete_keypair(name) if kp_names.include? name
  end

  def delete_if_exists(name)
    s = server_by_name name
    s.delete! if s
  end

  def run_command(creds, cmd)
    res = Net::SSH::Simple.sync do
      ssh(creds[:ip], '/bin/sh', :user => creds[:user], :key_data => [creds[:key]]) do |e,c,d|
        case e
        when :start
          c.send_data "#{cmd}\n"
          c.eof!
        when :stdout
          # read the input line-wise (it *will* arrive fragmented!)
          (@buf ||= '') << d
          while line = @buf.slice!(/(.*)\r?\n/)
            yield line.chomp if block_given?
          end
        when :stderr
          (@buf ||= '') << d
          while line = @buf.slice!(/(.*)\r?\n/)
            yield line.chomp if block_given?
          end
        end
      end
    end
    if res.exit_code != 0
      raise "command #{cmd} failed on #{creds[:ip]}:\n#{res.stdout}\n#{res.stderr}"
    end
    res
  end

  # boot an instance and return creds
  def boot(opts)
    opts[:flavor] ||= 'standard.xsmall'
    opts[:image]  ||= /Ubuntu Precise/
    opts[:sec_groups] ||= ['default']
    opts[:key_name] ||= 'default'
    raise 'no name provided' if !opts[:name] or opts[:name].empty?

    private_key = new_key opts[:name]
    server = @os.create_server(
      :imageRef => image_id(opts[:image]),
      :flavorRef => flavor_id(opts[:flavor]),
      :key_name => opts[:name],
      :security_groups => opts[:sec_groups],
      :name => opts[:name])

    wait(300) do
      server = @os.server(server.id)
      raise 'error booting vm' if server.status == 'ERROR'
      server.status == 'ACTIVE'
    end
    sleep 60

    {
      :ip => public_ip(server),
      :user => 'ubuntu',
      :key => private_key
    }
  end

end
