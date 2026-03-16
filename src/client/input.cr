# src/client/input.cr
#
# Reads raw keystrokes from STDIN, assembles multi-byte escape sequences,
# and yields them as strings.
#
# read_char_timeout(seconds) yields a key string if one is available
# within the timeout, otherwise returns without yielding.
#
# Uses IO::FileDescriptor#read_timeout= (Crystal 1.19.1 API) to implement
# polling without LibC.select or wait_readable.
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
  # STDIN is an IO::FileDescriptor (fd 0). We read from it directly.
  # read_timeout= causes reads to raise IO::TimeoutError after the span elapses.
  STDIN_IO = STDIN

  def read_char_timeout(timeout_sec : Float64, & : String ->)
    first = read_byte_timeout(timeout_sec)
    return unless first

    if first == 0x1b  # ESC -- start of escape sequence
      seq = String::Builder.new
      seq << '\e'

      second = read_byte_timeout(0.05)
      if second
        seq << second.chr
        if second == '['.ord || second == 'O'.ord
          # Read until terminator (letter or ~)
          loop do
            b = read_byte_timeout(0.05)
            break unless b
            seq << b.chr
            break if (b >= 'A'.ord && b <= 'Z'.ord) ||
                     (b >= 'a'.ord && b <= 'z'.ord) ||
                     b == '~'.ord
          end
        elsif second == 0x1b  # ESC ESC -- alt sequence
          t = read_byte_timeout(0.05)
          if t && t == '['.ord
            seq << '['
            loop do
              b = read_byte_timeout(0.05)
              break unless b
              seq << b.chr
              break if (b >= 'A'.ord && b <= 'Z'.ord) || b == '~'.ord
            end
          end
        end
      end
      yield seq.to_s
    else
      yield first.chr.to_s
    end
  end

  # Attempts to read one byte from STDIN within timeout_sec seconds.
  # Returns nil on timeout or error.
  private def read_byte_timeout(timeout_sec : Float64) : UInt8?
    STDIN_IO.read_timeout = timeout_sec.seconds
    byte = STDIN_IO.read_byte
    byte
  rescue IO::TimeoutError
    nil
  rescue
    nil
  ensure
    # Reset timeout so normal reads don't time out unexpectedly
    STDIN_IO.read_timeout = nil
  end
end