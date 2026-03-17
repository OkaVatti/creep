# src/creep.cr -- IRC client TUI entry point

require "./common/config"
require "./client/connection"
require "./client/ui"

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

# The UI manages its own connection lifecycle.
# It starts in offline mode; the user connects via /connect or the config
# auto-connects if a server is configured.
ui = UI.new(cfg.client)

# If the config has a server set, auto-connect on startup.
# The UI will call do_connect internally after the screen is rendered,
# so the user sees the interface before any network activity begins.
unless cfg.client.server.empty?
  # We signal the UI to connect by pre-populating the input and submitting,
  # but since start() hasn't run yet we instead pass a flag via a method.
  ui.autoconnect = true
end

ui.start