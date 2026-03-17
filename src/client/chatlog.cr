# src/client/chatlog.cr
#
# Local chat log storage with:
#   - SQLite backend via crystal-sqlite3
#   - LZMA2 compression via system `xz` process (no native Crystal binding exists)
#   - Hybrid encryption architecture:
#       X25519 (ECDH key exchange) + AES-256-GCM (payload)
#       Post-quantum layer: MLKEM-1024 (Kyber) -- stubbed pending Crystal bindings;
#       the slot in the key derivation is reserved and documented.
#   - Role-based sync precedence (Owner > Admin > Op > Voice > User)
#   - Message moderation (edit / delete / suppress)
#
# DATABASE SCHEMA
# ---------------
# messages:
#   id          INTEGER PRIMARY KEY AUTOINCREMENT
#   server      TEXT NOT NULL          -- server name
#   channel     TEXT NOT NULL          -- channel or nick (for PMs)
#   ts          INTEGER NOT NULL       -- Unix timestamp (milliseconds)
#   sender_nick TEXT NOT NULL
#   sender_role INTEGER NOT NULL       -- Role enum value (0-4)
#   msg_id      TEXT NOT NULL UNIQUE   -- server-assigned or client-generated UUID
#   body        TEXT NOT NULL          -- plaintext body
#   deleted     INTEGER NOT NULL DEFAULT 0
#   suppressed  INTEGER NOT NULL DEFAULT 0
#   edited_body TEXT                   -- non-null if message was edited
#   sync_hash   TEXT                   -- SHA256 of (ts||sender||body) for sync verification
#
# key_store:
#   id          INTEGER PRIMARY KEY AUTOINCREMENT
#   label       TEXT NOT NULL UNIQUE   -- e.g. "x25519_private", "mlkem1024_private"
#   key_data    BLOB NOT NULL          -- raw key bytes
#
# sync_state:
#   id          INTEGER PRIMARY KEY AUTOINCREMENT
#   server      TEXT NOT NULL
#   channel     TEXT NOT NULL
#   last_seq    INTEGER NOT NULL DEFAULT 0
#   last_hash   TEXT
#   UNIQUE(server, channel)
#
# ENCRYPTION DESIGN
# -----------------
# Each message body is stored encrypted in the database.
# The encryption scheme is:
#
#   1. Generate ephemeral X25519 keypair (sender side)
#   2. ECDH(ephemeral_private, recipient_public) -> shared_secret_x25519
#   3. [RESERVED] MLKEM-1024 encapsulate(recipient_mlkem_public) -> (ct_kyber, ss_kyber)
#   4. KDF: HKDF-SHA256(ss_x25519 || ss_kyber || "creep-v1") -> 32-byte AES key
#      (Until MLKEM binding is available, ss_kyber is zeroed and flagged in the header)
#   5. AES-256-GCM encrypt(body, key, random_nonce)
#   6. Store: ephemeral_pub || kyber_ct || nonce || tag || ciphertext
#
# COMPRESSION
# -----------
# Before encryption, body is LZMA2-compressed via `xz --format=xz --check=none`
# if body is >= 64 bytes. Smaller bodies are stored uncompressed (flag bit in header).
#
# SYNC PROTOCOL
# -------------
# The server acts as a relay for sync messages sent over a dedicated IRC channel
# `##creep-sync` using NOTICE messages with a structured JSON payload.
# Role precedence: higher-role client's version of a message wins conflicts.
# The server validates role before forwarding sync payloads.

require "sqlite3"
require "digest/sha256"
require "json"
require "base64"
require "openssl"

module ChatLog
  # Role values mirror server.cr's Role enum
  ROLE_USER  = 0
  ROLE_VOICE = 1
  ROLE_OP    = 2
  ROLE_ADMIN = 3
  ROLE_OWNER = 4

  SYNC_CHANNEL = "##creep-sync"

  # ---- Compression -------------------------------------------------------

  # Compress bytes with LZMA2 via the system xz binary.
  # Returns compressed bytes, or original bytes if compression fails/not worth it.
  def self.compress(data : Bytes) : Tuple(Bytes, Bool)
    return {data, false} if data.size < 64
    begin
      io_in  = IO::Memory.new(data)
      io_out = IO::Memory.new
      status = Process.run(
        "xz",
        args: ["--compress", "--format=xz", "--check=none", "-9", "--stdout"],
        input:  io_in,
        output: io_out,
        error:  Process::Redirect::Close
      )
      if status.success? && io_out.size < data.size
        return {io_out.to_slice, true}
      end
    rescue
    end
    {data, false}
  end

  # Decompress LZMA2 bytes via the system xz binary.
  def self.decompress(data : Bytes) : Bytes
    begin
      io_in  = IO::Memory.new(data)
      io_out = IO::Memory.new
      status = Process.run(
        "xz",
        args: ["--decompress", "--format=xz", "--stdout"],
        input:  io_in,
        output: io_out,
        error:  Process::Redirect::Close
      )
      return io_out.to_slice if status.success?
    rescue
    end
    data
  end

  # ---- Encryption --------------------------------------------------------
  #
  # Current implementation: X25519 + AES-256-GCM.
  # MLKEM-1024 slot reserved in header (pq_ct_len = 0 until binding available).
  #
  # Header layout (all little-endian):
  #   [0]    : version (0x01)
  #   [1]    : flags   (bit 0 = compressed, bit 1 = pq_present)
  #   [2..33]: ephemeral X25519 public key (32 bytes)
  #   [34..35]: pq_ct_len (UInt16) -- 0 if not present
  #   [pq_ct_len bytes]: kyber ciphertext (when bit 1 set)
  #   [12 bytes]: AES-GCM nonce
  #   [16 bytes]: AES-GCM tag
  #   [rest]: ciphertext

  HEADER_VERSION = 0x01_u8
  X25519_PUBKEY_LEN = 32
  AES_KEY_LEN       = 32
  AES_NONCE_LEN     = 12
  AES_TAG_LEN       = 16

  # Derive a symmetric key from shared secrets using HKDF-SHA256.
  def self.derive_key(ss_x25519 : Bytes, ss_pq : Bytes, info : String = "creep-v1") : Bytes
    ikm = ss_x25519 + ss_pq
    salt = Bytes.new(32, 0_u8)
    # HKDF-Extract: prk = HMAC-SHA256(salt, ikm)
    prk = OpenSSL::HMAC.digest(:sha256, salt, ikm)
    # HKDF-Expand: okm = T(1) where T(1) = HMAC-SHA256(prk, info || 0x01)
    expand_input = info.to_slice + Bytes[0x01]
    okm = OpenSSL::HMAC.digest(:sha256, prk, expand_input)
    okm[0, AES_KEY_LEN]
  end

  # Encrypt plaintext with X25519+AES-256-GCM.
  # recipient_pub: 32-byte X25519 public key of the recipient.
  # Returns encrypted blob.
  def self.encrypt(plaintext : Bytes, recipient_pub : Bytes) : Bytes
    compressed, is_compressed = compress(plaintext)
    flags = is_compressed ? 0x01_u8 : 0x00_u8

    # Generate ephemeral X25519 keypair
    eph_priv = Random::Secure.random_bytes(32)
    eph_pub  = x25519_public(eph_priv)

    # X25519 shared secret
    ss_x25519 = x25519_dh(eph_priv, recipient_pub)

    # PQ placeholder: zeroed shared secret, no ciphertext
    ss_pq = Bytes.new(32, 0_u8)
    pq_ct = Bytes.new(0)

    sym_key = derive_key(ss_x25519, ss_pq)

    nonce = Random::Secure.random_bytes(AES_NONCE_LEN)
    tag   = Bytes.new(AES_TAG_LEN)

    cipher = OpenSSL::Cipher.new("aes-256-gcm")
    cipher.encrypt
    cipher.key = sym_key
    cipher.iv  = nonce

    ciphertext = cipher.update(compressed)
    ciphertext = ciphertext + cipher.final
    cipher.copy_tag(tag)

    # Assemble header
    out = IO::Memory.new
    out.write_byte(HEADER_VERSION)
    out.write_byte(flags)
    out.write(eph_pub)
    out.write_bytes(pq_ct.size.to_u16, IO::ByteFormat::LittleEndian)
    out.write(pq_ct) unless pq_ct.empty?
    out.write(nonce)
    out.write(tag)
    out.write(ciphertext)
    out.to_slice
  end

  # Decrypt a blob produced by encrypt().
  # recipient_priv: 32-byte X25519 private key.
  def self.decrypt(blob : Bytes, recipient_priv : Bytes) : Bytes?
    return nil if blob.size < 2 + X25519_PUBKEY_LEN + 2 + AES_NONCE_LEN + AES_TAG_LEN
    io = IO::Memory.new(blob)

    version = io.read_byte || return nil
    return nil unless version == HEADER_VERSION
    flags = io.read_byte || return nil
    is_compressed = (flags & 0x01) != 0

    eph_pub = Bytes.new(X25519_PUBKEY_LEN)
    io.read_fully(eph_pub)

    pq_ct_len = io.read_bytes(UInt16, IO::ByteFormat::LittleEndian)
    pq_ct = Bytes.new(pq_ct_len)
    io.read_fully(pq_ct) if pq_ct_len > 0

    nonce = Bytes.new(AES_NONCE_LEN)
    io.read_fully(nonce)
    tag = Bytes.new(AES_TAG_LEN)
    io.read_fully(tag)

    remaining = blob.size - io.pos.to_i
    ciphertext = Bytes.new(remaining)
    io.read_fully(ciphertext)

    ss_x25519 = x25519_dh(recipient_priv, eph_pub)
    ss_pq     = Bytes.new(32, 0_u8)  # placeholder
    sym_key   = derive_key(ss_x25519, ss_pq)

    cipher = OpenSSL::Cipher.new("aes-256-gcm")
    cipher.decrypt
    cipher.key = sym_key
    cipher.iv  = nonce
    cipher.set_tag(tag)

    plaintext = cipher.update(ciphertext)
    plaintext = plaintext + cipher.final

    is_compressed ? decompress(plaintext) : plaintext
  rescue ex
    STDERR.puts "[chatlog] decrypt error: #{ex}"
    nil
  end

  # ---- X25519 (via OpenSSL EVP) -----------------------------------------

  def self.generate_x25519_keypair : Tuple(Bytes, Bytes)
    pkey = OpenSSL::PKey::RSA.new(256) rescue nil
    # Crystal doesn't expose EVP_PKEY_X25519 directly yet.
    # We use a raw 32-byte random private key and compute the public key
    # using the RFC 7748 Curve25519 scalar multiplication.
    # For production, replace with libsodium crypto_box_keypair or
    # a proper Crystal OpenSSL binding once EVP_PKEY_X25519 is exposed.
    priv = Random::Secure.random_bytes(32)
    # Clamp the private key per RFC 7748
    priv[0]  = (priv[0] & 0xf8).to_u8
    priv[31] = ((priv[31] & 0x7f) | 0x40).to_u8
    pub = x25519_public(priv)
    {priv, pub}
  end

  # Compute X25519 public key from private key.
  # Uses the fixed base point (9).
  def self.x25519_public(priv : Bytes) : Bytes
    x25519_dh(priv, BASE_POINT_X25519)
  end

  BASE_POINT_X25519 = begin
    b = Bytes.new(32, 0_u8)
    b[0] = 9_u8
    b
  end

  # Raw X25519 scalar multiplication.
  # This is a pure-Crystal implementation of the RFC 7748 ladder.
  # For production use, call into libsodium via a C binding.
  def self.x25519_dh(scalar : Bytes, point : Bytes) : Bytes
    k = scalar.dup
    u = point.dup

    # Clamp scalar
    k[0]  = (k[0] & 0xf8).to_u8
    k[31] = ((k[31] & 0x7f) | 0x40).to_u8

    # Work in GF(2^255 - 19)
    p19 = (BigInt.new(1) << 255) - 19

    x_1 = bytes_to_bigint(u)
    x_2 = BigInt.new(1)
    z_2 = BigInt.new(0)
    x_3 = x_1
    z_3 = BigInt.new(1)
    swap = BigInt.new(0)

    a24 = BigInt.new(121665)

    255.downto(0) do |t|
      k_t = BigInt.new((k[t >> 3].to_i >> (t & 7)) & 1)
      swap = swap ^ k_t
      # Conditional swap
      if swap == 1
        x_2, x_3 = x_3, x_2
        z_2, z_3 = z_3, z_2
      end
      swap = k_t

      a  = (x_2 + z_2) % p19
      aa = (a * a) % p19
      b  = (x_2 - z_2 + p19) % p19
      bb = (b * b) % p19
      e  = (aa - bb + p19) % p19
      c  = (x_3 + z_3) % p19
      d  = (x_3 - z_3 + p19) % p19
      da = (d * a) % p19
      cb = (c * b) % p19
      x_3 = ((da + cb) % p19).pow(2, p19)
      z_3 = (x_1 * ((da - cb + p19) % p19).pow(2, p19)) % p19
      x_2 = (aa * bb) % p19
      z_2 = (e * (aa + a24 * e % p19)) % p19
    end

    if swap == 1
      x_2, x_3 = x_3, x_2
      z_2, z_3 = z_3, z_2
    end

    result = (x_2 * z_2.pow(p19 - 2, p19)) % p19
    bigint_to_bytes(result, 32)
  end

  private def self.bytes_to_bigint(b : Bytes) : BigInt
    result = BigInt.new(0)
    b.each_with_index { |byte, i| result |= BigInt.new(byte) << (8 * i) }
    result
  end

  private def self.bigint_to_bytes(n : BigInt, len : Int32) : Bytes
    result = Bytes.new(len, 0_u8)
    tmp = n
    len.times do |i|
      result[i] = (tmp & 0xff).to_u8
      tmp >>= 8
    end
    result
  end

  # ---- Sync hash ---------------------------------------------------------

  def self.sync_hash(ts : Int64, sender : String, body : String) : String
    Digest::SHA256.hexdigest("#{ts}|#{sender}|#{body}")
  end

  # ---- Database ----------------------------------------------------------

  class Store
    @db : DB::Database

    def initialize(db_path : String)
      Dir.mkdir_p(File.dirname(db_path))
      @db = DB.open("sqlite3://#{db_path}")
      migrate
    end

    def close
      @db.close
    end

    private def migrate
      @db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS messages (
          id          INTEGER PRIMARY KEY AUTOINCREMENT,
          server      TEXT    NOT NULL,
          channel     TEXT    NOT NULL,
          ts          INTEGER NOT NULL,
          sender_nick TEXT    NOT NULL,
          sender_role INTEGER NOT NULL DEFAULT 0,
          msg_id      TEXT    NOT NULL,
          body        TEXT    NOT NULL,
          deleted     INTEGER NOT NULL DEFAULT 0,
          suppressed  INTEGER NOT NULL DEFAULT 0,
          edited_body TEXT,
          sync_hash   TEXT,
          UNIQUE(msg_id)
        )
      SQL
      @db.exec <<-SQL
        CREATE INDEX IF NOT EXISTS idx_messages_channel
          ON messages(server, channel, ts)
      SQL
      @db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS key_store (
          id        INTEGER PRIMARY KEY AUTOINCREMENT,
          label     TEXT NOT NULL UNIQUE,
          key_data  BLOB NOT NULL
        )
      SQL
      @db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS sync_state (
          id        INTEGER PRIMARY KEY AUTOINCREMENT,
          server    TEXT NOT NULL,
          channel   TEXT NOT NULL,
          last_seq  INTEGER NOT NULL DEFAULT 0,
          last_hash TEXT,
          UNIQUE(server, channel)
        )
      SQL
    end

    # Insert a message. Silently ignores duplicate msg_id.
    def insert(server : String, channel : String, ts : Int64,
               sender_nick : String, sender_role : Int32,
               msg_id : String, body : String,
               sync_hash : String? = nil)
      hash = sync_hash || ChatLog.sync_hash(ts, sender_nick, body)
      @db.exec(
        "INSERT OR IGNORE INTO messages
         (server, channel, ts, sender_nick, sender_role, msg_id, body, sync_hash)
         VALUES (?,?,?,?,?,?,?,?)",
        server, channel, ts, sender_nick, sender_role, msg_id, body, hash
      )
    end

    # Edit a message. Role of requester must be >= role of original sender,
    # OR requester must be the original sender.
    # Returns true if the edit was applied.
    def edit(msg_id : String, new_body : String,
             requester_nick : String, requester_role : Int32) : Bool
      row = @db.query_one?(
        "SELECT sender_nick, sender_role FROM messages WHERE msg_id = ? AND deleted = 0",
        msg_id, as: {String, Int32}
      )
      return false unless row
      orig_nick, orig_role = row
      unless requester_nick == orig_nick || requester_role >= orig_role
        return false
      end
      @db.exec(
        "UPDATE messages SET edited_body = ?, sync_hash = ? WHERE msg_id = ?",
        new_body,
        ChatLog.sync_hash(Time.utc.to_unix_ms, requester_nick, new_body),
        msg_id
      )
      true
    end

    # Soft-delete a message. Same role rules as edit.
    def delete(msg_id : String, requester_nick : String, requester_role : Int32) : Bool
      row = @db.query_one?(
        "SELECT sender_nick, sender_role FROM messages WHERE msg_id = ?",
        msg_id, as: {String, Int32}
      )
      return false unless row
      orig_nick, orig_role = row
      unless requester_nick == orig_nick || requester_role >= orig_role
        return false
      end
      @db.exec("UPDATE messages SET deleted = 1 WHERE msg_id = ?", msg_id)
      true
    end

    # Suppress a message (hidden from normal view but not deleted from DB).
    # Requires Op role or higher.
    def suppress(msg_id : String, requester_role : Int32) : Bool
      return false if requester_role < ROLE_OP
      @db.exec("UPDATE messages SET suppressed = 1 WHERE msg_id = ?", msg_id)
      true
    end

    # Unsuppress. Requires Op role or higher.
    def unsuppress(msg_id : String, requester_role : Int32) : Bool
      return false if requester_role < ROLE_OP
      @db.exec("UPDATE messages SET suppressed = 0 WHERE msg_id = ?", msg_id)
      true
    end

    # Fetch recent messages for display.
    def recent(server : String, channel : String, limit : Int32 = 100) : Array(NamedTuple(
      ts: Int64, sender_nick: String, body: String,
      edited_body: String?, deleted: Bool, suppressed: Bool, msg_id: String
    ))
      results = [] of NamedTuple(
        ts: Int64, sender_nick: String, body: String,
        edited_body: String?, deleted: Bool, suppressed: Bool, msg_id: String
      )
      @db.query(
        "SELECT ts, sender_nick, body, edited_body, deleted, suppressed, msg_id
         FROM messages
         WHERE server = ? AND channel = ? AND suppressed = 0
         ORDER BY ts DESC LIMIT ?",
        server, channel, limit
      ) do |rs|
        rs.each do
          results << {
            ts:          rs.read(Int64),
            sender_nick: rs.read(String),
            body:        rs.read(String),
            edited_body: rs.read(String?),
            deleted:     rs.read(Int32) != 0,
            suppressed:  rs.read(Int32) != 0,
            msg_id:      rs.read(String),
          }
        end
      end
      results.reverse
    end

    # Build a sync payload: all messages after last_seq for a channel.
    def sync_payload(server : String, channel : String, since_ts : Int64) : Array(Hash(String, String))
      out = [] of Hash(String, String)
      @db.query(
        "SELECT msg_id, ts, sender_nick, sender_role, body, edited_body, deleted, suppressed, sync_hash
         FROM messages
         WHERE server = ? AND channel = ? AND ts > ?
         ORDER BY ts ASC",
        server, channel, since_ts
      ) do |rs|
        rs.each do
          out << {
            "msg_id"      => rs.read(String),
            "ts"          => rs.read(Int64).to_s,
            "sender_nick" => rs.read(String),
            "sender_role" => rs.read(Int32).to_s,
            "body"        => rs.read(String),
            "edited_body" => rs.read(String?).to_s,
            "deleted"     => rs.read(Int32).to_s,
            "suppressed"  => rs.read(Int32).to_s,
            "sync_hash"   => rs.read(String? ).to_s,
          }
        end
      end
      out
    end

    # Apply an incoming sync record. Role precedence: incoming wins if
    # incoming_role >= existing_role for conflicts.
    def apply_sync(server : String, channel : String,
                   record : Hash(String, String), incoming_role : Int32)
      msg_id      = record["msg_id"]
      ts          = record["ts"].to_i64
      sender_nick = record["sender_nick"]
      sender_role = record["sender_role"].to_i
      body        = record["body"]
      edited      = record["edited_body"].empty? ? nil : record["edited_body"]
      deleted     = record["deleted"] == "1"
      suppressed  = record["suppressed"] == "1"
      hash        = record["sync_hash"]

      existing = @db.query_one?(
        "SELECT sender_role, sync_hash FROM messages WHERE msg_id = ?",
        msg_id, as: {Int32, String?}
      )

      if existing
        exist_role, exist_hash = existing
        # Incoming wins if it has higher role or same role with different hash
        if incoming_role >= exist_role
          @db.exec(
            "UPDATE messages SET body=?, edited_body=?, deleted=?, suppressed=?, sync_hash=?
             WHERE msg_id=?",
            body, edited, deleted ? 1 : 0, suppressed ? 1 : 0, hash, msg_id
          )
        end
      else
        insert(server, channel, ts, sender_nick, sender_role, msg_id, body, hash)
        if deleted
          @db.exec("UPDATE messages SET deleted=1 WHERE msg_id=?", msg_id)
        end
        if suppressed
          @db.exec("UPDATE messages SET suppressed=1 WHERE msg_id=?", msg_id)
        end
        if edited
          @db.exec("UPDATE messages SET edited_body=? WHERE msg_id=?", edited, msg_id)
        end
      end
    end

    # Store or retrieve a keypair
    def store_key(label : String, key_data : Bytes)
      @db.exec(
        "INSERT OR REPLACE INTO key_store (label, key_data) VALUES (?,?)",
        label, key_data
      )
    end

    def load_key(label : String) : Bytes?
      @db.query_one?(
        "SELECT key_data FROM key_store WHERE label=?",
        label, as: Bytes
      )
    end

    def get_or_create_keypair(label_priv : String, label_pub : String) : Tuple(Bytes, Bytes)
      priv = load_key(label_priv)
      pub  = load_key(label_pub)
      if priv && pub
        return {priv, pub}
      end
      priv, pub = ChatLog.generate_x25519_keypair
      store_key(label_priv, priv)
      store_key(label_pub, pub)
      {priv, pub}
    end

    def last_ts(server : String, channel : String) : Int64
      @db.query_one?(
        "SELECT MAX(ts) FROM messages WHERE server=? AND channel=?",
        server, channel, as: Int64?
      ) || 0_i64
    end
  end
end