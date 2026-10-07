package pay

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/rsa"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// WeChat is WeChat Pay Native payment (Native 支付, APIv3): the buyer scans a
// dynamic QR code (weixin://wxpay/bizpayurl?pr=…). Requests are signed with
// the merchant API private key; responses and notifications are verified
// with the WeChat Pay public key (微信支付公钥, not platform certificates),
// and notification resources are decrypted with the APIv3 key.
type WeChat struct {
	MchID       string
	AppID       string
	CertSerial  string // serial number of the merchant API certificate
	PublicKeyID string // PUB_KEY_ID_…: the id of the WeChat Pay public key
	Gateway     string // https://api.mch.weixin.qq.com
	NotifyURL   string
	Client      *http.Client
	Now         func() time.Time

	apiV3Key []byte
	priv     *rsa.PrivateKey // the merchant API key (apiclient_key.pem)
	pub      *rsa.PublicKey  // the WeChat Pay public key
}

// WeChatConfig is what NewWeChat needs. Keys may be PEM, PEM with literal
// \n, or bare base64, as for Alipay.
type WeChatConfig struct {
	MchID, AppID, APIv3Key, CertSerial string
	PrivateKey, PublicKey, PublicKeyID string
	Gateway, NotifyURL                 string
}

// NewWeChat checks the APIv3 key and parses the keys.
func NewWeChat(c WeChatConfig) (*WeChat, error) {
	if len(c.APIv3Key) != 32 {
		return nil, errors.New("WECHAT_API_V3_KEY must be 32 bytes")
	}
	priv, err := ParsePrivateKey(c.PrivateKey)
	if err != nil {
		return nil, fmt.Errorf("WECHAT_PRIVATE_KEY: %w", err)
	}
	pub, err := ParsePublicKey(c.PublicKey)
	if err != nil {
		return nil, fmt.Errorf("WECHAT_PUBLIC_KEY: %w", err)
	}
	return &WeChat{
		MchID:       c.MchID,
		AppID:       c.AppID,
		CertSerial:  c.CertSerial,
		PublicKeyID: c.PublicKeyID,
		Gateway:     strings.TrimRight(c.Gateway, "/"),
		NotifyURL:   c.NotifyURL,
		Client:      &http.Client{Timeout: 15 * time.Second},
		Now:         time.Now,
		apiV3Key:    []byte(c.APIv3Key),
		priv:        priv,
		pub:         pub,
	}, nil
}

// Name implements Provider.
func (w *WeChat) Name() string { return "wechat_native" }

// Method implements Provider.
func (w *WeChat) Method() string { return "wechat" }

// TTL implements Provider: WeChat orders stay open for 2 hours.
func (w *WeChat) TTL() time.Duration { return 2 * time.Hour }

// Available implements Provider.
func (w *WeChat) Available() bool { return true }

// NativePath is the Native order endpoint under the gateway.
const NativePath = "/v3/pay/transactions/native"

// Create places a Native order and returns its code_url as a QR code.
func (w *WeChat) Create(ctx context.Context, o Order) (Info, error) {
	body, err := compactJSON(map[string]any{
		"appid":        w.AppID,
		"mchid":        w.MchID,
		"description":  o.Subject,
		"out_trade_no": o.No,
		"notify_url":   w.NotifyURL,
		"time_expire":  w.Now().Add(w.TTL()).In(cst).Format(time.RFC3339),
		"amount":       map[string]any{"total": o.AmountCents, "currency": "CNY"},
	})
	if err != nil {
		return Info{}, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, w.Gateway+NativePath, strings.NewReader(body))
	if err != nil {
		return Info{}, err
	}
	auth, err := w.Authorization(http.MethodPost, req.URL.RequestURI(), body)
	if err != nil {
		return Info{}, err
	}
	req.Header.Set("Authorization", auth)
	req.Header.Set("Accept", "application/json")
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", "cirrus-license (Go)")
	req.Header.Set("Wechatpay-Serial", w.PublicKeyID)

	resp, err := w.Client.Do(req)
	if err != nil {
		return Info{}, fmt.Errorf("wechat native: %w", err)
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return Info{}, fmt.Errorf("wechat native: %w", err)
	}
	if resp.StatusCode != http.StatusOK {
		var e struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		}
		json.Unmarshal(raw, &e)
		return Info{}, fmt.Errorf("wechat native: HTTP %d %s %s", resp.StatusCode, e.Code, e.Message)
	}
	if resp.Header.Get("Wechatpay-Signature") != "" {
		if err := w.VerifyResponse(resp.Header, raw); err != nil {
			return Info{}, fmt.Errorf("wechat native: response signature: %w", err)
		}
	}
	var r struct {
		CodeURL string `json:"code_url"`
	}
	if err := json.Unmarshal(raw, &r); err != nil || r.CodeURL == "" {
		return Info{}, errors.New("wechat native: response has no code_url")
	}
	return Info{Type: TypeQR, QRText: r.CodeURL}, nil
}

// Authorization returns the Authorization header for a request:
// WECHATPAY2-SHA256-RSA2048 over "METHOD\nURL\nTIMESTAMP\nNONCE\nBODY\n",
// where URL is the path and query.
func (w *WeChat) Authorization(method, canonicalURL, body string) (string, error) {
	ts := strconv.FormatInt(w.Now().Unix(), 10)
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	nonce := strings.ToUpper(hex.EncodeToString(b))
	sig, err := Sign(w.priv, method+"\n"+canonicalURL+"\n"+ts+"\n"+nonce+"\n"+body+"\n")
	if err != nil {
		return "", err
	}
	return fmt.Sprintf(`WECHATPAY2-SHA256-RSA2048 mchid="%s",nonce_str="%s",signature="%s",timestamp="%s",serial_no="%s"`,
		w.MchID, nonce, sig, ts, w.CertSerial), nil
}

// VerifyResponse checks the Wechatpay-* signature headers of an API response.
func (w *WeChat) VerifyResponse(h http.Header, body []byte) error {
	return w.verify(h, body, false)
}

// verify checks a signature made with the WeChat Pay public key over
// "TIMESTAMP\nNONCE\nBODY\n"; with fresh, the timestamp must be within 5
// minutes of now.
func (w *WeChat) verify(h http.Header, body []byte, fresh bool) error {
	if s := h.Get("Wechatpay-Serial"); s != w.PublicKeyID {
		return fmt.Errorf("serial %q is not WECHAT_PUBLIC_KEY_ID", s)
	}
	ts, nonce, sig := h.Get("Wechatpay-Timestamp"), h.Get("Wechatpay-Nonce"), h.Get("Wechatpay-Signature")
	if ts == "" || nonce == "" || sig == "" {
		return errors.New("missing Wechatpay signature headers")
	}
	if fresh {
		sec, err := strconv.ParseInt(ts, 10, 64)
		if err != nil {
			return errors.New("bad Wechatpay-Timestamp")
		}
		if d := w.Now().Sub(time.Unix(sec, 0)); d > 5*time.Minute || d < -5*time.Minute {
			return errors.New("stale Wechatpay-Timestamp")
		}
	}
	return Verify(w.pub, ts+"\n"+nonce+"\n"+string(body)+"\n", sig)
}

// WeChatTransaction is the decrypted resource of a payment notification.
type WeChatTransaction struct {
	AppID         string `json:"appid"`
	MchID         string `json:"mchid"`
	OutTradeNo    string `json:"out_trade_no"`
	TransactionID string `json:"transaction_id"`
	TradeState    string `json:"trade_state"`
	Amount        struct {
		Total    int64  `json:"total"`
		Currency string `json:"currency"`
	} `json:"amount"`
}

// VerifyNotify checks the signature of a payment notification (the raw
// body and its headers) and decrypts its resource. Callers must still check
// mchid, appid, trade_state and amount.
func (w *WeChat) VerifyNotify(h http.Header, body []byte) (WeChatTransaction, error) {
	var tx WeChatTransaction
	if err := w.verify(h, body, true); err != nil {
		return tx, err
	}
	var n struct {
		Resource struct {
			Algorithm      string `json:"algorithm"`
			Ciphertext     string `json:"ciphertext"`
			AssociatedData string `json:"associated_data"`
			Nonce          string `json:"nonce"`
		} `json:"resource"`
	}
	if err := json.Unmarshal(body, &n); err != nil {
		return tx, errors.New("bad notification")
	}
	r := n.Resource
	if r.Algorithm != "AEAD_AES_256_GCM" {
		return tx, fmt.Errorf("unsupported algorithm %q", r.Algorithm)
	}
	plain, err := w.decrypt(r.AssociatedData, r.Nonce, r.Ciphertext)
	if err != nil {
		return tx, err
	}
	if err := json.Unmarshal(plain, &tx); err != nil {
		return tx, errors.New("bad resource")
	}
	return tx, nil
}

// decrypt opens AEAD_AES_256_GCM ciphertext (base64, tag appended) with the
// APIv3 key.
func (w *WeChat) decrypt(associatedData, nonce, ciphertext string) ([]byte, error) {
	ct, err := base64.StdEncoding.DecodeString(ciphertext)
	if err != nil {
		return nil, errors.New("ciphertext is not base64")
	}
	block, err := aes.NewCipher(w.apiV3Key)
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	if len(nonce) != gcm.NonceSize() {
		return nil, errors.New("bad nonce")
	}
	plain, err := gcm.Open(nil, []byte(nonce), ct, []byte(associatedData))
	if err != nil {
		return nil, errors.New("cannot decrypt resource")
	}
	return plain, nil
}
