require "socket"
require "openssl"
require "./socks5_helper"

class IRCConnection
  getter io : IO

  def initialize(
    host : String,
    port : Int32,
    tls : Bool = false,
    proxy : String? = nil
  )
    socket = if proxy
      Socks5Helper.connect(proxy, host, port)
    else
      TCPSocket.new(host, port)
    end

    if tls
      ctx = OpenSSL::SSL::Context::Client.new
      @io = OpenSSL::SSL::Socket::Client.new(socket, context: ctx, sync_close: true)
    else
      @io = socket
    end
  end

  def send(line : String)
    @io.puts line
  end

  def read_loop(&block)
    while line = @io.gets
      yield line
    end
  end
end