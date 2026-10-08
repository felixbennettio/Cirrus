#!/bin/bash
# One screenshot of the Linux build of the app, against scripts/demo_api.py.
#   shoot.sh <en|zh> <light|dark> <WxH> <name> <route> [wait] [step...]
# Starts the app in a WxH window on the page <route>, waits [wait] seconds,
# runs the steps (key:<xdotool keys>, click:<x>,<y>, type:<text>,
# paste:<text>, sleep:<seconds>) and saves $OUT/<name>.png. NOPROFILE=1
# starts without a saved profile (welcome screen). See batch.sh for the setup.
set -u
APP=${APP:-$(cd "$(dirname "$0")/../.." && pwd)}
OUT=${OUT:-$APP/build/screenshots}
L=$1 THEME=$2 SIZE=$3 NAME=$4 ROUTE=$5 WAIT=${6:-6}
shift $(( $# < 6 ? $# : 6 ))
export DISPLAY=:99 NO_AT_BRIDGE=1 NO_PROXY=localhost,127.0.0.1,api.cloudflare.com no_proxy=localhost,127.0.0.1,api.cloudflare.com
pgrep -x Xvfb >/dev/null || { Xvfb :99 -screen 0 1600x1000x24 -nolisten tcp >/dev/null 2>&1 & sleep 1; }
# A session bus with an unlocked keyring, so the app can use its secure storage.
if [ ! -s /tmp/dbus.env ] || ! kill -0 "$(. /tmp/dbus.env; echo $DBUS_SESSION_BUS_PID)" 2>/dev/null; then
  dbus-launch --sh-syntax >/tmp/dbus.env
  ( . /tmp/dbus.env; printf demo | gnome-keyring-daemon --unlock --components=secrets --daemonize >/tmp/keyring.env )
  sleep 1
fi
. /tmp/dbus.env
if [ "$(cat /tmp/api.lang 2>/dev/null)" != "$L" ]; then
  pkill -f demo_api.py; sleep 0.3
  (python3 "$APP/scripts/demo_api.py" --lang "$L" --port 80 >/tmp/api.log 2>&1 &)
  echo "$L" >/tmp/api.lang; sleep 1
fi
D=$HOME/.local/share/io.felixbennett.cirrus
mkdir -p "$D"
read -r ACC ZONE < <(cd "$APP" && python3 -c "import importlib.util as u;s=u.spec_from_file_location(\"d\",\"scripts/demo_api.py\");d=u.module_from_spec(s);s.loader.exec_module(d);print(d.ACC, d.ZONES[0][\"id\"])")
if [ "${NOPROFILE:-0}" = 1 ]; then echo "[]" >"$D/profiles.json"; PROF=null; else
  echo "[{\"id\":\"demo\",\"name\":\"Acme Studio\",\"kind\":\"apiToken\",\"token\":\"demo-token\",\"createdAt\":\"2026-01-01T00:00:00Z\"}]" >"$D/profiles.json"; PROF="\"demo\""; fi
python3 - "$D" "$THEME" "$L" "$PROF" "$ACC" "$ZONE" <<PY
import json, sys
d, theme, lang, prof, acc, zone = sys.argv[1:]
s = {"themeMode": theme, "localeCode": lang, "appLock": False, "activeProfileId": json.loads(prof),
     "activeAccount": {"demo": acc}, "activeZone": {acc: zone}, "favoriteOps": [], "compactSidebar": False,
     "confirmMutations": True, "dynamicColor": True}
json.dump({"flutter.cirrus.settings.v1": json.dumps(s)}, open(d + "/shared_preferences.json", "w"))
PY
pkill -x cirrus 2>/dev/null; sleep 0.5
CIRRUS_WINDOW_SIZE=$SIZE CIRRUS_INITIAL_ROUTE=$ROUTE "$APP/build/linux/x64/release/bundle/cirrus" >/tmp/app.log 2>&1 &
PID=$!
sleep "$WAIT"
for st in "$@"; do
  case $st in
    key:*) xdotool key --delay 80 ${st#key:} ;;
    click:*) c=${st#click:}; xdotool mousemove ${c%%,*} ${c##*,} click 1 ;;
    type:*) xdotool type --delay 60 "${st#type:}" ;;
    paste:*) printf %s "${st#paste:}" | xclip -selection clipboard; xdotool key ctrl+v ;;
    sleep:*) sleep "${st#sleep:}" ;;
  esac
  sleep 1.2
done
xdotool mousemove 1590 990
sleep 0.5
mkdir -p "$(dirname "$OUT/$NAME.png")"
import -window root -crop "${SIZE}+0+0" +repage "$OUT/$NAME.png"
kill $PID 2>/dev/null
echo "$OUT/$NAME.png"
