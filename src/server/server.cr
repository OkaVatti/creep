# src/server.cr
require "socket"
require "yaml"
require "fast_irc"
require "openssl"

module SimpleIRC
  # Connection-level client state
  class Client
    property io : IO
    property nick : String
    property user : String
    property host : String
    property realname : String
    property channels : Array(String)

    def initialize(io : IO)
      @io = io
      @nick = ""
      @user = ""
      @host = ""
      @realname = ""
      @channels = [] of String
    end
  end

  class Channel
    property name : String
    property members : Array(IO)
    property ops : Set(String)
    property topic : String?

    def initialize(name : String)
      @name = name
      @members = [] of IO
      @ops = Set(String).new
      @topic = nil
    end
  end

  @@server_name = "simpleirc"
  @@clients_by_io = {} of IO => Client
  @@nicks = {} of String => IO # nick -> IO
  @@channels = {} of String => Channel

  # ---------- YAML helpers ----------
  def self.any_to_s(any, default = "")
    begin
      return any.as_s
    rescue
      begin
        return any.to_s
      rescue
        return default
      end
    end
  end

  def self.any_to_s_opt(any) : String?
    begin
      return any.as_s
    rescue
      begin
        s = any.to_s
        return s
      rescue
        return nil
      end
    end
  end

  def self.any_to_i(any, default = 0)
    case any.raw
    when Int64
      any.as_i
    when String
      any.as_s.to_i
    else
      default
    end
  end

  def self.any_to_bool(any, default = false)
    begin
      return any if any.is_a?(Bool)
    rescue
    end

    begin
      s = any.as_s.downcase
      return true if s == "true" || s == "yes" || s == "1"
      return false if s == "false" || s == "no" || s == "0"
      return default
    rescue
      return default
    end
  end

  # ---------- I/O helpers ----------
  def self.write_line(io : IO, line : String)
    begin
      io.puts line
    rescue ex
      STDERR.puts "write error: #{ex}" if ENV["DEBUG"]
    end
  end

  def self.numeric(io : IO, code : Int32, target : String, message : String)
    write_line(io, ":#{@@server_name} #{code.to_s.rjust(3, '0')} #{target} :#{message}")
  end

  def self.welcome(io : IO, nick : String)
    numeric(io, 1, nick, "Welcome to #{@@server_name}, #{nick}")
  end

  def self.nick_in_use(io : IO, attempted : String)
    numeric(io, 433, attempted, "Nickname is already in use")
  end

  def self.ensure_client(io : IO)
    @@clients_by_io[io] ||= Client.new(io)
  end

  def self.send_topic(io : IO, ch : Channel)
    client = @@clients_by_io[io]
    if ch.topic
      write_line(io, ":#{@@server_name} 332 #{client.nick} #{ch.name} :#{ch.topic}")
    else
      write_line(io, ":#{@@server_name} 331 #{client.nick} #{ch.name} :No topic is set")
    end
  end

  def self.broadcast_to_channel(ch : Channel, line : String, except_io : IO? = nil)
    ch.members.each do |m|
      next if except_io && m == except_io
      write_line(m, line)
    end
  end

  # ---------- Command handling ----------
  def self.handle_message(io : IO, msg)
    ensure_client(io)
    client = @@clients_by_io[io]

    case msg.command
    when "NICK"
      newnick = msg.params[0]? || ""
      if newnick.empty?
        numeric(io, 431, "*", "No nickname given")
        return
      end

      if existing = @@nicks[newnick]
        if existing != io
          nick_in_use(io, newnick)
          return
        end
      end

      if client.nick && client.nick.size > 0
        @@nicks.delete(client.nick) rescue nil
      end

      client.nick = newnick
      @@nicks[newnick] = io

      if client.user && client.user.size > 0
        welcome(io, newnick)
      end
    when "USER"
      user = msg.params[0]? || ""
      hostname = msg.params[1]? || "unknown"
      real = msg.params[3]? || ""
      client.user = user
      client.host = hostname
      client.realname = real

      if client.nick && client.nick.size > 0
        welcome(io, client.nick)
      end
    when "JOIN"
      channel_name = msg.params[0]? || ""
      if channel_name.empty?
        numeric(io, 461, client.nick || "*", "JOIN")
        return
      end

      ch = @@channels[channel_name] ||= Channel.new(channel_name)
      if ch.members.empty?
        # first member is op
        ch.ops.add(client.nick)
      end

      unless ch.members.includes?(io)
        ch.members << io
      end

      client.channels << channel_name unless client.channels.includes?(channel_name)

      join_line = ":#{client.nick || "anon"} JOIN #{channel_name}"
      broadcast_to_channel(ch, join_line)

      # topic + NAMES
      send_topic(io, ch)

      nicks_list = ch.members.map do |m|
        if c = @@clients_by_io[m]?
          c.nick
        else
          "?"
        end
      end.join(" ")

      write_line(io, ":#{@@server_name} 353 #{client.nick} = #{channel_name} :#{nicks_list}")
      write_line(io, ":#{@@server_name} 366 #{client.nick} #{channel_name} :End of /NAMES list")
    when "PART"
      channel_name = msg.params[0]? || ""
      if channel_name.empty?
        numeric(io, 461, client.nick || "*", "PART")
        return
      end

      ch = @@channels[channel_name]
      unless ch
        numeric(io, 403, client.nick || "*", "#{channel_name} :No such channel")
        return
      end

      if ch.members.includes?(io)
        ch.members.delete(io)
        client.channels.delete(channel_name)
        part_line = ":#{client.nick || "anon"} PART #{channel_name}"
        broadcast_to_channel(ch, part_line)
        ch.ops.delete(client.nick) if ch.ops.includes?(client.nick)
        @@channels.delete(channel_name) if ch.members.empty?
      else
        numeric(io, 442, client.nick || "*", "#{channel_name} :You're not on that channel")
      end
    when "PRIVMSG"
      target = msg.params[0]? || ""
      body = msg.params[1]? || ""
      if target.empty? || body.empty?
        numeric(io, 461, client.nick || "*", "PRIVMSG")
        return
      end

      if target.starts_with?("#")
        ch = @@channels[target]
        unless ch
          numeric(io, 403, client.nick || "*", "#{target} :No such channel")
          return
        end
        line = ":#{client.nick || "anon"} PRIVMSG #{target} :#{body}"
        broadcast_to_channel(ch, line)
      else
        if dest_io = @@nicks[target]
          write_line(dest_io, ":#{client.nick || "anon"} PRIVMSG #{target} :#{body}")
        else
          numeric(io, 401, client.nick || "*", "#{target} :No such nick")
        end
      end
    when "MODE"
      target = msg.params[0]? || ""
      modes = msg.params[1]? || ""
      mode_arg = msg.params[2]? || ""

      if target.starts_with?("#")
        ch = @@channels[target]
        unless ch
          numeric(io, 403, client.nick || "*", "#{target} :No such channel")
          return
        end

        unless ch.ops.includes?(client.nick)
          numeric(io, 482, client.nick || "*", "#{target} :You're not channel operator")
          return
        end

        if modes.starts_with?("+") && modes.includes?("o")
          if @@nicks[mode_arg]
            ch.ops.add(mode_arg)
            write_line(io, ":#{@@server_name} MODE #{target} +o #{mode_arg}")
          else
            numeric(io, 401, client.nick || "*", "#{mode_arg} :No such nick")
          end
        elsif modes.starts_with?("-") && modes.includes?("o")
          ch.ops.delete(mode_arg)
          write_line(io, ":#{@@server_name} MODE #{target} -o #{mode_arg}")
        else
          numeric(io, 472, client.nick || "*", "Unknown MODE flag")
        end
      else
        numeric(io, 501, client.nick || "*", "Unknown MODE target")
      end
    when "TOPIC"
      target = msg.params[0]? || ""
      newtopic = msg.params[1]? || nil
      ch = @@channels[target]
      unless ch
        numeric(io, 403, client.nick || "*", "#{target} :No such channel")
        return
      end

      if newtopic
        unless ch.ops.includes?(client.nick)
          numeric(io, 482, client.nick || "*", "#{target} :You're not channel operator")
          return
        end
        ch.topic = newtopic
        broadcast_to_channel(ch, ":#{client.nick} TOPIC #{target} :#{newtopic}")
      else
        send_topic(io, ch)
      end
    when "QUIT"
      reason = msg.params[0]? || "Quit"
      handle_quit(io, reason)
    when "PING"
      nonce = msg.params[0]? || ""
      write_line(io, "PONG :#{nonce}")
    else
      # unhandled commands ignored
    end
  end

  def self.handle_quit(io : IO, reason : String)
    if client = @@clients_by_io[io]?
      quit_line = ":#{client.nick || "anon"} QUIT :#{reason}"
      client.channels.each do |chname|
        ch = @@channels[chname]
        if ch
          broadcast_to_channel(ch, quit_line, io)
          ch.members.delete(io) rescue nil
          ch.ops.delete(client.nick) rescue nil
          @@channels.delete(chname) if ch.members.empty?
        end
      end

      @@nicks.delete(client.nick) rescue nil
      @@clients_by_io.delete(io) rescue nil
    end

    begin
      write_line(io, ":#{@@server_name} ERROR :Closing Link (#{reason})")
    rescue
    end

    begin
      io.close
    rescue
    end
  end

  # Accept loop for TCPServer or OpenSSL::SSL::Server
  def self.accept_loop(listener : TCPServer | OpenSSL::SSL::Server)
    loop do
      begin
        client = listener.accept
      rescue ex
        STDERR.puts "accept error: #{ex}"
        next
      end

      spawn do
        io = client.as(IO)
        begin
          @@clients_by_io[io] = Client.new(io)
          FastIRC.parse(io) do |msg|
            handle_message(io, msg)
          end
        rescue ex
          STDERR.puts "client handler error: #{ex}"
        ensure
          if @@clients_by_io[io]
            handle_quit(io, "Connection closed")
          end
          begin
            io.close
          rescue
          end
        end
      end
    end
  end

  # Start server from config.yml
  def self.start_from_config
    cfg_any = nil : YAML::Any?
    begin
      cfg_any = YAML.parse(File.read("config/config.yml"))
    rescue ex
      STDERR.puts "Failed to read/parse config.yml: #{ex}"
      cfg_any = nil
    end

    cfg = {} of String => YAML::Any
    if cfg_any
      begin
        cfg = cfg_any.as_h
      rescue
        cfg = {} of String => YAML::Any
      end
    end

    sconf = {} of String => YAML::Any
    if cfg.has_key?("server")
      begin
        sconf = cfg["server"].as_h
      rescue
        sconf = {} of String => YAML::Any
      end
    end

    listeners_any = [] of YAML::Any
    if sconf.has_key?("listeners")
      begin
        listeners_any = sconf["listeners"].as_a
      rescue
        listeners_any = [] of YAML::Any
      end
    end

    if sconf.has_key?("name")
      begin
        @@server_name = sconf["name"].as_s
      rescue
      end
    end

    bound = Set(String).new

    listeners_any.each do |entry_any|
      entry = entry_any.as_h

      host = entry["host"]?.try { |v| any_to_s(v) } || "0.0.0.0"
      port = entry["port"]?.try { |v| any_to_i(v) } || 6667
      tls = entry["tls"]?.try { |v| any_to_bool(v) } || false

      key = "#{host}:#{port}"

      if bound.includes?(key)
        raise "Duplicate listener: #{key}"
      end

      bound << key

      if tls
        cert = entry["cert"]?.try { |v| any_to_s(v) } || raise "Missing TLS cert"
        keyf = entry["key"]?.try { |v| any_to_s(v) } || raise "Missing TLS key"

        ctx = OpenSSL::SSL::Context::Server.new
        ctx.certificate_chain = cert
        ctx.private_key = keyf

        tcp = TCPServer.new(host, port)
        ssl = OpenSSL::SSL::Server.new(tcp, ctx)

        puts "Listening TLS on #{key}"
        spawn { accept_loop(ssl) }
      else
        tcp = TCPServer.new(host, port)
        puts "Listening TCP on #{key}"
        spawn { accept_loop(tcp) }
      end
    end

    loop do
      sleep(Time::Span.new(seconds: 60))
    end
  end
end
