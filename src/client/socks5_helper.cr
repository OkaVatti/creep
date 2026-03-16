# src/socks5_helper.cr
require "socket"

# Minimal SOCKS5 dialer (no auth). Returns a TCPSocket connected through the proxy.
# Usage:
#   sock = Socks5.dial("127.0.0.1", 9050, "irc.example.com", 6667)
module Socks5
  def self.dial(proxy_host : String, proxy_port : Int32, dest_host : String, dest_port : Int32) : TCPSocket
    sock = TCPSocket.new(proxy_host, proxy_port)

    # Greeting: VER=5, NMETHODS=1, METHOD=0 (no auth)
    greet = Bytes.new(3)
    greet[0] = 0x05_u8
    greet[1] = 0x01_u8
    greet[2] = 0x00_u8
    sock.write greet

    resp = sock.read(2) || raise "SOCKS5: no response from proxy"
    if resp.bytesize < 2 || resp.getbyte(0) != 0x05 || resp.getbyte(1) != 0x00
      raise "SOCKS5: proxy requires auth or responded with unsupported method"
    end

    # Build CONNECT request:
    # VER=5, CMD=1(connect), RSV=0, ATYP=3(domain), <len><domain>, <port hi><port lo>
    domain_bytes = dest_host.bytes
    domain_len = domain_bytes.size
    req_len = 4 + 1 + domain_len + 2
    req = Bytes.new(req_len)
    req[0] = 0x05_u8
    req[1] = 0x01_u8
    req[2] = 0x00_u8
    req[3] = 0x03_u8
    req[4] = domain_len.to_u8

    domain_bytes.each_with_index do |b, i|
      req[5 + i] = b
    end

    port_offset = 5 + domain_len
    req[port_offset]     = ((dest_port >> 8) & 0xff).to_u8
    req[port_offset + 1] = (dest_port & 0xff).to_u8

    sock.write req

    # Read response header (VER, REP, RSV, ATYP)
    header = sock.read(4) || raise "SOCKS5: truncated response header"
    rep = header.getbyte(1)
    if rep != 0x00
      raise "SOCKS5: connect failed (reply=#{rep})"
    end

    atyp = header.getbyte(3)
    case atyp
    when 0x01
      # IPv4 (4 bytes)
      _ = sock.read(4) || raise "SOCKS5: truncated IPv4 address"
    when 0x03
      # Domain: one length byte then that many bytes
      len_byte = sock.read(1) || raise "SOCKS5: truncated domain len"
      len = len_byte.getbyte(0)
      _ = sock.read(len) || raise "SOCKS5: truncated domain addr"
    when 0x04
      # IPv6 (16 bytes)
      _ = sock.read(16) || raise "SOCKS5: truncated IPv6 address"
    else
      raise "SOCKS5: unknown ATYP #{atyp}"
    end

    # read port (2 bytes)
    _ = sock.read(2) || raise "SOCKS5: truncated port bytes"

    # Success: the proxy has connected the socket to the destination.
    sock
  end
end

require "socket"

module Socks5Helper
  def self.connect(proxy_url : String, host : String, port : Int32) : TCPSocket
    uri = URI.parse(proxy_url)

    sock = TCPSocket.new(uri.host.not_nil!, uri.port || 1080)

    sock.write Bytes[0x05, 0x01, 0x00]
    sock.read(Bytes.new(2))

    host_bytes = host.to_slice

    req = Bytes[
      0x05,
      0x01,
      0x00,
      0x03,
      host_bytes.size.to_u8
    ]

    sock.write req
    sock.write host_bytes
    sock.write Bytes[(port >> 8).to_u8, (port & 0xff).to_u8]

    sock.read(Bytes.new(10))

    sock
  end
end