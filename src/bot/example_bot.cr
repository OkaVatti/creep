# src/bot/example_bot.cr -- example bot using the Creep Bot API
#
# Build separately or include from your own binary.
# Build:  crystal build src/bot/example_bot.cr -o bin/example_bot
# Run:    ./bin/example_bot [--config config/config.yml]

require "../common/config"
require "./bot"

config_path = "config/config.yml"
if (idx = ARGV.index("--config"))
  config_path = ARGV[idx + 1]? || config_path
end

cfg = Config.load(config_path)
c   = cfg.client
b   = cfg.bot

bot = Creep::Bot.new(b)

# ---- Built-in commands -----------------------------------------------

# !ping -> "pong"
bot.on_command("ping") do |e|
  bot.say(e.target, "#{e.nick}: pong!")
end

# !echo <text> -> repeats text
bot.on_command("echo") do |e|
  bot.say(e.target, e.args) unless e.args.empty?
end

# !help -> lists commands
bot.on_command("help") do |e|
  bot.say(e.target, "#{e.nick}: available commands: #{b.prefix}ping, #{b.prefix}echo, #{b.prefix}say, #{b.prefix}topic")
end

# !say <channel> <text> -> make bot say something in a channel
bot.on_command("say") do |e|
  parts = e.args.split(" ", 2)
  if parts.size == 2
    bot.say(parts[0], parts[1])
  else
    bot.say(e.target, "#{e.nick}: usage: #{b.prefix}say #channel <text>")
  end
end

# !topic <text> -> set topic in current channel
bot.on_command("topic") do |e|
  if e.target.starts_with?("#") && !e.args.empty?
    bot.set_topic(e.target, e.args)
  end
end

# General PRIVMSG hook: log to STDOUT
bot.on_privmsg do |e|
  puts "[#{e.target}] <#{e.nick}> #{e.body}"
end

# ---- Connect and run --------------------------------------------------

bot.connect(
  host:       c.server,
  port:       c.port,
  tls:        c.tls,
  proxy:      c.proxy,
  tls_verify: c.tls_verify
)

puts "[bot] connected as #{b.nick}, joining #{b.autojoin.join(", ")}"
bot.run