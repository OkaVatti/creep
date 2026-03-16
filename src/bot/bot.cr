# src/bot/bot.cr
#
# Programmatic bot API.
#
# Usage:
#   bot = Creep::Bot.new(cfg.bot)
#   bot.on_privmsg { |event| ... }
#   bot.on_command("hello") { |event| bot.say(event.channel, "Hello!") }
#   bot.connect(cfg.client.server, cfg.client.port, tls: cfg.client.tls, proxy: cfg.client.proxy)
#   bot.run
#
# BotEvent fields:
#   nick     : String   -- sender nick
#   user     : String   -- sender user
#   host     : String   -- sender host
#   target   : String   -- channel or bot nick
#   body     : String   -- message text
#   command  : String?  -- command name (stripped prefix), if any
#   args     : String   -- remainder after command word
#   raw      : IRC message object

require "http/client"
require "json"
require "../common/transport"
require "../common/config"
require "fast_irc"

module Creep
  class Bot
    record BotEvent,
      nick : String,
      user : String,
      host : String,
      target : String,
      body : String,
      command : String?,
      args : String,
      raw : FastIRC::Message

    alias Handler = Proc(BotEvent, Nil)

    getter nick : String

    def initialize(@cfg : Config::BotConfig)
      @nick = @cfg.nick
      @privmsg_hooks = [] of Handler
      @notice_hooks = [] of Handler
      @join_hooks = [] of Handler
      @part_hooks = [] of Handler
      @command_handlers = {} of String => Handler
      @io = IO::Memory.new.as(IO) # replaced on connect
      @connected = false
    end

    # ---- Registration ---------------------------------------------------

    # Called for every PRIVMSG received (includes commands).
    def on_privmsg(&block : BotEvent ->)
      @privmsg_hooks << block
    end

    def on_notice(&block : BotEvent ->)
      @notice_hooks << block
    end

    def on_join(&block : BotEvent ->)
      @join_hooks << block
    end

    def on_part(&block : BotEvent ->)
      @part_hooks << block
    end

    # Register a command handler. If prefix is "!" and command is "ping",
    # a message "!ping rest" triggers this.
    def on_command(command : String, &block : BotEvent ->)
      @command_handlers[command.downcase] = block
    end

    # ---- Actions --------------------------------------------------------

    def say(target : String, text : String)
      send_raw("PRIVMSG #{target} :#{text}")
    end

    def notice(target : String, text : String)
      send_raw("NOTICE #{target} :#{text}")
    end

    def join(channel : String)
      send_raw("JOIN #{channel}")
    end

    def part(channel : String, reason : String = "Leaving")
      send_raw("PART #{channel} :#{reason}")
    end

    def set_topic(channel : String, topic : String)
      send_raw("TOPIC #{channel} :#{topic}")
    end

    def kick(channel : String, target_nick : String, reason : String = "")
      send_raw("KICK #{channel} #{target_nick} :#{reason}")
    end

    def send_raw(line : String)
      @io.puts(line)
      @io.flush
    rescue ex
      STDERR.puts "[bot] send error: #{ex}"
    end

    # ---- Connection & main loop -----------------------------------------

    def connect(
      host : String,
      port : Int32,
      tls : Bool = false,
      proxy : String? = nil,
      tls_verify : Bool = true,
    )
      @io = Transport.connect(host, port, tls: tls, proxy: proxy, tls_verify: tls_verify)
      @connected = true
      send_raw("NICK #{@cfg.nick}")
      send_raw("USER #{@cfg.user} 0 * :#{@cfg.realname}")
    end

    def run
      raise "Not connected" unless @connected

      registered = false

      while line = @io.gets(chomp: true)
        next if line.empty?
        msg = FastIRC.parse_line(line)
        next unless msg
        case msg.command
        when "PING"
          nonce = msg.params[0]? || ""
          send_raw("PONG :#{nonce}")
        when "001" # RPL_WELCOME
          unless registered
            registered = true
            @cfg.autojoin.each { |ch| join(ch) }
          end
        when "NICK"
          if nick_from(msg.prefix) == @nick
            @nick = msg.params[0]? || @nick
          end
        when "PRIVMSG"
          dispatch_privmsg(msg)
        when "NOTICE"
          dispatch_generic(msg, @notice_hooks)
        when "JOIN"
          dispatch_generic(msg, @join_hooks)
        when "PART"
          dispatch_generic(msg, @part_hooks)
        end
      end
    rescue ex
      STDERR.puts "[bot] run error: #{ex}"
    end

    # ---- Dispatch -------------------------------------------------------

    private def dispatch_privmsg(msg)
      p = msg.prefix
      nick = p.try(&.nick) || ""
      user = p.try(&.user) || ""
      host = p.try(&.host) || ""
      target = msg.params[0]? || ""
      body = msg.params[1]? || ""

      cmd_name = nil
      args = ""
      if body.starts_with?(@cfg.prefix)
        words = body[1..].split(" ", 2)
        cmd_name = words[0]?.try(&.downcase)
        args = words[1]? || ""
      end

      event = BotEvent.new(
        nick: nick,
        user: user,
        host: host,
        target: target,
        body: body,
        command: cmd_name,
        args: args,
        raw: msg
      )

      forward_webhook(event)

      if cmd_name && (handler = @command_handlers[cmd_name]?)
        begin
          handler.call(event)
        rescue ex
          STDERR.puts "[bot] command handler error: #{ex}"
        end
      end

      @privmsg_hooks.each do |hook|
        begin
          hook.call(event)
        rescue ex
          STDERR.puts "[bot] privmsg hook error: #{ex}"
        end
      end
    end

    private def dispatch_generic(msg, hooks : Array(Handler))
      p = msg.prefix
      event = BotEvent.new(
        nick: p.try(&.nick) || "",
        user: p.try(&.user) || "",
        host: p.try(&.host) || "",
        target: msg.params[0]? || "",
        body: msg.params[1]? || "",
        command: nil,
        args: "",
        raw: msg
      )
      hooks.each { |h| h.call(event) rescue nil }
    end

    private def nick_from(prefix : FastIRC::Prefix?) : String
      prefix.to_s.split('!').first
    end

    # ---- Webhook --------------------------------------------------------

    private def forward_webhook(event : BotEvent)
      url = @cfg.webhook_url
      return unless url && !url.empty?

      payload = {
        "nick"    => event.nick,
        "user"    => event.user,
        "host"    => event.host,
        "target"  => event.target,
        "body"    => event.body,
        "command" => event.command,
        "args"    => event.args,
      }.to_json

      spawn do
        begin
          HTTP::Client.post(url, headers: HTTP::Headers{"Content-Type" => "application/json"}, body: payload)
        rescue ex
          STDERR.puts "[bot] webhook error: #{ex}"
        end
      end
    end
  end
end
