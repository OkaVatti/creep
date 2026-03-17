# src/client/ui.cr
#
# Terminal UI.
#
# Architecture
# ------------
# Two fibers run alongside the main fiber:
#   1. network_fiber  -- calls conn.read_loop, posts Event objects to @events
#   2. lag_fiber      -- sends periodic PING :LAGxxx to measure round-trip time
#
# The main fiber runs the render/input loop:
#   - Drains @events (non-blocking receive?)
#   - Calls Input#read_char_timeout(0.05) to poll the keyboard
#   - Renders on change
#
# All @buffers mutations happen on the main fiber only.
# The network fiber never touches @buffers directly -- it posts Event values.
#
# Pre-connection mode
# -------------------
# Before a connection is established the UI starts in offline mode.
# The user can type /server, /nick, /port, /tls, /proxy, /connect.
# Once /connect succeeds the normal IRC session begins.
#
# Connection state machine
# ------------------------
#   :offline  -> user has not connected yet
#   :connecting -> connection attempt in progress
#   :registering -> TCP connected, sent NICK/USER, waiting for 001
#   :connected  -> received 001, normal operation

require "./connection"
require "./input"
require "./kitty"
require "./chatlog"
require "../common/config"
require "../common/markdown"

# ---- Internal event types -----------------------------------------------

private alias MsgEvent  = FastIRC::Message
private alias ExitEvent = Symbol   # :exit
private alias RawEvent  = String   # pre-formatted status line (used for errors)

# ---- Buffer -----------------------------------------------------------------

class Buffer
  property name     : String
  property lines    : Array(String)
  property unread   : Int32
  property scroll   : Int32
  property activity : Symbol   # :none :activity :mention

  def initialize(@name : String)
    @lines    = [] of String
    @unread   = 0
    @scroll   = 0
    @activity = :none
  end

  def push(line : String, mention : Bool = false)
    @lines << line
    @unread += 1
    @activity = (mention ? :mention : :activity) if @activity != :mention
    @scroll  += 1 if @scroll > 0
  end

  def mark_read
    @unread   = 0
    @activity = :none
  end
end

# ---- UI ---------------------------------------------------------------------

class UI
  # ANSI
  RESET   = "\e[0m"
  BOLD    = "\e[1m"
  DIM     = "\e[2m"
  ITALIC  = "\e[3m"
  REVERSE = "\e[7m"
  CLEAR   = "\e[2J\e[H"
  HIDE_C  = "\e[?25l"
  SHOW_C  = "\e[?25h"

  # Colours (256-colour palette)
  C_TAB_ACTIVE   = "\e[38;5;15m\e[48;5;24m"
  C_TAB_ACTIVITY = "\e[38;5;11m"
  C_TAB_MENTION  = "\e[38;5;9m"
  C_STATUS_BAR   = "\e[38;5;15m\e[48;5;236m"
  C_DIVIDER      = "\e[38;5;240m"
  C_TIMESTAMP    = "\e[38;5;244m"
  C_JOIN_PART    = "\e[38;5;242m"
  C_NICK_OWN     = "\e[38;5;39m"
  C_NICK_OP      = "\e[38;5;220m"
  C_NICK_VOICE   = "\e[38;5;46m"
  C_MENTION      = "\e[38;5;196m"
  C_SERVER       = "\e[38;5;33m"
  C_DELETED      = "\e[38;5;238m\e[9m"
  C_EDITED       = "\e[38;5;248m\e[3m"
  C_OFFLINE      = "\e[38;5;240m"

  NICK_PALETTE = [
    "\e[38;5;81m",  "\e[38;5;214m", "\e[38;5;119m",
    "\e[38;5;183m", "\e[38;5;87m",  "\e[38;5;222m",
    "\e[38;5;159m", "\e[38;5;208m", "\e[38;5;156m",
  ]

  # Event channel: network fiber -> main fiber
  alias NetEvent = FastIRC::Message | Symbol | String
  @events : ::Channel(NetEvent)

  property autoconnect : Bool = false

  def initialize(@cfg : Config::ClientConfig)
    @nick        = @cfg.nick
    @server      = @cfg.server
    @port        = @cfg.port
    @tls         = @cfg.tls
    @tls_verify  = @cfg.tls_verify
    @proxy       = @cfg.proxy

    @conn        = nil.as(IRCConnection?)
    @state       = :offline.as(Symbol)

    @buffers     = [Buffer.new("*status*")] of Buffer
    @active      = 0
    @input_line  = ""
    @cursor_pos  = 0
    @events      = ::Channel(NetEvent).new(512)
    @running     = true
    @rows        = 24
    @cols        = 80
    @lag_ms      = 0_i64
    @scrollback  = @cfg.scrollback
    @ts_fmt      = @cfg.timestamp_format
    @kitty       = @cfg.kitty_graphics && Kitty.supported?
    @log         = ChatLog::Store.new(@cfg.log_db)
    @need_render = true
  end

  # ---- Public entry point -------------------------------------------------

  def start
    STDIN.raw! rescue nil
    update_terminal_size
    render_full

    push_status("#{BOLD}creep IRC client#{RESET} -- type #{BOLD}/help#{RESET} for commands")

    if @autoconnect && !@cfg.server.empty?
      push_status("Auto-connecting to #{@cfg.server}:#{@cfg.port}...")
      render_full
      do_connect
    else
      push_status("Not connected. Use #{BOLD}/connect#{RESET} or #{BOLD}/server <host>#{RESET} to connect.")
    end

    input_reader = Input.new

    loop do
      # --- drain network events (non-blocking) ---
      changed = false
      loop do
        ev = @events.receive?
        break unless ev
        case ev
        when FastIRC::Message
          process_server_msg(ev)
        when Symbol
          if ev == :exit
            @state = :offline
            push_status("#{C_MENTION}Disconnected from server.#{RESET}")
          end
        when String
          push_status(ev)
        end
        changed = true
      end

      # --- keyboard ---
      input_reader.read_char_timeout(0.05) do |key|
        handle_key(key)
        changed = true
      end

      render_full if changed
      break unless @running
    end
  ensure
    STDIN.cooked! rescue nil
    @log.close rescue nil
    print SHOW_C + "\n" + RESET
    @conn.try(&.close)
  end

  # ---- Connection management ----------------------------------------------

  private def do_connect
    push_status("Connecting to #{@server}:#{@port}#{@tls ? " (TLS)" : ""}#{@proxy ? " via #{@proxy}" : ""}...")
    @state = :connecting
    render_full

    conn = IRCConnection.new(
      host:       @server,
      port:       @port,
      tls:        @tls,
      proxy:      @proxy,
      tls_verify: @tls_verify
    )
    @conn = conn
    @state = :registering

    # Network reader fiber
    spawn do
      conn.read_loop do |msg|
        @events.send(msg)
      end
      @events.send(:exit)
    end

    # Lag ping fiber
    spawn do
      loop do
        sleep 30.seconds
        break unless conn.connected
        conn.send("PING :LAG#{Time.utc.to_unix_ms}")
      end
    end

    # Register
    conn.send("NICK #{@nick}")
    conn.send("USER #{@cfg.user} 0 * :#{@cfg.realname}")
    push_status("Sent NICK/USER, waiting for server welcome...")

  rescue ex
    @state = :offline
    @conn  = nil
    push_status("#{C_MENTION}Connection failed: #{ex.message}#{RESET}")
    push_status("Check server/port/tls settings. Use /server, /port, /tls, /connect.")
  end

  private def do_autojoin
    @conn.try do |c|
      c.send("JOIN #{ChatLog::SYNC_CHANNEL}")
      @cfg.autojoin.each { |ch| c.send("JOIN #{ch}") }
    end
  end

  # ---- Server message processing (called from main fiber) -----------------

  private def process_server_msg(msg : FastIRC::Message)
    ts      = Time.utc.to_unix_ms
    ts_disp = Time.local.to_s(@ts_fmt)

    case msg.command

    when "001"  # RPL_WELCOME -- registration complete
      @state = :connected
      text = msg.params.last? || ""
      push_status("#{C_SERVER}#{text}#{RESET}")
      push_status("#{C_SERVER}Connected to #{@server} as #{@nick}.#{RESET}")
      do_autojoin

    when "002", "003", "004", "005"
      text = msg.params.last? || ""
      push_status("#{C_SERVER}#{text}#{RESET}")

    when "372", "375", "376"
      text = msg.params.last? || ""
      push_status("#{DIM}#{text}#{RESET}")

    when "PING"
      nonce = msg.params[0]? || ""
      @conn.try(&.send("PONG :#{nonce}"))

    when "PONG"
      body = msg.params[1]? || msg.params[0]? || ""
      if body.starts_with?("LAG")
        sent = body[3..].to_i64?
        @lag_ms = Time.utc.to_unix_ms - sent if sent
      end

    when "PRIVMSG", "NOTICE"
      sender = prefix_nick(msg)
      target = msg.params[0]? || ""
      body   = msg.params[1]? || ""

      # Lag NOTICE
      if msg.command == "NOTICE" && body.starts_with?("LAG")
        sent = body[3..].to_i64?
        @lag_ms = Time.utc.to_unix_ms - sent if sent
        return
      end

      # Creep sync/moderation
      if target == ChatLog::SYNC_CHANNEL && msg.command == "NOTICE"
        handle_sync_notice(body, sender)
        return
      end
      if body.starts_with?("CREEP:") && msg.command == "NOTICE"
        handle_creep_notice(body[6..], ts_disp)
        return
      end

      dest = target.starts_with?("#") ? target : sender
      ensure_buffer(dest)

      is_action = body.starts_with?("\x01ACTION") && body.ends_with?("\x01")
      line = if is_action
        action = body[8..-2]
        "#{C_TIMESTAMP}#{ts_disp}#{RESET} #{C_JOIN_PART}* #{sender} #{Markdown.render_inline(action)}#{RESET}"
      else
        "#{C_TIMESTAMP}#{ts_disp}#{RESET} #{nick_colour(sender)}<#{sender}>#{RESET} #{Markdown.render_inline(body)}"
      end

      msg_id = generate_msg_id(ts, sender, dest)
      @log.insert(@server, dest, ts, sender, ChatLog::ROLE_USER, msg_id, body)
      push_to(dest, line, mention: body.downcase.includes?(@nick.downcase))

    when "JOIN"
      sender = prefix_nick(msg)
      ch     = (msg.params[0]? || "").strip.split(" ").first  # strip any trailing params
      ch     = ch[1..] if ch.starts_with?(":") # some servers include colon
      ch     = ":#{ch}" unless ch.starts_with?("#")
      # normalise: remove leading colon if present
      ch = ch.lstrip(':')
      ch = "##{ch}" unless ch.starts_with?("#")

      ensure_buffer(ch)
      if sender == @nick
        push_status("Joined #{ch}")
        @active = buf_idx(ch)
        load_log_into_buffer(ch)
      end
      push_to(ch, "#{C_TIMESTAMP}#{ts_disp}#{RESET} #{C_JOIN_PART}--> #{sender} joined #{ch}#{RESET}")

    when "PART"
      sender = prefix_nick(msg)
      ch     = msg.params[0]? || ""
      reason = msg.params[1]? || ""
      push_to(ch, "#{C_TIMESTAMP}#{ts_disp}#{RESET} #{C_JOIN_PART}<-- #{sender} left #{ch} (#{reason})#{RESET}")
      if sender == @nick
        @buffers.reject! { |b| b.name.downcase == ch.downcase }
        @active = [0, @active - 1].max
      end

    when "KICK"
      kicker = prefix_nick(msg)
      ch     = msg.params[0]? || ""
      kicked = msg.params[1]? || ""
      reason = msg.params[2]? || ""
      push_to(ch, "#{C_TIMESTAMP}#{ts_disp}#{RESET} #{C_JOIN_PART}*** #{kicker} kicked #{kicked} from #{ch} (#{reason})#{RESET}")
      if kicked == @nick
        @buffers.reject! { |b| b.name.downcase == ch.downcase }
        @active = [0, @active - 1].max
        push_status("You were kicked from #{ch} by #{kicker}: #{reason}")
      end

    when "QUIT"
      sender = prefix_nick(msg)
      reason = msg.params[0]? || ""
      line   = "#{C_TIMESTAMP}#{ts_disp}#{RESET} #{C_JOIN_PART}!-- #{sender} quit (#{reason})#{RESET}"
      @buffers.each { |b| b.push(line) if b.name.starts_with?("#") }

    when "NICK"
      old_nick = prefix_nick(msg)
      new_nick = msg.params[0]? || ""
      if old_nick == @nick
        @nick = new_nick
        push_status("You are now known as #{new_nick}")
      end
      line = "#{C_TIMESTAMP}#{ts_disp}#{RESET} #{C_JOIN_PART}*** #{old_nick} is now known as #{new_nick}#{RESET}"
      @buffers.each { |b| b.push(line) if b.name.starts_with?("#") }

    when "TOPIC"
      setter = prefix_nick(msg)
      ch     = msg.params[0]? || ""
      topic  = msg.params[1]? || ""
      push_to(ch, "#{C_TIMESTAMP}#{ts_disp}#{RESET} #{C_JOIN_PART}*** #{setter} set topic: #{Markdown.render_inline(topic)}#{RESET}")

    when "INVITE"
      inviter = prefix_nick(msg)
      ch      = msg.params[1]? || ""
      push_status("#{inviter} invited you to #{ch}. /join #{ch}")

    when "WALLOPS"
      sender = prefix_nick(msg)
      text   = msg.params[0]? || ""
      push_status("#{C_MENTION}[WALLOPS] #{sender}: #{text}#{RESET}")

    when "ERROR"
      text = msg.params[0]? || ""
      push_status("#{C_MENTION}[ERROR] #{text}#{RESET}")
      @state = :offline

    when "332"  # RPL_TOPIC
      ch    = msg.params[1]? || ""
      topic = msg.params[2]? || msg.params.last? || ""
      push_to(ch, "#{C_TIMESTAMP}#{ts_disp}#{RESET} #{C_JOIN_PART}Topic: #{Markdown.render_inline(topic)}#{RESET}")

    when "353"  # RPL_NAMREPLY
      ch    = msg.params[2]? || ""
      nicks = msg.params[3]? || msg.params.last? || ""
      push_to(ch, "#{C_TIMESTAMP}#{ts_disp}#{RESET} #{DIM}[members: #{nicks}]#{RESET}")

    when "381"  # RPL_YOUREOPER
      push_status("#{C_SERVER}#{msg.params.last? || ""}#{RESET}")

    when "341"  # RPL_INVITING
      push_status(msg.params.last? || "")

    when /\A\d{3}\z/
      code = msg.command.to_i
      text = msg.params.last? || ""
      case code
      when 401, 403, 404, 421, 431, 432, 433, 442, 451, 461, 462, 464, 473, 474, 475, 481, 482
        push_status("#{C_MENTION}[#{code}] #{text}#{RESET}")
      else
        push_status("#{DIM}[#{code}] #{text}#{RESET}")
      end
    end
  end

  # ---- Creep protocol -----------------------------------------------------

  private def handle_creep_notice(payload : String, ts_disp : String)
    begin
      data    = JSON.parse(payload)
      action  = data["action"]?.try(&.as_s) || ""
      msg_id  = data["msg_id"]?.try(&.as_s) || ""
      channel = data["channel"]?.try(&.as_s) || ""
      case action
      when "delete"
        @log.delete(msg_id, "server", ChatLog::ROLE_ADMIN)
        push_to(channel, "#{C_TIMESTAMP}#{ts_disp}#{RESET} #{C_DELETED}[message deleted]#{RESET}")
      when "suppress"
        @log.suppress(msg_id, ChatLog::ROLE_ADMIN)
      when "edit"
        new_body = data["body"]?.try(&.as_s) || ""
        @log.edit(msg_id, new_body, "server", ChatLog::ROLE_ADMIN)
        push_to(channel, "#{C_TIMESTAMP}#{ts_disp}#{RESET} #{C_EDITED}[edited: #{Markdown.render_inline(new_body)}]#{RESET}")
      end
    rescue
    end
  end

  private def handle_sync_notice(payload : String, sender : String)
    begin
      data    = JSON.parse(payload)
      records = data["records"]?.try(&.as_a) || return
      channel = data["channel"]?.try(&.as_s) || return
      role    = data["role"]?.try(&.as_i) || ChatLog::ROLE_USER
      records.each do |r|
        rec = {} of String => String
        r.as_h.each { |k, v| rec[k.to_s] = v.to_s }
        @log.apply_sync(@server, channel, rec, role)
      end
    rescue
    end
  end

  # ---- Log helpers --------------------------------------------------------

  private def load_log_into_buffer(channel : String)
    buf = @buffers.find { |b| b.name.downcase == channel.downcase }
    return unless buf
    rows = @log.recent(@server, channel, 100)
    rows.each do |row|
      ts_disp = Time.unix_ms(row[:ts]).to_local.to_s(@ts_fmt)
      line = if row[:deleted]
        "#{C_TIMESTAMP}#{ts_disp}#{RESET} #{C_DELETED}[deleted message]#{RESET}"
      elsif (eb = row[:edited_body])
        "#{C_TIMESTAMP}#{ts_disp}#{RESET} #{nick_colour(row[:sender_nick])}<#{row[:sender_nick]}>#{RESET} #{Markdown.render_inline(eb)} #{C_EDITED}(edited)#{RESET}"
      else
        "#{C_TIMESTAMP}#{ts_disp}#{RESET} #{nick_colour(row[:sender_nick])}<#{row[:sender_nick]}>#{RESET} #{Markdown.render_inline(row[:body])}"
      end
      buf.lines.unshift(line)
    end
    while buf.lines.size > @scrollback
      buf.lines.shift
    end
  end

  private def generate_msg_id(ts : Int64, sender : String, channel : String) : String
    "#{ts}-#{sender}-#{channel}-#{Random::Secure.hex(4)}"
  end

  # ---- Rendering ----------------------------------------------------------

  private def active_buf : Buffer
    @buffers[@active]
  end

  private def update_terminal_size
    parts = `stty size 2>/dev/null`.strip.split
    r = parts[0].to_i? || 24
    c = parts[1].to_i? || 80
    @rows = [r, 8].max
    @cols = [c, 40].max
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
        col = case buf.activity
              when :mention  then C_TAB_MENTION
              when :activity then C_TAB_ACTIVITY
              else                DIM
              end
        bar << col << " #{buf.name}#{badge} " << RESET
      end
    end
    s = bar.to_s
    print trunc(s, @cols) + " " * [0, @cols - vlen(s)].max
  end

  private def render_divider(row : Int32)
    print "\e[#{row};1H#{C_DIVIDER}#{"─" * @cols}#{RESET}"
  end

  private def render_messages
    msg_rows = @rows - 4
    return if msg_rows < 1
    buf    = active_buf
    buf.mark_read
    total  = buf.lines.size
    scroll = [[buf.scroll, [0, total - msg_rows].max].min, 0].max
    buf.scroll = scroll
    start   = [0, total - msg_rows - scroll].max
    visible = buf.lines[start, msg_rows]
    (3..(msg_rows + 2)).each do |row|
      print "\e[#{row};1H\e[2K"
      idx = row - 3
      print trunc(visible[idx], @cols) if idx < visible.size
    end
  end

  private def render_status_bar
    lag   = @lag_ms > 0 ? " lag:#{@lag_ms}ms" : ""
    state_indicator = case @state
                      when :offline     then " #{C_OFFLINE}[offline]#{RESET}#{C_STATUS_BAR}"
                      when :connecting  then " #{C_MENTION}[connecting...]#{RESET}#{C_STATUS_BAR}"
                      when :registering then " #{C_TAB_ACTIVITY}[registering...]#{RESET}#{C_STATUS_BAR}"
                      else                   ""
                      end
    left  = " #{@nick} | #{active_buf.name}#{lag}#{state_indicator} "
    right = " #{Time.local.to_s(@ts_fmt)} "
    pad   = [0, @cols - vlen(left) - vlen(right)].max
    print "\e[#{@rows - 1};1H#{C_STATUS_BAR}#{left}#{" " * pad}#{right}#{RESET}"
  end

  private def render_input_bar
    row   = @rows
    max_w = [1, @cols - 3].max
    # Show only the tail of the input that fits
    disp  = @input_line.size > max_w ? @input_line[(@input_line.size - max_w)..] : @input_line
    # Compute cursor column relative to the displayed tail
    tail_start = @input_line.size > max_w ? @input_line.size - max_w : 0
    cur_in_disp = [@cursor_pos - tail_start, 0].max
    cur_col = 3 + [cur_in_disp, max_w].min
    print "\e[#{row};1H\e[2K#{BOLD}> #{RESET}#{disp}\e[#{row};#{cur_col}H#{SHOW_C}"
  end

  # ---- Key handling -------------------------------------------------------

  private def handle_key(ch : String)
    case ch
    when "\r", "\n"
      submit_input

    when "\x7f", "\b"   # Backspace
      if @cursor_pos > 0
        @input_line = @input_line[0, @cursor_pos - 1] + @input_line[@cursor_pos..]
        @cursor_pos -= 1
      end

    when "\e[3~"        # Delete key (forward delete)
      if @cursor_pos < @input_line.size
        @input_line = @input_line[0, @cursor_pos] + @input_line[@cursor_pos + 1..]
      end

    when "\e[C"         # Right arrow
      @cursor_pos = [@cursor_pos + 1, @input_line.size].min

    when "\e[D"         # Left arrow
      @cursor_pos = [@cursor_pos - 1, 0].max

    when "\e[A"         # Up -- scroll up 1
      active_buf.scroll += 1

    when "\e[B"         # Down -- scroll down 1
      active_buf.scroll = [active_buf.scroll - 1, 0].max

    when "\e[5~"        # Page Up
      active_buf.scroll += (@rows - 4)

    when "\e[6~"        # Page Down
      active_buf.scroll = [active_buf.scroll - (@rows - 4), 0].max

    when "\e[1;5C", "\e[1;3C", "\e\e[C"   # Ctrl/Alt + Right -- next buffer
      @active = (@active + 1) % @buffers.size

    when "\e[1;5D", "\e[1;3D", "\e\e[D"   # Ctrl/Alt + Left -- prev buffer
      @active = (@active - 1 + @buffers.size) % @buffers.size

    when "\x01"   # Ctrl+A -- beginning of line
      @cursor_pos = 0

    when "\x05"   # Ctrl+E -- end of line
      @cursor_pos = @input_line.size

    when "\x0b"   # Ctrl+K -- kill to end of line
      @input_line = @input_line[0, @cursor_pos]

    when "\x15"   # Ctrl+U -- kill to start of line
      @input_line = @input_line[@cursor_pos..]
      @cursor_pos = 0

    when "\x0c"   # Ctrl+L -- force redraw
      render_full

    when "\x03"   # Ctrl+C
      push_status("Use /quit to disconnect and exit.")

    when "\x04"   # Ctrl+D -- EOF / quit
      @conn.try(&.send("QUIT :Quit"))
      @running = false

    else
      # Printable input: insert at cursor position
      # Filter out lone control bytes that slipped through
      if ch.size >= 1 && (ch.bytes[0] >= 0x20 || ch.size > 1)
        @input_line = @input_line[0, @cursor_pos] + ch + @input_line[@cursor_pos..]
        @cursor_pos += ch.size
      end
    end
  end

  # ---- Input submission ---------------------------------------------------

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
    if @state != :connected
      push_status("Not connected. Use /connect first.")
      return
    end
    unless target.starts_with?("#") || (!target.empty? && target != "*status*")
      push_status("Not in a channel. Use /join #channel")
      return
    end
    c = @conn
    unless c
      push_status("Not connected.")
      return
    end
    c.send("PRIVMSG #{target} :#{text}")
    ts      = Time.utc.to_unix_ms
    ts_disp = Time.local.to_s(@ts_fmt)
    msg_id  = generate_msg_id(ts, @nick, target)
    @log.insert(@server, target, ts, @nick, ChatLog::ROLE_USER, msg_id, text)
    active_buf.lines << "#{C_TIMESTAMP}#{ts_disp}#{RESET} #{C_NICK_OWN}<#{@nick}>#{RESET} #{Markdown.render_inline(text)}"
    active_buf.scroll += 1 if active_buf.scroll > 0
  end

  # ---- Command handling ---------------------------------------------------

  private def handle_command(raw : String)
    parts = raw.split(" ", 2)
    cmd   = parts[0].downcase
    args  = parts[1]? || ""

    # Pre-connection commands available in all states
    case cmd
    when "server"
      h = args.strip
      if h.empty?
        push_status("Current server: #{@server}:#{@port} tls=#{@tls}")
      else
        @server = h
        push_status("Server set to #{@server} (use /connect to connect)")
      end
      return

    when "port"
      p = args.strip.to_i?
      if p
        @port = p
        push_status("Port set to #{@port}")
      else
        push_status("Usage: /port <number>")
      end
      return

    when "tls"
      case args.strip.downcase
      when "on", "true", "1"
        @tls = true
        push_status("TLS enabled")
      when "off", "false", "0"
        @tls = false
        push_status("TLS disabled")
      else
        push_status("TLS is #{@tls ? "on" : "off"}. Use /tls on|off")
      end
      return

    when "proxy"
      p = args.strip
      if p.empty? || p == "none" || p == "null"
        @proxy = nil
        push_status("Proxy cleared")
      else
        @proxy = p
        push_status("Proxy set to #{@proxy}")
      end
      return

    when "connect"
      if @state == :connected || @state == :registering
        push_status("Already connected. /disconnect first, or /quit.")
      else
        target = args.strip
        if !target.empty?
          parts2 = target.split(":")
          @server = parts2[0]
          @port   = parts2[1]?.try(&.to_i?) || @port
        end
        do_connect
      end
      return

    when "disconnect"
      @conn.try do |c|
        c.send("QUIT :#{args.empty? ? "Disconnecting" : args}")
        c.close
      end
      @conn  = nil
      @state = :offline
      push_status("Disconnected.")
      return

    when "nick"
      n = args.strip
      if n.empty?
        push_status("Current nick: #{@nick}. Usage: /nick <newnick>")
      else
        @nick = n
        @conn.try(&.send("NICK #{n}"))
        push_status("Nick set to #{n}#{@state == :connected ? "" : " (will use on next connect)"}")
      end
      return

    when "quit"
      reason = args.empty? ? "Quit" : args
      @conn.try(&.send("QUIT :#{reason}"))
      @running = false
      return

    when "help"
      show_help
      return
    end

    # Commands that require a connection
    if @state != :connected
      push_status("Not connected. Use /connect to connect first. Type /help for help.")
      return
    end

    c = @conn.not_nil!

    case cmd
    when "join"
      ch = args.strip
      ch = "##{ch}" unless ch.starts_with?("#") || ch.empty?
      if ch.empty?
        push_status("Usage: /join #channel")
      else
        ensure_buffer(ch)
        @active = buf_idx(ch)
        c.send("JOIN #{ch}")
      end

    when "part"
      ch = args.empty? ? active_buf.name : args.strip
      c.send("PART #{ch} :Leaving")

    when "msg"
      sub = args.split(" ", 2)
      sub.size < 2 ? push_status("Usage: /msg <nick> <message>") : c.send("PRIVMSG #{sub[0]} :#{sub[1]}")

    when "me"
      c.send("PRIVMSG #{active_buf.name} :\x01ACTION #{args}\x01")

    when "topic"
      ch = active_buf.name
      args.empty? ? c.send("TOPIC #{ch}") : c.send("TOPIC #{ch} :#{args}")

    when "kick"
      sub = args.split(" ", 2)
      sub.empty? ? push_status("Usage: /kick <nick> [reason]") :
        c.send("KICK #{active_buf.name} #{sub[0]} :#{sub[1]? || @nick}")

    when "invite"
      sub = args.split(" ", 2)
      sub[0]? ? c.send("INVITE #{sub[0]} #{sub[1]? || active_buf.name}") :
        push_status("Usage: /invite <nick> [#channel]")

    when "ban"
      args.strip.empty? ? c.send("MODE #{active_buf.name} +b") :
        c.send("MODE #{active_buf.name} +b #{args.strip}")

    when "unban"  then c.send("MODE #{active_buf.name} -b #{args.strip}")
    when "op"     then c.send("MODE #{active_buf.name} +o #{args.strip}")
    when "deop"   then c.send("MODE #{active_buf.name} -o #{args.strip}")
    when "voice"  then c.send("MODE #{active_buf.name} +v #{args.strip}")
    when "devoice" then c.send("MODE #{active_buf.name} -v #{args.strip}")
    when "mode"   then c.send("MODE #{args}")
    when "oper"
      sub = args.split(" ", 2)
      sub.size < 2 ? push_status("Usage: /oper <name> <password>") :
        c.send("OPER #{sub[0]} #{sub[1]}")

    when "wallops" then c.send("WALLOPS :#{args}")
    when "whois"   then c.send("WHOIS #{args}")
    when "list"    then c.send("LIST")
    when "names"
      t = args.empty? ? active_buf.name : args
      c.send("NAMES #{t}")
    when "motd"    then c.send("MOTD")
    when "raw"     then c.send(args)

    when "img"     then handle_img(args.strip)

    when "delmsg"
      mid = args.strip
      if mid.empty?
        push_status("Usage: /delmsg <msg_id>")
      elsif @log.delete(mid, @nick, ChatLog::ROLE_USER)
        push_status("Deleted locally.")
        payload = {action: "delete", msg_id: mid, channel: active_buf.name}.to_json
        c.send("NOTICE #{ChatLog::SYNC_CHANNEL} :CREEP:#{payload}")
      else
        push_status("Could not delete: insufficient role or not found.")
      end

    when "editmsg"
      sub = args.split(" ", 2)
      if sub.size < 2
        push_status("Usage: /editmsg <msg_id> <new text>")
      elsif @log.edit(sub[0], sub[1], @nick, ChatLog::ROLE_USER)
        push_status("Edited locally.")
        payload = {action: "edit", msg_id: sub[0], channel: active_buf.name, body: sub[1]}.to_json
        c.send("NOTICE #{ChatLog::SYNC_CHANNEL} :CREEP:#{payload}")
      else
        push_status("Could not edit: insufficient role or not found.")
      end

    when "sync"
      channel = args.empty? ? active_buf.name : args.strip
      do_sync(channel)

    when "clear"
      active_buf.lines.clear
      active_buf.scroll = 0

    when "close"
      if @buffers.size > 1
        @buffers.delete_at(@active)
        @active = [0, @active - 1].max
      end

    else
      push_status("Unknown command /#{cmd}. Type /help for help.")
    end
  end

  private def show_help
    [
      "#{BOLD}Connection#{RESET}",
      "  /server <host[:port]>   set server (or just host)",
      "  /port <n>               set port",
      "  /tls on|off             toggle TLS",
      "  /proxy <url>|none       set SOCKS5 proxy (Tor/I2P)",
      "  /connect [host[:port]]  connect to server",
      "  /disconnect [reason]    disconnect",
      "  /nick <n>               set nick (before or after connect)",
      "#{BOLD}Channels#{RESET}",
      "  /join #ch               join channel",
      "  /part [#ch]             leave channel",
      "  /topic [text]           get or set topic",
      "  /list                   list channels on server",
      "  /names [#ch]            list members",
      "  /invite <n> [#ch]       invite user",
      "#{BOLD}Messaging#{RESET}",
      "  /msg <nick> <text>      private message",
      "  /me <action>            CTCP ACTION",
      "  /delmsg <id>            delete a message",
      "  /editmsg <id> <text>    edit a message",
      "  /sync [#ch]             sync chat logs",
      "  /img <path>             embed image (Kitty terminals)",
      "#{BOLD}Moderation#{RESET}",
      "  /kick <n> [reason]      kick user",
      "  /ban [mask]             ban (no mask = list bans)",
      "  /unban <mask>           remove ban",
      "  /op /deop /voice /devoice <n>",
      "  /mode <args>            raw MODE",
      "  /oper <n> <pw>          IRC operator auth",
      "  /wallops <text>         message all opers",
      "#{BOLD}Other#{RESET}",
      "  /whois <n>              user info",
      "  /motd                   server MOTD",
      "  /raw <line>             raw IRC line",
      "  /clear                  clear buffer",
      "  /close                  close buffer tab",
      "  /quit [reason]          exit",
      "#{BOLD}Keys#{RESET}",
      "  Alt/Ctrl + Left/Right   switch buffers",
      "  PageUp/Down, Up/Down    scroll",
      "  Ctrl+A/E                line start/end",
      "  Ctrl+K/U                kill to end/start",
      "  Ctrl+L                  redraw",
      "  Ctrl+D                  quit",
    ].each { |l| push_status(l) }
  end

  private def do_sync(channel : String)
    c = @conn
    return push_status("Not connected.") unless c
    since   = @log.last_ts(@server, channel)
    records = @log.sync_payload(@server, channel, since)
    return push_status("Nothing to sync for #{channel}.") if records.empty?
    payload = {channel: channel, role: ChatLog::ROLE_USER, records: records}.to_json
    max_body = IRCConnection::MAX_LINE - "NOTICE  :CREEP:".bytesize - ChatLog::SYNC_CHANNEL.bytesize
    if payload.bytesize <= max_body
      c.send("NOTICE #{ChatLog::SYNC_CHANNEL} :CREEP:#{payload}")
      push_status("Synced #{records.size} records for #{channel}.")
    else
      push_status("Sync payload too large (#{payload.bytesize} bytes). Feature: chunked sync planned.")
    end
  end

  # ---- Image embedding ----------------------------------------------------

  private def handle_img(path : String)
    if path.empty?
      push_status("Usage: /img <path>")
      return
    end
    unless @kitty
      push_status("[img] Kitty graphics not available in this terminal (set TERM=xterm-kitty)")
      return
    end
    seq = Kitty.encode_file(path)
    if seq.starts_with?("[kitty]")
      push_status(seq)
    else
      ts_disp = Time.local.to_s(@ts_fmt)
      active_buf.lines << "#{C_TIMESTAMP}#{ts_disp}#{RESET} #{C_NICK_OWN}<#{@nick}>#{RESET} [image: #{File.basename(path)}]"
      print "\e[s\e[999;1H#{seq}\e[u"
      @conn.try(&.send("PRIVMSG #{active_buf.name} :[image: #{File.basename(path)}]"))
    end
  end

  # ---- Helpers ------------------------------------------------------------

  private def prefix_nick(msg : FastIRC::Message) : String
    (msg.prefix.try(&.to_s) || "").split("!").first
  end

  private def mention?(text : String) : Bool
    text.downcase.includes?(@nick.downcase)
  end

  private def nick_colour(nick : String) : String
    return C_NICK_OP    if nick.starts_with?("@")
    return C_NICK_VOICE if nick.starts_with?("+")
    NICK_PALETTE[nick.bytes.sum % NICK_PALETTE.size]
  end

  private def ensure_buffer(name : String)
    key = name.downcase
    @buffers << Buffer.new(name) unless @buffers.any? { |b| b.name.downcase == key }
  end

  private def buf_idx(name : String) : Int32
    key = name.downcase
    @buffers.index { |b| b.name.downcase == key } || 0
  end

  private def push_to(name : String, line : String, mention : Bool = false)
    key = name.downcase
    buf = @buffers.find { |b| b.name.downcase == key }
    if buf
      buf.push(line, mention)
      while buf.lines.size > @scrollback
        buf.lines.shift
      end
    end
  end

  private def push_status(text : String)
    ts_disp = Time.local.to_s(@ts_fmt)
    line    = "#{C_TIMESTAMP}#{ts_disp}#{RESET} #{text}"
    @buffers[0].push(line)
    @buffers[@active].push(line) if @active != 0
  end

  # ANSI-aware truncation
  private def trunc(s : String, max : Int32) : String
    return s if vlen(s) <= max
    out     = String::Builder.new
    visible = 0
    i       = 0
    bytes   = s.bytes
    while i < bytes.size && visible < max
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

  private def vlen(s : String) : Int32
    s.gsub(/\e\[[^m]*m/, "").size
  end
end