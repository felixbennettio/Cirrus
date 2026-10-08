#!/bin/bash
# The website's screenshots of the desktop and phone layouts (Linux build).
#   batch.sh <en|zh> [name...]      -> $OUT/<en|zh>/<name>.png (all, or the names given)
#
# Needs an X-less Linux box (we use an Ubuntu 22.04 container) with Flutter's
# Linux build tools and: xvfb imagemagick xdotool xclip dbus-x11
# gnome-keyring fonts-inter fonts-noto-cjk, plus a fontconfig alias that
# prefers Inter and Noto Sans CJK SC for sans-serif. Point api.cloudflare.com
# at 127.0.0.1 in /etc/hosts (so the request log shows the usual address;
# shoot.sh runs scripts/demo_api.py on port 80) and build:
#   flutter build linux --release --dart-define=CIRRUS_API_BASE=http://api.cloudflare.com/client/v4
# Then server/scripts/gallery_images.py turns the PNGs into the website's
# pictures, and phones.sh makes the "phone" picture.
# List lines: name theme route [step...]; "~" in a step stands for a space.
L=$1; shift
HERE=$(cd "$(dirname "$0")" && pwd)
APP=${APP:-$(cd "$HERE/../.." && pwd)}
OUT=${OUT:-$APP/build/screenshots}
export APP OUT
cd "$APP"
read -r KV TUN D1 < <(python3 -c 'import importlib.util as u;s=u.spec_from_file_location("d","scripts/demo_api.py");d=u.module_from_spec(s);s.loader.exec_module(d);print(d.hexid("kv-flags"), d.hexid("tunoffice-nas"), d.hexid("d1-orders"))')
# Things that differ by language: the AI question, where the Worker's bindings tab is.
if [ "$L" = zh ]; then Q='什么是边缘缓存？' BX=459; else Q='What~is~edge~caching?' BX=537; fi
list() { cat <<L
home light /
home-dark dark /
domains light /domains
zone light /zone
analytics light /zone/analytics
dns light /zone/dns
dns-dark dark /zone/dns
ssl light /zone/ssl
security light /zone/security
rules light /zone/rules
cache light /zone/cache
zone-settings light /zone/settings
email light /zone/email
zone-more light /zone/more
workers light /workers
worker light /workers/api-gateway
worker-bindings light /workers/api-gateway click:$BX,78 sleep:2
pages light /pages
pages-project light /pages/acme-blog
ai light /ai click:740,760 paste:$Q key:Return sleep:3
kv light /kv
kv-keys light /kv/$KV
r2 light /r2
r2-bucket light /r2/acme-assets
d1 light /d1
d1-db light /d1/$D1 click:700,120 key:ctrl+a paste:SELECT~*~FROM~orders~ORDER~BY~created_at~DESC~LIMIT~20; click:1218,276 sleep:2
tunnels light /zt/tunnels
tunnel light /zt/tunnels/$TUN
zt-networks light /zt/networks
access light /zt/access
gateway light /zt/gateway
devices light /zt/devices
members light /account/members
tokens light /account/tokens
tokens-dark dark /account/tokens
audit light /account/audit
lists light /account/lists
account-more light /account/more
console light /console/op/dns-records-for-a-zone-list-dns-records click:351,395 sleep:2
console-dark dark /console/op/dns-records-for-a-zone-list-dns-records click:351,395 sleep:2
graphql light /graphql click:731,92 sleep:2 click:909,88
requests light /zone/analytics click:91,347 sleep:2 key:ctrl+k type:request~log sleep:1 key:Return sleep:2
palette light / click:700,20 key:ctrl+k type:dns
palette-dark dark / click:700,20 key:ctrl+k type:worker
welcome light /welcome NOPROFILE
profile light /profiles/add
settings light /settings
m-home light /
m-home-dark dark /
m-dns light /zone/dns
m-zone light /zone
m-drawer light / click:30,30
m-drawer-dark dark / click:30,30
L
}
mkdir -p "$OUT/$L"
set -f  # steps may contain "*"
list | while read -r name theme route rest; do
  if [ $# -gt 0 ] && ! printf "%s\n" "$@" | grep -qx "$name"; then continue; fi
  np=0; steps=()
  for x in $rest; do [ "$x" = NOPROFILE ] && np=1 || steps+=("${x//\~/ }"); done
  size=1280x800; case $name in m-*) size=430x860 ;; esac
  NOPROFILE=$np "$HERE/shoot.sh" "$L" "$theme" $size "$L/$name" "$route" 7 "${steps[@]}" >/dev/null 2>&1 < /dev/null
  echo "$name"
done
