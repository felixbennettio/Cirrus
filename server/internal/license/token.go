package license

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"strings"
)

// Claims is the activation token payload. Field order is part of the
// contract: the JSON is produced in exactly this order.
type Claims struct {
	V        int    `json:"v"`
	Lic      string `json:"lic"`
	Product  string `json:"product"`
	Platform string `json:"platform"`
	Device   string `json:"device"`
	Iat      int64  `json:"iat"`
	Owner    string `json:"owner"`
}

// Payload returns the compact UTF-8 JSON bytes that get signed.
func (c Claims) Payload() ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(c); err != nil {
		return nil, err
	}
	return bytes.TrimSuffix(buf.Bytes(), []byte("\n")), nil
}

var b64 = base64.RawURLEncoding

// SignPayload returns base64url(payload) "." base64url(signature), unpadded.
func SignPayload(key ed25519.PrivateKey, payload []byte) string {
	sig := ed25519.Sign(key, payload)
	return b64.EncodeToString(payload) + "." + b64.EncodeToString(sig)
}

// Sign builds and signs a token for the claims.
func Sign(key ed25519.PrivateKey, c Claims) (string, error) {
	p, err := c.Payload()
	if err != nil {
		return "", err
	}
	return SignPayload(key, p), nil
}

// ErrBadToken is returned by Verify for any malformed or forged token.
var ErrBadToken = errors.New("invalid activation token")

// Verify checks the signature and decodes the claims. It does not check the
// platform or device; that is the app's job.
func Verify(pub ed25519.PublicKey, token string) (Claims, error) {
	var c Claims
	p64, s64, ok := strings.Cut(token, ".")
	if !ok {
		return c, ErrBadToken
	}
	payload, err := b64.DecodeString(p64)
	if err != nil {
		return c, ErrBadToken
	}
	sig, err := b64.DecodeString(s64)
	if err != nil || len(sig) != ed25519.SignatureSize {
		return c, ErrBadToken
	}
	if !ed25519.Verify(pub, payload, sig) {
		return c, ErrBadToken
	}
	if err := json.Unmarshal(payload, &c); err != nil || c.V != 1 {
		return c, ErrBadToken
	}
	return c, nil
}

// PublicKeyBase64 is the standard base64 of the 32-byte public key, the form
// the app embeds as CIRRUS_LICENSE_PUBKEY.
func PublicKeyBase64(key ed25519.PrivateKey) string {
	return base64.StdEncoding.EncodeToString(key.Public().(ed25519.PublicKey))
}

// LoadOrCreateKey reads the hex Ed25519 seed at path, creating it (mode 0600)
// when the file does not exist. An existing file is never overwritten: if it
// is unreadable or malformed, an error is returned instead.
func LoadOrCreateKey(path string) (key ed25519.PrivateKey, created bool, err error) {
	data, err := os.ReadFile(path)
	switch {
	case err == nil:
		seed, err := hex.DecodeString(strings.TrimSpace(string(data)))
		if err != nil || len(seed) != ed25519.SeedSize {
			return nil, false, fmt.Errorf("%s: expected %d bytes of hex, refusing to replace it", path, ed25519.SeedSize)
		}
		return ed25519.NewKeyFromSeed(seed), false, nil
	case !errors.Is(err, fs.ErrNotExist):
		return nil, false, err
	}

	seed := make([]byte, ed25519.SeedSize)
	if _, err := rand.Read(seed); err != nil {
		return nil, false, err
	}
	// O_EXCL: if another process created the file in the meantime, fail
	// rather than overwrite.
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return nil, false, err
	}
	if _, err := f.WriteString(hex.EncodeToString(seed) + "\n"); err != nil {
		f.Close()
		return nil, false, err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return nil, false, err
	}
	if err := f.Close(); err != nil {
		return nil, false, err
	}
	return ed25519.NewKeyFromSeed(seed), true, nil
}
