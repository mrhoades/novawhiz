Gem::Specification.new do |s|
  s.name        = 'novawhiz'
  s.version     = '0.0.4'
  s.date        = '2012-09-11'
  s.summary     = 'simplify nova operations'
  s.description = 'library and command line tool for simplifying openstack nova operations'
  s.authors     = ['tim miller']
  s.email       = 'none@example.com'
  s.files       = ["lib/novawhiz.rb"]
  s.homepage    = 'http://rubygems.org/gems/novawhiz'

  s.add_runtime_dependency 'openstack',      '>= 0'
  s.add_runtime_dependency 'net-ssh-simple', '>= 0'
end
