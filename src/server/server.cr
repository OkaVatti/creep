# src/server/server.cr
#
# IRC server. Supports:
#   NICK USER JOIN PART PRIVMSG NOTICE TOPIC MODE NAMES WHO LIST
#   QUIT PING PONG MOTD
#
# Each listener is an independent TCPServer (plain or TLS-wrapped).
# Spawned fibers handle each client concurrently.
# State is shared via module-level hashes (single-process).

require "socket"
require "openssl"
require "fast_irc"
require "../common/config"

module Creep
  module Server
    # ---- Data structures ------------------------------------------------

    class Client
      property io : IO
      property nick : String = ""
      property user : String = ""
      property host : String = "unknown"
      property realname : String = ""
      property channels : Array(String) = [] of String
      property registered : Bool = false

      def initialize(@io : IO)
      end

      def prefix : String
        "#{nick}!#{user}@#{host}"
      end
    end

    class Channel
      property name : String
      property topic : String? = nil
      property members : Array(IO) = [] of IO
      property ops : Set(String) = Set(String).new
      property voiced : Set(String) = Set(String).new
      property modes : Set(Char) = Set(Char).new # e.g. 'n', 't', 'm'

      def initialize(@name : String)
      end
    end

    # ---- Shared state ---------------------------------------------------

    @@server_name = "creep"
    @@motd = "Welcome."
    @@clients = {} of IO => Client
    @@nicks = {} of String => IO         # lowercase nick -> IO
    @@channels = {} of String => Channel # lowercase name -> Channel
    @@lock = Mutex.new

    # ---- Helpers --------------------------------------------------------

    private def self.write(io : IO, line : String)
      io.puts(line)
      io.flush
    rescue
    end

    private def self.numeric(io : IO, code : Int32, target : String, text : String)
      write(io, ":#{@@server_name} #{code.to_s.rjust(3, '0')} #{target} :#{text}")
    end

    private def self.numeric_bare(io : IO, code : Int32, target : String, args : String, text : String)
      write(io, ":#{@@server_name} #{code.to_s.rjust(3, '0')} #{target} #{args} :#{text}")
    end

    private def self.broadcast(ch : Channel, line : String, except_io : IO? = nil)
      ch.members.each do |m|
        next if m.same?(except_io)
        write(m, line)
      end
    end

    private def self.client_of(io : IO) : Client
      @@clients[io]? || Client.new(io).tap { |c| @@clients[io] = c }
    end

    private def self.check_registered(io : IO, client : Client) : Bool
      return true if client.registered
      numeric(io, 451, "*", "You have not registered")
      false
    end

    # ---- Registration & Welcome -----------------------------------------

    private def self.try_register(io : IO, client : Client)
      return if client.registered
      return if client.nick.empty? || client.user.empty?
      client.registered = true
      numeric(io, 1, client.nick, "Welcome to #{@@server_name}, #{client.nick}")
      numeric(io, 2, client.nick, "Your host is #{@@server_name}")
      numeric(io, 3, client.nick, "This server was created recently")
      numeric(io, 4, client.nick, "#{@@server_name} creep-0.1.0 o nt")
      send_motd(io, client)
    end

    private def self.send_motd(io : IO, client : Client)
      numeric(io, 375, client.nick, "- #{@@server_name} Message of the Day -")
      @@motd.each_line do |line|
        numeric(io, 372, client.nick, "- #{line.rstrip}")
      end
      numeric(io, 376, client.nick, "End of /MOTD command")
    end

    # ---- Command handlers -----------------------------------------------

    private def self.handle_nick(io : IO, client : Client, msg)
      newnick = msg.params[0]? || ""
      if newnick.empty?
        numeric(io, 431, client.nick.empty? ? "*" : client.nick, "No nickname given")
        return
      end
      unless newnick =~ /\A[A-Za-z\[\]\\`_\^\{\|\}][A-Za-z0-9\[\]\\`_\^\{\|\}\-]{0,15}\z/
        numeric(io, 432, newnick, "Erroneous nickname")
        return
      end
      key = newnick.downcase
      if (existing = @@nicks[key]?) && !existing.same?(io)
        numeric(io, 433, newnick, "Nickname is already in use")
        return
      end
      old_nick = client.nick
      @@nicks.delete(old_nick.downcase) unless old_nick.empty?
      client.nick = newnick
      @@nicks[key] = io
      if client.registered
        # Notify all channels of the nick change
        line = ":#{client.prefix} NICK :#{newnick}"
        notified = Set(IO).new
        client.channels.each do |chname|
          if ch = @@channels[chname]?
            ch.members.each do |m|
              next if notified.includes?(m)
              write(m, line)
              notified << m
            end
          end
        end
        # Update ops/voiced sets in all channels
        client.channels.each do |chname|
          if ch = @@channels[chname]?
            if ch.ops.includes?(old_nick)
              ch.ops.delete(old_nick)
              ch.ops.add(newnick)
            end
            if ch.voiced.includes?(old_nick)
              ch.voiced.delete(old_nick)
              ch.voiced.add(newnick)
            end
          end
        end
      else
        try_register(io, client)
      end
    end

    private def self.handle_user(io : IO, client : Client, msg)
      if client.registered
        numeric(io, 462, client.nick, "Unauthorized command (already registered)")
        return
      end
      client.user = msg.params[0]? || "unknown"
      client.host = msg.params[1]? || "unknown"
      client.realname = msg.params[3]? || ""
      try_register(io, client)
    end

    private def self.handle_join(io : IO, client : Client, msg)
      return unless check_registered(io, client)
      channel_names = (msg.params[0]? || "").split(",")
      channel_names.each do |channel_name|
        channel_name = channel_name.strip
        next if channel_name.empty?
        unless channel_name =~ /\A#[^ \a\0\r\n,]{1,49}\z/
          numeric(io, 403, client.nick, "#{channel_name} :No such channel (invalid name)")
          next
        end
        key = channel_name.downcase
        ch = @@channels[key] ||= Channel.new(channel_name)
        if ch.members.empty?
          ch.ops.add(client.nick)
        end
        unless ch.members.any?(&.same?(io))
          ch.members << io
        end
        unless client.channels.includes?(key)
          client.channels << key
        end
        broadcast(ch, ":#{client.prefix} JOIN :#{ch.name}")
        send_topic_reply(io, client, ch)
        send_names(io, client, ch)
      end
    end

    private def self.handle_part(io : IO, client : Client, msg)
      return unless check_registered(io, client)
      channel_name = msg.params[0]? || ""
      reason = msg.params[1]? || "Leaving"
      key = channel_name.downcase
      ch = @@channels[key]?
      unless ch
        numeric(io, 403, client.nick, "#{channel_name} :No such channel")
        return
      end
      unless ch.members.any?(&.same?(io))
        numeric(io, 442, client.nick, "#{channel_name} :You're not on that channel")
        return
      end
      broadcast(ch, ":#{client.prefix} PART #{ch.name} :#{reason}")
      remove_from_channel(io, client, ch, key)
    end

    private def self.handle_privmsg(io : IO, client : Client, msg, command : String)
      return unless check_registered(io, client)
      target = msg.params[0]? || ""
      body = msg.params[1]? || ""
      if target.empty?
        numeric(io, 411, client.nick, "No recipient given (#{command})")
        return
      end
      if body.empty?
        numeric(io, 412, client.nick, "No text to send")
        return
      end
      line = ":#{client.prefix} #{command} #{target} :#{body}"
      if target.starts_with?("#")
        key = target.downcase
        ch = @@channels[key]?
        unless ch
          numeric(io, 403, client.nick, "#{target} :No such channel")
          return
        end
        unless ch.members.any?(&.same?(io))
          numeric(io, 404, client.nick, "#{target} :Cannot send to channel (not a member)")
          return
        end
        # +m channel: only ops/voiced may speak
        if ch.modes.includes?('m') && !ch.ops.includes?(client.nick) && !ch.voiced.includes?(client.nick)
          numeric(io, 404, client.nick, "#{target} :Cannot send to channel (moderated)")
          return
        end
        broadcast(ch, line, except_io: io)
      else
        key = target.downcase
        dest_io = @@nicks[key]?
        unless dest_io
          numeric(io, 401, client.nick, "#{target} :No such nick/channel")
          return
        end
        write(dest_io, line)
      end
    end

    private def self.handle_topic(io : IO, client : Client, msg)
      return unless check_registered(io, client)
      channel_name = msg.params[0]? || ""
      key = channel_name.downcase
      ch = @@channels[key]?
      unless ch
        numeric(io, 403, client.nick, "#{channel_name} :No such channel")
        return
      end
      if msg.params.size >= 2
        newtopic = msg.params[1]
        if ch.modes.includes?('t') && !ch.ops.includes?(client.nick)
          numeric(io, 482, client.nick, "#{ch.name} :You're not channel operator")
          return
        end
        ch.topic = newtopic
        broadcast(ch, ":#{client.prefix} TOPIC #{ch.name} :#{newtopic}")
      else
        send_topic_reply(io, client, ch)
      end
    end

    private def self.handle_mode(io : IO, client : Client, msg)
      return unless check_registered(io, client)
      target = msg.params[0]? || ""
      modes = msg.params[1]? || ""
      marg = msg.params[2]? || ""

      if target.starts_with?("#")
        key = target.downcase
        ch = @@channels[key]?
        unless ch
          numeric(io, 403, client.nick, "#{target} :No such channel")
          return
        end
        if modes.empty?
          mode_str = ch.modes.empty? ? "+" : "+#{ch.modes.to_a.join}"
          numeric_bare(io, 324, client.nick, "#{ch.name} #{mode_str}", "")
          return
        end
        unless ch.ops.includes?(client.nick)
          numeric(io, 482, client.nick, "#{ch.name} :You're not channel operator")
          return
        end
        adding = true
        modes.each_char do |c|
          case c
          when '+' then adding = true
          when '-' then adding = false
          when 'o'
            if marg.empty?
              numeric(io, 461, client.nick, "MODE :Not enough parameters")
              next
            end
            if adding
              if @@nicks[marg.downcase]?
                ch.ops.add(marg)
                broadcast(ch, ":#{@@server_name} MODE #{ch.name} +o #{marg}")
              else
                numeric(io, 401, client.nick, "#{marg} :No such nick")
              end
            else
              ch.ops.delete(marg)
              broadcast(ch, ":#{@@server_name} MODE #{ch.name} -o #{marg}")
            end
          when 'v'
            if marg.empty?
              numeric(io, 461, client.nick, "MODE :Not enough parameters")
              next
            end
            if adding
              ch.voiced.add(marg)
              broadcast(ch, ":#{@@server_name} MODE #{ch.name} +v #{marg}")
            else
              ch.voiced.delete(marg)
              broadcast(ch, ":#{@@server_name} MODE #{ch.name} -v #{marg}")
            end
          when 'n', 't', 'm', 'i', 's'
            if adding
              ch.modes.add(c)
            else
              ch.modes.delete(c)
            end
            sign = adding ? "+" : "-"
            broadcast(ch, ":#{@@server_name} MODE #{ch.name} #{sign}#{c}")
          end
        end
      else
        # User mode -- minimal stub
        numeric_bare(io, 221, client.nick, modes, "")
      end
    end

    private def self.handle_names(io : IO, client : Client, msg)
      return unless check_registered(io, client)
      channel_name = msg.params[0]? || ""
      if channel_name.empty?
        @@channels.each_value { |ch| send_names(io, client, ch) }
      else
        ch = @@channels[channel_name.downcase]?
        if ch
          send_names(io, client, ch)
        else
          numeric(io, 403, client.nick, "#{channel_name} :No such channel")
        end
      end
    end

    private def self.handle_who(io : IO, client : Client, msg)
      return unless check_registered(io, client)
      mask = msg.params[0]? || "*"
      if mask.starts_with?("#")
        ch = @@channels[mask.downcase]?
        if ch
          ch.members.each do |m|
            if c = @@clients[m]?
              flags = ch.ops.includes?(c.nick) ? "@" : " "
              write(io, ":#{@@server_name} 352 #{client.nick} #{ch.name} #{c.user} #{c.host} #{@@server_name} #{c.nick} H#{flags} :0 #{c.realname}")
            end
          end
        end
      end
      write(io, ":#{@@server_name} 315 #{client.nick} #{mask} :End of /WHO list")
    end

    private def self.handle_list(io : IO, client : Client, msg)
      return unless check_registered(io, client)
      write(io, ":#{@@server_name} 321 #{client.nick} Channel :Users Name")
      @@channels.each_value do |ch|
        topic = ch.topic || ""
        write(io, ":#{@@server_name} 322 #{client.nick} #{ch.name} #{ch.members.size} :#{topic}")
      end
      write(io, ":#{@@server_name} 323 #{client.nick} :End of /LIST")
    end

    private def self.handle_whois(io : IO, client : Client, msg)
      return unless check_registered(io, client)
      target = msg.params[0]? || ""
      dest_io = @@nicks[target.downcase]?
      unless dest_io
        numeric(io, 401, client.nick, "#{target} :No such nick")
        return
      end
      c = @@clients[dest_io]?
      return unless c
      write(io, ":#{@@server_name} 311 #{client.nick} #{c.nick} #{c.user} #{c.host} * :#{c.realname}")
      chs = c.channels.join(" ")
      write(io, ":#{@@server_name} 319 #{client.nick} #{c.nick} :#{chs}") unless chs.empty?
      write(io, ":#{@@server_name} 318 #{client.nick} #{c.nick} :End of /WHOIS list")
    end

    private def self.handle_motd(io : IO, client : Client)
      return unless check_registered(io, client)
      send_motd(io, client)
    end

    # ---- Helpers for channel state --------------------------------------

    private def self.send_topic_reply(io : IO, client : Client, ch : Channel)
      if ch.topic
        write(io, ":#{@@server_name} 332 #{client.nick} #{ch.name} :#{ch.topic}")
      else
        write(io, ":#{@@server_name} 331 #{client.nick} #{ch.name} :No topic is set")
      end
    end

    private def self.send_names(io : IO, client : Client, ch : Channel)
      nicks_str = ch.members.compact_map do |m|
        if c = @@clients[m]?
          prefix = ch.ops.includes?(c.nick) ? "@" : ch.voiced.includes?(c.nick) ? "+" : ""
          "#{prefix}#{c.nick}"
        end
      end.join(" ")
      write(io, ":#{@@server_name} 353 #{client.nick} = #{ch.name} :#{nicks_str}")
      write(io, ":#{@@server_name} 366 #{client.nick} #{ch.name} :End of /NAMES list")
    end

    private def self.remove_from_channel(io : IO, client : Client, ch : Channel, key : String)
      ch.members.reject! { |m| m.same?(io) }
      ch.ops.delete(client.nick)
      ch.voiced.delete(client.nick)
      client.channels.delete(key)
      @@channels.delete(key) if ch.members.empty?
    end

    def self.handle_quit(io : IO, reason : String = "Quit")
      client = @@clients[io]?
      unless client
        begin
          io.close
        rescue
        end
        return
      end
      quit_line = ":#{client.prefix} QUIT :#{reason}"
      client.channels.dup.each do |key|
        if ch = @@channels[key]?
          broadcast(ch, quit_line, except_io: io)
          remove_from_channel(io, client, ch, key)
        end
      end
      @@nicks.delete(client.nick.downcase)
      @@clients.delete(io)
      begin
        write(io, ":#{@@server_name} ERROR :Closing Link (#{reason})")
      rescue
      end
      begin
        io.close
      rescue
      end
    end

    # ---- Main dispatch --------------------------------------------------

    def self.handle_message(io : IO, msg)
      @@lock.synchronize do
        client = client_of(io)
        case msg.command
        when "NICK"    then handle_nick(io, client, msg)
        when "USER"    then handle_user(io, client, msg)
        when "JOIN"    then handle_join(io, client, msg)
        when "PART"    then handle_part(io, client, msg)
        when "PRIVMSG" then handle_privmsg(io, client, msg, "PRIVMSG")
        when "NOTICE"  then handle_privmsg(io, client, msg, "NOTICE")
        when "TOPIC"   then handle_topic(io, client, msg)
        when "MODE"    then handle_mode(io, client, msg)
        when "NAMES"   then handle_names(io, client, msg)
        when "WHO"     then handle_who(io, client, msg)
        when "LIST"    then handle_list(io, client, msg)
        when "WHOIS"   then handle_whois(io, client, msg)
        when "MOTD"    then handle_motd(io, client)
        when "PING"
          nonce = msg.params[0]? || ""
          write(io, ":#{@@server_name} PONG #{@@server_name} :#{nonce}")
        when "PONG"
          # ignore
        when "QUIT"
          reason = msg.params[0]? || "Quit"
          handle_quit(io, reason)
        else
          numeric(io, 421, client.registered ? client.nick : "*", "#{msg.command} :Unknown command")
        end
      end
    end

    # ---- Accept loop ---------------------------------------------------

    private def self.accept_loop(listener)
      loop do
        begin
          raw_client = listener.accept
        rescue ex
          STDERR.puts "[server] accept error: #{ex}"
          next
        end
        spawn handle_client(raw_client.as(IO))
      end
    end

    private def self.handle_client(io : IO)
      @@lock.synchronize { @@clients[io] = Client.new(io) }
      begin
        FastIRC.parse(io) do |msg|
          handle_message(io, msg)
        end
      rescue ex
        STDERR.puts "[server] client error: #{ex}" if ENV["DEBUG"]?
      ensure
        @@lock.synchronize { handle_quit(io, "Connection closed") }
      end
    end

    # ---- Entry point ---------------------------------------------------

    def self.start(cfg : Config::ServerConfig)
      @@server_name = cfg.name
      @@motd = cfg.motd

      cfg.listeners.each do |l|
        if l.tls
          cert = l.cert || raise ArgumentError.new("TLS listener on #{l.host}:#{l.port} missing cert")
          keyf = l.key || raise ArgumentError.new("TLS listener on #{l.host}:#{l.port} missing key")
          ctx = OpenSSL::SSL::Context::Server.new
          ctx.certificate_chain = cert
          ctx.private_key = keyf
          tcp = TCPServer.new(l.host, l.port)
          ssl = OpenSSL::SSL::Server.new(tcp, ctx)
          puts "[server] listening TLS on #{l.host}:#{l.port}"
          spawn accept_loop(ssl)
        else
          tcp = TCPServer.new(l.host, l.port)
          puts "[server] listening TCP on #{l.host}:#{l.port}"
          spawn accept_loop(tcp)
        end
      end

      loop { sleep 60.seconds }
    end
  end
end
