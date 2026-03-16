# src/common/transport.cr
#
# Establishes a connected IO to a remote IRC server.
# Supports:
#   - Plain TCP
#   - TLS (OpenSSL)
#   - SOCKS5 proxy (Tor: socks5://127.0.0.1:9050,
#                   I2P: socks5://127.0.0.1:4447,
#                   I2P+: socks5://127.0.0.1:4448)
#
# Usage:
#   io = Transport.connect(host, port, tls: true, proxy: "socks5://127.0.0.1:9050")

require "socket"
require "openssl"
require "uri"

module Transport
  # Returns a ready-to-use IO connected to host:port.
  # If proxy is set it tunnels through SOCKS5 first, then optionally wraps TLS.
  def self.connect(
    host : String,
    port : Int32,
    tls : Bool = false,
    proxy : String? = nil,
    tls_verify : Bool = true
  ) : IO
    raw = if proxy
      Socks5.connect(proxy, host, port)
    else
      TCPSocket.new(host, port)
    end

    if tls
      ctx = OpenSSL::SSL::Context::Client.new
      ctx.verify_mode = OpenSSL::SSL::VerifyMode::NONE unless tls_verify
      OpenSSL::SSL::Socket::Client.new(raw, context: ctx, hostname: host, sync_close: true)
    else
      raw
    end
  end
end

# Minimal no-auth SOCKS5 dialer.
module Socks5
  def self.connect(proxy_url : String, dest_host : String, dest_port : Int32) : TCPSocket
    uri = URI.parse(proxy_url)
    proxy_host = uri.host || raise ArgumentError.new("SOCKS5: missing proxy host in #{proxy_url}")
    proxy_port = uri.port || 1080

    sock = TCPSocket.new(proxy_host, proxy_port)

    # Greeting: version=5, nmethods=1, method=0 (no auth)
    sock.write Bytes[0x05, 0x01, 0x00]
    resp = Bytes.new(2)
    sock.read_fully(resp)
    raise "SOCKS5: auth required (method=#{resp[1]})" unless resp[0] == 5 && resp[1] == 0

    # CONNECT request with domain-name address type (0x03)
    domain = dest_host.to_slice
    raise ArgumentError.new("SOCKS5: hostname too long") if domain.size > 255

    req = IO::Memory.new
    req.write Bytes[0x05, 0x01, 0x00, 0x03, domain.size.to_u8]
    req.write domain
    req.write_bytes(dest_port.to_u16, IO::ByteFormat::BigEndian)
    sock.write req.to_slice

    # Response: VER REP RSV ATYP [addr] [port]
    header = Bytes.new(4)
    sock.read_fully(header)
    raise "SOCKS5: connect failed (rep=#{header[1]})" unless header[1] == 0

    case header[3]
    when 0x01 # IPv4
      sock.read_fully(Bytes.new(4))
    when 0x03 # domain
      len_byte = Bytes.new(1)
      sock.read_fully(len_byte)
      sock.read_fully(Bytes.new(len_byte[0]))
    when 0x04 # IPv6
      sock.read_fully(Bytes.new(16))
    else
      raise "SOCKS5: unknown ATYP #{header[3]}"
    end
    sock.read_fully(Bytes.new(2)) # bound port

    sock
  end
end