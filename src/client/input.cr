# src/client/input.cr
#
# Reads raw keystrokes from STDIN, assembles multi-byte escape sequences,
# and yields them as strings.
#
# read_char_timeout(seconds) yields a key string if one is available
# within the timeout, otherwise returns without yielding.
#
# Known sequences returned:
#   "\r"           Enter
#   "\x7f"         Backspace
#   "\e[A"         Up arrow
#   "\e[B"         Down arrow
#   "\e[C"         Right arrow
#   "\e[D"         Left arrow
#   "\e[1;5C"      Ctrl+Right
#   "\e[1;5D"      Ctrl+Left
#   "\e\e[C"       Alt+Right (some terminals)
#   "\e\e[D"       Alt+Left  (some terminals)
#   Any printable  Single character string

class Input
  STDIN_FD = STDIN.fd

  def read_char_timeout(timeout_sec : Float64, & : String ->)
    return unless char_available?(timeout_sec)

    first = read_byte
    return unless first

    if first == 0x1b  # ESC -- start of escape sequence
      seq = String::Builder.new
      seq << '\e'
      # Short wait for more bytes
      if char_available?(0.05)
        second = read_byte
        if second
          seq << second.chr
          if second == '['.ord || second == 'O'.ord
            # Read until we hit a terminator (letter or ~)
            loop do
              break unless char_available?(0.05)
              b = read_byte
              break unless b
              seq << b.chr
              break if (b >= 'A'.ord && b <= 'Z'.ord) || (b >= 'a'.ord && b <= 'z'.ord) || b == '~'.ord
            end
          elsif second == 0x1b  # ESC ESC -- alt sequence
            if char_available?(0.05)
              t = read_byte
              if t && t == '['.ord
                seq << '['
                loop do
                  break unless char_available?(0.05)
                  b = read_byte
                  break unless b
                  seq << b.chr
                  break if (b >= 'A'.ord && b <= 'Z'.ord) || b == '~'.ord
                end
              end
            end
          end
        end
      end
      yield seq.to_s
    else
      yield first.chr.to_s
    end
  end

  private def char_available?(timeout : Float64) : Bool
    fd_set = IO::FileDescriptor::FDSet.new
    fd_set.set(STDIN_FD)
    tv = LibC::Timeval.new
    tv.tv_sec  = timeout.to_i
    tv.tv_usec = ((timeout - timeout.to_i) * 1_000_000).to_i
    ret = LibC.select(STDIN_FD + 1, pointerof(fd_set), nil, nil, pointerof(tv))
    ret > 0
  rescue
    false
  end

  private def read_byte : UInt8?
    buf = Bytes.new(1)
    n = LibC.read(STDIN_FD, buf.to_unsafe, 1)
    n > 0 ? buf[0] : nil
  rescue
    nil
  end
end