class Renderer
  def self.render(text : String) : String
    out = text

    out = out.gsub(/\*\*(.+?)\*\*/, "\e[1m\\1\e[0m")
    out = out.gsub(/\*(.+?)\*/, "\e[3m\\1\e[0m")
    out = out.gsub(/`(.+?)`/, "\e[36m\\1\e[0m")

    out
  end
end