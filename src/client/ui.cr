class UI
  def self.start(conn)
    spawn do
      conn.read_loop do |line|
        puts line
      end
    end

    while input = STDIN.gets
      conn.send input.strip
    end
  end
end