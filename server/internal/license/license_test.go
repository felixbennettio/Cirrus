package license

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

type vector struct {
	SeedHex         string `json:"seed_hex"`
	PublicKeyBase64 string `json:"public_key_base64"`
	MachineID       string `json:"machine_id"`
	DeviceID        string `json:"device_id"`
	Payload         string `json:"payload"`
	Token           string `json:"token"`
}

func loadVector(t *testing.T) vector {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "docs", "licensing_test_vector.json"))
	if err != nil {
		t.Fatalf("read test vector: %v", err)
	}
	var v vector
	if err := json.Unmarshal(data, &v); err != nil {
		t.Fatal(err)
	}
	return v
}

func vectorKey(t *testing.T, v vector) ed25519.PrivateKey {
	t.Helper()
	seed, err := hex.DecodeString(v.SeedHex)
	if err != nil {
		t.Fatal(err)
	}
	return ed25519.NewKeyFromSeed(seed)
}

func TestVectorTokenExact(t *testing.T) {
	v := loadVector(t)
	key := vectorKey(t, v)

	if got := PublicKeyBase64(key); got != v.PublicKeyBase64 {
		t.Fatalf("public key = %s, want %s", got, v.PublicKeyBase64)
	}
	if got := SignPayload(key, []byte(v.Payload)); got != v.Token {
		t.Fatalf("token mismatch\n got %s\nwant %s", got, v.Token)
	}
}

func TestVectorClaimsSerialiseToPayload(t *testing.T) {
	v := loadVector(t)
	key := vectorKey(t, v)
	c := Claims{
		V: 1, Lic: "lic_test0001", Product: "cirrus-linux", Platform: "linux",
		Device: v.DeviceID, Iat: 1767225600, Owner: MaskEmail("qa@example.com"),
	}
	p, err := c.Payload()
	if err != nil {
		t.Fatal(err)
	}
	if string(p) != v.Payload {
		t.Fatalf("payload mismatch\n got %s\nwant %s", p, v.Payload)
	}
	tok, err := Sign(key, c)
	if err != nil {
		t.Fatal(err)
	}
	if tok != v.Token {
		t.Fatalf("Sign(claims) != vector token")
	}
}

func TestVectorDeviceID(t *testing.T) {
	v := loadVector(t)
	if got := DeviceID(v.MachineID); got != v.DeviceID {
		t.Fatalf("DeviceID = %s, want %s", got, v.DeviceID)
	}
	if got := DeviceID("  " + v.MachineID + "\n"); got != v.DeviceID {
		t.Fatalf("raw value is not trimmed")
	}
	if !ValidDeviceID(v.DeviceID) {
		t.Fatal("vector device id rejected")
	}
	for _, bad := range []string{"", "abc", strings.ToUpper(v.DeviceID), v.DeviceID + "0", strings.Repeat("g", 64)} {
		if ValidDeviceID(bad) {
			t.Errorf("ValidDeviceID(%q) = true", bad)
		}
	}
}

func TestVerify(t *testing.T) {
	v := loadVector(t)
	pubRaw, _ := base64.StdEncoding.DecodeString(v.PublicKeyBase64)
	pub := ed25519.PublicKey(pubRaw)

	c, err := Verify(pub, v.Token)
	if err != nil {
		t.Fatal(err)
	}
	if c.Lic != "lic_test0001" || c.Platform != "linux" || c.Device != v.DeviceID || c.Iat != 1767225600 {
		t.Fatalf("claims = %+v", c)
	}

	// Tamper with the payload: the signature must fail.
	p64, s64, _ := strings.Cut(v.Token, ".")
	payload, _ := base64.RawURLEncoding.DecodeString(p64)
	forged := strings.Replace(string(payload), "linux", "windows", 1)
	bad := base64.RawURLEncoding.EncodeToString([]byte(forged)) + "." + s64
	if _, err := Verify(pub, bad); err == nil {
		t.Fatal("tampered token verified")
	}
	other := ed25519.NewKeyFromSeed(make([]byte, 32))
	if _, err := Verify(other.Public().(ed25519.PublicKey), v.Token); err == nil {
		t.Fatal("token verified with the wrong key")
	}
	for _, junk := range []string{"", "abc", "a.b", v.Token + "x"} {
		if _, err := Verify(pub, junk); err == nil {
			t.Errorf("Verify(%q) succeeded", junk)
		}
	}
}

var keyRe = regexp.MustCompile(`^CIRRUS-[0-9A-HJKMNP-TV-Z]{5}-[0-9A-HJKMNP-TV-Z]{5}-[0-9A-HJKMNP-TV-Z]{5}-[0-9A-HJKMNP-TV-Z]{5}$`)

func TestNewKey(t *testing.T) {
	seen := map[string]bool{}
	counts := map[rune]int{}
	for i := 0; i < 2000; i++ {
		k, err := NewKey()
		if err != nil {
			t.Fatal(err)
		}
		if !keyRe.MatchString(k) {
			t.Fatalf("bad key format %q", k)
		}
		if seen[k] {
			t.Fatalf("duplicate key %q", k)
		}
		seen[k] = true
		n, err := NormalizeKey(k)
		if err != nil || n != k {
			t.Fatalf("NormalizeKey(%q) = %q, %v", k, n, err)
		}
		for _, r := range strings.ReplaceAll(k[len(KeyPrefix):], "-", "") {
			counts[r]++
		}
	}
	// Every alphabet character should show up across 40000 draws.
	if len(counts) != len(Alphabet) {
		t.Fatalf("only %d distinct characters used", len(counts))
	}
}

func TestNormalizeKey(t *testing.T) {
	const want = "CIRRUS-ABCDE-FGH01-JKMNP-QRSTV"
	ok := []string{
		want,
		"cirrus-abcde-fgh01-jkmnp-qrstv",
		"  CIRRUS-ABCDE-FGH01-JKMNP-QRSTV \n",
		"ABCDE-FGH01-JKMNP-QRSTV",
		"ABCDEFGH01JKMNPQRSTV",
		"CIRRUSABCDEFGH01JKMNPQRSTV",
		"abcdefghO1jkmnpqrstv",           // O → 0
		"ABCDE-FGH0I-JKMNP-QRSTV",        // I → 1
		"ABCDE-FGH0l-JKMNP-QRSTV",        // l → L → 1
		"ABCDE FGH01 JKMNP QRSTV",        // spaces
		"CIRRUS–ABCDE–FGH01–JKMNP–QRSTV", // en dashes
	}
	for _, in := range ok {
		got, err := NormalizeKey(in)
		if err != nil || got != want {
			t.Errorf("NormalizeKey(%q) = %q, %v; want %q", in, got, err, want)
		}
	}
	bad := []string{
		"",
		"CIRRUS",
		"ABCDE-FGH01-JKMNP-QRST",         // 19 chars
		"ABCDE-FGH01-JKMNP-QRSTVW",       // 21 chars
		"ABCDE-FGH01-JKMNP-QRSTU",        // U is not in the alphabet
		"CIRRUZ-ABCDE-FGH01-JKMNP-QRSTV", // wrong prefix
		"ABCDE-FGH01-JKMNP-QRST!",
		"ABCDE-FGH01-JKMNP-QRSTＶ", // full-width V
	}
	for _, in := range bad {
		if got, err := NormalizeKey(in); err == nil {
			t.Errorf("NormalizeKey(%q) = %q, want error", in, got)
		}
	}
}

func TestMaskEmail(t *testing.T) {
	cases := map[string]string{
		"qingzeqi@gmail.com": "q***@gmail.com",
		"q@example.com":      "q***@example.com",
		"张三@例子.中国":           "张***@例子.中国",
		"":                   "",
		"no-at-sign":         "",
		"@example.com":       "",
	}
	for in, want := range cases {
		if got := MaskEmail(in); got != want {
			t.Errorf("MaskEmail(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestLoadOrCreateKey(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "signing.key")

	k1, created, err := LoadOrCreateKey(path)
	if err != nil || !created {
		t.Fatalf("create: %v created=%v", err, created)
	}
	st, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if st.Mode().Perm() != 0o600 {
		t.Fatalf("mode = %v, want 0600", st.Mode().Perm())
	}
	data, _ := os.ReadFile(path)
	if len(strings.TrimSpace(string(data))) != 64 {
		t.Fatalf("seed file should hold 64 hex chars, got %q", data)
	}

	k2, created, err := LoadOrCreateKey(path)
	if err != nil || created {
		t.Fatalf("reload: %v created=%v", err, created)
	}
	if !k1.Equal(k2) {
		t.Fatal("reloaded key differs")
	}

	// A corrupt key file is an error and is left untouched.
	if err := os.WriteFile(path, []byte("garbage"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, _, err := LoadOrCreateKey(path); err == nil {
		t.Fatal("corrupt key accepted")
	}
	data, _ = os.ReadFile(path)
	if string(data) != "garbage" {
		t.Fatal("corrupt key file was overwritten")
	}
}
