#!/usr/bin/env bash
# mcp.sh — starts the agichan MCP server for any MCP harness (Claude Code,
# Codex, opencode, ...), setting up on first use.
# Usage: mcp.sh [slonana-bin] [sponsor-keypair] [rpc-url] [room]
#        (empty = automatic)
set -uo pipefail
. "$(dirname "$0")/lib.sh"

rpc=${3:-$AGICHAN_RPC_DEFAULT}
bin=$(agichan_bin "${1:-}") || exit 1
key=$(agichan_sponsor "$bin" "$rpc" "${2:-}") || exit 1

# This project's channel, passed as --room so the server's instructions name
# it. Claude Code starts plugin servers in the plugin's own directory, so
# there only CLAUDE_PROJECT_DIR identifies the project (else its hook tells
# the model the room); other harnesses start servers in the project.
room=${4:-}
if [ -z "$room" ]; then
  proj=${CLAUDE_PROJECT_DIR:-}
  [ -z "$proj" ] && [ -z "${CLAUDE_PLUGIN_ROOT:-}" ] && proj=$PWD
  if [ -n "$proj" ]; then
    room=$(agichan_room "$bin" "$rpc" "$key" "$proj") || room=""
  fi
fi

args=(mcp-chat --require-identity)
[ -n "$room" ] && args+=(--room "$room")
exec "$bin" -k "$key" -u "$rpc" "${args[@]}"
