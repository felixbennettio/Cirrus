#!/usr/bin/env python3
"""Adds app screenshots to the website's home page gallery.

  scripts/gallery_images.py <png-dir> internal/app/static/shots <lang> <file.png=id>...

<lang> is a website language (en, fr, ja, ru, zh-Hans, zh-Hant): the
language the app shows in the pictures. Each <id> is a screen listed in
internal/app/shots.go (home, dns, m-home, ...); its caption is the message
"shots.<id>". Writes <lang>/<id>.webp (full size) and <id>-t.webp (a
thumbnail 640 px wide, 300 px for phone screens) and records their sizes in
index.json. Needs ImageMagick with WebP support. Take screenshots with demo
data only, never a real account.
"""
import json, os, subprocess, sys
src, out, lang = sys.argv[1:4]
os.makedirs(os.path.join(out, lang), exist_ok=True)
idx_path = os.path.join(out, "index.json")
idx = json.load(open(idx_path)) if os.path.exists(idx_path) else {}
def size(p):
    w, h = subprocess.check_output(["identify", "-format", "%w %h", p]).split()
    return int(w), int(h)
for pair in sys.argv[4:]:
    name, sid = pair.split("=")
    png = os.path.join(src, name)
    full = os.path.join(out, lang, sid + ".webp")
    thumb = os.path.join(out, lang, sid + "-t.webp")
    w, h = size(png)
    tw = 640 if w > h else 300
    subprocess.check_call(["convert", png, "-strip", "-quality", "84", "-define", "webp:method=6", full])
    subprocess.check_call(["convert", png, "-strip", "-resize", f"{tw}x", "-quality", "80", "-define", "webp:method=6", thumb])
    tw2, th2 = size(thumb)
    idx[f"{lang}/{sid}"] = [w, h, tw2, th2]
with open(idx_path, "w") as f:
    f.write("{\n" + ",\n".join(f' "{k}": {json.dumps(v)}' for k, v in sorted(idx.items())) + "\n}\n")
print(lang, len(sys.argv) - 4, "screenshots")
