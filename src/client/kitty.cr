# src/client/kitty.cr
#
# Kitty terminal graphics protocol support.
# Encodes an image file as base64 and emits the Kitty APC sequence
# so the terminal renders it inline.
#
# Only works inside a Kitty terminal (or Ghostty/WezTerm with the protocol enabled).
# Falls back to a text notice in other terminals.
#
# Protocol reference: https://sw.kovidgoyal.net/kitty/graphics-protocol/

require "base64"

module Kitty
  # Returns true if the terminal is likely Kitty-compatible.
  def self.supported? : Bool
    term = ENV["TERM"]? || ""
    kit  = ENV["TERM_PROGRAM"]? || ""
    term.includes?("kitty") || kit.includes?("kitty") ||
      kit.includes?("WezTerm") || kit.includes?("ghostty")
  end

  # Emit an image from a file path.
  # Returns a String containing the APC escape sequences, ready to print.
  # On error returns an error string to display as text.
  def self.encode_file(path : String) : String
    unless File.exists?(path)
      return "[kitty] file not found: #{path}"
    end

    data = File.read(path, encoding: "binary")
    b64  = Base64.strict_encode(data)
    mime = mime_for(path)

    # Choose format code: 100=PNG, 32=RGBA raw -- we always send as PNG/JPEG/etc
    # using format=100 (direct file transfer) is simplest but requires Kitty 0.20+.
    # We use the chunked payload approach (safe across versions).
    chunks = b64.scan(/.{1,4096}/).map(&.[0])
    last   = chunks.size - 1

    result = String::Builder.new
    chunks.each_with_index do |chunk, i|
      more = i < last ? 1 : 0
      # First chunk carries the control data
      if i == 0
        ctrl = "a=T,f=100,m=#{more}"
      else
        ctrl = "m=#{more}"
      end
      result << "\e_G#{ctrl};#{chunk}\e\\"
    end
    result.to_s
  end

  private def self.mime_for(path : String) : String
    case File.extname(path).downcase
    when ".png"          then "image/png"
    when ".jpg", ".jpeg" then "image/jpeg"
    when ".gif"          then "image/gif"
    when ".webp"         then "image/webp"
    else                      "image/png"
    end
  end
end