# src/server/server.cr
#
# IRC server supporting:
#   NICK USER JOIN PART PRIVMSG NOTICE TOPIC MODE NAMES WHO LIST WHOIS
#   KICK INVITE OPER WALLOPS MOTD QUIT PING PONG
#
# Extended features:
#   - Per-channel roles: owner (~) admin (&) op (@) voice (+) user
#   - Ban list (+b)
#   - Invite-only channels (+i)
#   - Channel join history (last N lines replayed on join)
#   - Server operator authentication (/oper)
#   - Periodic PING keepalive with dead-client detection
#   - Structured JSON event log
#   - SIGTERM / SIGINT graceful shutdown

require "socket"
require "openssl"
require "fast_irc"
require "json"
require "../common/config"

module Creep
  module Server
    # ---- Roles ----------------------------------------------------------

    enum Role
      User  = 0
      Voice = 1
      Op    = 2
      Admin = 3
      Owner = 4
    end

    # ---- Data structures ------------------------------------------------

    class Client
      property io : IO
      property nick : String = ""
      property user : String = ""
      property host : String = "unknown"
      property realname : String = ""
      property channels : Array(String) = [] of String
      property registered : Bool = false
      property is_oper : Bool = false
      property last_pong : Time = Time.utc

      def initialize(@io : IO)
      end

      def prefix : String
        "#{nick}!#{user}@#{host}"
      end

      def mode_char : String
        is_oper ? "*" : ""
      end
    end

    class Channel
      property name : String
      property topic : String? = nil
      property members : Array(IO) = [] of IO
      property roles : Hash(String, Role) = {} of String => Role # nick -> role
      property bans : Array(String) = [] of String               # ban masks
      property invites : Array(String) = [] of String            # invited nicks
      property modes : Set(Char) = Set(Char).new                 # n t m i s k
      property key : String? = nil
      property history : Array(String) = [] of String

      def initialize(@name : String)
      end

      def role_of(nick : String) : Role
        roles[nick]? || Role::User
      end

      def set_role(nick : String, role : Role)
        roles[nick] = role
      end

      def remove_role(nick : String)
        roles.delete(nick)
      end

      def mode_prefix(nick : String) : String
        case role_of(nick)
        when Role::Owner then "~"
        when Role::Admin then "&"
        when Role::Op    then "@"
        when Role::Voice then "+"
        else                  ""
        end
      end

      def can_speak?(nick : String) : Bool
        return true unless modes.includes?('m')
        role_of(nick) >= Role::Voice
      end

      def is_banned?(nick : String, user : String, host : String) : Bool
        mask = "#{nick}!#{user}@#{host}".downcase
        bans.any? do |ban|
          pattern = ban.downcase.gsub(".", "\\.").gsub("*", ".*").gsub("?", ".")
          mask =~ Regex.new(pattern) rescue false
        end
      end

      def push_history(line : String, max : Int32)
        history << line
        history.shift if history.size > max
      end
    end

    # ---- Shared state ---------------------------------------------------

    @@server_name = "creep"
    @@motd = "Welcome."
    @@max_nick = 30
    @@max_channel = 50
    @@max_message = 512
    @@history_lines = 50
    @@ping_interval = 60
    @@log_file : String? = nil
    @@log_io : File? = nil
    @@opers = {} of String => String # name -> password
    @@clients = {} of IO => Client
    @@nicks = {} of String => IO
    @@channels = {} of String => Channel
    @@lock = Mutex.new

    # ---- Logging --------------------------------------------------------

    private def self.log_event(type : String, data : Hash(String, String))
      io = @@log_io
      return unless io
      entry = {"time" => Time.utc.to_rfc3339, "type" => type}.merge(data)
      io.puts(entry.to_json)
      io.flush
    rescue
    end

    # ---- IO helpers -----------------------------------------------------

    private def self.write(io : IO, line : String)
      io.puts(line)
      io.flush
    rescue
    end

    private def self.numeric(io : IO, code : Int32, target : String, text : String)
      write(io, ":#{@@server_name} #{code.to_s.rjust(3, '0')} #{target} :#{text}")
    end

    private def self.numeric_raw(io : IO, code : Int32, target : String, tail : String)
      write(io, ":#{@@server_name} #{code.to_s.rjust(3, '0')} #{target} #{tail}")
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

    # ---- Welcome --------------------------------------------------------

    private def self.try_register(io : IO, client : Client)
      return if client.registered
      return if client.nick.empty? || client.user.empty?
      client.registered = true
      numeric(io, 1, client.nick, "Welcome to #{@@server_name}, #{client.nick}!")
      numeric(io, 2, client.nick, "Your host is #{@@server_name}, running creep-0.2.0")
      numeric(io, 3, client.nick, "This server was created recently")
      numeric(io, 4, client.nick, "#{@@server_name} creep-0.2.0 io bciklmnopstv")
      numeric(io, 5, client.nick, "CHANTYPES=# CHANMODES=b,k,l,imnst PREFIX=(qaov)~&@+ CASEMAPPING=rfc1459 are supported")
      send_motd(io, client)
      log_event("connect", {"nick" => client.nick, "host" => client.host})
    end

    private def self.send_motd(io : IO, client : Client)
      numeric(io, 375, client.nick, "- #{@@server_name} Message of the Day -")
      @@motd.each_line { |line| numeric(io, 372, client.nick, "- #{line.rstrip}") }
      numeric(io, 376, client.nick, "End of /MOTD command")
    end

    # ---- NICK -----------------------------------------------------------

    private def self.handle_nick(io : IO, client : Client, msg)
      newnick = msg.params[0]? || ""
      if newnick.empty?
        numeric(io, 431, client.nick.empty? ? "*" : client.nick, "No nickname given")
        return
      end
      if newnick.size > @@max_nick
        numeric(io, 432, newnick, "Erroneous nickname (too long)")
        return
      end
      unless newnick =~ /\A[A-Za-z\[\]\\`_\^\{\|\}][A-Za-z0-9\[\]\\`_\^\{\|\}\-]*\z/
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
        line = ":#{client.prefix} NICK :#{newnick}"
        notified = Set(IO).new
        client.channels.each do |chname|
          next unless ch = @@channels[chname]?
          ch.members.each do |m|
            next if notified.includes?(m)
            write(m, line)
            notified << m
          end
          # update role key
          if (role = ch.roles.delete(old_nick))
            ch.roles[newnick] = role
          end
        end
      else
        try_register(io, client)
      end
    end

    # ---- USER -----------------------------------------------------------

    private def self.handle_user(io : IO, client : Client, msg)
      if client.registered
        numeric(io, 462, client.nick, "Unauthorized command (already registered)")
        return
      end
      client.user = (msg.params[0]? || "unknown")[0, 10]
      client.host = msg.params[1]? || "unknown"
      client.realname = msg.params[3]? || ""
      try_register(io, client)
    end

    # ---- JOIN -----------------------------------------------------------

    private def self.handle_join(io : IO, client : Client, msg)
      return unless check_registered(io, client)
      channel_names = (msg.params[0]? || "").split(",")
      keys = (msg.params[1]? || "").split(",")

      channel_names.each_with_index do |channel_name, idx|
        channel_name = channel_name.strip
        next if channel_name.empty?

        unless channel_name.size <= @@max_channel + 1 && channel_name =~ /\A#[^ \a\0\r\n,]{1,}\z/
          numeric(io, 403, client.nick, "#{channel_name} :Invalid channel name")
          next
        end

        chkey = channel_name.downcase
        ch = @@channels[chkey] ||= Channel.new(channel_name)

        # +i invite-only check
        if ch.modes.includes?('i') && !ch.invites.includes?(client.nick.downcase)
          numeric(io, 473, client.nick, "#{channel_name} :Cannot join channel (+i)")
          next
        end

        # +b ban check
        if ch.is_banned?(client.nick, client.user, client.host)
          numeric(io, 474, client.nick, "#{channel_name} :Cannot join channel (+b)")
          next
        end

        # +k key check
        if (chkey_val = ch.key)
          provided = keys[idx]? || ""
          unless provided == chkey_val
            numeric(io, 475, client.nick, "#{channel_name} :Cannot join channel (+k)")
            next
          end
        end

        first_member = ch.members.empty?
        unless ch.members.any?(&.same?(io))
          ch.members << io
        end
        unless client.channels.includes?(chkey)
          client.channels << chkey
        end

        if first_member
          ch.set_role(client.nick, Role::Owner)
        end

        ch.invites.delete(client.nick.downcase)

        broadcast(ch, ":#{client.prefix} JOIN :#{ch.name}")
        send_topic_reply(io, client, ch)
        send_names(io, client, ch)

        # Replay history
        ch.history.each { |h| write(io, h) }

        log_event("join", {"nick" => client.nick, "channel" => ch.name})
      end
    end

    # ---- PART -----------------------------------------------------------

    private def self.handle_part(io : IO, client : Client, msg)
      return unless check_registered(io, client)
      channel_name = msg.params[0]? || ""
      reason = msg.params[1]? || "Leaving"
      chkey = channel_name.downcase
      ch = @@channels[chkey]?
      unless ch
        numeric(io, 403, client.nick, "#{channel_name} :No such channel")
        return
      end
      unless ch.members.any?(&.same?(io))
        numeric(io, 442, client.nick, "#{channel_name} :You're not on that channel")
        return
      end
      part_line = ":#{client.prefix} PART #{ch.name} :#{reason}"
      broadcast(ch, part_line)
      remove_from_channel(io, client, ch, chkey)
      log_event("part", {"nick" => client.nick, "channel" => ch.name, "reason" => reason})
    end

    # ---- PRIVMSG / NOTICE -----------------------------------------------

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
      if body.bytesize > @@max_message
        numeric(io, 416, client.nick, "Input line was too long")
        return
      end

      line = ":#{client.prefix} #{command} #{target} :#{body}"

      if target.starts_with?("#")
        chkey = target.downcase
        ch = @@channels[chkey]?
        unless ch
          numeric(io, 403, client.nick, "#{target} :No such channel")
          return
        end
        unless ch.members.any?(&.same?(io))
          numeric(io, 404, client.nick, "#{target} :Cannot send to channel (not a member)")
          return
        end
        unless ch.can_speak?(client.nick)
          numeric(io, 404, client.nick, "#{target} :Cannot send to channel (+m)")
          return
        end
        if command == "PRIVMSG"
          ch.push_history(line, @@history_lines)
        end
        broadcast(ch, line, except_io: io)
        log_event("message", {"nick" => client.nick, "target" => target, "body" => body})
      else
        dest_io = @@nicks[target.downcase]?
        unless dest_io
          numeric(io, 401, client.nick, "#{target} :No such nick/channel")
          return
        end
        write(dest_io, line)
      end
    end

    # ---- TOPIC ----------------------------------------------------------

    private def self.handle_topic(io : IO, client : Client, msg)
      return unless check_registered(io, client)
      channel_name = msg.params[0]? || ""
      chkey = channel_name.downcase
      ch = @@channels[chkey]?
      unless ch
        numeric(io, 403, client.nick, "#{channel_name} :No such channel")
        return
      end
      if msg.params.size >= 2
        if ch.modes.includes?('t') && ch.role_of(client.nick) < Role::Op && !client.is_oper
          numeric(io, 482, client.nick, "#{ch.name} :You're not channel operator")
          return
        end
        newtopic = msg.params[1]
        ch.topic = newtopic
        line = ":#{client.prefix} TOPIC #{ch.name} :#{newtopic}"
        broadcast(ch, line)
        ch.push_history(line, @@history_lines)
        log_event("topic", {"nick" => client.nick, "channel" => ch.name, "topic" => newtopic})
      else
        send_topic_reply(io, client, ch)
      end
    end

    # ---- MODE -----------------------------------------------------------

    private def self.handle_mode(io : IO, client : Client, msg)
      return unless check_registered(io, client)
      target = msg.params[0]? || ""
      modes = msg.params[1]? || ""
      marg = msg.params[2]? || ""

      if target.starts_with?("#")
        chkey = target.downcase
        ch = @@channels[chkey]?
        unless ch
          numeric(io, 403, client.nick, "#{target} :No such channel")
          return
        end
        if modes.empty?
          mode_str = "+" + ch.modes.to_a.sort.join
          numeric_raw(io, 324, client.nick, "#{ch.name} #{mode_str}")
          return
        end
        unless ch.role_of(client.nick) >= Role::Op || client.is_oper
          numeric(io, 482, client.nick, "#{ch.name} :You're not channel operator")
          return
        end
        adding = true
        modes.each_char do |c|
          case c
          when '+' then adding = true
          when '-' then adding = false
          when 'o', 'q', 'a', 'h', 'v'
            apply_role_mode(io, client, ch, c, marg, adding)
          when 'b'
            if adding
              unless marg.empty?
                ch.bans << marg unless ch.bans.includes?(marg)
                broadcast(ch, ":#{@@server_name} MODE #{ch.name} +b #{marg}")
              else
                ch.bans.each { |ban| numeric_raw(io, 367, client.nick, "#{ch.name} #{ban}") }
                numeric_raw(io, 368, client.nick, "#{ch.name} :End of channel ban list")
              end
            else
              ch.bans.delete(marg)
              broadcast(ch, ":#{@@server_name} MODE #{ch.name} -b #{marg}")
            end
          when 'k'
            if adding && !marg.empty?
              ch.key = marg
              broadcast(ch, ":#{@@server_name} MODE #{ch.name} +k #{marg}")
            else
              ch.key = nil
              broadcast(ch, ":#{@@server_name} MODE #{ch.name} -k *")
            end
          when 'i', 'm', 'n', 's', 't'
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
        # User mode stub
        numeric_raw(io, 221, client.nick, modes)
      end
    end

    private def self.apply_role_mode(io : IO, client : Client, ch : Channel,
                                     mode_char : Char, target_nick : String, adding : Bool)
      return if target_nick.empty?
      unless @@nicks[target_nick.downcase]?
        numeric(io, 401, client.nick, "#{target_nick} :No such nick")
        return
      end
      role = case mode_char
             when 'q' then Role::Owner
             when 'a' then Role::Admin
             when 'o' then Role::Op
             when 'h' then Role::Voice # halfop -> voice
             when 'v' then Role::Voice
             else          Role::User
             end
      if adding
        ch.set_role(target_nick, role)
      else
        ch.remove_role(target_nick) if ch.role_of(target_nick) == role
      end
      sign = adding ? "+" : "-"
      broadcast(ch, ":#{@@server_name} MODE #{ch.name} #{sign}#{mode_char} #{target_nick}")
    end

    # ---- KICK -----------------------------------------------------------

    private def self.handle_kick(io : IO, client : Client, msg)
      return unless check_registered(io, client)
      channel_name = msg.params[0]? || ""
      target_nick = msg.params[1]? || ""
      reason = msg.params[2]? || client.nick
      chkey = channel_name.downcase
      ch = @@channels[chkey]?
      unless ch
        numeric(io, 403, client.nick, "#{channel_name} :No such channel")
        return
      end
      unless ch.role_of(client.nick) >= Role::Op || client.is_oper
        numeric(io, 482, client.nick, "#{ch.name} :You're not channel operator")
        return
      end
      target_io = @@nicks[target_nick.downcase]?
      unless target_io && ch.members.any?(&.same?(target_io))
        numeric(io, 441, client.nick, "#{target_nick} #{ch.name} :They aren't on that channel")
        return
      end
      target_client = @@clients[target_io]?
      return unless target_client
      if ch.role_of(target_nick) >= ch.role_of(client.nick) && !client.is_oper
        numeric(io, 482, client.nick, "#{ch.name} :You cannot kick someone with equal or higher rank")
        return
      end
      kick_line = ":#{client.prefix} KICK #{ch.name} #{target_nick} :#{reason}"
      broadcast(ch, kick_line)
      remove_from_channel(target_io, target_client, ch, chkey)
      log_event("kick", {"by" => client.nick, "target" => target_nick, "channel" => ch.name})
    end

    # ---- INVITE ---------------------------------------------------------

    private def self.handle_invite(io : IO, client : Client, msg)
      return unless check_registered(io, client)
      target_nick = msg.params[0]? || ""
      channel_name = msg.params[1]? || ""
      chkey = channel_name.downcase
      ch = @@channels[chkey]?
      unless ch
        numeric(io, 403, client.nick, "#{channel_name} :No such channel")
        return
      end
      unless ch.members.any?(&.same?(io))
        numeric(io, 442, client.nick, "#{channel_name} :You're not on that channel")
        return
      end
      if ch.modes.includes?('i') && ch.role_of(client.nick) < Role::Op && !client.is_oper
        numeric(io, 482, client.nick, "#{ch.name} :You're not channel operator")
        return
      end
      target_io = @@nicks[target_nick.downcase]?
      unless target_io
        numeric(io, 401, client.nick, "#{target_nick} :No such nick")
        return
      end
      ch.invites << target_nick.downcase
      write(target_io, ":#{client.prefix} INVITE #{target_nick} :#{ch.name}")
      numeric(io, 341, client.nick, "#{target_nick} #{ch.name}")
    end

    # ---- OPER -----------------------------------------------------------

    private def self.handle_oper(io : IO, client : Client, msg)
      return unless check_registered(io, client)
      name = msg.params[0]? || ""
      password = msg.params[1]? || ""
      expected = @@opers[name]?
      if expected && expected == password
        client.is_oper = true
        numeric(io, 381, client.nick, "You are now an IRC operator")
        write(io, ":#{@@server_name} MODE #{client.nick} :+o")
        log_event("oper", {"nick" => client.nick})
      else
        numeric(io, 464, client.nick, "Password incorrect")
      end
    end

    # ---- WALLOPS --------------------------------------------------------

    private def self.handle_wallops(io : IO, client : Client, msg)
      return unless check_registered(io, client)
      unless client.is_oper
        numeric(io, 481, client.nick, "Permission Denied- You're not an IRC operator")
        return
      end
      text = msg.params[0]? || ""
      line = ":#{client.prefix} WALLOPS :#{text}"
      @@clients.each_value do |c|
        write(c.io, line) if c.registered
      end
    end

    # ---- NAMES / WHO / LIST / WHOIS / MOTD -----------------------------

    private def self.handle_names(io : IO, client : Client, msg)
      return unless check_registered(io, client)
      channel_name = msg.params[0]? || ""
      if channel_name.empty?
        @@channels.each_value { |ch| send_names(io, client, ch) }
      elsif (ch = @@channels[channel_name.downcase]?)
        send_names(io, client, ch)
      else
        numeric(io, 403, client.nick, "#{channel_name} :No such channel")
      end
    end

    private def self.handle_who(io : IO, client : Client, msg)
      return unless check_registered(io, client)
      mask = msg.params[0]? || "*"
      if mask.starts_with?("#")
        if (ch = @@channels[mask.downcase]?)
          ch.members.each do |m|
            next unless c = @@clients[m]?
            flags = ch.role_of(c.nick) >= Role::Op ? "@" : " "
            oper = c.is_oper ? "*" : ""
            write(io, ":#{@@server_name} 352 #{client.nick} #{ch.name} #{c.user} #{c.host} #{@@server_name} #{c.nick} H#{oper}#{flags} :0 #{c.realname}")
          end
        end
      end
      write(io, ":#{@@server_name} 315 #{client.nick} #{mask} :End of /WHO list")
    end

    private def self.handle_list(io : IO, client : Client, msg)
      return unless check_registered(io, client)
      write(io, ":#{@@server_name} 321 #{client.nick} Channel :Users Name")
      @@channels.each_value do |ch|
        next if ch.modes.includes?('s') && !ch.members.any?(&.same?(io))
        write(io, ":#{@@server_name} 322 #{client.nick} #{ch.name} #{ch.members.size} :#{ch.topic || ""}")
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
      if c.is_oper
        numeric(io, 313, client.nick, "#{c.nick} :is an IRC operator")
      end
      unless c.channels.empty?
        write(io, ":#{@@server_name} 319 #{client.nick} #{c.nick} :#{c.channels.join(" ")}")
      end
      write(io, ":#{@@server_name} 318 #{client.nick} #{c.nick} :End of /WHOIS list")
    end

    private def self.handle_motd(io : IO, client : Client)
      return unless check_registered(io, client)
      send_motd(io, client)
    end

    # ---- Channel helpers ------------------------------------------------

    private def self.send_topic_reply(io : IO, client : Client, ch : Channel)
      if (t = ch.topic)
        write(io, ":#{@@server_name} 332 #{client.nick} #{ch.name} :#{t}")
      else
        write(io, ":#{@@server_name} 331 #{client.nick} #{ch.name} :No topic is set")
      end
    end

    private def self.send_names(io : IO, client : Client, ch : Channel)
      nicks_str = ch.members.compact_map do |m|
        next unless c = @@clients[m]?
        "#{ch.mode_prefix(c.nick)}#{c.nick}"
      end.join(" ")
      write(io, ":#{@@server_name} 353 #{client.nick} = #{ch.name} :#{nicks_str}")
      write(io, ":#{@@server_name} 366 #{client.nick} #{ch.name} :End of /NAMES list")
    end

    private def self.remove_from_channel(io : IO, client : Client, ch : Channel, chkey : String)
      ch.members.reject! { |m| m.same?(io) }
      ch.remove_role(client.nick)
      client.channels.delete(chkey)
      @@channels.delete(chkey) if ch.members.empty?
    end

    # ---- QUIT -----------------------------------------------------------

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
      client.channels.dup.each do |chkey|
        next unless ch = @@channels[chkey]?
        broadcast(ch, quit_line, except_io: io)
        remove_from_channel(io, client, ch, chkey)
      end
      @@nicks.delete(client.nick.downcase)
      @@clients.delete(io)
      log_event("quit", {"nick" => client.nick, "reason" => reason})
      begin
        write(io, ":#{@@server_name} ERROR :Closing Link (#{reason})")
      rescue
      end
      begin
        io.close
      rescue
      end
    end

    # ---- Dispatch -------------------------------------------------------

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
        when "KICK"    then handle_kick(io, client, msg)
        when "INVITE"  then handle_invite(io, client, msg)
        when "OPER"    then handle_oper(io, client, msg)
        when "WALLOPS" then handle_wallops(io, client, msg)
        when "MOTD"    then handle_motd(io, client)
        when "PING"
          nonce = msg.params[0]? || ""
          write(io, ":#{@@server_name} PONG #{@@server_name} :#{nonce}")
        when "PONG"
          client.last_pong = Time.utc
        when "QUIT"
          handle_quit(io, msg.params[0]? || "Quit")
        else
          numeric(io, 421, client.registered ? client.nick : "*", "#{msg.command} :Unknown command")
        end
      end
    end

    # ---- Ping loop ------------------------------------------------------

    private def self.ping_loop
      interval = @@ping_interval.seconds
      loop do
        sleep interval
        deadline = Time.utc - (interval * 2)
        @@lock.synchronize do
          dead = [] of IO
          @@clients.each do |io, client|
            next unless client.registered
            if client.last_pong < deadline
              dead << io
            else
              write(io, "PING :#{@@server_name}")
            end
          end
          dead.each { |io| handle_quit(io, "Ping timeout") }
        end
      end
    end

    # ---- Accept loop ----------------------------------------------------

    private def self.accept_loop(listener)
      loop do
        begin
          raw = listener.accept
        rescue ex
          STDERR.puts "[server] accept error: #{ex}"
          next
        end
        spawn handle_client(raw.as(IO))
      end
    end

    private def self.handle_client(io : IO)
      @@lock.synchronize do
        c = Client.new(io)
        c.last_pong = Time.utc
        @@clients[io] = c
      end
      begin
        while line = io.gets(chomp: true)
          next if line.empty?
          msg = FastIRC.parse_line(line)
          next unless msg
          handle_message(io, msg)
        end
      rescue ex
        STDERR.puts "[server] client error: #{ex}" if ENV["DEBUG"]?
      ensure
        @@lock.synchronize { handle_quit(io, "Connection closed") }
      end
    end

    # ---- Entry point ----------------------------------------------------

    def self.start(cfg : Config::ServerConfig)
      @@server_name = cfg.name
      @@motd = cfg.motd
      @@max_nick = cfg.max_nick_length
      @@max_channel = cfg.max_channel_length
      @@max_message = cfg.max_message_length
      @@history_lines = cfg.history_lines
      @@ping_interval = cfg.ping_interval

      if (lf = cfg.log_file)
        @@log_file = lf
        @@log_io = File.open(lf, "a")
      end

      cfg.opers.each { |o| @@opers[o.name] = o.password }

      cfg.listeners.each do |l|
        if l.tls
          cert = l.cert || raise ArgumentError.new("TLS listener #{l.host}:#{l.port} missing cert")
          keyf = l.key || raise ArgumentError.new("TLS listener #{l.host}:#{l.port} missing key")
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

      spawn ping_loop

      Signal::INT.trap { puts "\n[creepd] shutting down"; exit 0 }
      Signal::TERM.trap { puts "\n[creepd] shutting down"; exit 0 }

      loop { sleep 60.seconds }
    end
  end
end
