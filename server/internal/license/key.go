// Package license implements the licence key format, device ids and signed
// activation tokens described in docs/licensing.md.
package license

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"strings"
	"unicode"
)

// Alphabet is Crockford base32: no I, L, O or U.
const Alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

// KeyPrefix starts every canonical key.
const KeyPrefix = "CIRRUS"

const bodyLen = 20

// ErrInvalidKey means the input cannot be a licence key.
var ErrInvalidKey = errors.New("invalid licence key")

// NewKey returns a fresh key, CIRRUS-XXXXX-XXXXX-XXXXX-XXXXX, carrying 100
// random bits (20 characters of 5 bits).
func NewKey() (string, error) {
	var raw [bodyLen]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "", err
	}
	body := make([]byte, bodyLen)
	for i, b := range raw {
		// 256 is a multiple of 32, so the low five bits are uniform.
		body[i] = Alphabet[b&31]
	}
	return format(body), nil
}

func format(body []byte) string {
	var sb strings.Builder
	sb.Grow(len(KeyPrefix) + bodyLen + 4)
	sb.WriteString(KeyPrefix)
	for i := 0; i < bodyLen; i += 5 {
		sb.WriteByte('-')
		sb.Write(body[i : i+5])
	}
	return sb.String()
}

// NormalizeKey returns the canonical form of a user-typed key: trimmed,
// upper-cased, O→0 and I/L→1, with or without dashes and the CIRRUS prefix.
// Whitespace and Unicode dashes inside the key are ignored as well.
func NormalizeKey(s string) (string, error) {
	s = strings.ToUpper(strings.TrimSpace(s))
	b := make([]byte, 0, len(s))
	for _, r := range s {
		switch {
		case r == '-' || unicode.IsSpace(r) || unicode.Is(unicode.Pd, r) || r == '−':
			continue
		case r > unicode.MaxASCII:
			return "", ErrInvalidKey
		}
		b = append(b, byte(r))
	}
	// The prefix contains I and U, which never occur in a key body, so it can
	// be stripped before the O/I/L mapping without ambiguity.
	if len(b) == len(KeyPrefix)+bodyLen && string(b[:len(KeyPrefix)]) == KeyPrefix {
		b = b[len(KeyPrefix):]
	}
	if len(b) != bodyLen {
		return "", ErrInvalidKey
	}
	for i, c := range b {
		switch c {
		case 'O':
			c = '0'
		case 'I', 'L':
			c = '1'
		}
		if strings.IndexByte(Alphabet, c) < 0 {
			return "", ErrInvalidKey
		}
		b[i] = c
	}
	return format(b), nil
}

// DeviceID is how the app derives its device id from the raw machine id:
// lowercase hex sha256("cirrus-device:" + trimmed raw). The server only ever
// receives the result; this is here for tests and tooling.
func DeviceID(raw string) string {
	sum := sha256.Sum256([]byte("cirrus-device:" + strings.TrimSpace(raw)))
	return hex.EncodeToString(sum[:])
}

// ValidDeviceID reports whether s looks like a device id: 64 lowercase hex
// characters.
func ValidDeviceID(s string) bool {
	if len(s) != 64 {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return false
		}
	}
	return true
}

// MaskEmail hides most of the local part: "qing@gmail.com" → "q***@gmail.com".
// It is what activation tokens carry as "owner".
func MaskEmail(email string) string {
	email = strings.TrimSpace(email)
	local, domain, ok := strings.Cut(email, "@")
	if !ok || local == "" {
		return ""
	}
	first := []rune(local)[0]
	return string(first) + "***@" + domain
}
