# src/bot/bot.cr
#
# Programmatic bot API with:
#   - Command dispatch (on_command)
#   - Event hooks (on_privmsg, on_notice, on_join, on_part, on_kick, on_nick, on_topic)
#   - Middleware chain (use { |event, next_fn| ... })
#   - Scheduled tasks (every(interval) { ... })
#   - HTTP webhook forwarding
#   - Connection state (auto-reconnect handled by caller)

require "http/client"
require "json"
require "../common/transport"
require "../common/config"
require "fast_irc"

module Creep
  class Bot
    record BotEvent,
      type    : String,
      nick    : String,
      user    : String,
      host    : String,
      target  : String,
      body    : String,
      command : String?,
      args    : String,
      raw     : FastIRC::Message

    alias Handler    = Proc(BotEvent, Nil)
    alias Middleware = Proc(BotEvent, Proc(Nil), Nil)

    getter nick : String

    def initialize(@cfg : Config::BotConfig)
      @nick             = @cfg.nick
      @io               = IO::Memory.new.as(IO)
      @connected        = false
      @command_handlers = {} of String => Handler
      @hooks            = {} of String => Array(Handler)
      @middleware       = [] of Middleware
      @tasks            = [] of Tuple(Time::Span, Proc(Nil))
    end

    # ---- Middleware --------------------------------------------------------

    def use(&block : BotEvent, Proc(Nil) ->)
      @middleware << block
    end

    # ---- Event hooks -------------------------------------------------------

    {% for ev in %w[privmsg notice join part kick nick topic quit] %}
      def on_{{ev.id}}(&block : BotEvent ->)
        (@hooks[{{ev}}] ||= [] of Handler) << block
      end
    {% end %}

    def on_command(command : String, &block : BotEvent ->)
      @command_handlers[command.downcase] = block
    end

    # ---- Scheduled tasks ---------------------------------------------------

    def every(interval : Time::Span, &block : ->)
      @tasks << {interval, block}
    end

    # ---- Actions -----------------------------------------------------------

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

    def op(channel : String, target : String)
      send_raw("MODE #{channel} +o #{target}")
    end

    def deop(channel : String, target : String)
      send_raw("MODE #{channel} -o #{target}")
    end

    def send_raw(line : String)
      @io.puts(line)
      @io.flush
    rescue ex
      STDERR.puts "[bot] send error: #{ex}"
    end

    # ---- Connection --------------------------------------------------------

    def connect(host : String, port : Int32,
                tls : Bool = false, proxy : String? = nil, tls_verify : Bool = true)
      @io        = Transport.connect(host, port, tls: tls, proxy: proxy, tls_verify: tls_verify)
      @connected = true
      send_raw("NICK #{@cfg.nick}")
      send_raw("USER #{@cfg.user} 0 * :#{@cfg.realname}")
    end

    def run
      raise "Not connected" unless @connected

      # Start scheduled tasks
      @tasks.each do |interval, block|
        spawn do
          loop do
            sleep interval
            begin
              block.call
            rescue ex
              STDERR.puts "[bot] task error: #{ex}"
            end
          end
        end
      end

      registered = false

      while line = @io.gets(chomp: true)
        next if line.empty?
        msg = FastIRC.parse_line(line)
        next unless msg

        case msg.command
        when "PING"
          send_raw("PONG :#{msg.params[0]? || ""}")
        when "001"
          unless registered
            registered = true
            @cfg.autojoin.each { |ch| join(ch) }
          end
        when "NICK"
          if prefix_nick(msg) == @nick
            @nick = msg.params[0]? || @nick
          end
          dispatch("nick", msg)
        when "PRIVMSG"
          dispatch_privmsg(msg)
        when "NOTICE"
          dispatch("notice", msg)
        when "JOIN"
          dispatch("join", msg)
        when "PART"
          dispatch("part", msg)
        when "KICK"
          dispatch("kick", msg)
        when "TOPIC"
          dispatch("topic", msg)
        when "QUIT"
          dispatch("quit", msg)
        end
      end
    rescue ex
      STDERR.puts "[bot] run error: #{ex}"
    end

    # ---- Dispatch ----------------------------------------------------------

    private def dispatch_privmsg(msg)
      p      = msg.prefix.try(&.to_s) || ""
      parts  = p.split(/[!@]/, 3)
      nick   = parts[0]? || ""
      user   = parts[1]? || ""
      host   = parts[2]? || ""
      target = msg.params[0]? || ""
      body   = msg.params[1]? || ""

      cmd_name = nil
      args     = ""
      if body.starts_with?(@cfg.prefix)
        words    = body[@cfg.prefix.size..].split(" ", 2)
        cmd_name = words[0]?.try(&.downcase)
        args     = words[1]? || ""
      end

      event = BotEvent.new(
        type:    "privmsg",
        nick:    nick,
        user:    user,
        host:    host,
        target:  target,
        body:    body,
        command: cmd_name,
        args:    args,
        raw:     msg
      )

      run_middleware(event) do
        forward_webhook(event)

        if cmd_name && (handler = @command_handlers[cmd_name]?)
          handler.call(event) rescue nil
        end

        (@hooks["privmsg"]? || [] of Handler).each { |h| h.call(event) rescue nil }
      end
    end

    private def dispatch(type : String, msg)
      p      = msg.prefix.try(&.to_s) || ""
      parts  = p.split(/[!@]/, 3)
      event  = BotEvent.new(
        type:    type,
        nick:    parts[0]? || "",
        user:    parts[1]? || "",
        host:    parts[2]? || "",
        target:  msg.params[0]? || "",
        body:    msg.params[1]? || msg.params[0]? || "",
        command: nil,
        args:    "",
        raw:     msg
      )
      run_middleware(event) do
        (@hooks[type]? || [] of Handler).each { |h| h.call(event) rescue nil }
      end
    end

    private def run_middleware(event : BotEvent, &final : ->)
      if @middleware.empty?
        final.call
        return
      end
      idx  = 0
      chain = uninitialized Proc(Nil)
      chain = Proc(Nil).new do
        if idx < @middleware.size
          mw = @middleware[idx]
          idx += 1
          mw.call(event, chain)
        else
          final.call
        end
      end
      chain.call
    end

    private def prefix_nick(msg) : String
      (msg.prefix.try(&.to_s) || "").split("!").first
    end

    # ---- Webhook -----------------------------------------------------------

    private def forward_webhook(event : BotEvent)
      url = @cfg.webhook_url
      return unless url && !url.empty?

      payload = {
        "type"    => event.type,
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
          HTTP::Client.post(url,
            headers: HTTP::Headers{"Content-Type" => "application/json"},
            body: payload)
        rescue ex
          STDERR.puts "[bot] webhook error: #{ex}"
        end
      end
    end
  end
end