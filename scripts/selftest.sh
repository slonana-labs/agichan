#!/usr/bin/env bash
# selftest.sh — checks lib.sh's release verification with throwaway keys and
# fake releases served over file://. Needs openssl, curl, gzip, awk.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
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

# A release in <dir> for <payload>, signed by <key.pem>; prints the pubkey b58.
make_release() { # <dir> <payload> <key.pem> [sign-this-digest-instead]
  local dir=$1 digest sig pk
  mkdir -p "$dir"
  printf '%s' "$2" >"$dir/slonana"
  gzip -c "$dir/slonana" >"$dir/slonana.gz"
  digest=$(sha256sum "$dir/slonana" | cut -c1-64)
  agichan_hex_bin "${4:-$digest}" >"$dir/d.bin"
  openssl pkeyutl -sign -inkey "$3" -rawin -in "$dir/d.bin" -out "$dir/s.bin"
  sig=$(od -An -tx1 -v "$dir/s.bin" | tr -d ' \n')
  printf '{"version":"v0.0.1-test","sha256":"%s","signature":"%s","pubkey":"x"}' \
    "$digest" "$(hex_b58 "$sig")" >"$dir/slonana.manifest.json"
  pk=$(openssl pkey -in "$3" -pubout -outform DER | od -An -tx1 -v | tr -d ' \n')
  hex_b58 "${pk:24}"
}

openssl genpkey -algorithm ed25519 -out "$tmp/k1.pem" 2>/dev/null
openssl genpkey -algorithm ed25519 -out "$tmp/k2.pem" 2>/dev/null

ck "base58 round-trips the pinned release key" \
  "$(hex_b58 "$(agichan_b58_hex "$AGICHAN_RELEASE_KEY")")" "$AGICHAN_RELEASE_KEY"

k1=$(make_release "$tmp/r1" "#!/bin/sh
echo genuine" "$tmp/k1.pem")
agichan_fetch_release "file://$tmp/r1" "$k1" "$tmp/out/a" 2>/dev/null
ck "a release signed by the pinned key installs" "$("$tmp/out/a" 2>/dev/null)" genuine

k2=$(make_release "$tmp/r2" "#!/bin/sh
echo evil" "$tmp/k2.pem")
agichan_fetch_release "file://$tmp/r2" "$k1" "$tmp/out/b" 2>"$tmp/err"
ck "a release signed by another key is refused" \
  "$([ -e "$tmp/out/b" ] && echo installed || echo absent)" absent
ck "and says why" "$(grep -c 'does not verify under the pinned key' "$tmp/err")" 1

make_release "$tmp/r3" "#!/bin/sh
echo genuine" "$tmp/k1.pem" >/dev/null
printf '#!/bin/sh\necho swapped\n' >"$tmp/r3/slonana"
gzip -c "$tmp/r3/slonana" >"$tmp/r3/slonana.gz"
agichan_fetch_release "file://$tmp/r3" "$k1" "$tmp/out/c" 2>"$tmp/err"
ck "a binary that does not match its manifest digest is refused" \
  "$([ -e "$tmp/out/c" ] && echo installed || echo absent)" absent
ck "and says why" "$(grep -c 'does not match its manifest digest' "$tmp/err")" 1

make_release "$tmp/r4" "#!/bin/sh
echo genuine" "$tmp/k1.pem" \
  "$(printf 'something else' | sha256sum | cut -c1-64)" >/dev/null
agichan_fetch_release "file://$tmp/r4" "$k1" "$tmp/out/d" 2>/dev/null
ck "a signature over a different digest is refused" \
  "$([ -e "$tmp/out/d" ] && echo installed || echo absent)" absent

echo "agichan lib --selftest: $pass/$((pass + fail)) PASS"
[ "$fail" -eq 0 ]
