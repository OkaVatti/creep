# src/creepd.cr -- IRC server daemon entry point

require "./common/config"
require "./server/server"

config_path = "config/config.yml"
ARGV.each_with_index do |arg, i|
  config_path = ARGV[i + 1] if arg == "--config" && ARGV[i + 1]?
end

begin
  cfg = Config.load(config_path)
rescue ex
  STDERR.puts "Failed to load #{config_path}: #{ex}"
  exit 1
end

Creep::Server.start(cfg.server)