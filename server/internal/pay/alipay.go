package pay

import (
	"bytes"
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"time"

	"cirrus/server/internal/money"
)

// Alipay modes (ALIPAY_MODE).
const (
	// ModePrecreate is Face-to-Face (当面付, alipay.trade.precreate): the
	// buyer scans a dynamic QR code.
	ModePrecreate = "precreate"
	// ModePage is computer website payment (电脑网站支付,
	// alipay.trade.page.pay): the buyer is sent to Alipay's cashier. Phones
	// get mobile website payment (手机网站支付, alipay.trade.wap.pay).
	ModePage = "page"
)

// Alipay is Alipay payment in public-key mode (公钥模式) with RSA2
// signatures: Face-to-Face (precreate) or website payment (page), as set by
// Mode. Both are confirmed by the same asynchronous notification.
type Alipay struct {
	AppID     string
	Gateway   string
	NotifyURL string
	Mode      string // ModePrecreate (default) or ModePage
	Client    *http.Client
	Now       func() time.Time

	priv *rsa.PrivateKey // the app private key (应用私钥)
	pub  *rsa.PublicKey  // Alipay's public key (支付宝公钥)
}

// NewAlipay parses the keys. Keys may be PEM or bare base64 (as Alipay's key
// tool prints them), PKCS#8 or PKCS#1 for the private key, X.509
// SubjectPublicKeyInfo or PKCS#1 for the public key.
func NewAlipay(appID, privateKey, alipayPublicKey, gateway, notifyURL string) (*Alipay, error) {
	priv, err := ParsePrivateKey(privateKey)
	if err != nil {
		return nil, fmt.Errorf("ALIPAY_PRIVATE_KEY: %w", err)
	}
	pub, err := ParsePublicKey(alipayPublicKey)
	if err != nil {
		return nil, fmt.Errorf("ALIPAY_PUBLIC_KEY: %w", err)
	}
	return &Alipay{
		AppID:     appID,
		Gateway:   gateway,
		NotifyURL: notifyURL,
		Client:    &http.Client{Timeout: 15 * time.Second},
		Now:       time.Now,
		priv:      priv,
		pub:       pub,
	}, nil
}

// Name implements Provider: "alipay_f2f" or "alipay_page".
func (a *Alipay) Name() string {
	if a.Mode == ModePage {
		return "alipay_page"
	}
	return "alipay_f2f"
}

// Method implements Provider.
func (a *Alipay) Method() string { return "alipay" }

// TTL implements Provider: Alipay orders stay open for 2 hours.
func (a *Alipay) TTL() time.Duration { return 2 * time.Hour }

// Available implements Provider.
func (a *Alipay) Available() bool { return true }

// China Standard Time: Alipay timestamps are in UTC+8 (no DST).
var cst = time.FixedZone("CST", 8*3600)

// Create starts the payment: a QR code in precreate mode, a cashier URL in
// page mode.
func (a *Alipay) Create(ctx context.Context, o Order) (Info, error) {
	if a.Mode == ModePage {
		u, err := a.PageURL(o)
		return Info{Type: TypeRedirect, URL: u}, err
	}
	return a.precreate(ctx, o)
}

// signedParams builds and signs the common request parameters.
func (a *Alipay) signedParams(method string, biz, extra map[string]string) (url.Values, error) {
	bizJSON, err := compactJSON(biz)
	if err != nil {
		return nil, err
	}
	params := url.Values{}
	params.Set("app_id", a.AppID)
	params.Set("method", method)
	params.Set("format", "JSON")
	params.Set("charset", "utf-8")
	params.Set("sign_type", "RSA2")
	params.Set("timestamp", a.Now().In(cst).Format("2006-01-02 15:04:05"))
	params.Set("version", "1.0")
	params.Set("notify_url", a.NotifyURL)
	params.Set("biz_content", bizJSON)
	for k, v := range extra {
		if v != "" {
			params.Set(k, v)
		}
	}
	sig, err := Sign(a.priv, Content(params, "sign"))
	if err != nil {
		return nil, err
	}
	params.Set("sign", sig)
	return params, nil
}

// PageURL returns the signed URL of Alipay's cashier for the order:
// alipay.trade.page.pay (FAST_INSTANT_TRADE_PAY), or alipay.trade.wap.pay
// (QUICK_WAP_WAY) when o.Mobile. No request is made: the browser follows the
// URL. Its timestamp makes it short-lived, so build a fresh one each time.
func (a *Alipay) PageURL(o Order) (string, error) {
	method := "alipay.trade.page.pay"
	biz := map[string]string{
		"out_trade_no":    o.No,
		"total_amount":    money.Format(o.AmountCents),
		"subject":         o.Subject,
		"product_code":    "FAST_INSTANT_TRADE_PAY",
		"timeout_express": "2h",
	}
	if o.Mobile {
		method = "alipay.trade.wap.pay"
		biz["product_code"] = "QUICK_WAP_WAY"
		if o.ReturnURL != "" {
			biz["quit_url"] = o.ReturnURL
		}
	}
	params, err := a.signedParams(method, biz, map[string]string{"return_url": o.ReturnURL})
	if err != nil {
		return "", err
	}
	sep := "?"
	if strings.Contains(a.Gateway, "?") {
		sep = "&"
	}
	return a.Gateway + sep + params.Encode(), nil
}

// precreate calls alipay.trade.precreate and returns the QR code to show.
func (a *Alipay) precreate(ctx context.Context, o Order) (Info, error) {
	params, err := a.signedParams("alipay.trade.precreate", map[string]string{
		"out_trade_no":    o.No,
		"total_amount":    money.Format(o.AmountCents),
		"subject":         o.Subject,
		"timeout_express": "2h",
	}, nil)
	if err != nil {
		return Info{}, err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, a.Gateway, strings.NewReader(params.Encode()))
	if err != nil {
		return Info{}, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded;charset=utf-8")
	resp, err := a.Client.Do(req)
	if err != nil {
		return Info{}, fmt.Errorf("alipay precreate: %w", err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return Info{}, fmt.Errorf("alipay precreate: %w", err)
	}
	if resp.StatusCode != http.StatusOK {
		return Info{}, fmt.Errorf("alipay precreate: HTTP %d", resp.StatusCode)
	}

	var env map[string]json.RawMessage
	if err := json.Unmarshal(body, &env); err != nil {
		return Info{}, fmt.Errorf("alipay precreate: bad response: %w", err)
	}
	raw := env["alipay_trade_precreate_response"]
	var r struct {
		Code       string `json:"code"`
		Msg        string `json:"msg"`
		SubCode    string `json:"sub_code"`
		SubMsg     string `json:"sub_msg"`
		OutTradeNo string `json:"out_trade_no"`
		QRCode     string `json:"qr_code"`
	}
	if err := json.Unmarshal(raw, &r); err != nil {
		return Info{}, fmt.Errorf("alipay precreate: bad response: %w", err)
	}
	if r.Code != "10000" {
		return Info{}, fmt.Errorf("alipay precreate: %s %s %s %s", r.Code, r.Msg, r.SubCode, r.SubMsg)
	}
	// The response signature covers the exact bytes of the response object.
	var respSig string
	if err := json.Unmarshal(env["sign"], &respSig); err != nil || respSig == "" {
		return Info{}, errors.New("alipay precreate: response is not signed")
	}
	if err := Verify(a.pub, string(raw), respSig); err != nil {
		return Info{}, fmt.Errorf("alipay precreate: response signature: %w", err)
	}
	if r.OutTradeNo != o.No || r.QRCode == "" {
		return Info{}, errors.New("alipay precreate: response does not match the order")
	}
	return Info{Type: TypeQR, QRText: r.QRCode}, nil
}

// VerifyNotify checks the signature of an asynchronous notification (the
// form posted to notify_url). Callers must still check app_id,
// out_trade_no, total_amount and trade_status.
func (a *Alipay) VerifyNotify(form url.Values) error {
	if st := form.Get("sign_type"); st != "" && st != "RSA2" {
		return fmt.Errorf("unsupported sign_type %q", st)
	}
	sig := form.Get("sign")
	if sig == "" {
		return errors.New("missing sign")
	}
	return Verify(a.pub, Content(form, "sign", "sign_type"), sig)
}

// Content is Alipay's string to sign: parameters with non-empty values,
// minus the excluded keys, sorted by key and joined as k=v with "&", values
// unencoded.
func Content(params url.Values, exclude ...string) string {
	keys := make([]string, 0, len(params))
	for k := range params {
		skip := params.Get(k) == ""
		for _, e := range exclude {
			skip = skip || k == e
		}
		if !skip {
			keys = append(keys, k)
		}
	}
	sort.Strings(keys)
	var sb strings.Builder
	for i, k := range keys {
		if i > 0 {
			sb.WriteByte('&')
		}
		sb.WriteString(k)
		sb.WriteByte('=')
		sb.WriteString(params.Get(k))
	}
	return sb.String()
}

// Sign returns the RSA2 (SHA256withRSA, PKCS#1 v1.5) signature, base64.
func Sign(priv *rsa.PrivateKey, content string) (string, error) {
	sum := sha256.Sum256([]byte(content))
	sig, err := rsa.SignPKCS1v15(rand.Reader, priv, crypto.SHA256, sum[:])
	if err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(sig), nil
}

// Verify checks an RSA2 signature.
func Verify(pub *rsa.PublicKey, content, sig string) error {
	raw, err := base64.StdEncoding.DecodeString(sig)
	if err != nil {
		return errors.New("signature is not base64")
	}
	sum := sha256.Sum256([]byte(content))
	if err := rsa.VerifyPKCS1v15(pub, crypto.SHA256, sum[:], raw); err != nil {
		return errors.New("bad signature")
	}
	return nil
}

func compactJSON(v any) (string, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return "", err
	}
	return strings.TrimSuffix(buf.String(), "\n"), nil
}

func keyDER(s string) ([]byte, error) {
	s = strings.TrimSpace(strings.ReplaceAll(s, `\n`, "\n"))
	if strings.HasPrefix(s, "-----BEGIN") {
		block, _ := pem.Decode([]byte(s))
		if block == nil {
			return nil, errors.New("bad PEM")
		}
		return block.Bytes, nil
	}
	der, err := base64.StdEncoding.DecodeString(strings.Join(strings.Fields(s), ""))
	if err != nil {
		return nil, errors.New("expected PEM or base64")
	}
	return der, nil
}

// ParsePrivateKey reads an RSA private key (PKCS#8 or PKCS#1, PEM or bare
// base64).
func ParsePrivateKey(s string) (*rsa.PrivateKey, error) {
	der, err := keyDER(s)
	if err != nil {
		return nil, err
	}
	if k, err := x509.ParsePKCS8PrivateKey(der); err == nil {
		if rk, ok := k.(*rsa.PrivateKey); ok {
			return rk, nil
		}
		return nil, errors.New("not an RSA key")
	}
	if k, err := x509.ParsePKCS1PrivateKey(der); err == nil {
		return k, nil
	}
	return nil, errors.New("not a PKCS#8 or PKCS#1 RSA private key")
}

// ParsePublicKey reads an RSA public key (X.509 SubjectPublicKeyInfo or
// PKCS#1, PEM or bare base64).
func ParsePublicKey(s string) (*rsa.PublicKey, error) {
	der, err := keyDER(s)
	if err != nil {
		return nil, err
	}
	if k, err := x509.ParsePKIXPublicKey(der); err == nil {
		if rk, ok := k.(*rsa.PublicKey); ok {
			return rk, nil
		}
		return nil, errors.New("not an RSA key")
	}
	if k, err := x509.ParsePKCS1PublicKey(der); err == nil {
		return k, nil
	}
	return nil, errors.New("not an RSA public key")
}
