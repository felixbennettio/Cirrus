#!/usr/bin/env python3
"""Checks the Apple setup the App Store workflow depends on.

Reads the App Store Connect API key from the environment (the repository
secrets), signs in to the App Store Connect API and reports whether the App
ID, the app record and the Cirrus Pro in-app purchase exist. Writes a
summary for the run page and `ready=true|false` to $GITHUB_OUTPUT.

Exit status: 1 when the secrets are incomplete or rejected, 0 otherwise
(including when none are set yet).
"""

import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import jwt  # PyJWT with the "crypto" extra

API = "https://api.appstoreconnect.apple.com"
BUNDLE_ID = os.environ.get("BUNDLE_ID", "io.felixbennett.cirrus")
PRODUCT_ID = os.environ.get("PRODUCT_ID", "cirrus_pro_lifetime")
GUIDE = "见《Cirrus 上架 App Store 新手指南》"

rows = []  # (ok, item, detail)


def row(ok, item, detail):
    rows.append((ok, item, detail))
    mark = {True: "OK  ", False: "FAIL", None: "--  "}[ok]
    print(f"[{mark}] {item}: {detail}")


def finish(ready, code):
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        icon = {True: "✅", False: "❌", None: "➖"}
        with open(summary, "a", encoding="utf-8") as f:
            f.write("### Apple 设置检查\n\n| | 项目 | 结果 |\n| --- | --- | --- |\n")
            for ok, item, detail in rows:
                f.write(f"| {icon[ok]} | {item} | {detail} |\n")
            f.write("\n")
    out = os.environ.get("GITHUB_OUTPUT")
    if out:
        with open(out, "a", encoding="utf-8") as f:
            f.write(f"ready={'true' if ready else 'false'}\n")
    sys.exit(code)


def secrets():
    names = {
        "APP_STORE_CONNECT_ISSUER_ID": r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
        "APP_STORE_CONNECT_KEY_ID": r"^[A-Z0-9]{10}$",
        "APP_STORE_CONNECT_PRIVATE_KEY": r"-----BEGIN PRIVATE KEY-----[\s\S]+-----END PRIVATE KEY-----",
        "APPLE_TEAM_ID": r"^[A-Z0-9]{10}$",
    }
    if not any(os.environ.get(name, "").strip() for name in names):
        # Not set up yet: report it without failing the run.
        row(None, "API 密钥", f"还没有添加。在仓库 Settings → Secrets and variables → Actions 里添加 4 个 Secret（{GUIDE}第 1 步）")
        finish(False, 0)
    values, bad = {}, False
    for name, pattern in names.items():
        value = os.environ.get(name, "").strip()
        if not value:
            row(False, name, f"没有设置。在仓库 Settings → Secrets and variables → Actions 里添加（{GUIDE}第 1 步）")
            bad = True
        elif not re.search(pattern, value, re.IGNORECASE if "ISSUER" in name else 0):
            hint = {
                "APP_STORE_CONNECT_ISSUER_ID": "应形如 57246542-96fe-1a63-e053-0824d011072a",
                "APP_STORE_CONNECT_KEY_ID": "应是 10 位大写字母和数字",
                "APP_STORE_CONNECT_PRIVATE_KEY": "应是 .p8 文件的全部内容，包括 BEGIN 和 END 两行",
                "APPLE_TEAM_ID": "应是 10 位大写字母和数字",
            }[name]
            row(False, name, f"格式不对：{hint}")
            bad = True
        else:
            values[name] = value
            row(True, name, "已设置")
    if bad:
        finish(False, 1)
    return values


def token(v):
    now = int(time.time())
    return jwt.encode(
        {"iss": v["APP_STORE_CONNECT_ISSUER_ID"], "iat": now, "exp": now + 15 * 60, "aud": "appstoreconnect-v1"},
        v["APP_STORE_CONNECT_PRIVATE_KEY"],
        algorithm="ES256",
        headers={"kid": v["APP_STORE_CONNECT_KEY_ID"], "typ": "JWT"},
    )


def get(bearer, path, **params):
    url = API + path + ("?" + urllib.parse.urlencode(params) if params else "")
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {bearer}"})
    try:
        with urllib.request.urlopen(req, timeout=30) as res:
            return res.status, json.load(res)
    except urllib.error.HTTPError as e:
        try:
            body = json.load(e)
        except Exception:
            body = {}
        return e.code, body


def error_text(body):
    errs = body.get("errors") or [{}]
    return "; ".join(f"{e.get('title', '')} {e.get('detail', '')}".strip() for e in errs)


def main():
    v = secrets()
    try:
        bearer = token(v)
    except Exception as e:  # malformed key
        row(False, "API 密钥", f"无法用 .p8 私钥签名：{e}")
        finish(False, 1)

    status, body = get(bearer, "/v1/bundleIds", **{"filter[identifier]": BUNDLE_ID, "limit": "20"})
    if status == 401:
        row(False, "登录 App Store Connect API", "被拒绝（401）。Issuer ID、Key ID 和 .p8 文件三者要属于同一把密钥")
        finish(False, 1)
    if status == 403:
        row(False, "登录 App Store Connect API", "权限不足（403）。这把密钥的角色需要是 Admin")
        finish(False, 1)
    if status != 200:
        row(False, "登录 App Store Connect API", f"HTTP {status}：{error_text(body)}")
        finish(False, 1)
    row(True, "登录 App Store Connect API", "成功")

    ids = [b for b in body.get("data", []) if b["attributes"]["identifier"] == BUNDLE_ID]
    if ids:
        attrs = ids[0]["attributes"]
        row(True, "App ID", f"{BUNDLE_ID}（{attrs.get('name')}，平台 {attrs.get('platform')}）")
    else:
        row(False, "App ID", f"还没有注册 {BUNDLE_ID}（{GUIDE}第 2 步）")

    status, body = get(bearer, "/v1/apps", **{"filter[bundleId]": BUNDLE_ID})
    apps = [a for a in body.get("data", []) if a["attributes"].get("bundleId") == BUNDLE_ID] if status == 200 else []
    if not apps:
        row(False, "App Store Connect 里的 App", f"还没有新建（{GUIDE}第 5 步）")
        row(None, f"内购 {PRODUCT_ID}", "先新建 App")
        finish(False, 0)
    app = apps[0]
    row(True, "App Store Connect 里的 App", f"{app['attributes'].get('name')}（SKU {app['attributes'].get('sku')}）")

    status, body = get(bearer, f"/v1/apps/{app['id']}/inAppPurchasesV2", **{"filter[productId]": PRODUCT_ID})
    iaps = [i for i in body.get("data", []) if i["attributes"].get("productId") == PRODUCT_ID] if status == 200 else []
    if iaps:
        a = iaps[0]["attributes"]
        kind = a.get("inAppPurchaseType")
        ok = kind == "NON_CONSUMABLE"
        detail = f"类型 {kind}，状态 {a.get('state')}"
        row(ok, f"内购 {PRODUCT_ID}", detail if ok else f"{detail}；类型应为非消耗型（NON_CONSUMABLE）")
    elif status == 200:
        row(False, f"内购 {PRODUCT_ID}", f"还没有创建（{GUIDE}第 6 步）。不影响上传 TestFlight，但 App 里会显示「商店暂不可用」")
    else:
        row(None, f"内购 {PRODUCT_ID}", f"查询失败：HTTP {status} {error_text(body)}")

    # The upload only needs the App ID and the app record.
    finish(bool(ids), 0)


if __name__ == "__main__":
    main()
