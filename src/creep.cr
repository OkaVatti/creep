# src/creep.cr -- IRC client TUI entry point
#
# Build:   shards build creep
# Run:     ./bin/creep [--config path/to/config.yml]

require "./common/config"
require "./client/connection"
require "./client/ui"

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

c = cfg.client

print "Connecting to #{c.server}:#{c.port}"
print c.proxy ? " via proxy #{c.proxy}" : ""
puts c.tls ? " (TLS)" : " (plain)"

conn = IRCConnection.new(
  host:       c.server,
  port:       c.port,
  tls:        c.tls,
  proxy:      c.proxy,
  tls_verify: c.tls_verify
)

conn.send("NICK #{c.nick}")
conn.send("USER #{c.user} 0 * :#{c.realname}")
c.autojoin.each { |ch| conn.send("JOIN #{ch}") }

ui = UI.new(conn, c.nick, autojoin: c.autojoin)
ui.start