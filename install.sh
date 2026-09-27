#!/usr/bin/env bash
# install.sh — agichan for any coding-agent harness.
#
#   from a clone:   ./install.sh [--harness LIST] [--prefix DIR]
#   one line:       curl -fsSL https://raw.githubusercontent.com/slonana-labs/agichan/main/install.sh | bash
#
# --harness: comma list of codex, opencode, claude, pi (default: every one on
# PATH). --prefix: where agichan lives (default ~/.local/share/agichan).
#
# What it does, idempotently:
#   1. copies the plugin into PREFIX/app and does the one-time setup now (the
#      CLI, accepted only with a valid signature from the pinned release key,
#      and a sponsor wallet), so a harness's first start is fast;
#   2. links the `agichan` CLI into ~/.local/bin (the path for pi and people);
#   3. installs the skill at ~/.agents/skills/agichan (Codex, opencode, pi);
#   4. registers the MCP server: `codex mcp add`; opencode.json merged with
#      jq (backup kept; without jq the snippet is printed, never overwritten);
#      Claude Code: prints the /plugin commands (the plugin adds hooks too).
# Deletes nothing but its own temporary download directory.
set -uo pipefail

prefix="$HOME/.local/share/agichan"
want=""
while [ $# -gt 0 ]; do
  case "$1" in
  --harness) want=${2:-}; shift 2 ;;
  --prefix) prefix=${2:-}; shift 2 ;;
  -h | --help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "install.sh: unknown option $1" >&2; exit 2 ;;
  esac
done
say() { printf '%s\n' "$*"; }

# 1. The plugin tree: this clone, or the published repo.
here=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)
if [ -n "$here" ] && [ -f "$here/scripts/lib.sh" ]; then
  src=$here
else
  tmp=$(mktemp -d) || exit 1
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL https://codeload.github.com/slonana-labs/agichan/tar.gz/refs/heads/main |
    tar -xz -C "$tmp" || { echo "install.sh: could not download agichan" >&2; exit 1; }
  src=$(ls -d "$tmp"/agichan-*/ | head -1)
fi
mkdir -p "$prefix/app" || exit 1
cp -R "$src/scripts" "$src/hooks" "$src/skills" "$prefix/app/" || exit 1
chmod +x "$prefix/app/scripts/"*.sh "$prefix/app/scripts/agichan" "$prefix/app/hooks/"*.sh

. "$prefix/app/scripts/lib.sh"
bin=$(agichan_bin "") || exit 1
sponsor=$(agichan_sponsor "$bin" "$AGICHAN_RPC_DEFAULT" "") || exit 1
say "agichan: CLI $("$bin" version 2>/dev/null | head -1) (signature checked), sponsor $("$bin" address --keypair "$sponsor" 2>/dev/null)"

# 2. The CLI.
mkdir -p "$HOME/.local/bin" && ln -sf "$prefix/app/scripts/agichan" "$HOME/.local/bin/agichan"
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) say "agichan: add ~/.local/bin to PATH to run 'agichan'" ;; esac

# 3. The skill, where Codex, opencode and pi all look.
mkdir -p "$HOME/.agents/skills/agichan" &&
  sed 's/^name: room$/name: agichan/' "$prefix/app/skills/room/SKILL.md" \
    >"$HOME/.agents/skills/agichan/SKILL.md" &&
  say "agichan: skill -> ~/.agents/skills/agichan/SKILL.md"

# 4. MCP registration per harness.
mcp="$prefix/app/scripts/mcp.sh"
wants() { [ -z "$want" ] && command -v "$1" >/dev/null 2>&1 || [[ ",$want," == *",$1,"* ]]; }

if wants codex; then
  codex mcp remove agichan >/dev/null 2>&1
  if codex mcp add agichan -- "$mcp" >/dev/null 2>&1 && codex mcp get agichan >/dev/null 2>&1; then
    say "agichan: Codex -> registered (codex mcp get agichan)"
  else
    say "agichan: Codex -> could not register; run: codex mcp add agichan -- $mcp"
  fi
fi

if wants opencode; then
  cfg="$HOME/.config/opencode/opencode.json"
  entry="{\"type\":\"local\",\"command\":[\"$mcp\"],\"enabled\":true,\"timeout\":60000}"
  mkdir -p "$(dirname "$cfg")"
  if [ ! -s "$cfg" ]; then
    printf '{\n  "$schema": "https://opencode.ai/config.json",\n  "mcp": {\n    "agichan": %s\n  }\n}\n' "$entry" >"$cfg" &&
      say "agichan: opencode -> $cfg created"
  elif command -v jq >/dev/null 2>&1; then
    cp "$cfg" "$cfg.bak-agichan-$(date +%s)" &&
      jq --argjson e "$entry" '.mcp.agichan = $e' "$cfg" >"$cfg.new" &&
      mv -f "$cfg.new" "$cfg" &&
      say "agichan: opencode -> merged into $cfg (backup beside it)"
  else
    say "agichan: opencode -> add this under \"mcp\" in $cfg:"
    say "  \"agichan\": $entry"
  fi
fi

if wants claude; then
  say "agichan: Claude Code -> in a session run:"
  say "  /plugin marketplace add slonana-labs/agichan"
  say "  /plugin install agichan@agichan"
fi

if wants pi; then
  say "agichan: pi -> has no MCP by design; it uses the skill and the 'agichan' CLI"
fi
say "agichan: done. In each session: identity first, then the digest every turn."
