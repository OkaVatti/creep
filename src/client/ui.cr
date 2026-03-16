# src/client/ui.cr
#
# Terminal UI layout (ANSI escape sequences, no external TUI library required):
#
#   +--[#channel1] [#channel2*]----[status]--+
#   |                                         |
#   |   message area (scrollback)             |
#   |                                         |
#   +-----------------------------------------+
#   | Input: _                                |
#   +-----------------------------------------+
#
# Controls:
#   Alt+Left / Alt+Right  -- previous / next channel
#   /join #name           -- join channel
#   /part                 -- part current channel
#   /nick <new>           -- change nick
#   /msg <nick> <text>    -- PM
#   /quit [reason]        -- quit
#   /help                 -- print command list
#   /clear                -- clear scrollback for current buffer
#   Enter                 -- send message to current channel
#
# The UI runs entirely in the main fiber.
# A background fiber feeds incoming messages via a Channel(String).

require "./connection"
require "./input"
require "../common/markdown"

struct Buffer
  property name : String
  property lines : Array(String) = [] of String
  property unread : Int32 = 0
  property scroll : Int32 = 0 # lines scrolled up from bottom (0 = follow tail)

  def initialize(@name : String)
  end

  def push(line : String)
    @lines << line
    @unread += 1 if @scroll > 0
  end
end

class UI
  RESET   = "\e[0m"
  BOLD    = "\e[1m"
  DIM     = "\e[2m"
  REVERSE = "\e[7m"
  CLEAR   = "\e[2J"
  HOME    = "\e[H"
  HIDE_C  = "\e[?25l"
  SHOW_C  = "\e[?25h"
  SAVE_C  = "\e[s"
  REST_C  = "\e[u"

  def initialize(@conn : IRCConnection, @nick : String, autojoin : Array(String) = [] of String)
    @buffers = [Buffer.new("*status*")] of Buffer
    @active = 0
    @input_line = ""
    @cursor_pos = 0
    @incoming = ::Channel(String).new(256)
    @running = true
    @rows = 24
    @cols = 80
    autojoin.each { |ch| @buffers << Buffer.new(ch) }
  end

  def start
    # Raw mode + hide cursor
    system("stty raw -echo")
    print HIDE_C
    update_terminal_size

    # Background fiber: parse incoming messages -> push to channel
    spawn do
      @conn.read_loop do |msg|
        @incoming.send(format_message(msg))
      end
      @incoming.send("\x00EXIT")
    end

    # Render initial frame
    render_full

    # Main loop: alternate between terminal input and incoming messages
    input_reader = Input.new
    loop do
      # Non-blocking check for incoming messages
      begin
        while msg_text = @incoming.receive?
          if msg_text == "\x00EXIT"
            @running = false
            break
          end
          active_buf.push(msg_text)
          render_messages
          render_status_bar
          render_input_bar
        end
      end

      break unless @running

      # Check for keyboard input (100ms timeout via select-like poll)
      input_reader.read_char_timeout(0.1) do |ch|
        handle_key(ch, input_reader)
        render_messages
        render_status_bar
        render_input_bar
      end
    end
  ensure
    system("stty sane")
    print SHOW_C
    print "\n"
  end

  private def active_buf : Buffer
    @buffers[@active]
  end

  private def update_terminal_size
    if (ws = `stty size 2>/dev/null`.strip.split)
      @rows = ws[0].to_i if ws.size >= 2
      @cols = ws[1].to_i if ws.size >= 2
    end
    @rows = 24 if @rows < 8
    @cols = 80 if @cols < 40
  end

  # ---- Rendering -------------------------------------------------------

  private def render_full
    update_terminal_size
    print HIDE_C + CLEAR + HOME
    render_tab_bar
    render_messages
    render_status_bar
    render_input_bar
  end

  private def render_tab_bar
    print "\e[1;1H" # row 1, col 1
    bar = @buffers.each_with_index.map do |buf, i|
      badge = buf.unread > 0 ? "*" : ""
      if i == @active
        "#{REVERSE} #{buf.name}#{badge} #{RESET}"
      else
        " #{DIM}#{buf.name}#{badge}#{RESET} "
      end
    end.join("")
    print truncate(bar, @cols)
    print " " * [0, @cols - visible_length(bar)].max
  end

  private def render_messages
    msg_rows = @rows - 3 # tab bar (1) + status bar (1) + input bar (1)
    return if msg_rows < 1
    buf = active_buf
    buf.unread = 0

    lines = buf.lines
    start = [0, lines.size - msg_rows - buf.scroll].max
    visible = lines[start, msg_rows]

    (2..(msg_rows + 1)).each do |row|
      print "\e[#{row};1H\e[2K"
      idx = row - 2
      if idx < visible.size
        print truncate(visible[idx], @cols)
      end
    end
  end

  private def render_status_bar
    row = @rows - 1
    print "\e[#{row};1H"
    ch_name = active_buf.name
    status = "#{REVERSE} #{@nick} | #{ch_name} | #{Time.local.to_s("%H:%M")} #{RESET}"
    print truncate(status, @cols)
    print " " * [0, @cols - visible_length(status)].max
  end

  private def render_input_bar
    row = @rows
    print "\e[#{row};1H\e[2K"
    prompt = "> "
    visible_input = @input_line
    max_input = @cols - prompt.size - 1
    visible_input = visible_input[([0, visible_input.size - max_input].max)..]
    print "#{BOLD}#{prompt}#{RESET}#{visible_input}"
    # Position cursor
    cursor_col = prompt.size + [@cursor_pos, max_input].min + 1
    print "\e[#{row};#{cursor_col}H"
    print SHOW_C
  end

  # ---- Key handling ---------------------------------------------------

  private def handle_key(ch : String, input : Input)
    case ch
    when "\r", "\n"
      submit_input
    when "\x7f", "\b" # backspace
      if @cursor_pos > 0
        @input_line = @input_line[0, @cursor_pos - 1] + @input_line[@cursor_pos..]
        @cursor_pos -= 1
      end
    when "\e[C" # right arrow
      @cursor_pos = [@cursor_pos + 1, @input_line.size].min
    when "\e[D" # left arrow
      @cursor_pos = [@cursor_pos - 1, 0].max
    when "\e[A" # up arrow -- scroll up
      active_buf.scroll += 1
      render_messages
    when "\e[B" # down arrow -- scroll down
      active_buf.scroll = [active_buf.scroll - 1, 0].max
      render_messages
    when "\e[1;5C", "\e\e[C" # Alt+Right / Ctrl+Right -- next buffer
      @active = (@active + 1) % @buffers.size
      render_full
    when "\e[1;5D", "\e\e[D" # Alt+Left / Ctrl+Left -- prev buffer
      @active = (@active - 1 + @buffers.size) % @buffers.size
      render_full
    when "\x0c" # Ctrl+L -- force redraw
      render_full
    else
      if ch.size == 1 && ch.bytes[0] >= 0x20
        @input_line = @input_line[0, @cursor_pos] + ch + @input_line[@cursor_pos..]
        @cursor_pos += 1
      end
    end
  end

  private def submit_input
    line = @input_line.strip
    @input_line = ""
    @cursor_pos = 0
    return if line.empty?

    if line.starts_with?("/")
      handle_command(line)
    else
      target = active_buf.name
      unless target.starts_with?("#") || !@@nicks_known.nil?
        push_status("(not in a channel -- use /join #name)")
        return
      end
      @conn.send("PRIVMSG #{target} :#{line}")
      active_buf.push(format_own(target, line))
    end
  end

  private def handle_command(line : String)
    parts = line[1..].split(" ", 2)
    cmd = parts[0].downcase
    args = parts[1]? || ""

    case cmd
    when "join"
      channel = args.strip
      channel = "##{channel}" unless channel.starts_with?("#")
      unless @buffers.any? { |b| b.name == channel }
        @buffers << Buffer.new(channel)
      end
      @active = @buffers.index { |b| b.name == channel } || @active
      @conn.send("JOIN #{channel}")
    when "part"
      ch = args.empty? ? active_buf.name : args.strip
      @conn.send("PART #{ch}")
      @buffers.reject! { |b| b.name == ch }
      @active = [0, @active - 1].max
      render_full
    when "nick"
      newnick = args.strip
      if newnick.empty?
        push_status("usage: /nick <newnick>")
      else
        @nick = newnick
        @conn.send("NICK #{newnick}")
      end
    when "msg"
      sub = args.split(" ", 2)
      if sub.size < 2
        push_status("usage: /msg <nick> <message>")
      else
        target, text = sub[0], sub[1]
        @conn.send("PRIVMSG #{target} :#{text}")
        push_status("[-> #{target}] #{text}")
      end
    when "topic"
      ch = active_buf.name
      if args.empty?
        @conn.send("TOPIC #{ch}")
      else
        @conn.send("TOPIC #{ch} :#{args}")
      end
    when "me"
      target = active_buf.name
      @conn.send("PRIVMSG #{target} :\x01ACTION #{args}\x01")
    when "mode"
      @conn.send("MODE #{args}")
    when "whois"
      @conn.send("WHOIS #{args}")
    when "list"
      @conn.send("LIST")
    when "names"
      target = args.empty? ? active_buf.name : args
      @conn.send("NAMES #{target}")
    when "raw"
      @conn.send(args)
    when "quit"
      reason = args.empty? ? "Quit" : args
      @conn.send("QUIT :#{reason}")
      @running = false
    when "clear"
      active_buf.lines.clear
      active_buf.scroll = 0
      render_full
    when "help"
      help_lines = [
        "Commands:",
        "  /join #channel      join a channel",
        "  /part [#channel]    leave current or named channel",
        "  /nick <nick>        change nickname",
        "  /msg <nick> <text>  send private message",
        "  /me <action>        send CTCP ACTION",
        "  /topic [text]       get or set topic",
        "  /mode <args>        send a MODE command",
        "  /whois <nick>       show user info",
        "  /list               list channels",
        "  /names [#channel]   list members",
        "  /raw <line>         send raw IRC line",
        "  /clear              clear current buffer",
        "  /quit [reason]      disconnect and exit",
        "  Alt+Left/Right      switch buffers",
        "  Up/Down arrow       scroll messages",
        "  Ctrl+L              force redraw",
      ]
      help_lines.each { |l| push_status(l) }
    else
      push_status("Unknown command: /#{cmd} -- type /help for help")
    end
  end

  # ---- Message formatting ---------------------------------------------

  private def format_message(msg) : String
    ts = Time.local.to_s("%H:%M")
    case msg.command
    when "PRIVMSG", "NOTICE"
      sender = prefix_nick(msg)
      target = msg.params[0]? || ""
      body = msg.params[1]? || ""
      # Route to appropriate buffer
      dest = target.starts_with?("#") ? target : sender
      route_to_buffer(dest)
      ctcp = body =~ /\A\x01ACTION (.+)\x01\z/
      display_body = ctcp ? "* #{sender} #{$~[1]}" : "<#{sender}> #{Markdown.render_inline(body)}"
      "#{DIM}#{ts}#{RESET} #{display_body}"
    when "JOIN"
      sender = prefix_nick(msg)
      ch = msg.params[0]? || ""
      route_to_buffer(ch)
      "#{DIM}#{ts}#{RESET} #{DIM}--> #{sender} joined #{ch}#{RESET}"
    when "PART"
      sender = prefix_nick(msg)
      ch = msg.params[0]? || ""
      reason = msg.params[1]? || ""
      route_to_buffer(ch)
      "#{DIM}#{ts}#{RESET} #{DIM}<-- #{sender} left #{ch} (#{reason})#{RESET}"
    when "QUIT"
      sender = prefix_nick(msg)
      reason = msg.params[0]? || ""
      "#{DIM}#{ts}#{RESET} #{DIM}!-- #{sender} quit (#{reason})#{RESET}"
    when "NICK"
      old_nick = prefix_nick(msg)
      new_nick = msg.params[0]? || ""
      if old_nick == @nick
        @nick = new_nick
      end
      "#{DIM}#{ts}#{RESET} #{DIM}*** #{old_nick} is now known as #{new_nick}#{RESET}"
    when "TOPIC"
      sender = prefix_nick(msg)
      ch = msg.params[0]? || ""
      topic = msg.params[1]? || ""
      route_to_buffer(ch)
      "#{DIM}#{ts}#{RESET} #{DIM}*** #{sender} set topic: #{topic}#{RESET}"
    when /\A\d{3}\z/
      code = msg.command.to_i
      text = msg.params.last? || ""
      case code
      when 1, 2, 3, 4, 372, 375, 376
        push_status_raw("#{DIM}#{ts}#{RESET} #{text}")
        ""
      when 353 # NAMES
        ch = msg.params[2]? || ""
        nicks = msg.params[3]? || ""
        push_to_buffer(ch, "#{DIM}#{ts}#{RESET} #{DIM}[names #{ch}] #{nicks}#{RESET}")
        ""
      else
        push_status_raw("#{DIM}#{ts}#{RESET} [#{code}] #{text}")
        ""
      end
    else
      "#{DIM}#{ts}#{RESET} [#{msg.command}] #{msg.params.join(" ")}"
    end
  end

  private def format_own(target : String, text : String) : String
    ts = Time.local.to_s("%H:%M")
    "#{DIM}#{ts}#{RESET} <#{@nick}> #{Markdown.render_inline(text)}"
  end

  private def prefix_nick(msg : FastIRC::Message) : String
    p = msg.prefix
    return "" unless p
    p.to_s.split('!').first
  end

  private def route_to_buffer(name : String)
    key = name.downcase
    unless @buffers.any? { |b| b.name.downcase == key }
      @buffers << Buffer.new(name)
    end
  end

  private def push_to_buffer(name : String, text : String)
    return if text.empty?
    key = name.downcase
    buf = @buffers.find { |b| b.name.downcase == key }
    if buf
      buf.push(text)
    end
  end

  private def push_status(text : String)
    ts = Time.local.to_s("%H:%M")
    @buffers[0].push("#{DIM}#{ts}#{RESET} #{text}")
  end

  private def push_status_raw(text : String)
    return if text.empty?
    @buffers[0].push(text)
  end

  # Allow empty marker -- callers check .empty? before pushing
  @@nicks_known : Nil = nil

  # ---- String utilities -----------------------------------------------

  private def truncate(s : String, max : Int32) : String
    # Strips ANSI before measuring visible length, then truncates by byte
    vlen = visible_length(s)
    return s if vlen <= max
    # Rebuild until visible length is within budget
    out = String::Builder.new
    visible = 0
    i = 0
    bytes = s.bytes
    while i < bytes.size && visible < max
      if bytes[i] == 0x1b
        # consume escape sequence
        esc_start = i
        i += 1
        while i < bytes.size && bytes[i] != 'm'.ord
          i += 1
        end
        i += 1
        j = esc_start
        while j < i
          out << bytes[j].chr
          j += 1
        end
      else
        out << bytes[i].chr
        visible += 1
        i += 1
      end
    end
    out << RESET
    out.to_s
  end

  private def visible_length(s : String) : Int32
    s.gsub(/\e\[[^m]*m/, "").size
  end
end
