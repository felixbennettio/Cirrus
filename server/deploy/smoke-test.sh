#!/usr/bin/env bash
# End-to-end check of a running licence server, using only curl and python3:
# pages, a test order, admin confirmation, polling, activation, validation and
# deactivation. The test licence is revoked at the end.
#
# Usage: ./smoke-test.sh <base-url> <admin-password> [method]
#   ./smoke-test.sh http://127.0.0.1:8790 "$ADMIN_PASSWORD"
#   ./smoke-test.sh https://cirrus.routeforge.zone "$ADMIN_PASSWORD"
# method: alipay (default) or wechat; its QR image must be in data/pay/.
set -euo pipefail
BASE=${1:?usage: smoke-test.sh <base-url> <admin-password> [method]}
BASE=${BASE%/}
PASS=${2:?admin password required}
METHOD=${3:-alipay}
jar=$(mktemp)
trap 'rm -f "$jar"' EXIT

ok()   { printf '  ok   %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*" >&2; exit 1; }
json() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval("d"+sys.argv[1]))' "$1"; }

echo "== pages"
for p in /healthz / /buy "/buy?product=cirrus-android" /license /privacy /terms /support "/?lang=en" /static/site.css /api/v1/pubkey; do
  code=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE$p")
  [ "$code" = 200 ] && ok "$code $p" || fail "$code $p"
done
curl -sS "$BASE/" | grep -q 'beian.miit.gov.cn' && ok "footer has the ICP link" || fail "no ICP link in the footer"
echo "  public key: $(curl -sS "$BASE/api/v1/pubkey" | json '["ed25519"]')"

echo "== order"
order=$(curl -sS -X POST "$BASE/api/v1/orders" -H 'Content-Type: application/json' \
  -d "{\"product\":\"cirrus-linux\",\"email\":\"smoke-test@example.com\",\"method\":\"$METHOD\"}")
no=$(echo "$order" | json '["order_no"]' 2>/dev/null) || fail "create order: $order"
tok=$(echo "$order" | json '["token"]')
ok "created $no ($(echo "$order" | json '["pay"]["type"]'), ¥$(echo "$order" | json '["amount"]'))"
st=$(curl -sS "$BASE/api/v1/orders/$no?token=$tok" | json '["status"]')
[ "$st" = pending ] && ok "status pending" || fail "status $st"

echo "== admin confirm"
code=$(curl -sS -o /dev/null -w '%{http_code}' -u "admin:$PASS" -c "$jar" "$BASE/admin")
[ "$code" = 200 ] || fail "admin login: HTTP $code (wrong ADMIN_PASSWORD?)"
csrf=$(awk '$6 == "cirrus_csrf" { print $7 }' "$jar")
[ -n "$csrf" ] || fail "no CSRF cookie"
loc=$(curl -sS -o /dev/null -w '%{redirect_url}' -u "admin:$PASS" -b "$jar" -H "Origin: $BASE" \
  --data "csrf=$csrf&pay_ref=smoke-test" "$BASE/admin/orders/$no/confirm")
lic=$(echo "$loc" | sed -n 's|.*/admin/licenses/\(lic_[0-9a-f]*\).*|\1|p')
[ -n "$lic" ] && ok "confirmed, licence $lic" || fail "confirm: $loc"

r=$(curl -sS "$BASE/api/v1/orders/$no?token=$tok")
key=$(echo "$r" | json '["license_key"]')
[ "$(echo "$r" | json '["status"]')" = paid ] && ok "status paid, key $key" || fail "$r"

echo "== licence API"
device=$(printf 'cirrus-device:smoke-test-%s' "$no" | sha256sum | cut -d' ' -f1)
body="{\"license_key\":\"$key\",\"device_id\":\"$device\",\"device_name\":\"smoke-test\",\"platform\":\"linux\",\"app_version\":\"smoke\"}"
r=$(curl -sS -X POST "$BASE/api/v1/activate" -H 'Content-Type: application/json' -d "$body")
echo "$r" | json '["activation"]' >/dev/null 2>&1 && ok "activate" || fail "activate: $r"
r=$(curl -sS -X POST "$BASE/api/v1/activate" -H 'Content-Type: application/json' \
  -d "{\"license_key\":\"$key\",\"device_id\":\"$device\",\"device_name\":\"x\",\"platform\":\"windows\",\"app_version\":\"smoke\"}")
[ "$(echo "$r" | json '["error"]')" = wrong_platform ] && ok "wrong platform rejected" || fail "$r"
kd="{\"license_key\":\"$key\",\"device_id\":\"$device\"}"
st=$(curl -sS -X POST "$BASE/api/v1/validate" -H 'Content-Type: application/json' -d "$kd" | json '["status"]')
[ "$st" = active ] && ok "validate: active" || fail "validate: $st"
curl -sS -X POST "$BASE/api/v1/deactivate" -H 'Content-Type: application/json' -d "$kd" | grep -q '"ok":true' && ok "deactivate" || fail "deactivate"

echo "== clean up"
curl -sS -o /dev/null -u "admin:$PASS" -b "$jar" -H "Origin: $BASE" --data "csrf=$csrf&note=smoke-test" "$BASE/admin/licenses/$lic/note"
curl -sS -o /dev/null -u "admin:$PASS" -b "$jar" -H "Origin: $BASE" --data "csrf=$csrf" "$BASE/admin/licenses/$lic/revoke"
st=$(curl -sS -X POST "$BASE/api/v1/validate" -H 'Content-Type: application/json' -d "$kd" | json '["status"]')
[ "$st" = revoked ] && ok "test licence $lic revoked" || fail "revoke: $st"
echo "ALL OK"
