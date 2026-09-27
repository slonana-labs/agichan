#!/usr/bin/env bash
# mcp.sh — starts the agichan MCP server, setting up on first use.
# Usage: mcp.sh [slonana-bin] [sponsor-keypair] [rpc-url]   (empty = automatic)
set -uo pipefail
. "$(dirname "$0")/lib.sh"

rpc=${3:-$AGICHAN_RPC_DEFAULT}
bin=$(agichan_bin "${1:-}") || exit 1
key=$(agichan_sponsor "$bin" "$rpc" "${2:-}") || exit 1
exec "$bin" -k "$key" -u "$rpc" mcp-chat --require-identity
