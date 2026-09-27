#!/usr/bin/env bash
# selftest.sh — checks lib.sh's release verification with throwaway keys and
# fake releases served over file://. Needs openssl 3, curl, gzip, awk, flock.
# Exit 0 = pass, 1 = a check failed, 2 = could not measure (no Ed25519 here).
# agichan deletes nothing: the scratch dir is left in /tmp and named at the end.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/agichan-selftest.XXXXXX") || exit 2
pass=0 fail=0
ck() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "  ok   $1"; else
  fail=$((fail + 1)); echo "  FAIL $1 (got '$2', want '$3')"; fi; }

# hex -> base58 (bitcoin alphabet), the inverse of agichan_b58_hex.
hex_b58() {
  printf '%s\n' "$1" | awk '
    BEGIN { A = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz" }
    { h = $0; n = 0; split("", d)
      for (i = 1; i <= length(h); i += 2) {
        hi = index("0123456789abcdef", substr(h, i, 1)) - 1
        lo = index("0123456789abcdef", substr(h, i + 1, 1)) - 1
        c = hi * 16 + lo
        for (j = 0; j < n; j++) { c += d[j] * 256; d[j] = c % 58; c = int(c / 58) }
        while (c > 0) { d[n++] = c % 58; c = int(c / 58) }
      }
      out = ""; for (i = 1; i <= length(h) && substr(h, i, 2) == "00"; i += 2) out = out "1"
      for (j = n - 1; j >= 0; j--) out = out substr(A, d[j] + 1, 1)
      print out }'
}

# Signs <dir>/slonana as a release: slonana.gz plus a manifest claiming
# <version>, signed by <key.pem> (over another digest when one is given).
# Prints the public key, base58.
sign_release() { # <dir> <version> <key.pem> [sign-this-digest-instead]
  local dir=$1 digest sig pk
  gzip -c "$dir/slonana" >"$dir/slonana.gz"
  digest=$(sha256sum "$dir/slonana" | cut -c1-64)
  agichan_hex_bin "${4:-$digest}" >"$dir/d.bin"
  openssl pkeyutl -sign -inkey "$3" -rawin -in "$dir/d.bin" -out "$dir/s.bin"
  sig=$(od -An -tx1 -v "$dir/s.bin" | tr -d ' \n')
  printf '{"version":"%s","sha256":"%s","signature":"%s","pubkey":"x"}' \
    "$2" "$digest" "$(hex_b58 "$sig")" >"$dir/slonana.manifest.json"
  pk=$(openssl pkey -in "$3" -pubout -outform DER | od -An -tx1 -v | tr -d ' \n')
  hex_b58 "${pk:24}"
}

# A release whose binary prints <says> (default: the version it claims).
make_release() { # <dir> <version> <key.pem> [says] [sign-this-digest-instead]
  mkdir -p "$1"
  printf '#!/bin/sh\necho %s\n' "${4:-$2}" >"$1/slonana"
  sign_release "$1" "$2" "$3" "${5:-}"
}

installed() { [ -e "$1" ] && echo installed || echo absent; }

if ! agichan_verifier_works "$tmp"; then
  echo "agichan lib --selftest: UNMEASURED: this openssl cannot check Ed25519 (needs OpenSSL 3)"
  exit 2
fi

openssl genpkey -algorithm ed25519 -out "$tmp/k1.pem" 2>/dev/null
openssl genpkey -algorithm ed25519 -out "$tmp/k2.pem" 2>/dev/null

ck "base58 round-trips the pinned release key" \
  "$(hex_b58 "$(agichan_b58_hex "$AGICHAN_RELEASE_KEY")")" "$AGICHAN_RELEASE_KEY"
ck "release versions: v<maj>.<min>.<patch>-slon only" \
  "$(for v in v0.1.9055-slon v1.2.3-slon .840.113549 v0.1.9055 v0.1.9055-slonX v0.1.1234567890-slon ''; do
    agichan_is_release_version "$v" && printf 1 || printf 0; done)" 1100000
ck "version order is numeric, strict, and by field" \
  "$(agichan_newer v0.1.10-slon v0.1.9-slon && printf 1 || printf 0
    agichan_newer v0.1.9-slon v0.1.9-slon && printf 1 || printf 0
    agichan_newer v0.2.0-slon v0.1.99-slon && printf 1 || printf 0
    agichan_newer v0.1.08-slon v0.1.7-slon && printf 1 || printf 0
    agichan_newer v0.1.9-slon v0.1.10-slon && printf 1 || printf 0)" 10110

k1=$(make_release "$tmp/r1" v0.0.1-slon "$tmp/k1.pem")
agichan_fetch_release "file://$tmp/r1" "$k1" "$tmp/out/a" 2>/dev/null
ck "a release signed by the pinned key installs" "$("$tmp/out/a" 2>/dev/null)" v0.0.1-slon
ck "and its manifest is kept beside it" "$(agichan_version_of "$tmp/out/a.manifest.json")" v0.0.1-slon
ck "the staging dir is private" "$(stat -c %a "$tmp/out/.fetch")" 700

make_release "$tmp/r2" v0.0.1-slon "$tmp/k2.pem" >/dev/null
agichan_fetch_release "file://$tmp/r2" "$k1" "$tmp/out/b" 2>"$tmp/err"
ck "a release signed by another key is refused" "$(installed "$tmp/out/b")" absent
ck "and says why" "$(grep -c 'does not verify under the pinned key' "$tmp/err")" 1

make_release "$tmp/r3" v0.0.1-slon "$tmp/k1.pem" >/dev/null
printf '#!/bin/sh\necho swapped v0.0.1-slon\n' >"$tmp/r3/slonana"
gzip -c "$tmp/r3/slonana" >"$tmp/r3/slonana.gz"
agichan_fetch_release "file://$tmp/r3" "$k1" "$tmp/out/c" 2>"$tmp/err"
ck "a binary that does not match its manifest digest is refused" "$(installed "$tmp/out/c")" absent
ck "and says why" "$(grep -c 'does not match its manifest digest' "$tmp/err")" 1

make_release "$tmp/r4" v0.0.1-slon "$tmp/k1.pem" "" \
  "$(printf 'something else' | sha256sum | cut -c1-64)" >/dev/null
agichan_fetch_release "file://$tmp/r4" "$k1" "$tmp/out/d" 2>/dev/null
ck "a signature over a different digest is refused" "$(installed "$tmp/out/d")" absent

# The signature covers the digest, never the version field.
make_release "$tmp/r5" .840.113549 "$tmp/k1.pem" >/dev/null
agichan_fetch_release "file://$tmp/r5" "$k1" "$tmp/out/e" 2>"$tmp/err"
ck "a manifest whose version is not a release version is refused" "$(installed "$tmp/out/e")" absent
ck "and says the manifest is malformed" "$(grep -c 'manifest at .* is malformed' "$tmp/err")" 1

make_release "$tmp/r6" v0.0.9-slon "$tmp/k1.pem" v0.0.2-slon >/dev/null
agichan_fetch_release "file://$tmp/r6" "$k1" "$tmp/out/f" 2>"$tmp/err"
ck "a signed binary that does not carry the claimed version is refused" "$(installed "$tmp/out/f")" absent
ck "and says why" "$(grep -c "does not carry its manifest's version v0.0.9-slon" "$tmp/err")" 1

make_release "$tmp/r7" v0.0.2-slon "$tmp/k1.pem" >/dev/null
agichan_fetch_release "file://$tmp/r7" "$k1" "$tmp/out/g" 2>/dev/null
make_release "$tmp/r8" v0.0.1-slon "$tmp/k1.pem" >/dev/null
agichan_fetch_release "file://$tmp/r8" "$k1" "$tmp/out/g" 2>"$tmp/err"
ck "a downgrade to an older, genuinely signed release is refused" "$("$tmp/out/g")" v0.0.2-slon
ck "and says why" "$(grep -c 'v0.0.1-slon is not newer than the installed v0.0.2-slon' "$tmp/err")" 1
agichan_fetch_release "file://$tmp/r7" "$k1" "$tmp/out/g" 2>"$tmp/err"
ck "the same version is not installed again" "$(grep -c 'is not newer' "$tmp/err")" 1

mkdir -p "$tmp/r9"
{ printf '#!/bin/sh\necho v0.0.1-slon\n'; head -c $((2 << 20)) /dev/zero; } >"$tmp/r9/slonana"
sign_release "$tmp/r9" v0.0.1-slon "$tmp/k1.pem" >/dev/null
max=$AGICHAN_MAX_CLI_MIB AGICHAN_MAX_CLI_MIB=1
agichan_fetch_release "file://$tmp/r9" "$k1" "$tmp/out/h" 2>"$tmp/err"
AGICHAN_MAX_CLI_MIB=$max
ck "a download that unpacks past the cap is refused" "$(installed "$tmp/out/h")" absent
ck "and says why" "$(grep -c 'unpacks to over 1 MiB' "$tmp/err")" 1

mkdir -p "$tmp/oldssl"
printf '#!/usr/bin/env bash\nfor a in "$@"; do [ "$a" = -rawin ] && { echo "pkeyutl: Unknown option: -rawin" >&2; exit 1; }; done\nexec %s "$@"\n' \
  "$(command -v openssl)" >"$tmp/oldssl/openssl"
chmod +x "$tmp/oldssl/openssl"
PATH="$tmp/oldssl:$PATH" agichan_fetch_release "file://$tmp/r1" "$k1" "$tmp/out/i" 2>"$tmp/err"
ck "an openssl without Ed25519 support blames openssl, not the release" \
  "$(installed "$tmp/out/i") $(grep -c 'cannot check Ed25519' "$tmp/err") $(grep -c 'pinned key' "$tmp/err")" \
  "absent 1 0"

# Through agichan_bin, against a fake release site.
export CLAUDE_PLUGIN_DATA="$tmp/data"
AGICHAN_RELEASE_BASE="file://$tmp/site"
AGICHAN_RELEASE_KEY=$k1
agichan_locked true
ck "the data dir is created private" "$(stat -c %a "$tmp/data")" 700
make_release "$tmp/site" v0.0.1-slon "$tmp/k1.pem" >/dev/null
if [ "$(uname -s)/$(uname -m)" = Linux/x86_64 ]; then
  out=$(AGICHAN_RELEASE_BASE="file://$tmp/nowhere" CLAUDE_PLUGIN_DATA="$tmp/data0" \
    agichan_bin "" 2>"$tmp/err")
  rc=$?
  ck "a first use that cannot download fails, says why, and names no binary" \
    "$rc [$out] $(grep -c 'could not download the release manifest' "$tmp/err")" "1 [] 1"
  b=$(agichan_bin "")
  ck "first use installs the published release" "$("$b")" v0.0.1-slon
  make_release "$tmp/site" v0.0.2-slon "$tmp/k1.pem" >/dev/null
  ck "within a day the release is not re-checked" "$("$(agichan_bin "")")" v0.0.1-slon

  touch -d '2 days ago' "$tmp/data/bin/slonana.checked"
  agichan_bin "" >/dev/null
  for _ in $(seq 1 80); do [ "$("$b")" = v0.0.2-slon ] && break; sleep 0.25; done
  ck "after a day a newer signed release replaces it, in the background" "$("$b")" v0.0.2-slon

  # A site that never finishes sending: agichan_bin must still answer at once.
  mkdir -p "$tmp/slow"
  cp "$tmp/site/slonana.manifest.json" "$tmp/slow/"
  sed -i 's/v0.0.2-slon/v0.0.3-slon/' "$tmp/slow/slonana.manifest.json"
  mkfifo "$tmp/slow/slonana.gz"
  AGICHAN_RELEASE_BASE="file://$tmp/slow"
  touch -d '2 days ago' "$tmp/data/bin/slonana.checked"
  t0=$(date +%s%N)
  b2=$(timeout 10 bash -c '. "$1"; AGICHAN_RELEASE_BASE=$2 AGICHAN_RELEASE_KEY=$3; agichan_bin ""' \
    _ "$AGICHAN_LIB" "$AGICHAN_RELEASE_BASE" "$AGICHAN_RELEASE_KEY")
  ms=$((($(date +%s%N) - t0) / 1000000))
  busy=free
  for _ in $(seq 1 50); do flock -n "$tmp/data/.lock" true || { busy=held; break; }; sleep 0.1; done
  ck "a stalled release site does not hold up agichan_bin (the fetch is stuck, holding the lock)" \
    "$([ "$ms" -lt 3000 ] && echo prompt || echo "${ms}ms") $("$b2") $busy" "prompt v0.0.2-slon held"
  timeout 20 sh -c ': >"$1"' _ "$tmp/slow/slonana.gz" # let the stalled fetch end
  flock -w 30 "$tmp/data/.lock" true

  AGICHAN_RELEASE_BASE="file://$tmp/site"
  make_release "$tmp/site" v0.0.3-slon "$tmp/k2.pem" >/dev/null
  agichan_locked _agichan_update "$tmp/data/bin/slonana" "$AGICHAN_RELEASE_BASE" "$k1" 2>/dev/null
  ck "a newer release signed by another key is refused; the old one stays" "$("$b")" v0.0.2-slon
  agichan_locked _agichan_update "$tmp/data/bin/slonana" "file://$tmp/nowhere" "$k1" 2>/dev/null
  ck "an unreachable release site keeps the installed copy" "$("$b")" v0.0.2-slon
else
  echo "  skip update checks: agichan_bin installs only on Linux x86-64"
fi

# The sponsor wallet: created by `keygen new`, then private whatever the
# keygen's own file mode.
mkdir -p "$tmp/kg"
printf '#!/usr/bin/env bash\nwhile [ $# -gt 0 ]; do [ "$1" = --outfile ] && { umask 022; echo "[1]" >"$2"; chmod 644 "$2"; }; shift; done\n' >"$tmp/kg/slonana"
chmod +x "$tmp/kg/slonana"
: >"$tmp/data/sponsor2.json.login"
_agichan_sponsor "$tmp/kg/slonana" rpc "$tmp/data/sponsor2.json"
ck "the sponsor key ends up readable by its owner only" "$(stat -c %a "$tmp/data/sponsor2.json")" 600

echo "agichan lib --selftest: $pass/$((pass + fail)) PASS (scratch: $tmp)"
[ "$fail" -eq 0 ]
