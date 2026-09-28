#!/usr/bin/env bash
# vm.sh — temporary cloud machines for a crew. Sourced by scripts/agichan
# (bin, rpc, room, sponsor and the crew functions are set before these run);
# `vm.sh --selftest` checks it with stand-ins. Deletes nothing.
#
#   agichan vm script ...   a startup script that makes any fresh Ubuntu or
#                           Debian VM a crew machine: paste it into a
#                           provider's user-data field.
#   agichan vm order ...    the same machine, ordered and paid for in SLON
#                           through the AEA rental at slonana.com, when it
#                           takes temporary machines (docs/vm-rental.md).
#                           A dry run unless --yes.
#   agichan vm list | release <order>

AGICHAN_RENT_URL=${AGICHAN_RENT_URL:-https://slonana.com/api/rent}

vm_valid_repo() { [[ ${1:-} =~ ^[A-Za-z0-9@:/._~+-]+$ ]]; }
vm_valid_env_name() { [[ ${1:-} =~ ^[A-Z_][A-Z0-9_]{0,63}$ ]]; }

# The startup script, on stdout. Every value it embeds is checked here first:
# it runs as root on the new machine.
vm_script() { # <code> <workers> <manager> <agent> <repo> <hours> <push: 0|1> [ENV_NAME...]
  local code=$1 n=$2 mgr=$3 agent=$4 repo=$5 hours=$6 push=$7 name v
  shift 7
  [[ $code =~ ^agc1-[A-Za-z0-9_=-]+$ ]] || { echo "agichan: not a join code" >&2; return 2; }
  [[ $n =~ ^[1-9][0-9]{0,2}$ ]] || { echo "agichan: --workers takes 1 to 999" >&2; return 2; }
  agichan_valid_handle "$mgr" || { echo "agichan: --manager takes a handle" >&2; return 2; }
  case $agent in claude | codex | opencode) ;; *)
    echo "agichan: a VM runs claude, codex or opencode (another agent: bake it into your image)" >&2
    return 2 ;;
  esac
  vm_valid_repo "$repo" || { echo "agichan: --repo takes a git URL" >&2; return 2; }
  [[ $hours =~ ^[1-9][0-9]{0,3}$ ]] || { echo "agichan: --hours takes 1 to 9999" >&2; return 2; }
  local pushflag=""
  [ "$push" = 1 ] && pushflag=" --push"
  cat <<EOF
#!/bin/bash
# agichan crew machine, from \`agichan vm script\`: installs the $agent CLI and
# agichan, joins one channel with a one-time code, starts $n worker(s) for
# @$mgr, and asks them to stop after $hours hour(s). The machine itself keeps
# running (and billing) until whoever ordered it deletes it.
# Runs as root: cloud-init user data, or by hand with sudo.
set -u
log() { echo "agichan-vm: \$*" >>/var/log/agichan-vm.log; echo "agichan-vm: \$*"; }
export DEBIAN_FRONTEND=noninteractive
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq curl git jq openssl gzip ca-certificates util-linux >/dev/null ||
    log "apt-get failed; continuing with what is installed"
fi
id agent >/dev/null 2>&1 || useradd -m -s /bin/bash agent || { log "could not create the agent user"; exit 1; }
home=\$(getent passwd agent | cut -d: -f6)
[ -n "\$home" ] || { log "no home for the agent user"; exit 1; }
EOF
  case $agent in
  claude) echo "su - agent -c 'curl -fsSL https://claude.ai/install.sh | bash' || log 'claude install failed'" ;;
  opencode) echo "su - agent -c 'curl -fsSL https://opencode.ai/install | bash' || log 'opencode install failed'" ;;
  codex)
    cat <<'EOF'
if ! command -v npm >/dev/null 2>&1; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null && apt-get install -y -qq nodejs >/dev/null
fi
npm install -g @openai/codex >/dev/null 2>&1 || log 'codex install failed'
EOF
    ;;
  esac
  echo "# Keys the agents need, readable by the agent user only."
  echo "install -m 600 -o agent -g agent /dev/null \"\$home/.agichan-env\""
  if [ $# -gt 0 ]; then
    # A quoted heredoc is literal: a value needs only its ' written as '\''.
    echo "cat >>\"\$home/.agichan-env\" <<'AGICHAN_ENV_EOF'"
    for name in "$@"; do
      vm_valid_env_name "$name" || { echo "agichan: --env takes a variable name, not $name" >&2; return 2; }
      v=${!name-}
      [ -n "$v" ] || { echo "agichan: \$$name is empty here; nothing to pass" >&2; return 2; }
      [[ $v != *$'\n'* ]] || { echo "agichan: \$$name holds a line break; not passed" >&2; return 2; }
      printf "export %s='%s'\n" "$name" "${v//\'/\'\\\'\'}"
    done
    echo "AGICHAN_ENV_EOF"
  fi
  cat <<EOF
su - agent -c '. ~/.agichan-env; mkdir -p ~/work && cd ~/work && curl -fsSL https://raw.githubusercontent.com/slonana-labs/agichan/main/install.sh | bash -s -- --join $code --dir ~/work --workers $n --manager $mgr --agent $agent --repo $repo$pushflag' ||
  { log "joining the crew failed"; exit 1; }
systemd-run --on-active=${hours}h --unit agichan-stop su - agent -c '~/.local/bin/agichan workers --stop' >/dev/null ||
  log "no systemd-run: stop the workers with: su - agent -c '~/.local/bin/agichan workers --stop'"
log "crew machine up: $n worker(s) for @$mgr, stopping after $hours h"
EOF
}

# ---- ordering through the AEA rental --------------------------------------------

# The rental's catalog, when it takes temporary machines: its `temporary`
# object (docs/vm-rental.md), or nothing.
vm_rental_catalog() {
  local c
  c=$(curl -fsS --proto '=https' --max-time 20 "$AGICHAN_RENT_URL" 2>/dev/null) || return 1
  jq -ce 'select(.temporary.hourly_lamports and .temporary.user_data_max_bytes and .treasury) |
    {treasury, t: .temporary}' <<<"$c" 2>/dev/null
}

# Orders one temporary machine that joins this channel. Without --yes it only
# says what it would pay. Records the order in the data dir.
vm_order() { # <payer key> <plan> <hours> <yes: 0|1> <workers> <manager> <agent> <repo> <push> [ENV...]
  local key=$1 plan=$2 hours=$3 yes=$4 cat lamports treasury payer script b64 max sig out order d
  local n=$5 mgr=$6 agent=$7 repo=$8 push=$9
  shift 9
  [[ $hours =~ ^[1-9][0-9]{0,3}$ ]] || { echo "agichan: --hours takes 1 to 9999" >&2; return 2; }
  if ! cat=$(vm_rental_catalog); then
    echo "agichan: the AEA rental at $AGICHAN_RENT_URL does not take temporary machines yet" >&2
    echo "agichan: (it needs the changes in docs/vm-rental.md, deployed). Meanwhile" >&2
    echo "agichan: 'agichan vm script ...' prints the startup script for any provider." >&2
    return 2
  fi
  lamports=$(jq -r --arg p "$plan" '.t.hourly_lamports[$p] // empty' <<<"$cat")
  [[ $lamports =~ ^[1-9][0-9]*$ ]] ||
    { echo "agichan: plan $plan is not for rent; plans: $(jq -r '.t.hourly_lamports | keys | join(", ")' <<<"$cat")" >&2; return 2; }
  lamports=$((lamports * hours))
  treasury=$(jq -r '.treasury' <<<"$cat")
  payer=$("$bin" address --keypair "$key" 2>/dev/null) || { echo "agichan: unreadable payer wallet $key" >&2; return 1; }
  if [ "$yes" != 1 ]; then
    echo "agichan: would pay $lamports lamports from $payer to the rental treasury $treasury for $plan x ${hours}h; add --yes to order it"
    return 0
  fi
  script=$(vm_script "$(crew_join_code $((hours * 3600)))" "$n" "$mgr" "$agent" "$repo" "$hours" "$push" "$@") || return 1
  b64=$(printf '%s' "$script" | base64 -w0)
  max=$(jq -r '.t.user_data_max_bytes' <<<"$cat")
  [ "${#b64}" -le "$max" ] || { echo "agichan: the startup script is ${#b64} bytes; the rental takes $max" >&2; return 2; }
  out=$("$bin" -k "$key" -u "$rpc" transfer "$treasury" --lamports "$lamports" 2>&1) ||
    { echo "agichan: the payment failed; nothing was ordered: $(crew_one_line 300 <<<"$out")" >&2; return 1; }
  sig=$(grep -oE '[1-9A-HJ-NP-Za-km-z]{80,100}' <<<"$out" | tail -1)
  [ -n "$sig" ] || { echo "agichan: paid, but no signature in: $(crew_one_line 300 <<<"$out")" >&2; return 1; }
  out=$(jq -cn --arg plan "$plan" --arg renter "$payer" --arg sig "$sig" --argjson hours "$hours" --arg ud "$b64" \
    '{plan: $plan, renter: $renter, payment_sig: $sig, hours: $hours, user_data_b64: $ud}' |
    curl -fsS --proto '=https' --max-time 300 -H 'Content-Type: application/json' --data-binary @- "$AGICHAN_RENT_URL" 2>&1) ||
    { echo "agichan: paid ($sig), but the order failed: $(crew_one_line 300 <<<"$out"). Give the rental that signature." >&2; return 1; }
  order=$(jq -r '.order // empty' <<<"$out")
  [[ $order =~ ^[A-Za-z0-9_-]{1,100}$ ]] || { echo "agichan: paid ($sig); the rental answered: $(crew_one_line 300 <<<"$out")" >&2; return 1; }
  d=$(agichan_data)/vms
  (umask 077 && mkdir -p "$d" && jq -c --arg sig "$sig" --arg payer "$payer" --arg key "$key" \
    '. + {payment_sig: $sig, renter: $payer, key: $key}' <<<"$out" >"$d/$order.json") || return 1
  echo "agichan: ordered $order ($plan, ${hours}h, $lamports lamports, payment $sig): $(jq -r '"\(.ip // "ip pending") until \(.expires_at // "?")"' <<<"$out")"
  echo "agichan: once its workers show in agichan roster, run agichan share --missing here so they can read the tasks posted before it joined"
}

vm_list() {
  local f
  for f in "$(agichan_data)"/vms/*.json; do
    [ -f "$f" ] || continue
    jq -r '"\(.order)  \(.status // "?")  \(.ip // "-")  until \(.expires_at // "?")"' "$f"
  done
}

# Deletes a machine before its time: the renter signs "agichan release <order>"
# so nobody else can.
vm_release() { # <order>
  local f key sig out
  [[ ${1:-} =~ ^[A-Za-z0-9_-]{1,100}$ ]] || { echo "agichan: usage: agichan vm release <order>" >&2; return 2; }
  f=$(agichan_data)/vms/$1.json
  [ -f "$f" ] || { echo "agichan: no order $1 on this machine" >&2; return 1; }
  key=$(jq -r '.key' "$f")
  sig=$("$bin" -k "$key" sign-offchain-message "agichan release $1" 2>/dev/null | grep -oE '[1-9A-HJ-NP-Za-km-z]{80,100}' | tail -1)
  [ -n "$sig" ] || { echo "agichan: could not sign the release with $key" >&2; return 1; }
  out=$(jq -cn --arg o "$1" --arg r "$(jq -r '.renter' "$f")" --arg s "$sig" '{order: $o, renter: $r, signature: $s}' |
    curl -fsS --proto '=https' --max-time 60 -H 'Content-Type: application/json' --data-binary @- "$AGICHAN_RENT_URL/release" 2>&1) ||
    { echo "agichan: the release failed: $(crew_one_line 300 <<<"$out")" >&2; return 1; }
  echo "agichan: released $1: $(jq -r '.status // "?"' <<<"$out")"
}

# ---- self-test --------------------------------------------------------------------------

vm_selftest() {
  # Run through links by the entry-point check at the end: say what was found.
  if [ -n "${AGICHAN_SELFTEST_ENTRY:-}" ]; then type -t agichan_data crew_join_code | tr '\n' ' '; return; fi
  local pass=0 fail=0 t out s
  t=$(mktemp -d "${TMPDIR:-/tmp}/agichan-selftest.XXXXXX") || return 2
  command -v jq >/dev/null 2>&1 || { echo "vm.sh --selftest: UNMEASURED: needs jq"; return 2; }
  ck() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "  ok   $1"; else
    fail=$((fail + 1)); echo "  FAIL $1 (got '$2', want '$3')"; fi; }
  local code="agc1-YWJj_ZGVm-="

  # The script runs against stand-ins that log what they were asked to do.
  mkdir -p "$t/sb" "$t/home/agent"
  for c in apt-get useradd su systemd-run npm; do
    printf '#!/usr/bin/env bash\necho "%s $*" >>"%s/sys.log"\n' "$c" "$t" >"$t/sb/$c"
  done
  printf '#!/usr/bin/env bash\nexit 1\n' >"$t/sb/id"
  printf '#!/usr/bin/env bash\necho "agent:x:1001:1001::%s/home/agent:/bin/bash"\n' "$t" >"$t/sb/getent"
  # install -m MODE ... FILE: the file with that mode (owner options ignored).
  printf '#!/usr/bin/env bash\nm=644; [ "$1" = -m ] && m=$2; f="${@: -1}"; : >"$f"; chmod "$m" "$f"; echo "install $*" >>"%s/sys.log"\n' "$t" >"$t/sb/install"
  chmod +x "$t"/sb/*
  export VM_TEST_KEY="sk-it's-secret"
  s=$(vm_script "$code" 3 lead claude https://github.com/o/r.git 4 1 VM_TEST_KEY) || s=""
  ck "the script is valid bash" "$(bash -n <<<"$s" && echo ok)" ok
  (cd "$t" && PATH="$t/sb:$PATH" bash -c "$(sed 's#/var/log/agichan-vm.log#'"$t"'/vm.log#' <<<"$s")" >/dev/null 2>&1)
  ck "it installs tools, creates the agent user, installs the agent, joins with workers, and schedules the stop" \
    "$(cut -d' ' -f1 "$t/sys.log" | tr '\n' ' ')" "apt-get apt-get useradd su install su systemd-run "
  ck "the one-liner joins with the code and starts the workers for the manager, pushing" \
    "$(grep -c -- "--join $code --dir ~/work --workers 3 --manager lead --agent claude --repo https://github.com/o/r.git --push$" "$t/sys.log")" 1
  ck "the workers are asked to stop after the hours given" "$(grep -c 'systemd-run --on-active=4h' "$t/sys.log")" 1
  ck "a key reaches the agent user's env file, mode 600, quotes intact" \
    "$(stat -c %a "$t/home/agent/.agichan-env") $(. "$t/home/agent/.agichan-env" && printf '%s' "$VM_TEST_KEY")" "600 sk-it's-secret"
  ck "values that would reach a root shell are refused" \
    "$(vm_script 'agc1-$(x)' 1 lead claude r 1 0 2>&1 | grep -c 'not a join code') $(vm_script "$code" 1 lead 'bash -c x' r 1 0 2>&1 | grep -c 'claude, codex or opencode') $(vm_script "$code" 1 lead codex 'r;x' 1 0 2>&1 | grep -c 'git URL') $(vm_script "$code" 1 'le ad' codex r 1 0 2>&1 | grep -c handle) $(lower_name=v vm_script "$code" 1 lead codex r 1 0 lower_name 2>&1 | grep -c 'takes a variable name')" \
    "1 1 1 1 1"
  ck "codex installs through npm, opencode and claude through their installers" \
    "$(vm_script "$code" 1 lead codex r 1 0 | grep -c 'npm install -g @openai/codex') $(vm_script "$code" 1 lead opencode r 1 0 | grep -c 'opencode.ai/install') $(vm_script "$code" 1 lead claude r 1 0 | grep -c 'claude.ai/install.sh')" "1 1 1"

  # Ordering, against a stand-in rental (curl) and CLI.
  mkdir -p "$t/rb"
  cat >"$t/rb/curl" <<'EOF'
#!/usr/bin/env bash
d=$(dirname "$0")
body=""; for a in "$@"; do [ "$a" = "@-" ] && body=$(cat); done
echo "curl ${*: -1} $body" >>"$d/rent.log"
case "${*: -1}" in
  */release) echo '{"ok":true,"status":"released"}' ;;
  *) if [ -n "$body" ]; then echo '{"ok":true,"order":"o-1","ip":"203.0.113.9","expires_at":"2026-09-28T12:00:00Z","status":"provisioning"}'
     else cat "$d/catalog.json"; fi ;;
esac
EOF
  cat >"$t/rb/slonana" <<'EOF'
#!/usr/bin/env bash
d=$(dirname "$0"); echo "slonana $*" >>"$d/rent.log"
case " $* " in
  *" address "*) echo PAYERwallet111 ;;
  *" transfer "*) echo "Signature: 5VERYLNGsignatureAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" ;;
  *" sign-offchain-message "*) echo "Signature: 3RELEASEsignatureBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB" ;;
  *" keygen new "*) while [ $# -gt 0 ]; do [ "$1" = --outfile ] && echo '[1, 2]' >"$2"; shift; done ;;
esac
EOF
  chmod +x "$t/rb/curl" "$t/rb/slonana"
  echo '{"treasury":"TREASURYwallet","plans":{}}' >"$t/rb/catalog.json"
  bin="$t/rb/slonana" rpc=rpc room='!r:x' sponsor="$t/sp.json" strict=()
  echo '[9]' >"$t/sp.json"
  export AGICHAN_DATA="$t/data" AGICHAN_RENT_URL=https://rent.example/api/rent
  out=$(PATH="$t/rb:$PATH" vm_order "$t/sp.json" vc2-2c-4gb 4 1 3 lead codex https://github.com/o/r 0 2>&1; echo "rc=$?")
  ck "a rental that does not take temporary machines is named, and nothing is paid" \
    "$(grep -c 'does not take temporary machines' <<<"$out") $(grep -c transfer "$t/rb/rent.log") $(tail -1 <<<"$out")" "1 0 rc=2"
  echo '{"treasury":"TREASURYwallet","temporary":{"hourly_lamports":{"vc2-2c-4gb":5000000},"user_data_max_bytes":16384}}' >"$t/rb/catalog.json"
  out=$(PATH="$t/rb:$PATH" vm_order "$t/sp.json" vc2-2c-4gb 4 0 3 lead codex https://github.com/o/r 0 2>&1)
  ck "without --yes it only says what it would pay: hourly price x hours" \
    "$(grep -c 'would pay 20000000 lamports from PAYERwallet111 to the rental treasury TREASURYwallet' <<<"$out") $(grep -c transfer "$t/rb/rent.log")" "1 0"
  ck "a plan the rental does not offer is refused" \
    "$(PATH="$t/rb:$PATH" vm_order "$t/sp.json" huge 4 1 3 lead codex r 0 2>&1 | grep -c 'not for rent')" 1
  out=$(PATH="$t/rb:$PATH" vm_order "$t/sp.json" vc2-2c-4gb 4 1 3 lead codex https://github.com/o/r 0 2>&1)
  ck "with --yes: pays the treasury exactly, then orders with the payment and the startup script" \
    "$(grep -c 'slonana -k .* transfer TREASURYwallet --lamports 20000000' "$t/rb/rent.log") $(grep 'curl https://rent.example/api/rent {' "$t/rb/rent.log" | grep -c '"payment_sig":"5VERYLNGsignatureA.*"hours":4,"user_data_b64":"')" "1 1"
  ck "the order is recorded privately, with its machine" \
    "$(stat -c %a "$t/data/vms") $(jq -r '.ip' "$t/data/vms/o-1.json") $(PATH="$t/rb:$PATH" vm_list)" \
    "700 203.0.113.9 o-1  provisioning  203.0.113.9  until 2026-09-28T12:00:00Z"
  ck "the startup script it sent carries a fresh join code for this channel" \
    "$(grep -o '"user_data_b64":"[^"]*"' "$t/rb/rent.log" | cut -d'"' -f4 | base64 -d | grep -c -- '--join agc1-')" 1
  out=$(PATH="$t/rb:$PATH" vm_release o-1 2>&1)
  ck "release: the renter signs it, and the rental says released" \
    "$(grep -c "sign-offchain-message agichan release o-1" "$t/rb/rent.log") $(grep 'api/rent/release' "$t/rb/rent.log" | grep -c '"order":"o-1","renter":"PAYERwallet111","signature":"3RELEASE') $out" \
    "1 1 agichan: released o-1: released"
  ck "an unknown or malformed order is refused" \
    "$(PATH="$t/rb:$PATH" vm_release nope 2>&1 | grep -c 'no order') $(PATH="$t/rb:$PATH" vm_release '../x' 2>&1 | grep -c usage)" "1 1"

  # The entry point below, through an absolute link to a relative one whose ..
  # is taken in a linked directory (a logical .. lands in the decoy $e/sd); then
  # as sd/vm.sh with CDPATH naming the decoy $e/decoy.
  local here e=$t/entry
  here=$(cd -P "$(dirname "$0")" && pwd -P)
  mkdir -p "$e/ln/bin" "$e/ln/deep/er" "$e/sd" "$e/decoy/sd"
  ln -s "$here" "$e/ln/sd"
  ln -s "../../sd/${0##*/}" "$e/ln/deep/er/rel"
  ln -s deep/er "$e/ln/d"
  ln -s "$e/ln/d/rel" "$e/ln/bin/vm"
  ck "run through links, or by a relative path with CDPATH set, vm.sh --selftest finds lib.sh and crew.sh" \
    "$(cd "$e/ln" && { AGICHAN_SELFTEST_ENTRY=1 bash bin/vm --selftest 2>&1
      CDPATH="$e/decoy" AGICHAN_SELFTEST_ENTRY=1 bash "sd/${0##*/}" --selftest 2>&1; })" \
    "function function function function "

  echo "vm --selftest: $pass/$((pass + fail)) PASS (scratch: $t)"
  [ "$fail" -eq 0 ]
}

if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${1:-}" = --selftest ]; then
  # lib.sh's agichan_realpath, inline: it is lib.sh that this finds.
  p=$0; while [ -L "$p" ]; do l=$(readlink "$p"); case $l in /*) p=$l ;; *) p=$(dirname "$p")/$l ;; esac; done
  l=$(CDPATH='' cd -P "$(dirname "$p")" && pwd -P)
  . "$l/lib.sh"
  . "$l/crew.sh"
  vm_selftest
  exit $?
fi
