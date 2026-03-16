# src/common/config.cr -- typed config loader

require "yaml"

module Config
  struct Listener
    getter host : String
    getter port : Int32
    getter tls  : Bool
    getter cert : String?
    getter key  : String?
    def initialize(@host, @port, @tls, @cert, @key); end
  end

  struct Oper
    getter name     : String
    getter password : String
    def initialize(@name, @password); end
  end

  struct ServerConfig
    getter name               : String
    getter motd               : String
    getter max_nick_length    : Int32
    getter max_channel_length : Int32
    getter max_message_length : Int32
    getter history_lines      : Int32
    getter ping_interval      : Int32
    getter log_file           : String?
    getter opers              : Array(Oper)
    getter listeners          : Array(Listener)
    def initialize(@name, @motd, @max_nick_length, @max_channel_length,
                   @max_message_length, @history_lines, @ping_interval,
                   @log_file, @opers, @listeners); end
  end

  struct ClientConfig
    getter server           : String
    getter port             : Int32
    getter tls              : Bool
    getter tls_verify       : Bool
    getter proxy            : String?
    getter nick             : String
    getter user             : String
    getter realname         : String
    getter autojoin         : Array(String)
    getter kitty_graphics   : Bool
    getter scrollback       : Int32
    getter timestamp_format : String
    getter theme            : String
    def initialize(@server, @port, @tls, @tls_verify, @proxy, @nick, @user,
                   @realname, @autojoin, @kitty_graphics, @scrollback,
                   @timestamp_format, @theme); end
  end

  struct BotConfig
    getter nick        : String
    getter user        : String
    getter realname    : String
    getter autojoin    : Array(String)
    getter webhook_url : String?
    getter prefix      : String
    def initialize(@nick, @user, @realname, @autojoin, @webhook_url, @prefix); end
  end

  struct AppConfig
    getter server : ServerConfig
    getter client : ClientConfig
    getter bot    : BotConfig
    def initialize(@server, @client, @bot); end
  end

  def self.load(path : String = "config/config.yml") : AppConfig
    raw = YAML.parse(File.read(path))
    parse(raw)
  end

  private def self.s(v : YAML::Any, default = "") : String
    v.as_s? || v.to_s rescue default
  end

  private def self.i(v : YAML::Any, default = 0) : Int32
    case v.raw
    when Int64   then v.raw.as(Int64).to_i32
    when String  then v.raw.as(String).to_i32
    else default
    end
  rescue
    default
  end

  private def self.b(v : YAML::Any, default = false) : Bool
    case v.raw
    when Bool   then v.raw.as(Bool)
    when String
      s = v.raw.as(String).downcase
      return true  if s == "true"  || s == "yes" || s == "1"
      return false if s == "false" || s == "no"  || s == "0"
      default
    else default
    end
  rescue
    default
  end

  private def self.sopt(v : YAML::Any?) : String?
    return nil if v.nil?
    return nil if v.raw.nil?
    v.as_s? || v.to_s
  rescue
    nil
  end

  private def self.parse(raw : YAML::Any) : AppConfig
    srv = raw["server"]
    cli = raw["client"]
    bot = raw["bot"]? || YAML.parse("{}")

    opers = (srv["opers"]?.try(&.as_a) || [] of YAML::Any).map do |e|
      Oper.new(name: s(e["name"]), password: s(e["password"]))
    end

    listeners = (srv["listeners"]?.try(&.as_a) || [] of YAML::Any).map do |e|
      Listener.new(
        host: s(e["host"]? || YAML::Any.new("0.0.0.0")),
        port: i(e["port"]? || YAML::Any.new(6667_i64)),
        tls:  b(e["tls"]?  || YAML::Any.new(false)),
        cert: sopt(e["cert"]?),
        key:  sopt(e["key"]?)
      )
    end

    server = ServerConfig.new(
      name:               s(srv["name"]? || YAML::Any.new("creep")),
      motd:               s(srv["motd"]? || YAML::Any.new("Welcome.")),
      max_nick_length:    i(srv["max_nick_length"]?    || YAML::Any.new(30_i64), 30),
      max_channel_length: i(srv["max_channel_length"]? || YAML::Any.new(50_i64), 50),
      max_message_length: i(srv["max_message_length"]? || YAML::Any.new(512_i64), 512),
      history_lines:      i(srv["history_lines"]?      || YAML::Any.new(50_i64), 50),
      ping_interval:      i(srv["ping_interval"]?      || YAML::Any.new(60_i64), 60),
      log_file:           sopt(srv["log_file"]?),
      opers:              opers,
      listeners:          listeners
    )

    autojoin_client = (cli["autojoin"]?.try(&.as_a) || [] of YAML::Any).map { |v| s(v) }
    client = ClientConfig.new(
      server:           s(cli["server"]?  || YAML::Any.new("127.0.0.1")),
      port:             i(cli["port"]?    || YAML::Any.new(6667_i64), 6667),
      tls:              b(cli["tls"]?     || YAML::Any.new(false)),
      tls_verify:       b(cli["tls_verify"]? || YAML::Any.new(false), false),
      proxy:            sopt(cli["proxy"]?),
      nick:             s(cli["nick"]?    || YAML::Any.new("user")),
      user:             s(cli["user"]?    || YAML::Any.new("user")),
      realname:         s(cli["realname"]? || YAML::Any.new("creep user")),
      autojoin:         autojoin_client,
      kitty_graphics:   b(cli["kitty_graphics"]? || YAML::Any.new(true), true),
      scrollback:       i(cli["scrollback"]?     || YAML::Any.new(500_i64), 500),
      timestamp_format: s(cli["timestamp_format"]? || YAML::Any.new("%H:%M")),
      theme:            s(cli["theme"]?            || YAML::Any.new("default"))
    )

    autojoin_bot = (bot["autojoin"]?.try(&.as_a) || [] of YAML::Any).map { |v| s(v) }
    bot_cfg = BotConfig.new(
      nick:        s(bot["nick"]?        || YAML::Any.new("creepbot")),
      user:        s(bot["user"]?        || YAML::Any.new("creepbot")),
      realname:    s(bot["realname"]?    || YAML::Any.new("creep bot")),
      autojoin:    autojoin_bot,
      webhook_url: sopt(bot["webhook_url"]?),
      prefix:      s(bot["prefix"]?      || YAML::Any.new("!"))
    )

    AppConfig.new(server: server, client: client, bot: bot_cfg)
  end
end