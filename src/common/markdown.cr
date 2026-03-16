# src/common/markdown.cr
#
# Renders a Discord-style Markdown subset to ANSI escape sequences
# suitable for terminal display.
#
# Supported:
#   **bold**           -> ESC[1m
#   *italic* / _italic_ -> ESC[3m
#   __underline__      -> ESC[4m
#   ~~strikethrough~~  -> ESC[9m
#   `inline code`      -> ESC[36m (cyan)
#   ```code block```   -> ESC[36m block, prefixed with "  "
#   > blockquote       -> grey prefix bar
#   # / ## / ### headings -> bold + optional colour
#   [text](url)        -> text (url)   (terminals rarely support hyperlinks)
#   ---                -> horizontal rule
#   * / - / 1. lists   -> indented bullets
#
# Colours use 256-colour where available but fall back gracefully.

module Markdown
  RESET  = "\e[0m"
  BOLD   = "\e[1m"
  ITALIC = "\e[3m"
  UNDER  = "\e[4m"
  STRIKE = "\e[9m"
  CODE   = "\e[36m"      # cyan
  DIM    = "\e[2m"
  H1     = "\e[1;33m"    # bold yellow
  H2     = "\e[1;36m"    # bold cyan
  H3     = "\e[1m"       # bold
  QUOTE  = "\e[2m"       # dim
  HR     = "\e[2m"       # dim

  # Uses %r{} delimiter so that # is not treated as string interpolation.
  HEADING_RE = /\A(\#{1,3})\s+(.*)/

  def self.render(text : String) : String
    lines = text.split('\n')
    out = String::Builder.new
    in_code_block = false
    code_lang = ""

    lines.each_with_index do |line, i|
      # Fenced code block toggle
      if line.strip.starts_with?("```")
        if in_code_block
          in_code_block = false
          out << RESET << "\n"
        else
          in_code_block = true
          code_lang = line.strip[3..].strip
          out << CODE
          out << "  [#{code_lang}]\n" unless code_lang.empty?
        end
        next
      end

      if in_code_block
        out << "  " << line << "\n"
        next
      end

      # Horizontal rule
      if line.strip.size >= 3 && line.strip.chars.all? { |c| c == '-' || c == '*' || c == '_' }
        out << HR << ("─" * 60) << RESET << "\n"
        next
      end

      # Headings
      if (m = line.match(HEADING_RE))
        level = m[1].size
        content = render_inline(m[2])
        prefix = case level
                 when 1 then H1
                 when 2 then H2
                 else        H3
                 end
        out << prefix << content << RESET << "\n"
        next
      end

      # Blockquote
      if line.starts_with?("> ")
        out << QUOTE << "┃ " << render_inline(line[2..]) << RESET << "\n"
        next
      end

      # Unordered list
      if (m = line.match(/\A(\s*)[-*+]\s+(.*)/))
        indent = " " * (m[1].size + 2)
        out << indent << "• " << render_inline(m[2]) << RESET << "\n"
        next
      end

      # Ordered list
      if (m = line.match(/\A(\s*)\d+\.\s+(.*)/))
        indent = " " * (m[1].size + 3)
        out << indent << render_inline(m[2]) << RESET << "\n"
        next
      end

      out << render_inline(line) << RESET << "\n"
    end

    out.to_s
  end

  # Renders inline spans only (bold, italic, code, links, etc.)
  def self.render_inline(text : String) : String
    out = text

    # Inline code -- must be first so inner content is not re-parsed
    out = out.gsub(/`([^`]+)`/) { CODE + $~[1] + RESET }

    # Links: [text](url) -- show "text (url)"
    out = out.gsub(/\[([^\]]+)\]\(([^)]+)\)/) { $~[1] + DIM + " (#{$~[2]})" + RESET }

    # Bold+italic: ***text***
    out = out.gsub(/\*\*\*(.+?)\*\*\*/) { BOLD + ITALIC + $~[1] + RESET }

    # Bold: **text**
    out = out.gsub(/\*\*(.+?)\*\*/) { BOLD + $~[1] + RESET }

    # Underline: __text__
    out = out.gsub(/__(.+?)__/) { UNDER + $~[1] + RESET }

    # Italic: *text* or _text_
    out = out.gsub(/\*(.+?)\*/) { ITALIC + $~[1] + RESET }
    out = out.gsub(/_([^_]+)_/) { ITALIC + $~[1] + RESET }

    # Strikethrough: ~~text~~
    out = out.gsub(/~~(.+?)~~/) { STRIKE + $~[1] + RESET }

    out
  end
end