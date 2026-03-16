# src/common/config.cr
#
# Typed wrappers around config/config.yml.
# Both creepd (server) and creep (client) use this.

require "yaml"

module Config
  struct Listener
    getter host : String
    getter port : Int32
    getter tls : Bool
    getter cert : String?
    getter key : String?

    def initialize(@host, @port, @tls, @cert, @key)
    end
  end

  struct ServerConfig
    getter name : String
    getter motd : String
    getter listeners : Array(Listener)

    def initialize(@name, @motd, @listeners)
    end
  end

  struct ClientConfig
    getter server : String
    getter port : Int32
    getter tls : Bool
    getter proxy : String?
    getter tls_verify : Bool
    getter nick : String
    getter user : String
    getter realname : String
    getter autojoin : Array(String)

    def initialize(@server, @port, @tls, @proxy, @tls_verify, @nick, @user, @realname, @autojoin)
    end
  end

  struct BotConfig
    getter nick : String
    getter user : String
    getter realname : String
    getter autojoin : Array(String)
    getter webhook_url : String?
    getter prefix : String

    def initialize(@nick, @user, @realname, @autojoin, @webhook_url, @prefix)
    end
  end

  struct AppConfig
    getter server : ServerConfig
    getter client : ClientConfig
    getter bot : BotConfig

    def initialize(@server, @client, @bot)
    end
  end

  def self.load(path : String = "config/config.yml") : AppConfig
    raw = YAML.parse(File.read(path))
    parse(raw)
  end

  private def self.s(v : YAML::Any, default = "") : String
    v.as_s? || v.to_s rescue default
  end

  private def self.i(v : YAML::Any, default = 0) : Int32
    v.as_i? || v.as_s?.try(&.to_i?) || default
  end

  private def self.b(v : YAML::Any, default = false) : Bool
    r = v.raw
    return r if r.is_a?(Bool)
    s = v.as_s?.try(&.downcase)
    return true  if s == "true"  || s == "yes" || s == "1"
    return false if s == "false" || s == "no"  || s == "0"
    default
  rescue
    default
  end

  private def self.parse(raw : YAML::Any) : AppConfig
    srv_raw  = raw["server"]
    cli_raw  = raw["client"]
    bot_raw  = raw["bot"]? || YAML.parse("{}")

    listeners = (srv_raw["listeners"]?.try(&.as_a) || [] of YAML::Any).map do |e|
      Listener.new(
        host: s(e["host"], "0.0.0.0"),
        port: i(e["port"], 6667),
        tls:  b(e["tls"]? || YAML::Any.new(false)),
        cert: e["cert"]?.try { |v| s(v) },
        key:  e["key"]?.try  { |v| s(v) }
      )
    end

    server = ServerConfig.new(
      name:      s(srv_raw["name"], "creep"),
      motd:      s(srv_raw["motd"]? || YAML::Any.new("Welcome.")),
      listeners: listeners
    )

    autojoin_client = (cli_raw["autojoin"]?.try(&.as_a) || [] of YAML::Any).map { |v| s(v) }
    client = ClientConfig.new(
      server:     s(cli_raw["server"], "127.0.0.1"),
      port:       i(cli_raw["port"], 6667),
      tls:        b(cli_raw["tls"]? || YAML::Any.new(false)),
      proxy:      cli_raw["proxy"]?.try { |v| v.raw.nil? ? nil : s(v) },
      tls_verify: b(cli_raw["tls_verify"]? || YAML::Any.new(true), true),
      nick:       s(cli_raw["nick"], "creepuser"),
      user:       s(cli_raw["user"], "creepuser"),
      realname:   s(cli_raw["realname"], "creep"),
      autojoin:   autojoin_client
    )

    autojoin_bot = (bot_raw["autojoin"]?.try(&.as_a) || [] of YAML::Any).map { |v| s(v) }
    bot = BotConfig.new(
      nick:        s(bot_raw["nick"]? || YAML::Any.new("creepbot"), "creepbot"),
      user:        s(bot_raw["user"]? || YAML::Any.new("creepbot"), "creepbot"),
      realname:    s(bot_raw["realname"]? || YAML::Any.new("creep bot"), "creep bot"),
      autojoin:    autojoin_bot,
      webhook_url: bot_raw["webhook_url"]?.try { |v| v.raw.nil? ? nil : s(v) },
      prefix:      s(bot_raw["prefix"]? || YAML::Any.new("!"), "!")
    )

    AppConfig.new(server: server, client: client, bot: bot)
  end
end