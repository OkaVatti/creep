# src/bot/example_bot.cr
# Build: crystal build src/bot/example_bot.cr -o bin/example_bot

require "../common/config"
require "./bot"

config_path = "config/config.yml"
ARGV.each_with_index { |arg, i| config_path = ARGV[i+1] if arg == "--config" && ARGV[i+1]? }

cfg = Config.load(config_path)
bot = Creep::Bot.new(cfg.bot)

# ---- Middleware: rate limiting per nick (max 5 commands/minute) ----------
rate = {} of String => Array(Time)
bot.use do |event, next_fn|
  times = rate[event.nick] ||= [] of Time
  times.reject! { |t| t < Time.utc - 1.minute }
  if times.size >= 5
    bot.notice(event.nick, "Rate limit exceeded. Please slow down.")
  else
    times << Time.utc
    next_fn.call
  end
end

# ---- Commands ------------------------------------------------------------

bot.on_command("ping") { |e| bot.say(e.target, "#{e.nick}: pong!") }

bot.on_command("echo") do |e|
  bot.say(e.target, e.args) unless e.args.empty?
end

bot.on_command("help") do |e|
  cmds = ["ping", "echo", "uptime", "say", "topic", "help"]
  bot.say(e.target, "#{e.nick}: commands: #{cmds.map { |c| cfg.bot.prefix + c }.join(", ")}")
end

bot.on_command("uptime") do |e|
  bot.say(e.target, "#{e.nick}: online since #{START_TIME.to_rfc3339}")
end

bot.on_command("say") do |e|
  parts = e.args.split(" ", 2)
  parts.size == 2 ? bot.say(parts[0], parts[1]) : bot.say(e.target, "Usage: !say #channel <text>")
end

bot.on_command("topic") do |e|
  bot.set_topic(e.target, e.args) if e.target.starts_with?("#") && !e.args.empty?
end

# ---- Event hooks ---------------------------------------------------------

bot.on_join do |e|
  next if e.nick == bot.nick
  bot.say(e.target, "Welcome, #{e.nick}! Type #{cfg.bot.prefix}help for commands.")
end

bot.on_kick do |e|
  bot.say(e.target, "#{e.body} was kicked by #{e.nick}.") rescue nil
end

bot.on_privmsg do |e|
  STDERR.puts "[#{e.target}] <#{e.nick}> #{e.body}"
end

# ---- Scheduled tasks -----------------------------------------------------

bot.every(5.minutes) do
  STDERR.puts "[bot] heartbeat at #{Time.utc.to_rfc3339}"
end

# ---- Connect and run -----------------------------------------------------

START_TIME = Time.utc

bot.connect(
  host:       cfg.client.server,
  port:       cfg.client.port,
  tls:        cfg.client.tls,
  proxy:      cfg.client.proxy,
  tls_verify: cfg.client.tls_verify
)

STDERR.puts "[bot] connected as #{cfg.bot.nick}"
bot.run