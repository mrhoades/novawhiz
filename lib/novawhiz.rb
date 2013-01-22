require 'openstack'
require 'net/ssh/simple'
require 'fileutils'

class NovaWhiz

  attr_accessor :os

  def initialize(opts)
    @os = OpenStack::Connection.create(
      :username => opts[:username],
      :api_key => opts[:password],
      :authtenant => opts[:authtenant],
      :auth_url => opts[:auth_url],
      :region => opts[:region],
      :service_type => "compute")

    #@fog = Fog::Compute.new(
    #    :provider      => opts[:provider],
    #    :hp_account_id  => opts[:hp_account_id],
    #    :hp_secret_key => opts[:hp_secret_key],
    #    :hp_auth_uri   => opts[:hp_auth_uri],
    #    :hp_tenant_id => opts[:hp_tenant_id],
    #    :hp_avl_zone => opts[:hp_avl_zone])
  end

  ## fog methods
  #
  #def fog_test_method()
  #
  #  servers = @fog.servers
  #  servers.size   # returns no. of servers
  #                 # display servers in a tabular format
  #  @fog.servers.table([:id, :name, :state, :created_at])
  #  @fog.addresses.table([:id, :ip, :fixed_ip, :instance_id])
  #
  #  floatip_id = address_by_ip("15.185.164.224")
  #
  #end
  #
  #def assign_floating_ip(server_name,ip)
  #
  #  address = address_by_ip(ip)
  #  server = server_by_name(server_name)
  #  address.server = server
  #  address.instance_id
  #
  #end
  #
  #def server_by_name(name)
  #  @fog.server.each do |s|
  #    return s if s.name == name
  #  end
  #  raise "Could not find server with name: #{name}"
  #end
  #
  #def address_by_ip(ip)
  #  @fog.addresses.each do |f|
  #    return f if f.ip == ip
  #  end
  #  raise "Could not find id of floating IP: #{ip}"
  #end
  #
  #def address_by_instance_id(instance_id)
  #  @fog.addresses.each do |f|
  #    return f if f.instance_id == instance_id
  #  end
  #  raise "Could not find ID of floating IP using instance ID: #{instance_id}"
  #end
  ## end fog methods


  def flavor_id(name)
    flavors = @os.flavors.select { |f| f[:name] == name }
    raise "ambiguous/unknown flavor: #{name}" unless flavors.length == 1
    flavors.first[:id]
  end

  def image_id(reg)
    images = @os.images.select { |i| i[:name] =~ reg }
    raise "ambiguous/unknown image: #{reg} : #{images.inspect}" unless images.length >= 1
    images.first[:id]
  end

  def replace_period_with_dash(name)
    # bugbug - handle hp cloud bug where key names with two "." can't be deleted.
    # when writing and reading keys, convert "." to "-".
    # remove this code when this openstack bug is fixed
    nameclean = name.gsub(".","-")
    return nameclean
  end

  def new_key(name)
    key = @os.create_keypair :name => replace_period_with_dash(name)
    key
  end

  def get_key(key_name, key_dir = File.expand_path('~/.ssh/hpcloud-keys/az-2.region-a.geo-1/'))
    key = ""
    File.open(key_dir + "/"  + replace_period_with_dash(key_name), 'r') do |f|
      while line = f.gets
        key+=line
      end
    end
    return key
  end

  def write_key(key, key_dir = File.expand_path('~/.ssh/hpcloud-keys/az-2.region-a.geo-1/'))
    begin
      FileUtils.mkdir_p(key_dir) unless File.exists?(key_dir)
      keyfile_path = key_dir + "/"  + key[:name]
      File.open(keyfile_path, "w") do |f|
        f.write(key[:private_key])
        f.close
      end
      File.chmod(0600,keyfile_path)
    rescue
      raise "Error with writing key at: #{keyfile_path}"
    end
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

  def server_list()
    return @os.servers
  end

  def keypair_name(server)
    server.key_name
  end

  def default_user(node)
    'ubuntu'
  end

  def cleanup(name)
    if server_exists name
      delete_if_exists(name)
    end

    if keypair_exists name
      delete_keypair_if_exists(name)
    end

    #TODO: need consistent way of deciding that cleanup is complete. sleep for now.
    sleep(20)
  end

  def keypair_exists(name)
    kp_names = @os.keypairs.values.map { |v| v[:name] }
    return true if kp_names.include? name
  end

  def server_exists(name)
    s = server_by_name name
    return true if s
  end

  def delete_keypair_if_exists(name)
    @os.delete_keypair name if keypair_exists name
  end

  def delete_if_exists(name)
    s = server_by_name name
    s.delete! if s
  end

  def run_command(creds, cmd)
    res = Net::SSH::Simple.sync do
      ssh(creds[:ip], '/bin/sh', :user => creds[:user], :key_data => [creds[:key]], :timeout => 3600, :global_known_hosts_file => ['/dev/null'], :user_known_hosts_file => ['/dev/null']) do |e,c,d|
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
    opts[:region] ||= 'az-2.region-a.geo-1'

    raise 'no name provided' if !opts[:name] or opts[:name].empty?

    cleanup opts[:name]
    private_key = new_key opts[:name]
    write_key(private_key, File.expand_path('~/.ssh/hpcloud-keys/' + opts[:region] + '/'))

    server = @os.create_server(
      :imageRef => image_id(opts[:image]),
      :flavorRef => flavor_id(opts[:flavor]),
      :key_name => private_key[:name],
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
      :key => private_key[:private_key]
    }
  end

end
