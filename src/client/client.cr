require "yaml"
require "./connection"
require "./renderer"
require "./ui"

cfg = YAML.parse(File.read("config/config.yml"))

client = cfg["client"].as_h

host = client["server"].as_s
port = client["port"].as_i
nick = client["nick"].as_s
user = client["user"].as_s
realname = client["realname"].as_s
tls = client["tls"].as_bool
proxy = client["proxy"]?.try &.as_s

conn = IRCConnection.new(host, port, tls, proxy)

conn.send "NICK #{nick}"
conn.send "USER #{user} 0 * :#{realname}"

UI.start(conn)