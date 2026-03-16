# src/client/ui.cr
#
# Terminal UI:
#
#  [*status*] [#general*] [#other]   user@creep.local  12:34  lag:12ms
#  ──────────────────────────────────────────────────────────────────────
#  12:34 <alice> hello **world**
#  12:34 --> bob joined #general
#  12:34 <@carol> topic changed
#  ──────────────────────────────────────────────────────────────────────
#  > _
#
# Keyboard:
#   Alt/Ctrl + Left/Right  switch buffers
#   PageUp / PageDown      scroll
#   Up/Down arrow          scroll one line
#   Ctrl+L                 redraw
#   Enter                  send
#   /help                  command list

require "./connection"
require "./input"
require "./kitty"
require "../common/config"
require "../common/markdown"

# ---- Buffer -------------------------------------------------------------

class Buffer
  property name : String
  property lines : Array(String)
  property unread : Int32
  property scroll : Int32    # lines scrolled up from bottom
  property activity : Symbol # :none :activity :mention

  def initialize(@name : String)
    @lines = [] of String
    @unread = 0
    @scroll = 0
    @activity = :none
  end

  def push(line : String, mention : Bool = false)
    @lines << line
    @unread += 1
    @activity = mention ? :mention : :activity if @activity != :mention
    @scroll += 1 if @scroll > 0 # keep position when scrolled up
  end

  def mark_read
    @unread = 0
    @activity = :none
  end
end

# ---- UI -----------------------------------------------------------------

class UI
  # ANSI constants
  RESET   = "\e[0m"
  BOLD    = "\e[1m"
  DIM     = "\e[2m"
  ITALIC  = "\e[3m"
  REVERSE = "\e[7m"
  CLEAR   = "\e[2J\e[H"
  HIDE_C  = "\e[?25l"
  SHOW_C  = "\e[?25h"

  # Theme colours (256-colour)
  C_TAB_ACTIVE   = "\e[38;5;15m\e[48;5;24m"  # white on blue
  C_TAB_ACTIVITY = "\e[38;5;11m"             # yellow
  C_TAB_MENTION  = "\e[38;5;9m"              # red
  C_STATUS_BAR   = "\e[38;5;15m\e[48;5;236m" # white on dark grey
  C_DIVIDER      = "\e[38;5;240m"
  C_TIMESTAMP    = "\e[38;5;244m"
  C_JOIN_PART    = "\e[38;5;242m"
  C_NICK_OWN     = "\e[38;5;39m"  # bright blue
  C_NICK_OP      = "\e[38;5;220m" # gold
  C_NICK_VOICE   = "\e[38;5;46m"  # green
  C_NICK_NORMAL  = "\e[38;5;252m"
  C_MENTION      = "\e[38;5;196m" # red for highlights
  C_SERVER       = "\e[38;5;33m"

  def initialize(@conn : IRCConnection, @cfg : Config::ClientConfig)
    @nick = @cfg.nick
    @buffers = [Buffer.new("*status*")] of Buffer
    @active = 0
    @input_line = ""
    @cursor_pos = 0
    @incoming = ::Channel(String).new(512)
    @running = true
    @rows = 24
    @cols = 80
    @lag_ms = 0_i64
    @ping_sent = Time.utc
    @scrollback = @cfg.scrollback
    @ts_fmt = @cfg.timestamp_format
    @kitty = @cfg.kitty_graphics && Kitty.supported?

    @cfg.autojoin.each { |ch| @buffers << Buffer.new(ch) }
  end

  # ---- Entry point -------------------------------------------------------

  def start
    STDIN.raw! rescue nil
    print HIDE_C
    update_terminal_size

    # Background fiber: incoming messages
    spawn do
      @conn.read_loop do |msg|
        text = format_message(msg)
        @incoming.send(text) unless text.empty?
      end
      @incoming.send("\x00EXIT")
    end

    # Background fiber: lag ping every 30s
    spawn do
      loop do
        sleep 30.seconds
        next unless @conn
        @ping_sent = Time.utc
        @conn.send("PING :LAG#{@ping_sent.to_unix_ms}")
      end
    end

    render_full

    input_reader = Input.new
    loop do
      # Drain incoming
      loop do
        msg_text = @incoming.receive?
        break unless msg_text
        if msg_text == "\x00EXIT"
          @running = false
          break
        end
        # Empty strings are routing side-effects with no display output
        next if msg_text.empty?
        active_buf.push(msg_text, mention?(msg_text))
        if @active == 0 || active_buf.name != "*status*"
          render_messages
          render_status_bar
          render_input_bar
        end
      end
      break unless @running

      input_reader.read_char_timeout(0.05) do |ch|
        handle_key(ch)
        render_messages
        render_status_bar
        render_input_bar
      end
    end
  ensure
    STDIN.cooked! rescue nil
    print SHOW_C
    print "\n#{RESET}"
  end

  # ---- Rendering ---------------------------------------------------------

  private def active_buf : Buffer
    @buffers[@active]
  end

  private def update_terminal_size
    output = `stty size 2>/dev/null`.strip
    parts = output.split
    if parts.size >= 2
      r = parts[0].to_i?
      c = parts[1].to_i?
      @rows = r if r && r >= 8
      @cols = c if c && c >= 40
    end
  end

  private def render_full
    update_terminal_size
    print HIDE_C + CLEAR
    render_tab_bar
    render_divider(2)
    render_messages
    render_divider(@rows - 1)
    render_status_bar
    render_input_bar
  end

  private def render_tab_bar
    print "\e[1;1H"
    bar = String::Builder.new
    @buffers.each_with_index do |buf, i|
      badge = buf.unread > 0 ? "(#{buf.unread})" : ""
      if i == @active
        bar << C_TAB_ACTIVE << BOLD << " #{buf.name}#{badge} " << RESET
      else
        colour = case buf.activity
                 when :mention  then C_TAB_MENTION
                 when :activity then C_TAB_ACTIVITY
                 else                DIM
                 end
        bar << colour << " #{buf.name}#{badge} " << RESET
      end
    end
    s = bar.to_s
    print truncate_ansi(s, @cols)
    print " " * [0, @cols - visible_len(s)].max
  end

  private def render_divider(row : Int32)
    print "\e[#{row};1H"
    print C_DIVIDER + ("─" * @cols) + RESET
  end

  private def render_messages
    msg_rows = @rows - 4 # tab(1) divider(1) status(1) input(1)
    return if msg_rows < 1

    buf = active_buf
    buf.mark_read

    lines = buf.lines
    total = lines.size
    scroll = [buf.scroll, [0, total - msg_rows].max].min
    buf.scroll = scroll

    start = [0, total - msg_rows - scroll].max
    visible = lines[start, msg_rows]

    (3..(msg_rows + 2)).each do |row|
      print "\e[#{row};1H\e[2K"
      idx = row - 3
      if idx < visible.size
        print truncate_ansi(visible[idx], @cols)
      end
    end
  end

  private def render_status_bar
    row = @rows - 1
    print "\e[#{row};1H"
    buf = active_buf
    lag = @lag_ms > 0 ? " lag:#{@lag_ms}ms" : ""
    left = " #{@nick} | #{buf.name}#{lag} "
    right = " #{Time.local.to_s(@ts_fmt)} "
    pad = [0, @cols - visible_len(left) - visible_len(right)].max
    status = C_STATUS_BAR + left + (" " * pad) + right + RESET
    print truncate_ansi(status, @cols + status.size - visible_len(status))
  end

  private def render_input_bar
    row = @rows
    print "\e[#{row};1H\e[2K"
    prompt = "#{BOLD}> #{RESET}"
    max_w = @cols - 3
    display = @input_line.size > max_w ? @input_line[(@input_line.size - max_w)..] : @input_line
    print "#{prompt}#{display}"
    cur_col = 3 + [@cursor_pos, max_w].min
    print "\e[#{row};#{cur_col}H#{SHOW_C}"
  end

  # ---- Input handling ----------------------------------------------------

  private def handle_key(ch : String)
    case ch
    when "\r", "\n"
      submit_input
    when "\x7f", "\b"
      if @cursor_pos > 0
        @input_line = @input_line[0, @cursor_pos - 1] + @input_line[@cursor_pos..]
        @cursor_pos -= 1
      end
    when "\e[C" # right
      @cursor_pos = [@cursor_pos + 1, @input_line.size].min
    when "\e[D" # left
      @cursor_pos = [@cursor_pos - 1, 0].max
    when "\e[A" # up -- scroll up 1
      active_buf.scroll += 1
    when "\e[B" # down -- scroll down 1
      active_buf.scroll = [active_buf.scroll - 1, 0].max
    when "\e[5~" # PageUp
      active_buf.scroll += (@rows - 4)
    when "\e[6~" # PageDown
      active_buf.scroll = [active_buf.scroll - (@rows - 4), 0].max
    when "\e[1;5C", "\e\e[C", "\e[1;3C" # Alt/Ctrl+Right
      @active = (@active + 1) % @buffers.size
      render_full
      return
    when "\e[1;5D", "\e\e[D", "\e[1;3D" # Alt/Ctrl+Left
      @active = (@active - 1 + @buffers.size) % @buffers.size
      render_full
      return
    when "\x0c" # Ctrl+L
      render_full
      return
    when "\x01" # Ctrl+A -- beginning of line
      @cursor_pos = 0
    when "\x05" # Ctrl+E -- end of line
      @cursor_pos = @input_line.size
    when "\x0b" # Ctrl+K -- kill to end
      @input_line = @input_line[0, @cursor_pos]
    when "\x15" # Ctrl+U -- kill to start
      @input_line = @input_line[@cursor_pos..]
      @cursor_pos = 0
    else
      if ch.size >= 1 && ch.bytes[0] >= 0x20
        @input_line = @input_line[0, @cursor_pos] + ch + @input_line[@cursor_pos..]
        @cursor_pos += ch.size
      end
    end
  end

  private def submit_input
    line = @input_line.strip
    @input_line = ""
    @cursor_pos = 0
    return if line.empty?

    if line.starts_with?("/")
      handle_command(line[1..])
    else
      send_chat(active_buf.name, line)
    end
  end

  private def send_chat(target : String, text : String)
    unless target.starts_with?("#") || @@nicks_dummy
      push_status("Not in a channel. Use /join #channel")
      return
    end
    @conn.send("PRIVMSG #{target} :#{text}")
    ts = Time.local.to_s(@ts_fmt)
    rendered = Markdown.render_inline(text)
    active_buf.lines << "#{C_TIMESTAMP}#{ts}#{RESET} #{C_NICK_OWN}<#{@nick}>#{RESET} #{rendered}"
    active_buf.scroll += 1 if active_buf.scroll > 0
  end

  @@nicks_dummy : Nil = nil # type anchor

  # ---- Commands ----------------------------------------------------------

  private def handle_command(raw : String)
    parts = raw.split(" ", 2)
    cmd = parts[0].downcase
    args = parts[1]? || ""

    case cmd
    when "join"
      ch = args.strip
      ch = "##{ch}" unless ch.starts_with?("#")
      ensure_buffer(ch)
      @active = buffer_index(ch)
      @conn.send("JOIN #{ch}")
    when "part"
      ch = args.empty? ? active_buf.name : args.strip
      @conn.send("PART #{ch} :Leaving")
      @buffers.reject! { |b| b.name.downcase == ch.downcase }
      @active = [0, @active - 1].max
      render_full
    when "nick"
      n = args.strip
      n.empty? ? push_status("Usage: /nick <newnick>") : @conn.send("NICK #{n}")
    when "msg"
      sub = args.split(" ", 2)
      if sub.size < 2
        push_status("Usage: /msg <nick> <message>")
      else
        @conn.send("PRIVMSG #{sub[0]} :#{sub[1]}")
        push_status("[-> #{sub[0]}] #{sub[1]}")
      end
    when "me"
      @conn.send("PRIVMSG #{active_buf.name} :\x01ACTION #{args}\x01")
    when "topic"
      ch = active_buf.name
      args.empty? ? @conn.send("TOPIC #{ch}") : @conn.send("TOPIC #{ch} :#{args}")
    when "kick"
      sub = args.split(" ", 2)
      if sub.empty?
        push_status("Usage: /kick <nick> [reason]")
      else
        reason = sub[1]? || @nick
        @conn.send("KICK #{active_buf.name} #{sub[0]} :#{reason}")
      end
    when "invite"
      sub = args.split(" ", 2)
      ch = sub[1]? || active_buf.name
      sub[0]? ? @conn.send("INVITE #{sub[0]} #{ch}") : push_status("Usage: /invite <nick> [#channel]")
    when "ban"
      mask = args.strip
      mask.empty? ? @conn.send("MODE #{active_buf.name} +b") : @conn.send("MODE #{active_buf.name} +b #{mask}")
    when "unban"
      mask = args.strip
      @conn.send("MODE #{active_buf.name} -b #{mask}")
    when "op"
      @conn.send("MODE #{active_buf.name} +o #{args.strip}")
    when "deop"
      @conn.send("MODE #{active_buf.name} -o #{args.strip}")
    when "voice"
      @conn.send("MODE #{active_buf.name} +v #{args.strip}")
    when "devoice"
      @conn.send("MODE #{active_buf.name} -v #{args.strip}")
    when "mode"
      @conn.send("MODE #{args}")
    when "oper"
      sub = args.split(" ", 2)
      if sub.size < 2
        push_status("Usage: /oper <name> <password>")
      else
        @conn.send("OPER #{sub[0]} #{sub[1]}")
      end
    when "wallops"
      @conn.send("WALLOPS :#{args}")
    when "whois"
      @conn.send("WHOIS #{args}")
    when "list"
      @conn.send("LIST")
    when "names"
      target = args.empty? ? active_buf.name : args
      @conn.send("NAMES #{target}")
    when "motd"
      @conn.send("MOTD")
    when "raw"
      @conn.send(args)
    when "connect"
      push_status("Use /raw SERVER <host> or restart with a different config to switch servers.")
    when "img"
      handle_img(args.strip)
    when "clear"
      active_buf.lines.clear
      active_buf.scroll = 0
    when "close"
      if @buffers.size > 1
        @buffers.delete_at(@active)
        @active = [0, @active - 1].max
      end
      render_full
    when "quit"
      reason = args.empty? ? "Quit" : args
      @conn.send("QUIT :#{reason}")
      @running = false
    when "help"
      [
        "#{BOLD}Commands:#{RESET}",
        "  /join #ch         join a channel",
        "  /part [#ch]       leave current or named channel",
        "  /nick <n>         change nickname",
        "  /msg <n> <text>   private message",
        "  /me <action>      CTCP ACTION",
        "  /topic [text]     get or set topic",
        "  /kick <n> [r]     kick user from channel",
        "  /invite <n> [#ch] invite user to channel",
        "  /ban [mask]       ban mask (no mask = list bans)",
        "  /unban <mask>     remove ban",
        "  /op /deop <n>     grant or remove op",
        "  /voice /devoice   grant or remove voice",
        "  /mode <args>      raw MODE command",
        "  /oper <n> <pw>    authenticate as IRC operator",
        "  /wallops <text>   message all opers (requires oper)",
        "  /whois <n>        user info",
        "  /list             list channels",
        "  /names [#ch]      list members",
        "  /motd             show server MOTD",
        "  /raw <line>       send raw IRC line",
        "  /img <path>       embed image (Kitty terminals)",
        "  /clear            clear current buffer",
        "  /close            close current buffer tab",
        "  /quit [reason]    disconnect",
        "  /help             this help",
        "#{BOLD}Keys:#{RESET}",
        "  Alt/Ctrl+L/R      switch buffers",
        "  PageUp/Down       scroll",
        "  Up/Down           scroll 1 line",
        "  Ctrl+L            redraw",
        "  Ctrl+A/E          line start/end",
        "  Ctrl+K/U          kill to end/start",
      ].each { |l| push_status(l) }
    else
      push_status("Unknown command: /#{cmd} -- try /help")
    end

    render_full
  end

  # ---- Image embedding ---------------------------------------------------

  private def handle_img(path : String)
    if path.empty?
      push_status("Usage: /img <path-to-image>")
      return
    end
    unless @kitty
      push_status("[img] Kitty graphics not available in this terminal")
      return
    end
    seq = Kitty.encode_file(path)
    if seq.starts_with?("[kitty]")
      push_status(seq)
    else
      # Print the image inline in the message area
      # We add it to the buffer as a special sentinel so render picks it up
      ts = Time.local.to_s(@ts_fmt)
      active_buf.lines << "#{C_TIMESTAMP}#{ts}#{RESET} #{C_NICK_OWN}<#{@nick}>#{RESET} [image: #{File.basename(path)}]"
      # Emit the Kitty sequence directly -- it must go to the actual terminal
      # We save/restore cursor position around it
      print "\e[s"      # save cursor
      print "\e[999;1H" # move to bottom
      print seq
      print "\e[u" # restore cursor
      @conn.send("PRIVMSG #{active_buf.name} :[image: #{File.basename(path)}]")
    end
  end

  # ---- Message formatting ------------------------------------------------

  private def format_message(msg) : String
    ts = Time.local.to_s(@ts_fmt)

    case msg.command
    when "PRIVMSG", "NOTICE"
      sender = prefix_nick(msg)
      target = msg.params[0]? || ""
      body = msg.params[1]? || ""
      dest = target.starts_with?("#") ? target : sender
      ensure_buffer(dest)
      route(dest)

      is_action = body.starts_with?("\x01ACTION") && body.ends_with?("\x01")
      if is_action
        action_text = body[8..-2]
        line = "#{C_TIMESTAMP}#{ts}#{RESET} #{C_JOIN_PART}* #{sender} #{Markdown.render_inline(action_text)}#{RESET}"
      else
        nick_colour = nick_colour_for(sender)
        rendered = Markdown.render_inline(body)
        line = "#{C_TIMESTAMP}#{ts}#{RESET} #{nick_colour}<#{sender}>#{RESET} #{rendered}"
      end

      # Handle PONG back from server for lag calculation
      if msg.command == "NOTICE" && body.starts_with?("LAG")
        sent_ms = body[3..].to_i64?
        if sent_ms
          @lag_ms = Time.utc.to_unix_ms - sent_ms
        end
        return ""
      end

      push_to(dest, line, mention: body.downcase.includes?(@nick.downcase))
      ""
    when "PING"
      nonce = msg.params[0]? || ""
      @conn.send("PONG :#{nonce}")
      ""
    when "PONG"
      body = msg.params[1]? || msg.params[0]? || ""
      if body.starts_with?("LAG")
        sent_ms = body[3..].to_i64?
        @lag_ms = Time.utc.to_unix_ms - sent_ms if sent_ms
      end
      ""
    when "JOIN"
      sender = prefix_nick(msg)
      ch = msg.params[0]? || ""
      ensure_buffer(ch)
      route(ch)
      if sender == @nick
        push_status("Joined #{ch}")
      end
      line = "#{C_TIMESTAMP}#{ts}#{RESET} #{C_JOIN_PART}--> #{sender} joined #{ch}#{RESET}"
      push_to(ch, line)
      ""
    when "PART"
      sender = prefix_nick(msg)
      ch = msg.params[0]? || ""
      reason = msg.params[1]? || ""
      route(ch)
      line = "#{C_TIMESTAMP}#{ts}#{RESET} #{C_JOIN_PART}<-- #{sender} left #{ch} (#{reason})#{RESET}"
      push_to(ch, line)
      if sender == @nick
        @buffers.reject! { |b| b.name.downcase == ch.downcase }
        @active = [0, @active - 1].max
        render_full
      end
      ""
    when "KICK"
      kicker = prefix_nick(msg)
      ch = msg.params[0]? || ""
      kicked = msg.params[1]? || ""
      reason = msg.params[2]? || ""
      route(ch)
      line = "#{C_TIMESTAMP}#{ts}#{RESET} #{C_JOIN_PART}*** #{kicker} kicked #{kicked} from #{ch} (#{reason})#{RESET}"
      push_to(ch, line)
      if kicked == @nick
        @buffers.reject! { |b| b.name.downcase == ch.downcase }
        @active = [0, @active - 1].max
        push_status("You were kicked from #{ch} by #{kicker}: #{reason}")
        render_full
      end
      ""
    when "QUIT"
      sender = prefix_nick(msg)
      reason = msg.params[0]? || ""
      line = "#{C_TIMESTAMP}#{ts}#{RESET} #{C_JOIN_PART}!-- #{sender} quit (#{reason})#{RESET}"
      @buffers.each { |b| b.push(line) if b.name.starts_with?("#") }
      ""
    when "NICK"
      old_nick = prefix_nick(msg)
      new_nick = msg.params[0]? || ""
      if old_nick == @nick
        @nick = new_nick
        push_status("You are now known as #{new_nick}")
      end
      line = "#{C_TIMESTAMP}#{ts}#{RESET} #{C_JOIN_PART}*** #{old_nick} is now known as #{new_nick}#{RESET}"
      @buffers.each { |b| b.push(line) if b.name.starts_with?("#") }
      ""
    when "TOPIC"
      setter = prefix_nick(msg)
      ch = msg.params[0]? || ""
      topic = msg.params[1]? || ""
      route(ch)
      line = "#{C_TIMESTAMP}#{ts}#{RESET} #{C_JOIN_PART}*** #{setter} set topic: #{Markdown.render_inline(topic)}#{RESET}"
      push_to(ch, line)
      ""
    when "INVITE"
      inviter = prefix_nick(msg)
      ch = msg.params[1]? || ""
      push_status("#{inviter} invited you to #{ch}. Type /join #{ch} to join.")
      ""
    when "WALLOPS"
      sender = prefix_nick(msg)
      text = msg.params[0]? || ""
      push_status("#{C_MENTION}[WALLOPS] #{sender}: #{text}#{RESET}")
      ""
    when "ERROR"
      text = msg.params[0]? || ""
      push_status("#{C_MENTION}[ERROR] #{text}#{RESET}")
      ""
    when /\A\d{3}\z/
      code = msg.command.to_i
      text = msg.params.last? || ""
      handle_numeric(code, text, msg, ts)
      ""
    else
      ""
    end
  end

  private def handle_numeric(code : Int32, text : String, msg, ts : String)
    case code
    when 1, 2, 3, 4, 5
      push_status("#{C_SERVER}#{text}#{RESET}")
    when 372, 375, 376
      push_status("#{DIM}#{text}#{RESET}")
    when 332 # topic
      ch = msg.params[1]? || ""
      topic = msg.params[2]? || text
      push_to(ch, "#{C_TIMESTAMP}#{ts}#{RESET} #{C_JOIN_PART}Topic for #{ch}: #{Markdown.render_inline(topic)}#{RESET}")
    when 353 # NAMES
      ch = msg.params[2]? || ""
      nicks = msg.params[3]? || text
      push_to(ch, "#{C_TIMESTAMP}#{ts}#{RESET} #{DIM}[members: #{nicks}]#{RESET}")
    when 401, 403, 404, 421, 431, 432, 433, 442, 451, 461, 462, 464, 473, 474, 475, 481, 482
      push_status("#{C_MENTION}[#{code}] #{text}#{RESET}")
    when 341 # invite sent
      push_status("#{text}")
    when 381 # oper success
      push_status("#{C_SERVER}#{text}#{RESET}")
    else
      push_status("#{DIM}[#{code}] #{text}#{RESET}")
    end
  end

  # ---- Helpers -----------------------------------------------------------

  private def prefix_nick(msg) : String
    (msg.prefix.try(&.to_s) || "").split("!").first
  end

  private def mention?(text : String) : Bool
    text.downcase.includes?(@nick.downcase)
  end

  private def nick_colour_for(nick : String) : String
    case nick[0]?
    when '@' then C_NICK_OP
    when '+' then C_NICK_VOICE
    else
      idx = nick.bytes.sum % 6
      ["\e[38;5;81m", "\e[38;5;214m", "\e[38;5;119m",
       "\e[38;5;183m", "\e[38;5;87m", "\e[38;5;222m"][idx]
    end
  end

  private def ensure_buffer(name : String)
    key = name.downcase
    unless @buffers.any? { |b| b.name.downcase == key }
      @buffers << Buffer.new(name)
    end
  end

  private def buffer_index(name : String) : Int32
    key = name.downcase
    @buffers.index { |b| b.name.downcase == key } || 0
  end

  private def route(name : String)
    # Switch to the named buffer if it matches active
    # (no-op; messages are pushed directly)
  end

  private def push_to(name : String, line : String, mention : Bool = false)
    key = name.downcase
    buf = @buffers.find { |b| b.name.downcase == key }
    if buf
      buf.push(line, mention)
      buf.lines.shift if buf.lines.size > @scrollback
    end
  end

  private def push_status(text : String)
    ts = Time.local.to_s(@ts_fmt)
    line = "#{C_TIMESTAMP}#{ts}#{RESET} #{text}"
    @buffers[0].push(line)
    # Also mirror server messages to active channel buffer if it's not status
    if @active != 0
      @buffers[@active].push(line)
    end
  end

  # ---- String utilities --------------------------------------------------

  private def truncate_ansi(s : String, max_visible : Int32) : String
    return s if visible_len(s) <= max_visible
    out = String::Builder.new
    visible = 0
    i = 0
    bytes = s.bytes
    while i < bytes.size && visible < max_visible
      if bytes[i] == 0x1b
        j = i + 1
        while j < bytes.size && bytes[j] != 'm'.ord
          j += 1
        end
        j += 1
        bytes[i...j].each { |b| out << b.chr }
        i = j
      else
        out << bytes[i].chr
        visible += 1
        i += 1
      end
    end
    out << RESET
    out.to_s
  end

  private def visible_len(s : String) : Int32
    s.gsub(/\e\[[^m]*m/, "").size
  end
end
