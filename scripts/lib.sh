#!/usr/bin/env bash
# lib.sh — zero-config setup shared by the MCP launcher and the hooks.
#
# Everything lives in one data dir per user and machine (agichan_data), shared
# by Claude Code, Codex, opencode and pi, so their sessions on a project are
# one crew:
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
AGICHAN_MAX_CLI_MIB=512 # a download unpacking to more is refused unread
AGICHAN_LIB=$(readlink -f "${BASH_SOURCE[0]}")

# Data directory: AGICHAN_DATA; else, when installed by install.sh as
# <prefix>/app/scripts/lib.sh, <prefix>; else ~/.local/share/agichan. Never
# Claude Code's per-plugin dir: a sponsor per harness meant a channel per
# harness, so Claude Code and Codex sessions on one project never met.
agichan_data() {
  if [ -n "${AGICHAN_DATA:-}" ]; then
    printf '%s' "$AGICHAN_DATA"
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

# 0 when this CLI has `chat --bound-devices-only`: share keys with, and accept
# shares from, only devices whose key is their wallet's, so the node cannot
# add a device of its own to a member. Every agichan session's device is its
# wallet's, so an agichan channel loses nothing by it. Older CLIs refuse the
# flag; their usage text (no subcommand) does not name it. Captured, not
# piped: `chat` alone exits 2, which pipefail would report as "not found".
agichan_has_bound_devices() { # <bin>
  local usage
  usage=$("$1" chat 2>&1)
  [[ $usage == *--bound-devices-only* ]]
}

# Where handle wallets live: under the home in this uid's /etc/passwd line,
# read as slonana's chat and mcp-chat read it (common/passwd_home.h), so a
# session is one identity whether it talks MCP or the CLI, even when $HOME
# differs (sudo -E, containers).
agichan_keys_dir() {
  local h
  h=$(awk -F: -v u="$(id -u)" '/^#/ { next } NF >= 6 && $3 == u { print $6; exit }' \
    /etc/passwd 2>/dev/null)
  case $h in /*) ;; *) h=$HOME ;; esac
  printf '%s' "$h/.config/slonana/aexchat/agents"
}
agichan_handle_key() { printf '%s/%s.json' "${2:-$(agichan_keys_dir)}" "$1"; } # <handle> [keys dir]
# = is_chat_handle (a letter or digit first: a handle reaches argv), and not
# ALL, which addresses everyone.
agichan_valid_handle() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]] && [ "$1" != ALL ]; }

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

# 0 when this machine's openssl can check Ed25519 at all: it must accept a
# published release's (v0.1.9055) signature under the release key. Tells "the
# signature is bad" apart from "OpenSSL is older than 3.0" (no -rawin).
agichan_verifier_works() { # <work>
  mkdir -p "$1/ctl" &&
    agichan_verify_sig e3e0b4564f141889f8964b1309c8620e7fc8f98d7d1181a931713f296b4c7cfd \
      3NeCH5LRzg1cDTXTyCyoixtsG8wYMRKvtsGYUGZ71VMbUBHUNWXqsDmpn7gxSCRNdhvXBd2JQwZuEtb54uc7jgQ6 \
      GX8ntPDTJoAh3w7uC9AHazPcSCqGGScJZXkPUZMCrGUk "$1/ctl"
}

# A release version is v<major>.<minor>.<patch>-slon, as every published
# manifest carries. Only a constrained string makes "the signed binary
# contains it" mean anything (slonana's update.cpp, is_release_version).
agichan_is_release_version() { [[ ${1:-} =~ ^v[0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9}-slon$ ]]; }

# 0 when release version $1 is newer than release version $2.
agichan_newer() {
  local -a a b
  local i
  agichan_is_release_version "${1:-}" && agichan_is_release_version "${2:-}" || return 1
  IFS=. read -r -a a <<<"${1#v}"
  IFS=. read -r -a b <<<"${2#v}"
  a[2]=${a[2]%-slon} b[2]=${b[2]%-slon}
  for i in 0 1 2; do
    ((10#${a[i]} > 10#${b[i]})) && return 0
    ((10#${a[i]} < 10#${b[i]})) && return 1
  done
  return 1
}

# curl for the release site: https only, redirects included (file:// is for
# the selftest's fake site); gives up on a connection that stalls.
agichan_curl() { curl -fsSL --proto '=https,file' --proto-redir '=https' \
  --connect-timeout 20 --speed-limit 1024 --speed-time 60 "$@"; }

# Installs <base>'s published CLI at <dest> only when all of these hold:
#  1. the manifest names a release version newer than <dest>'s (if any);
#  2. the binary unpacks to under AGICHAN_MAX_CLI_MIB and its SHA-256 is the
#     manifest's;
#  3. the manifest's signature over that digest verifies under <pubkey>;
#  4. the verified binary contains the manifest's version string.
# The signature covers the digest only, never the version field, so 1 and 4
# together are what stop a downgrade to an old, genuinely signed release.
# Nothing runs before all four hold. Staged in <dest's dir>/.fetch (mode 700),
# which the next fetch overwrites: agichan deletes nothing.
agichan_fetch_release() { # <base> <pubkey_b58> <dest>
  local t st m sha sig ver have n cap=$((AGICHAN_MAX_CLI_MIB << 20))
  local -a s
  for t in curl gunzip sha256sum openssl awk flock grep; do
    command -v "$t" >/dev/null 2>&1 || { echo "agichan: needs '$t' to install the CLI" >&2; return 1; }
  done
  st="$(dirname "$3")/.fetch"
  (umask 077 && mkdir -p "$st") && chmod 700 "$st" || return 1 # bin/ too: it holds the executable
  m="$st/m.json"
  agichan_curl --max-time 30 --max-filesize 65536 "$1/slonana.manifest.json" -o "$m" ||
    { echo "agichan: could not download the release manifest from $1" >&2; return 1; }
  sha=$(sed -n 's/.*"sha256":"\([0-9a-f]\{64\}\)".*/\1/p' "$m")
  sig=$(sed -n 's/.*"signature":"\([1-9A-HJ-NP-Za-km-z]\{64,100\}\)".*/\1/p' "$m")
  ver=$(agichan_version_of "$m")
  [ -n "$sha" ] && [ -n "$sig" ] && agichan_is_release_version "$ver" ||
    { echo "agichan: the release manifest at $1 is malformed; not installed" >&2; return 1; }
  have=$(agichan_version_of "$3.manifest.json")
  if agichan_is_release_version "$have" && ! agichan_newer "$ver" "$have"; then
    echo "agichan: $ver is not newer than the installed $have; not installed" >&2
    return 1
  fi
  agichan_curl "$1/slonana.gz" | gunzip -c 2>/dev/null | head -c "$cap" >"$st/slonana"
  s=("${PIPESTATUS[@]}")
  n=$(wc -c <"$st/slonana")
  [ "$((n))" -lt "$cap" ] ||
    { echo "agichan: the CLI at $1 unpacks to over $AGICHAN_MAX_CLI_MIB MiB; not installed" >&2; return 1; }
  [ "${s[0]}" = 0 ] && [ "${s[1]}" = 0 ] ||
    { echo "agichan: could not download the CLI from $1" >&2; return 1; }
  [ "$(sha256sum "$st/slonana" | cut -c1-64)" = "$sha" ] ||
    { echo "agichan: downloaded CLI does not match its manifest digest; not installed" >&2; return 1; }
  if ! agichan_verify_sig "$sha" "$sig" "$2" "$st"; then
    if agichan_verifier_works "$st"; then
      echo "agichan: release signature does not verify under the pinned key; not installed" >&2
    else
      echo "agichan: this openssl cannot check Ed25519 signatures (needs OpenSSL 3.0 or later); not installed" >&2
    fi
    return 1
  fi
  grep -qaF -- "$ver" "$st/slonana" ||
    { echo "agichan: the signed CLI does not carry its manifest's version $ver; not installed" >&2; return 1; }
  # Same directory as <dest>, so each rename is atomic.
  chmod 755 "$st/slonana" && cp "$m" "$st/installed.json" &&
    mv -f "$st/slonana" "$3" && mv -f "$st/installed.json" "$3.manifest.json"
}

# Serialises first-run steps across processes. The data dir holds keys, so a
# new one is private to this user.
agichan_locked() { # <cmd...>
  local d
  d=$(agichan_data)
  mkdir -p "$(dirname "$d")" && (umask 077 && mkdir -p "$d") || return 1
  (flock -w 300 9 || exit 1; "$@") 9>"$d/.lock"
}

# Runs lib function <fn> <args...> in a new bash, detached: no stdio and its
# own session, so a hook or server that exits or times out never waits on it.
agichan_detach() { # <fn> <args...>
  local -a run=(bash -c '. "$1"; shift; "$@"' agichan-bg "$AGICHAN_LIB" "$@")
  if command -v setsid >/dev/null 2>&1; then
    setsid "${run[@]}" </dev/null >/dev/null 2>&1 &
  else
    ("${run[@]}" </dev/null >/dev/null 2>&1 &)
  fi
}

# Prints the CLI path: an explicit one, else the verified download in the data
# dir (fetched on first use). A `slonana` on PATH is deliberately NOT used: it
# may be an old build without the tools this plugin calls.
agichan_bin() { # [override]
  local d
  if [ -n "${1:-}" ]; then printf '%s' "$1"; return 0; fi
  d=$(agichan_data)
  if [ -x "$d/bin/slonana" ]; then
    # At most daily, a newer published release replaces this one through the
    # same checks, in the background: a hook or a server start never waits on
    # a download, and any failure keeps the installed, verified copy.
    if [ -z "$(find "$d/bin/slonana.checked" -mmin -1440 2>/dev/null)" ]; then
      : >"$d/bin/slonana.checked"
      agichan_detach agichan_locked _agichan_update "$d/bin/slonana" \
        "$AGICHAN_RELEASE_BASE" "$AGICHAN_RELEASE_KEY"
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
  if [ ! -x "$1" ]; then
    agichan_fetch_release "$AGICHAN_RELEASE_BASE" "$AGICHAN_RELEASE_KEY" "$1" || return 1
  fi
  : >"$1.checked"
}

agichan_version_of() { sed -n 's/.*"version":"\([^"]*\)".*/\1/p' "$1" 2>/dev/null; }

# Replaces <dest> when <base> publishes a newer release version. The check is
# recorded even when it fails, so an outage costs one try a day.
_agichan_update() { # <dest> <base> <pubkey_b58>
  local now have
  : >"$1.checked"
  now=$(agichan_curl --max-time 30 --max-filesize 65536 "$2/slonana.manifest.json" |
    sed -n 's/.*"version":"\([^"]*\)".*/\1/p') || return 1
  agichan_is_release_version "$now" || return 1
  have=$(agichan_version_of "$1.manifest.json")
  if agichan_is_release_version "$have" && ! agichan_newer "$now" "$have"; then
    return 0
  fi
  agichan_fetch_release "$2" "$3" "$1"
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
  _agichan_adopt "$(dirname "$3")" || return 1
  if [ ! -s "$3" ]; then
    (umask 077 && "$1" keygen new --outfile "$3" >/dev/null 2>&1) && chmod 600 "$3" ||
      { echo "agichan: could not create the sponsor wallet" >&2; return 1; }
  fi
  [ -f "$3.login" ] && return 0
  "$1" -k "$3" -u "$2" chat login >/dev/null 2>&1 ||
    { echo "agichan: sponsor login to $2 failed" >&2; return 1; }
  : >"$3.login"
}

# The Claude Code plugin used to keep its own sponsor and channels in
# CLAUDE_PLUGIN_DATA. A data dir with no sponsor yet takes a copy of them, so
# a plugin user keeps their channels; the old files stay. A data dir that has
# a sponsor keeps it: those channels have other members.
_agichan_adopt() { # <data dir>
  local old=${CLAUDE_PLUGIN_DATA:-} f
  [ -n "$old" ] && [ "$old" != "$1" ] && [ -s "$old/sponsor.json" ] &&
    [ ! -e "$1/sponsor.json" ] || return 0
  (umask 077 && cp "$old/sponsor.json" "$1/sponsor.json") ||
    { echo "agichan: could not copy the sponsor wallet from $old" >&2; return 1; }
  [ -f "$old/sponsor.json.login" ] && : >"$1/sponsor.json.login"
  mkdir -p "$1/rooms"
  for f in "$old/rooms/"*; do
    [ -f "$f" ] && [ ! -e "$1/rooms/${f##*/}" ] && cp "$f" "$1/rooms/"
  done
  return 0 # silent: the hook reads setup's first lines as bin, key, room
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
  # A random name: the relay stores room names in plaintext, and a project's
  # directory name is not its business.
  name="agichan-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
  id=$("$1" -k "$3" -u "$2" chat create "$name" 2>/dev/null |
    sed -n 's/.*"room_id":"\(![^"]*\)".*/\1/p')
  [ -n "$id" ] || { echo "agichan: could not create a channel on $2" >&2; return 1; }
  mkdir -p "$(dirname "$5")" && printf '%s\n' "$id" >"$5"
}
