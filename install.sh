#!/usr/bin/env bash
# install.sh — agichan for any coding-agent harness.
#
#   from a clone:   ./install.sh [--harness LIST] [--prefix DIR]
#   one line:       curl -fsSL https://raw.githubusercontent.com/slonana-labs/agichan/main/install.sh | bash
#   another machine joins a crew, and starts workers:
#                   ... | bash -s -- --join <code> [--dir DIR]
#                         [--workers N --manager <handle> [--agent A] [--repo URL]]
#   check itself:   ./install.sh --selftest
#
# --harness: comma list of codex, opencode, claude, pi (default: every one on
# PATH). --prefix: where agichan lives (default ~/.local/share/agichan).
# --join: `agichan join <code>` for DIR (default: here); --workers then runs
# `agichan workers` there (see scripts/crew.sh).
#
# What it does, idempotently:
#   1. copies the plugin into PREFIX/app and does the one-time setup now (the
#      CLI, accepted only with a valid signature from the pinned release key,
#      and a sponsor wallet), so a harness's first start is fast;
#   2. links the `agichan` CLI into ~/.local/bin, never over another file;
#   3. installs the skill at ~/.agents/skills/agichan (Codex, opencode, pi);
#   4. registers the MCP server: `codex mcp add`; opencode's config merged with
#      jq, rewritten in place (its mode, owner and a symlink kept) after a
#      backup with the same mode, or left untouched with the entry printed
#      when there is no jq, the file is not plain JSON, or it is read-only;
#      Claude Code: prints the /plugin commands (the plugin adds hooks too).
# Deletes nothing: a download is unpacked into PREFIX/download.
set -uo pipefail

SELF=${BASH_SOURCE[0]:-}
say() { printf '%s\n' "$*"; }

# The plugin tree this script belongs to, when run from a clone. Piped into
# bash there is none, and the current directory must not pass for one: it
# may be any project with a scripts/lib.sh of its own.
own_tree() { # <path of this script, empty when piped>
  local d
  [ -n "${1:-}" ] && [ -f "$1" ] || return 1
  d=$(cd "$(dirname "$1")" && pwd) || return 1
  [ -f "$d/scripts/lib.sh" ] &&
    grep -q '"name": *"agichan"' "$d/.claude-plugin/plugin.json" 2>/dev/null || return 1
  printf '%s' "$d"
}

# A JSON string for $1, a path: backslash and double quote escaped.
json_str() { printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }

opencode_entry() { # <mcp launcher>
  printf '{"type":"local","command":[%s],"enabled":true,"timeout":60000}' "$(json_str "$1")"
}

# Puts mcp.agichan into opencode config <cfg>; see step 4 above.
register_opencode() { # <cfg> <mcp launcher>
  local cfg=$1 entry new bak
  entry=$(opencode_entry "$2")
  untouched() {
    say "agichan: opencode -> $cfg $1, left as is; add this under \"mcp\" there:"
    say "  \"agichan\": $entry"
  }
  if [ -L "$cfg" ] && [ ! -e "$cfg" ]; then untouched "is a broken link"; return 0; fi
  if [ ! -s "$cfg" ]; then
    mkdir -p "$(dirname "$cfg")" &&
      printf '{\n  "$schema": "https://opencode.ai/config.json",\n  "mcp": {\n    "agichan": %s\n  }\n}\n' \
        "$entry" >"$cfg" || { say "agichan: opencode -> could not write $cfg"; return 1; }
    say "agichan: opencode -> $cfg created"
    return 0
  fi
  command -v jq >/dev/null 2>&1 || { untouched "exists and there is no jq here to merge it"; return 0; }
  if jq -e --argjson e "$entry" '.mcp.agichan == $e' "$cfg" >/dev/null 2>&1; then
    say "agichan: opencode -> already registered in $cfg"
    return 0
  fi
  new=$(jq --argjson e "$entry" '.mcp.agichan = $e' "$cfg" 2>/dev/null) ||
    { untouched "is not plain JSON (comments?)"; return 0; }
  [ -w "$cfg" ] || { untouched "is read-only"; return 0; }
  bak="$cfg.bak-agichan-$(date +%Y%m%d-%H%M%S)-$$"
  cp -p "$cfg" "$bak" && printf '%s\n' "$new" >"$cfg" ||
    { say "agichan: opencode -> could not write $cfg; the previous copy is $bak"; return 1; }
  say "agichan: opencode -> merged into $cfg (previous copy: $bak)"
}

# Registers the launcher with Codex. `codex mcp add` replaces an entry of the
# same name, so nothing is removed first. grep reads all of `codex mcp get`
# (no -q): stopping early would fail codex's next write, and pipefail would
# report a registered server as missing.
register_codex() { # <mcp launcher>
  local want="  command: $1"
  if codex mcp get agichan 2>/dev/null | grep -xF -- "$want" >/dev/null; then
    say "agichan: Codex -> already registered (codex mcp get agichan)"
  elif codex mcp add agichan -- "$1" >/dev/null 2>&1 &&
    codex mcp get agichan 2>/dev/null | grep -xF -- "$want" >/dev/null; then
    say "agichan: Codex -> registered (codex mcp get agichan)"
  else
    say "agichan: Codex -> could not register; run: codex mcp add agichan -- $1"
  fi
}

# Links <link> to the CLI <target> unless <link> is someone else's file.
# After an install: join the crew in <code> for <dir>, then, given <workers>,
# start that many workers there for <manager>. A failed join stops here, with
# its status as the installer's.
post_install() { # <agichan cli> <code> <dir> <workers> <manager> <agent> <repo>
  local d
  d=$(cd "$3" 2>/dev/null && pwd) || { echo "install.sh: --dir $3 does not exist" >&2; return 2; }
  "$1" join "$2" --dir "$d" || return 1
  [ -n "$4" ] || return 0
  [ -n "$5" ] || { echo "install.sh: --workers needs --manager <handle>" >&2; return 2; }
  local -a r=()
  [ -n "$7" ] && r=(--repo "$7")
  (cd "$d" && "$1" workers --count "$4" --manager "$5" --agent "$6" "${r[@]}")
}

link_cli() { # <target> <link>
  local cur
  if [ -e "$2" ] || [ -L "$2" ]; then
    cur=$(readlink "$2" 2>/dev/null) || cur=""
    case "$cur" in
    "$1" | */app/scripts/agichan) ;;
    *) say "agichan: $2 exists and is not agichan's; left as is (the CLI is $1)"; return 0 ;;
    esac
  fi
  mkdir -p "$(dirname "$2")" && ln -sfn "$1" "$2"
}

main() {
  local prefix="$HOME/.local/share/agichan" want="" src dl bin sponsor mcp
  local join="" dir=$PWD nworkers="" manager="" agent=claude repo=""
  while [ $# -gt 0 ]; do
    case "$1" in
    --harness) want=${2:-}; shift 2 ;;
    --prefix) prefix=${2:-}; shift 2 ;;
    --join) join=${2:-}; shift 2 ;;
    --dir) dir=${2:-}; shift 2 ;;
    --workers) nworkers=${2:-}; shift 2 ;;
    --manager) manager=${2:-}; shift 2 ;;
    --agent) agent=${2:-}; shift 2 ;;
    --repo) repo=${2:-}; shift 2 ;;
    -h | --help) sed -n '2,28p' "$SELF" | sed 's/^# \{0,1\}//'; return 0 ;;
    *) echo "install.sh: unknown option $1" >&2; return 2 ;;
    esac
  done
  wants() { [ -z "$want" ] && command -v "$1" >/dev/null 2>&1 || [[ ",$want," == *",$1,"* ]]; }

  # 1. The plugin tree: this clone, or the published repo.
  if ! src=$(own_tree "$SELF"); then
    dl="$prefix/download"
    (umask 077 && mkdir -p "$dl") || return 1
    curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 20 --max-time 300 \
      https://codeload.github.com/slonana-labs/agichan/tar.gz/refs/heads/main |
      tar -xz -C "$dl" || { echo "install.sh: could not download agichan" >&2; return 1; }
    src="$dl/agichan-main"
    [ -f "$src/scripts/lib.sh" ] || { echo "install.sh: the download has no scripts/lib.sh" >&2; return 1; }
  fi
  # PREFIX is also the data dir (keys, which channel a project uses): private.
  mkdir -p "$(dirname "$prefix")" && (umask 077 && mkdir -p "$prefix") &&
    mkdir -p "$prefix/app" || return 1
  cp -R "$src/scripts" "$src/hooks" "$src/skills" "$prefix/app/" || return 1
  chmod +x "$prefix/app/scripts/"*.sh "$prefix/app/scripts/agichan" "$prefix/app/hooks/"*.sh

  . "$prefix/app/scripts/lib.sh"
  bin=$(agichan_bin "") || return 1
  sponsor=$(agichan_sponsor "$bin" "$AGICHAN_RPC_DEFAULT" "") || return 1
  say "agichan: CLI $("$bin" version 2>/dev/null | sed -n 1p) (signature checked), sponsor $("$bin" address --keypair "$sponsor" 2>/dev/null)"

  # 2. The CLI.
  link_cli "$prefix/app/scripts/agichan" "$HOME/.local/bin/agichan"
  case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) say "agichan: add ~/.local/bin to PATH to run 'agichan'" ;; esac

  # 3. The skill, where Codex, opencode and pi all look.
  mkdir -p "$HOME/.agents/skills/agichan" &&
    sed 's/^name: room$/name: agichan/' "$prefix/app/skills/room/SKILL.md" \
      >"$HOME/.agents/skills/agichan/SKILL.md" &&
    say "agichan: skill -> ~/.agents/skills/agichan/SKILL.md"

  # 4. MCP registration per harness.
  mcp="$prefix/app/scripts/mcp.sh"
  wants codex && register_codex "$mcp"
  wants opencode && register_opencode "$HOME/.config/opencode/opencode.json" "$mcp"
  if wants claude; then
    say "agichan: Claude Code -> in a session run:"
    say "  /plugin marketplace add slonana-labs/agichan"
    say "  /plugin install agichan@agichan"
  fi
  wants pi && say "agichan: pi -> has no MCP by design; it uses the skill and the 'agichan' CLI"
  [ "$prefix" = "$HOME/.local/share/agichan" ] ||
    say "agichan: --prefix $prefix holds its own wallet and channels; Claude Code's plugin shares them only with AGICHAN_DATA=$prefix in its environment"
  say "agichan: done. In each session: identity first, then the digest every turn."
  [ -z "$join" ] || post_install "$prefix/app/scripts/agichan" "$join" "$dir" "$nworkers" \
    "$manager" "$agent" "$repo"
}

# Tests the pieces that touch other people's files, with stand-ins; the
# download and setup are covered by scripts/selftest.sh. Exit 2 = could not
# measure. The scratch dir stays in /tmp, named at the end.
selftest() {
  local t pass=0 fail=0 out cfg mcp e before
  t=$(mktemp -d "${TMPDIR:-/tmp}/agichan-selftest.XXXXXX") || return 2
  command -v jq >/dev/null 2>&1 || { echo "install.sh --selftest: UNMEASURED: needs jq"; return 2; }
  [ "$(id -u)" != 0 ] || { echo "install.sh --selftest: UNMEASURED: run as a user, not root"; return 2; }
  ck() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "  ok   $1"; else
    fail=$((fail + 1)); echo "  FAIL $1 (got '$2', want '$3')"; fi; }
  mcp="$t/my prefix/app/scripts/mcp.sh"
  e=$(opencode_entry "$mcp")

  ck "the entry stays valid JSON for a path with quotes and backslashes" \
    "$(jq -r '.command[0]' <<<"$(opencode_entry 'a"b\c')")" 'a"b\c'

  cfg="$t/h1/opencode.json"
  register_opencode "$cfg" "$mcp" >/dev/null
  ck "no config: one is created with the entry" "$(jq -r '.mcp.agichan.command[0]' "$cfg")" "$mcp"

  cfg="$t/h2/opencode.json"
  mkdir -p "$t/h2"
  printf '{"model":"m","provider":{"x":{"options":{"apiKey":"K"}}},"mcp":{"other":{"type":"local","command":["o"]}}}\n' >"$cfg"
  chmod 600 "$cfg"
  register_opencode "$cfg" "$mcp" >/dev/null
  ck "a merge keeps the user's settings and servers" \
    "$(jq -r '[.model, .provider.x.options.apiKey, .mcp.other.command[0], .mcp.agichan.command[0]] | join("|")' "$cfg")" \
    "m|K|o|$mcp"
  ck "a merge keeps the config's mode" "$(stat -c %a "$cfg")" 600
  ck "the backup keeps it too (it holds the same keys)" "$(stat -c %a "$t"/h2/opencode.json.bak-agichan-*)" 600
  out=$(register_opencode "$cfg" "$mcp")
  ck "a rerun changes nothing and makes no second backup" \
    "$(grep -c 'already registered' <<<"$out") $(find "$t/h2" -name '*bak-agichan*' | wc -l)" "1 1"

  cfg="$t/h3/opencode.json"
  mkdir -p "$t/h3"
  printf '{\n  // mine\n  "model": "m"\n}\n' >"$cfg"
  before=$(sha256sum <"$cfg")
  out=$(register_opencode "$cfg" "$mcp")
  ck "a config with comments is left untouched, the entry printed" \
    "$([ "$(sha256sum <"$cfg")" = "$before" ] && echo same) $(grep -c 'not plain JSON' <<<"$out") $(grep -cF "\"agichan\": $e" <<<"$out")" \
    "same 1 1"

  mkdir -p "$t/h4/dots"
  printf '{"model":"m"}\n' >"$t/h4/dots/opencode.json"
  ln -s "$t/h4/dots/opencode.json" "$t/h4/opencode.json"
  register_opencode "$t/h4/opencode.json" "$mcp" >/dev/null
  ck "a symlinked config stays a link, and its target gets the entry" \
    "$([ -L "$t/h4/opencode.json" ] && echo link) $(jq -r '.mcp.agichan.command[0]' "$t/h4/dots/opencode.json")" \
    "link $mcp"

  cfg="$t/h5/opencode.json"
  mkdir -p "$t/h5" "$t/nojq"
  printf '{"model":"m"}\n' >"$cfg"
  for c in sed cat mkdir dirname; do ln -s "$(command -v "$c")" "$t/nojq/$c"; done
  out=$(PATH="$t/nojq" register_opencode "$cfg" "$mcp")
  ck "without jq an existing config is left untouched, the entry printed" \
    "$(cat "$cfg") $(grep -c 'no jq' <<<"$out")" '{"model":"m"} 1'

  cfg="$t/h6/opencode.json"
  mkdir -p "$t/h6"
  printf '{"model":"m"}\n' >"$cfg"
  chmod 444 "$cfg"
  out=$(register_opencode "$cfg" "$mcp")
  ck "a read-only config is left untouched, with no backup" \
    "$(cat "$cfg") $(find "$t/h6" -name '*bak-agichan*' | wc -l) $(grep -c 'read-only' <<<"$out")" \
    '{"model":"m"} 0 1'

  mkdir -p "$t/cx"
  cat >"$t/cx/codex" <<'EOF'
#!/usr/bin/env bash
d=$(dirname "$0"); echo "$*" >>"$d/calls"
case "$1 $2" in
"mcp get") [ -s "$d/reg" ] || { echo "Error: No MCP server named '$3' found." >&2; exit 1; }
  # Line by line, like codex: a reader that stops at "command:" breaks the rest.
  printf 'agichan\n  enabled: true\n  command: %s\n' "$(cat "$d/reg")"
  sleep 0.2
  printf '  args: -\n  cwd: -\n  env: -\n' ;;
"mcp add") shift 3; [ "$1" = -- ] && shift; printf '%s' "$1" >"$d/reg" ;;
*) exit 1 ;;
esac
EOF
  chmod +x "$t/cx/codex"
  out=$(PATH="$t/cx:$PATH" register_codex "$mcp")
  ck "Codex: a fresh registration is added and confirmed" \
    "$(cat "$t/cx/reg") $(grep -c 'registered (' <<<"$out")" "$mcp 1"
  : >"$t/cx/calls"
  out=$(PATH="$t/cx:$PATH" register_codex "$mcp")
  ck "Codex: a rerun sees it registered and adds nothing" \
    "$(grep -c 'already registered' <<<"$out") $(grep -c add "$t/cx/calls")" "1 0"
  printf '/old/prefix/mcp.sh' >"$t/cx/reg"
  out=$(PATH="$t/cx:$PATH" register_codex "$mcp")
  ck "Codex: an entry pointing elsewhere is replaced" "$(cat "$t/cx/reg")" "$mcp"

  mkdir -p "$t/bin"
  link_cli "$t/app/scripts/agichan" "$t/bin/agichan"
  ck "the CLI link is made" "$(readlink "$t/bin/agichan")" "$t/app/scripts/agichan"
  ln -sfn /elsewhere/app/scripts/agichan "$t/bin/agichan"
  link_cli "$t/app/scripts/agichan" "$t/bin/agichan"
  ck "an older agichan link is repointed" "$(readlink "$t/bin/agichan")" "$t/app/scripts/agichan"
  printf 'mine\n' >"$t/bin/other"
  out=$(link_cli "$t/app/scripts/agichan" "$t/bin/other")
  ck "someone else's file of that name is left alone" \
    "$(cat "$t/bin/other") $(grep -c 'not agichan' <<<"$out")" "mine 1"

  mkdir -p "$t/proj/scripts"
  : >"$t/proj/scripts/lib.sh"
  : >"$t/proj/install.sh"
  ck "piped into bash, the current directory is never taken as the plugin" \
    "$(own_tree "" || echo none) $(own_tree "$t/proj/install.sh" || echo none)" "none none"
  ck "run from a clone, the clone is the plugin" "$(own_tree "$SELF")" "$(cd "$(dirname "$SELF")" && pwd)"

  # --join and --workers, against a stand-in CLI that logs its argv.
  printf '#!/usr/bin/env bash\necho "$*" >>"%s/cli.log"\n[ "$1" != join ] || [ ! -f "%s/join-fails" ]\n' "$t" "$t" >"$t/cli"
  chmod +x "$t/cli"
  mkdir -p "$t/work"
  post_install "$t/cli" CODE "$t/work" 2 lead codex https://git.example/r >/dev/null 2>&1
  ck "--join then --workers: join for the directory, then N workers there" \
    "$(tr '\n' ';' <"$t/cli.log")" \
    "join CODE --dir $t/work;workers --count 2 --manager lead --agent codex --repo https://git.example/r;"
  : >"$t/join-fails"
  out=$(post_install "$t/cli" CODE2 "$t/work" 2 lead codex "" 2>&1; echo "rc=$?")
  ck "a failed join starts no workers and fails the install" \
    "$(grep -c CODE2 "$t/cli.log") $(grep -c 'workers' "$t/cli.log") $(tail -1 <<<"$out")" "1 1 rc=1"
  out=$(post_install "$t/cli" CODE3 "$t/nowhere" 2 lead codex "" 2>&1; echo "rc=$?")
  ck "a missing --dir is refused before anything runs" \
    "$(grep -c CODE3 "$t/cli.log") $(tail -1 <<<"$out")" "0 rc=2"

  echo "install.sh --selftest: $pass/$((pass + fail)) PASS (scratch: $t)"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = --selftest ]; then
  selftest
  exit $?
fi
main "$@"
