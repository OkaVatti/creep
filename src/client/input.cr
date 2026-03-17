# src/client/input.cr
#
# Raw terminal keyboard reader.
#
# Design:
#   STDIN is put into raw mode by the UI before Input is used.
#   We set a short read_timeout on STDIN before each read attempt.
#   If no byte arrives within the timeout, IO::TimeoutError is raised
#   and we return nil -- this is the non-blocking poll mechanism.
#
#   The timeout is set immediately before each read and cleared
#   immediately after (in ensure). The key insight is that we must
#   NOT clear the timeout between the initial byte read and the
#   subsequent escape-sequence bytes -- those reads use their own
#   short timeout and manage the timeout themselves.
#
# Returned key strings:
#   "\r"             Enter
#   "\x7f"           Backspace / Delete
#   "\x01"           Ctrl+A
#   "\x03"           Ctrl+C
#   "\x04"           Ctrl+D
#   "\x05"           Ctrl+E
#   "\x0b"           Ctrl+K
#   "\x0c"           Ctrl+L
#   "\x15"           Ctrl+U
#   "\e[A"           Up arrow
#   "\e[B"           Down arrow
#   "\e[C"           Right arrow
#   "\e[D"           Left arrow
#   "\e[5~"          Page Up
#   "\e[6~"          Page Down
#   "\e[1;5C"        Ctrl+Right
#   "\e[1;5D"        Ctrl+Left
#   "\e[1;3C"        Alt+Right
#   "\e[1;3D"        Alt+Left
#   "\e\e[C"         Alt+Right (some terminals)
#   "\e\e[D"         Alt+Left  (some terminals)
#   Any printable    Single UTF-8 character string

class Input
  # Read one byte from STDIN with a timeout.
  # Returns the byte value, or nil if no byte arrived within the timeout.
  private def timed_byte(timeout_sec : Float64) : UInt8?
    STDIN.read_timeout = timeout_sec.seconds
    b = STDIN.read_byte
    STDIN.read_timeout = nil
    b
  rescue IO::TimeoutError
    STDIN.read_timeout = nil
    nil
  rescue
    STDIN.read_timeout = nil
    nil
  end

  # Attempt to read one complete key event.
  # Yields the key string if one is available within timeout_sec seconds.
  # Returns without yielding if no input arrives.
  def read_char_timeout(timeout_sec : Float64, & : String ->)
    first = timed_byte(timeout_sec)
    return unless first

    # Printable ASCII / UTF-8 multi-byte
    unless first == 0x1b
      # Accumulate a complete UTF-8 codepoint if needed
      if first < 0x80
        yield first.chr.to_s
      elsif first >= 0xC0
        # Multi-byte UTF-8: determine expected byte count
        extra = if first >= 0xF0
                  3
                elsif first >= 0xE0
                  2
                else
                  1
                end
        buf = String::Builder.new
        buf << first.chr
        extra.times do
          b = timed_byte(0.05)
          break unless b
          buf << b.chr
        end
        yield buf.to_s
      else
        yield first.chr.to_s
      end
      return
    end

    # ESC sequence
    seq = String::Builder.new
    seq << '\e'

    second = timed_byte(0.05)
    unless second
      # Bare ESC key
      yield seq.to_s
      return
    end

    seq << second.chr

    case second
    when '['.ord, 'O'.ord
      # CSI or SS3 sequence -- read until alphabetic or ~
      loop do
        b = timed_byte(0.05)
        break unless b
        seq << b.chr
        break if (b >= 'A'.ord && b <= 'Z'.ord) ||
                 (b >= 'a'.ord && b <= 'z'.ord) ||
                 b == '~'.ord
      end
    when 0x1b
      # ESC ESC [ ... -- Alt + arrow on some terminals
      seq << '\e'
      third = timed_byte(0.05)
      if third && third == '['.ord
        seq << '['
        loop do
          b = timed_byte(0.05)
          break unless b
          seq << b.chr
          break if (b >= 'A'.ord && b <= 'Z'.ord) || b == '~'.ord
        end
      end
    end

    yield seq.to_s
  end
end
