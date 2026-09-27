#!/usr/bin/env bash
# lib.sh — zero-config setup shared by the MCP launcher and the hooks.
#
# Everything lives in the plugin's data dir (CLAUDE_PLUGIN_DATA, kept across
# plugin updates):
#   bin/slonana       the CLI, downloaded from the release site and accepted
#                     only if its SHA-256 digest carries an Ed25519 signature
#                     by the PINNED release key, checked with openssl before
#                     the binary is ever run
#   sponsor.json      a wallet created on first use; it invites each session's
#                     own wallet and reads channels for the hooks
#   rooms/<hash>      one channel per project directory, created on first use
# Concurrent first starts (MCP server + hooks + other sessions) serialise on
# flock, so nothing downloads twice and no project gets two channels.
#
# Sourced, not run. Functions print a one-line reason to stderr and return
# non-zero on failure; they never exit the caller.

AGICHAN_RELEASE_BASE="https://slonana.com/dl"
AGICHAN_RELEASE_KEY="GX8ntPDTJoAh3w7uC9AHazPcSCqGGScJZXkPUZMCrGUk"
AGICHAN_RPC_DEFAULT="https://rpc.slonana.com"

# Data directory: Claude Code's per-plugin one; else, when installed by
# install.sh as <prefix>/app/scripts/lib.sh, <prefix>; else the default.
agichan_data() {
  if [ -n "${CLAUDE_PLUGIN_DATA:-}" ]; then
    printf '%s' "$CLAUDE_PLUGIN_DATA"
    return
  fi
  local app
  app=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)
  if [ "$(basename "$app")" = app ] && [ -f "$app/scripts/mcp.sh" ]; then
    dirname "$app"
    return
  fi
  printf '%s' "$HOME/.local/share/agichan"
}

# Task-board lines a session should see: unfinished tasks, and a DONE task's
# line with the UNPAID line printed under it. mcp-chat's chat_digest applies
# the same rule (open_board_lines in mcp_chat_protocol.h).
board_filter() {
  awk '
    /\[(open|claimed|blocked)\]/ { print; next }
    /^    UNPAID:/ { if (prev != "") print prev; print }
    { prev = $0 }'
}

# Where a handle's own wallet lives: the path mcp-chat's chat_identity uses,
# so a session is the same identity whether it talks MCP or the CLI.
agichan_handle_key() { printf '%s' "$HOME/.config/slonana/aexchat/agents/$1.json"; }
agichan_valid_handle() { [[ $1 =~ ^[A-Za-z0-9_-]{1,64}$ ]]; } # = is_chat_handle

# base58 (bitcoin alphabet) -> lowercase hex.
agichan_b58_hex() {
  printf '%s\n' "$1" | awk '
    BEGIN { A = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz" }
    { s = $0; n = 0; split("", b)
      for (i = 1; i <= length(s); i++) {
        v = index(A, substr(s, i, 1)) - 1
        if (v < 0) exit 1
        c = v
        for (j = 0; j < n; j++) { c += b[j] * 58; b[j] = c % 256; c = int(c / 256) }
        while (c > 0) { b[n++] = c % 256; c = int(c / 256) }
      }
      z = 0; while (substr(s, z + 1, 1) == "1") z++
      out = ""; for (k = 0; k < z; k++) out = out "00"
      for (j = n - 1; j >= 0; j--) out = out sprintf("%02x", b[j])
      print out }'
}

agichan_hex_bin() { printf '%s' "$1" | sed 's/../\\x&/g' | xargs -0 printf '%b'; }

# 0 when <sig_b58> is <pubkey_b58>'s Ed25519 signature over the 32-byte
# SHA-256 digest <digest_hex>. Uses only openssl; <work> is a scratch dir.
agichan_verify_sig() { # <digest_hex> <sig_b58> <pubkey_b58> <work>
  local pk sig
  pk=$(agichan_b58_hex "$3") && [ ${#pk} -eq 64 ] || return 1
  sig=$(agichan_b58_hex "$2") && [ ${#sig} -eq 128 ] || return 1
  [ ${#1} -eq 64 ] || return 1
  { agichan_hex_bin 302a300506032b6570032100; agichan_hex_bin "$pk"; } >"$4/pk.der"
  openssl pkey -pubin -inform DER -in "$4/pk.der" -out "$4/pk.pem" 2>/dev/null || return 1
  agichan_hex_bin "$sig" >"$4/sig.bin"
  agichan_hex_bin "$1" >"$4/digest.bin"
  openssl pkeyutl -verify -pubin -inkey "$4/pk.pem" -rawin \
    -in "$4/digest.bin" -sigfile "$4/sig.bin" >/dev/null 2>&1
}

# Downloads <base>/slonana.gz + manifest into <dest>, accepting it only when
# the digest matches the manifest AND the manifest's signature verifies under
# <pubkey>. The binary is not executed before that.
agichan_fetch_release() { # <base> <pubkey_b58> <dest>
  local t
  for t in curl gunzip sha256sum openssl awk flock; do
    command -v "$t" >/dev/null 2>&1 || { echo "agichan: needs '$t' to install the CLI" >&2; return 1; }
  done
  ( # subshell: the EXIT trap removes this run's own scratch dir
    tmp=$(mktemp -d) || exit 1
    trap 'rm -rf "$tmp"' EXIT
    curl -fsSL "$1/slonana.manifest.json" -o "$tmp/m.json" &&
      curl -fsSL "$1/slonana.gz" -o "$tmp/s.gz" &&
      gunzip -c "$tmp/s.gz" >"$tmp/slonana" ||
      { echo "agichan: could not download the CLI from $1" >&2; exit 1; }
    sha=$(sed -n 's/.*"sha256":"\([0-9a-f]\{64\}\)".*/\1/p' "$tmp/m.json")
    sig=$(sed -n 's/.*"signature":"\([1-9A-HJ-NP-Za-km-z]*\)".*/\1/p' "$tmp/m.json")
    [ -n "$sha" ] && [ "$(sha256sum "$tmp/slonana" | cut -c1-64)" = "$sha" ] ||
      { echo "agichan: downloaded CLI does not match its manifest digest; not installed" >&2; exit 1; }
    agichan_verify_sig "$sha" "$sig" "$2" "$tmp" ||
      { echo "agichan: release signature does not verify under the pinned key; not installed" >&2; exit 1; }
    # Staged beside the target so the final rename is atomic (same filesystem).
    mkdir -p "$(dirname "$3")" && cp "$tmp/slonana" "$3.new" && chmod +x "$3.new" &&
      cp "$tmp/m.json" "$3.manifest.json" && mv -f "$3.new" "$3"
  )
}

# Serialises first-run steps across processes.
agichan_locked() { # <cmd...>
  local d
  d=$(agichan_data)
  mkdir -p "$d" || return 1
  (flock -w 300 9 || exit 1; "$@") 9>"$d/.lock"
}

# Prints the CLI path: an explicit one, else the verified download in the data
# dir (fetched on first use). A `slonana` on PATH is deliberately NOT used: it
# may be an old build without the tools this plugin calls.
agichan_bin() { # [override]
  local d
  if [ -n "${1:-}" ]; then printf '%s' "$1"; return 0; fi
  d=$(agichan_data)
  if [ -x "$d/bin/slonana" ]; then
    # At most daily: a newer published release replaces this one, through the
    # same signature check. Any failure keeps the installed, verified copy.
    if [ -z "$(find "$d/bin/slonana.checked" -mmin -1440 2>/dev/null)" ]; then
      agichan_locked _agichan_update "$d/bin/slonana" 2>/dev/null || true
    fi
    printf '%s' "$d/bin/slonana"
    return 0
  fi
  case "$(uname -s)/$(uname -m)" in
  Linux/x86_64) ;;
  *) echo "agichan: no prebuilt CLI for $(uname -s)/$(uname -m) yet (Linux x86-64 only)" >&2; return 1 ;;
  esac
  agichan_locked _agichan_install "$d/bin/slonana" || return 1
  printf '%s' "$d/bin/slonana"
}
_agichan_install() {
  [ -x "$1" ] || agichan_fetch_release "$AGICHAN_RELEASE_BASE" "$AGICHAN_RELEASE_KEY" "$1"
  : >"$1.checked"
}

agichan_version_of() { sed -n 's/.*"version":"\([^"]*\)".*/\1/p' "$1" 2>/dev/null; }

# Replaces <dest> when the published manifest names another version. The
# check is recorded even when it fails, so an outage costs one try a day.
_agichan_update() { # <dest>
  local now
  : >"$1.checked"
  now=$(curl -fsSL --max-time 10 "$AGICHAN_RELEASE_BASE/slonana.manifest.json" |
    sed -n 's/.*"version":"\([^"]*\)".*/\1/p') || return 1
  [ -n "$now" ] && [ "$now" != "$(agichan_version_of "$1.manifest.json")" ] || return 0
  agichan_fetch_release "$AGICHAN_RELEASE_BASE" "$AGICHAN_RELEASE_KEY" "$1"
}

# Prints the sponsor keypair path: an explicit one, or one created and logged
# in on first use.
agichan_sponsor() { # <bin> <rpc> [override]
  local d
  if [ -n "${3:-}" ]; then printf '%s' "$3"; return 0; fi
  d=$(agichan_data)
  agichan_locked _agichan_sponsor "$1" "$2" "$d/sponsor.json" || return 1
  printf '%s' "$d/sponsor.json"
}
_agichan_sponsor() {
  if [ ! -s "$3" ]; then
    "$1" keygen new --outfile "$3" >/dev/null 2>&1 && chmod 600 "$3" ||
      { echo "agichan: could not create the sponsor wallet" >&2; return 1; }
  fi
  [ -f "$3.login" ] && return 0
  "$1" -k "$3" -u "$2" chat login >/dev/null 2>&1 ||
    { echo "agichan: sponsor login to $2 failed" >&2; return 1; }
  : >"$3.login"
}

# Prints the channel for a project dir: an explicit one, or the one this data
# dir created for that directory (created on first use).
agichan_room() { # <bin> <rpc> <key> <project_dir> [override]
  local d f
  if [ -n "${5:-}" ]; then printf '%s' "$5"; return 0; fi
  d=$(agichan_data)
  f="$d/rooms/$(printf '%s' "$4" | sha256sum | cut -c1-16)"
  agichan_locked _agichan_room "$1" "$2" "$3" "$4" "$f" || return 1
  cat "$f"
}
_agichan_room() {
  local name id
  [ -s "$5" ] && return 0
  name="agichan-$(basename "$4" | tr -c 'A-Za-z0-9_-' '-' | cut -c1-40)"
  id=$("$1" -k "$3" -u "$2" chat create "$name" 2>/dev/null |
    sed -n 's/.*"room_id":"\(![^"]*\)".*/\1/p')
  [ -n "$id" ] || { echo "agichan: could not create a channel on $2" >&2; return 1; }
  mkdir -p "$(dirname "$5")" && printf '%s\n' "$id" >"$5"
}
