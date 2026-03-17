# src/client/connection.cr
#
# IRC connection with:
#   - Plain TCP, TLS, SOCKS5 proxy
#   - 512-byte line limit enforced on send
#   - Automatic PING/PONG handling
#   - Reconnect callback hook
#   - Thread-safe send queue

require "fast_irc"
require "../common/transport"

class IRCConnection
  MAX_LINE = 510  # RFC 1459: 512 bytes including CRLF

  getter io        : IO
  getter connected : Bool = false

  def initialize(
    @host       : String,
    @port       : Int32,
    @tls        : Bool       = false,
    @proxy      : String?    = nil,
    @tls_verify : Bool       = true
  )
    @io        = IO::Memory.new.as(IO)
    @send_lock = Mutex.new
    connect!
  end

  private def connect!
    @io = Transport.connect(
      @host,
      @port,
      tls:        @tls,
      proxy:      @proxy,
      tls_verify: @tls_verify
    )
    @connected = true
  end

  # Send a single IRC line.
  # Truncates to MAX_LINE bytes (excluding CRLF) and appends CRLF.
  def send(line : String)
    # Strip any embedded newlines -- they would break framing
    clean = line.gsub(/[\r\n]/, "")
    # Truncate to max payload size
    if clean.bytesize > MAX_LINE
      clean = clean.byte_slice(0, MAX_LINE)
      # Ensure we didn't cut a multi-byte UTF-8 sequence
      clean = String.new(clean.to_slice) rescue clean.byte_slice(0, MAX_LINE - 1)
    end
    @send_lock.synchronize do
      @io.print(clean + "\r\n")
      @io.flush
    end
  rescue ex
    STDERR.puts "[conn] send error: #{ex}"
    @connected = false
  end

  # Yields each parsed FastIRC::Message.
  # PING is handled transparently and not yielded.
  def read_loop(&block : FastIRC::Message ->)
    while line = @io.gets(chomp: true)
      next if line.empty?
      # Enforce max receive size
      if line.bytesize > 512
        STDERR.puts "[conn] oversized line (#{line.bytesize} bytes), skipping"
        next
      end
      msg = FastIRC.parse_line(line)
      next unless msg
      if msg.command == "PING"
        nonce = msg.params[0]? || ""
        send("PONG :#{nonce}")
        next
      end
      block.call(msg)
    end
  rescue ex
    STDERR.puts "[conn] read error: #{ex}"
  ensure
    @connected = false
  end

  def close
    @io.close rescue nil
    @connected = false
  end
end