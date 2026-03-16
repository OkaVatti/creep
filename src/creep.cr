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

c = cfg.client

STDERR.puts "Connecting to #{c.server}:#{c.port}#{c.tls ? " (TLS)" : ""}#{c.proxy ? " via #{c.proxy}" : ""}"

begin
  conn = IRCConnection.new(
    host:       c.server,
    port:       c.port,
    tls:        c.tls,
    proxy:      c.proxy,
    tls_verify: c.tls_verify
  )
rescue ex
  STDERR.puts "Connection failed: #{ex}"
  exit 1
end

conn.send("NICK #{c.nick}")
conn.send("USER #{c.user} 0 * :#{c.realname}")
c.autojoin.each { |ch| conn.send("JOIN #{ch}") }

ui = UI.new(conn, cfg.client)
ui.start