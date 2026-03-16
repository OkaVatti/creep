# creep

A Crystal IRC server and client with support for ClearWeb (TLS/plain), Tor, and I2P.

## Features

- Multi-listener IRC server: each listener can be plain TCP or TLS, on any port
- TLS/SSL with per-listener certificates
- SOCKS5 proxy support on both client and server (Tor, I2P, I2P+, I2Pd)
- Markdown rendering in the TUI client (Discord-style subset)
- Programmatic Bot API with command dispatch and HTTP webhook forwarding
- Single `config/config.yml` controls everything

## Requirements

- Crystal >= 1.19.1
- OpenSSL (for TLS listeners/connections)

## Building

```sh
shards install
shards build --release
```

Produces `bin/creepd` (server) and `bin/creep` (client).

## Configuration

Copy and edit `config/config.yml`. Key sections:

### Server listeners

```yaml
server:
  name: "myserver.local"
  listeners:
    - host: "0.0.0.0"
      port: 6667
      tls: false
    - host: "0.0.0.0"
      port: 6697
      tls: true
      cert: "config/server.crt"
      key:  "config/server.key"
```

Each entry is independent. You can have as many as you like.

### Tor setup

1. Install Tor. In `torrc`:
   ```
   HiddenServiceDir /var/lib/tor/creep_irc/
   HiddenServicePort 6667 127.0.0.1:6668
   ```
2. Add a listener bound to `127.0.0.1:6668` (plain TCP -- Tor encrypts the circuit).
3. Users connect via their IRC client with SOCKS5 proxy `127.0.0.1:9050` to your `.onion:6667`.
4. In `config.yml` client section:
   ```yaml
   client:
     server: "youronion.onion"
     port: 6667
     tls: false
     proxy: "socks5://127.0.0.1:9050"
   ```

### I2P setup

There are two models:

**Outproxy model (server on ClearWeb, I2P users connect via outproxy)**
- Users configure I2P outproxy in their I2P router and point the client at `socks5://127.0.0.1:4447`.

**I2P destination model (server as I2P service)**
1. In your I2P router console, create a Server Tunnel:
   - Type: Standard
   - Target host: 127.0.0.1, port: 6669
   - Save and note the Base32 destination address.
2. Add a listener at `127.0.0.1:6669`.
3. Users create a Client Tunnel in their I2P router console pointing at your destination address.
4. Client config:
   ```yaml
   client:
     server: "127.0.0.1"
     port: <client tunnel local port>
     tls: false
     proxy: null
   ```
   Or with I2P SOCKS:
   ```yaml
   client:
     server: "yourdest.b32.i2p"
     proxy: "socks5://127.0.0.1:4447"
   ```

### TLS certificate generation (self-signed)

```sh
openssl req -x509 -newkey rsa:4096 -keyout config/server.key \
  -out config/server.crt -days 3650 -nodes \
  -subj "/CN=localhost"
```

## Running the server

```sh
./bin/creepd
# or with a custom config path:
./bin/creepd --config /etc/creep/config.yml
```

## Running the client

```sh
./bin/creep
# or:
./bin/creep --config ~/.config/creep/config.yml
```

### Client keyboard shortcuts

| Key | Action |
|-----|--------|
| Enter | Send message |
| Alt+Left / Alt+Right | Switch buffers |
| Up / Down | Scroll messages |
| Ctrl+L | Force redraw |

### Client commands

```
/join #channel        join a channel
/part [#channel]      leave current or named channel
/nick <nick>          change nickname
/msg <nick> <text>    send private message
/me <action>          send CTCP ACTION
/topic [text]         get or set topic
/mode <args>          send raw MODE command
/whois <nick>         show user info
/list                 list channels on server
/names [#channel]     list members of a channel
/raw <line>           send raw IRC line
/clear                clear current buffer scrollback
/quit [reason]        disconnect and exit
/help                 show this list
```

## Markdown

The client renders a Discord-style Markdown subset in incoming messages:

| Syntax | Result |
|--------|--------|
| `**bold**` | bold |
| `*italic*` or `_italic_` | italic |
| `__underline__` | underline |
| `~~strike~~` | strikethrough |
| `` `code` `` | inline code (cyan) |
| ` ```lang ... ``` ` | code block |
| `> quote` | blockquote |
| `# H1` / `## H2` / `### H3` | headings |
| `[text](url)` | link |
| `---` | horizontal rule |

## Bot API

```crystal
require "./src/bot/bot"
require "./src/common/config"

cfg = Config.load
bot = Creep::Bot.new(cfg.bot)

bot.on_command("ping") { |e| bot.say(e.target, "#{e.nick}: pong!") }
bot.on_privmsg        { |e| puts "<#{e.nick}> #{e.body}" }

bot.connect(cfg.client.server, cfg.client.port, tls: cfg.client.tls)
bot.run
```

See `src/bot/example_bot.cr` for a full example.

### BotEvent fields

| Field | Type | Description |
|-------|------|-------------|
| `nick` | String | Sender nick |
| `user` | String | Sender username |
| `host` | String | Sender hostname |
| `target` | String | Channel or bot nick |
| `body` | String | Full message text |
| `command` | String? | Command name (without prefix), or nil |
| `args` | String | Everything after the command word |
| `raw` | FastIRC::Message | Raw parsed message |

### Webhook forwarding

Set `bot.webhook_url` in config. Every PRIVMSG is forwarded as JSON POST:

```json
{
  "nick": "alice",
  "user": "alice",
  "host": "1.2.3.4",
  "target": "#general",
  "body": "!ping",
  "command": "ping",
  "args": ""
}
```

## Project structure

```
config/
  config.yml         main configuration
  server.crt         TLS certificate
  server.key         TLS private key
src/
  creepd.cr          server binary entry point
  creep.cr           client binary entry point
  common/
    config.cr        typed config loader
    transport.cr     TCP / TLS / SOCKS5 transport
    markdown.cr      Markdown to ANSI renderer
  server/
    server.cr        IRC server implementation
  client/
    connection.cr    IRC connection wrapper
    ui.cr            terminal UI
    input.cr         raw keyboard input reader
  bot/
    bot.cr           bot API
    example_bot.cr   example bot
```

## Contributing

1. Fork it
2. Create your feature branch (`git checkout -b my-feature`)
3. Commit your changes (`git commit -am 'Add feature'`)
4. Push (`git push origin my-feature`)
5. Open a pull request

## Contributors

- [OkaVatti](https://github.com/OkaVatti) - creator and maintainer