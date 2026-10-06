# Cirrus licences (direct sales)

Windows, Linux and Android builds sold outside the app stores unlock Cirrus
Pro with a licence key bought on the Cirrus website. The App Store and Google
Play builds keep using in-app purchase (`lib/core/billing`).

This file is the contract between the licence server (`server/`) and the app
(`lib/core/licensing/`). Change both sides together.

## Products

| Product id       | Platform | Devices per licence | Default price      |
| ---------------- | -------- | ------------------- | ------------------ |
| `cirrus-windows` | windows  | 1                   | CNY 198 / USD 39.99 |
| `cirrus-linux`   | linux    | 1                   | CNY 198 / USD 39.99 |
| `cirrus-android` | android  | 3                   | CNY 198 / USD 39.99 |

Windows and Linux are bought separately. Prices and limits live in the server
configuration, not in the app.

## Licence keys

`CIRRUS-XXXXX-XXXXX-XXXXX-XXXXX`: 20 random characters (100 bits) from the
Crockford base32 alphabet `0123456789ABCDEFGHJKMNPQRSTVWXYZ`. Input is
normalised before lookup: trim, upper-case, map `O`→`0` and `I`/`L`→`1`, and
accept the key with or without dashes and the `CIRRUS` prefix.

## Device ids

The app sends an opaque device id: lowercase hex
`sha256("cirrus-device:" + raw)`, where `raw` (trimmed) is

- Windows: `MachineGuid` under `HKLM\SOFTWARE\Microsoft\Cryptography`
- Linux: `/etc/machine-id`, falling back to `/var/lib/dbus/machine-id`
- Android: `Settings.Secure.ANDROID_ID`

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
status plus `{"error": "<code>", "message": "<text in Chinese>"}`.

### `POST /api/v1/activate`

Request: `{"license_key", "device_id", "device_name", "platform", "app_version"}`

| Status | Body |
| ------ | ---- |
| 200 | `{"activation": "<token>", "license": {"product", "platform", "max_devices", "devices_used"}}` |
| 404 | `invalid_key` |
| 403 | `wrong_platform` (the licence is for another platform) |
| 410 | `revoked` |
| 409 | `activation_limit`, plus `"devices": [{"name", "activated_at"}]` |

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

### Orders

- `POST /api/v1/orders` `{"product", "email", "method": "alipay" | "wechat"}`
  → 201 `{"order_no", "token", "amount", "currency": "CNY", "status": "pending", "pay": {…}}`.
  - Manual payment (default, uses the merchant's static collection QR codes):
    `"pay": {"type": "static_qr", "qr_image": "/static/pay/alipay.png", "amount": "198.00", "note": "<order_no>"}`.
    The buyer pays that amount and writes the order number in the payment
    note; the operator confirms the payment in `/admin`.
  - Alipay Face-to-Face (当面付), when configured:
    `"pay": {"type": "qr", "qr_text": "https://qr.alipay.com/…"}`, confirmed
    automatically by Alipay's notification.
- `GET /api/v1/orders/{order_no}?token=…` → `{"status": "pending" | "paid" | "expired", "license_key"?}`.
  The licence key is only included once paid and only with the order token.

The purchase page links from the app as `/buy?product=cirrus-windows`.
