# Cirrus licences (direct sales)

Windows, Linux and Android builds and the Developer ID Mac build sold outside
the app stores unlock Cirrus Pro with a licence key bought on the Cirrus
website. The App Store and Google
Play builds keep using in-app purchase (`lib/core/billing`).

This file is the contract between the licence server (`server/`) and the app
(`lib/core/licensing/`). Change both sides together.

## Products

| Product id       | Platform | Devices per licence | Default price      |
| ---------------- | -------- | ------------------- | ------------------ |
| `cirrus-windows` | windows  | 1                   | CNY 198 / USD 39.99 |
| `cirrus-macos`   | macos    | 1                   | CNY 198 / USD 39.99 |
| `cirrus-linux`   | linux    | 1                   | CNY 198 / USD 39.99 |
| `cirrus-android` | android  | 3                   | CNY 198 / USD 39.99 |

Each platform is bought separately. `cirrus-macos` is the Developer ID build
downloaded from the website (`.github/workflows/mac-direct.yml`); the Mac App
Store build keeps using in-app purchase, and the two purchases are separate.
Prices and limits live on the server, not in the app: the defaults come from
its configuration (`PRICE_*`, `MAX_DEVICES_*`, `PRODUCTS`) and the operator
can change prices on the admin Prices page.

## Licence keys

`CIRRUS-XXXXX-XXXXX-XXXXX-XXXXX`: 20 random characters (100 bits) from the
Crockford base32 alphabet `0123456789ABCDEFGHJKMNPQRSTVWXYZ`. Input is
normalised before lookup: remove whitespace anywhere, upper-case, map `O`→`0`
and `I`/`L`→`1`, and accept the key with or without dashes and the `CIRRUS`
prefix.

## Device ids

The app sends an opaque device id: lowercase hex
`sha256("cirrus-device:" + raw)`, where `raw` (trimmed) is

- Windows: `MachineGuid` under `HKLM\SOFTWARE\Microsoft\Cryptography`
- Linux: `/etc/machine-id`, falling back to `/var/lib/dbus/machine-id`
- Android: `Settings.Secure.ANDROID_ID`
- macOS: the hardware UUID (`IOPlatformUUID` of `IOPlatformExpertDevice`)

The server never sees the raw value. `device_name` is the host name (desktop)
or `manufacturer model` (Android), for display only.

## Activation token

`base64url(payload) "." base64url(signature)`, both without padding, where
`payload` is the UTF-8 JSON bytes exactly as signed and `signature` is the
64-byte Ed25519 signature of those bytes by the server's signing key.

```json
{"v":1,"lic":"lic_3f9a…","product":"cirrus-windows","platform":"windows",
 "device":"<device id>","iat":1767225600,"owner":"q***@gmail.com"}
```

The app accepts a token only when the signature verifies with the public key
built into the app (`CIRRUS_LICENSE_PUBKEY`, standard base64 of the 32-byte
Ed25519 public key), `v` is 1, `platform` is the running platform and `device`
is this device's id. Tokens do not expire (lifetime licences); revocation is
picked up by `/validate`.

## HTTP API

Base URL: `CIRRUS_LICENSE_SERVER` (default `https://cirrus.routeforge.zone`),
paths under `/api/v1`. Requests and responses are JSON. Errors use the HTTP
status plus `{"error": "<code>", "message": "<text>"}`. The message is in the
language of the request's `Accept-Language` header (English, French,
Japanese, Russian, Simplified or Traditional Chinese), else in Simplified
Chinese; apps should rely on the code.

### `POST /api/v1/activate`

Request: `{"license_key", "device_id", "device_name", "platform", "app_version"}`

| Status | Body |
| ------ | ---- |
| 200 | `{"activation": "<token>", "license": {"product", "platform", "max_devices", "devices_used"}}` |
| 404 | `invalid_key` |
| 403 | `wrong_platform`, plus `"platform"`: the licence's platform (e.g. `"linux"`) |
| 410 | `revoked` |
| 409 | `activation_limit`, plus `"devices": [{"name", "activated_at"}]` (`activated_at` in ISO 8601 UTC) |

Activating a device that is already activated returns 200 with a fresh token
and does not use another slot.

### `POST /api/v1/deactivate`

Request: `{"license_key", "device_id"}`. 200 `{"ok": true}` (also when the
device was not activated); 404 `invalid_key`.

### `POST /api/v1/validate`

Request: `{"license_key", "device_id"}`. 200
`{"status": "active" | "not_activated" | "revoked"}`; 404 `invalid_key`.
The app calls it at most once every 7 days when online and drops its local
activation on `not_activated` or `revoked`. Network errors keep the activation.

### `POST /api/v1/reset`

Self-service release of all devices, for a lost or reinstalled machine.
Request: `{"license_key", "email"}`. 200 `{"ok": true}`; 403
`email_mismatch`; 429 `too_soon` with `"retry_after_days"` (once per 30 days).

### `GET /api/v1/pubkey`

`{"ed25519": "<standard base64 public key>"}`.

### `GET /api/v1/oauth/config`

The Cloudflare OAuth client for "Sign in with Cloudflare". The app calls it
before starting the sign-in, so the requested scopes follow the OAuth client
without an app update.

| Status | Body |
| ------ | ---- |
| 200 | `{"client_id": "9c147a5155baf903357222bd4d31ad50", "scopes": ["…"], "optional_scopes": ["…"], "source": "cloudflare" \| "env"}` |
| 404 | `not_configured`: the server has no scopes to offer |

- `scopes` is never empty on 200; `optional_scopes` may be `[]`.
- Neither list contains `offline_access` or `openid`: the app adds
  `offline_access` itself.
- `source` is `cloudflare` when the scopes were synced from the client's
  settings in the Cloudflare API (refreshed hourly), and `env` when they come
  from the server configuration (`OAUTH_SCOPES`).
- Responses carry `Cache-Control: public, max-age=300`.
- On 404 or a network error the app should fall back to its built-in client id
  and scopes.

### Orders

- `POST /api/v1/orders` `{"product", "email", "method": "alipay" | "wechat"}`
  → 201 `{"order_no", "token", "amount", "currency": "CNY", "status": "pending", "pay": {…}}`.
  - Manual payment (default, uses the merchant's static collection QR codes):
    `"pay": {"type": "static_qr", "qr_image": "/static/pay/alipay.png", "amount": "198.00", "note": "<order_no>"}`.
    The buyer pays that amount and writes the order number in the payment
    note; the operator confirms the payment in `/admin`.
  - Alipay Face-to-Face (当面付, `ALIPAY_MODE=precreate`):
    `"pay": {"type": "qr", "qr_text": "https://qr.alipay.com/…", "qr_image", "amount"}`.
  - Alipay website payment (电脑网站支付, `ALIPAY_MODE=page`; 手机网站支付 on
    phones): `"pay": {"type": "redirect", "url": "<signed Alipay cashier URL>"}`.
  - Both Alipay modes are confirmed automatically by Alipay's notification to
    `/pay/alipay/notify`.
  - WeChat Pay Native (Native 支付, when the server has the WeChat Pay API
    configured): `"pay": {"type": "qr", "qr_text": "weixin://wxpay/bizpayurl?pr=…", "qr_image", "amount"}`,
    the same shape as Alipay Face-to-Face. The code can only be scanned with
    WeChat, not opened as a link. Confirmed automatically by WeChat Pay's
    notification to `/pay/wechat/notify`.
  - When the Alipay or WeChat Pay API fails, the order falls back to
    `static_qr` if the merchant's collection code exists.
  - Errors: 400 `invalid_product` / `invalid_email` / `invalid_method`,
    503 `method_unavailable`, 502 `payment_error`.
- `GET /api/v1/orders/{order_no}?token=…` → `{"status": "pending" | "paid" | "expired", "license_key"?}`.
  The licence key is only included once paid and only with the order token;
  a missing or wrong token gets 404 `order_not_found`.

### Payment notifications

Not called by the app; listed so the paths stay reserved.

- `POST /pay/alipay/notify`: Alipay's asynchronous notification (form,
  RSA2-signed). Answers `success`, or `failure` with a 4xx/5xx status.
- `POST /pay/wechat/notify`: WeChat Pay's APIv3 payment notification (JSON).
  The server verifies the `Wechatpay-Signature` over the raw body with the
  WeChat Pay public key (`Wechatpay-Serial` must be the configured public key
  id, `Wechatpay-Timestamp` within 5 minutes), decrypts `resource`
  (`AEAD_AES_256_GCM` with the APIv3 key), and checks `mchid`, `appid`,
  `trade_state == "SUCCESS"` and `amount.total` (fen) against the order.
  It answers 200 with an empty body when the order is paid (also for a
  repeated notification), and 400 or 500 with
  `{"code": "FAIL", "message": "…"}` otherwise, so that WeChat Pay retries.
  404 when the WeChat Pay API is not configured.

Any rate-limited POST gets 429 `rate_limited` with `Retry-After`; a malformed
request (including a device id that is not 64 lowercase hex characters) gets
400 `bad_request`.

The purchase page links from the app as `/buy?product=cirrus-windows`.

## Test vector

`docs/licensing_test_vector.json` holds a test-only key pair, a machine id,
its device id and a signed token. Both the server and the app tests check
against it, so the two sides agree on encoding and signing.
