# src/client/connection.cr
#
# Wraps an IRC server connection.
# Handles PING/PONG automatically in the read loop.

require "fast_irc"
require "../common/transport"

class IRCConnection
  getter io : IO

  def initialize(
    host : String,
    port : Int32,
    tls : Bool = false,
    proxy : String? = nil,
    tls_verify : Bool = true
  )
    @io = Transport.connect(host, port, tls: tls, proxy: proxy, tls_verify: tls_verify)
  end

  def send(line : String)
    @io.puts(line)
    @io.flush
  rescue ex
    STDERR.puts "[conn] send error: #{ex}"
  end

  # Yields each parsed FastIRC::Message. Handles PING transparently.
  def read_loop
    while line = @io.gets(chomp: true)
      next if line.empty?
      msg = FastIRC.parse_line(line)
      next unless msg
      if msg.command == "PING"
        nonce = msg.params[0]? || ""
        send("PONG :#{nonce}")
        next
      end
      yield msg
    end
  rescue ex
    STDERR.puts "[conn] read error: #{ex}"
  end

  def close
    @io.close rescue nil
  end
end