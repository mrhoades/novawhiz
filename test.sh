sudo gem build novawhiz.gemspec

sudo gem install novawhiz-0.0.8.gem

nw boot test-nw8

nw run test-nw8 "whoami && hostname && uname -a"

nw ssh test-nw8

