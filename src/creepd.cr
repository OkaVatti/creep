# src/creepd.cr -- IRC server binary entry point
#
# Build:   shards build creepd
# Run:     ./bin/creepd [--config path/to/config.yml]

require "./common/config"
require "./server/server"

config_path = "config/config.yml"
if (idx = ARGV.index("--config"))
  config_path = ARGV[idx + 1]? || config_path
end

begin
  cfg = Config.load(config_path)
rescue ex
  STDERR.puts "Failed to load config from #{config_path}: #{ex}"
  exit 1
end

Signal::INT.trap do
  puts "\n[creepd] shutting down"
  exit 0
end

Creep::Server.start(cfg.server)