// Package pay holds the payment providers. A provider turns an order into
// instructions for the buyer (the "pay" object of POST /api/v1/orders).
//
// Two providers exist: Static (the merchant's static collection QR code,
// confirmed by hand in /admin) and Alipay (Face-to-Face 当面付 or website
// payment 电脑网站支付, confirmed by Alipay's notification). WeChat Pay's API can be added later as another
// Provider.
package pay

import (
	"context"
	"os"
	"path/filepath"
	"time"
)

// Pay types: static_qr and qr are in docs/licensing.md; redirect is Alipay
// website payment.
const (
	TypeStaticQR = "static_qr"
	TypeQR       = "qr"
	TypeRedirect = "redirect"
)

// Order is what a provider needs to start a payment.
type Order struct {
	No          string
	Subject     string
	AmountCents int64
	ReturnURL   string // redirect: where the cashier sends the buyer back
	Mobile      bool   // redirect: the buyer is on a phone
}

// Info tells the buyer how to pay.
type Info struct {
	Type    string // TypeStaticQR, TypeQR or TypeRedirect
	QRImage string // static_qr: URL path of the collection QR image
	QRText  string // qr: text to encode as a QR code (https://qr.alipay.com/…)
	URL     string // redirect: the cashier URL
}

// Provider starts payments for one payment method.
type Provider interface {
	// Name is stored with the order: "manual" or "alipay_f2f".
	Name() string
	// Method is the buyer-facing method: "alipay" or "wechat".
	Method() string
	// TTL is how long an unpaid order stays open.
	TTL() time.Duration
	// Available reports whether the provider can take orders right now.
	Available() bool
	// Create starts the payment.
	Create(ctx context.Context, o Order) (Info, error)
}

// Static is manual payment through a static collection QR code that the
// operator drops into DATA_DIR/pay/<method>.png.
type Static struct {
	method string
	file   string
}

// NewStatic returns the static QR provider for method ("alipay" or "wechat").
func NewStatic(method, dataDir string) *Static {
	return &Static{method: method, file: filepath.Join(dataDir, "pay", method+".png")}
}

// Name implements Provider.
func (s *Static) Name() string { return "manual" }

// Method implements Provider.
func (s *Static) Method() string { return s.method }

// TTL implements Provider: manual orders stay open for 24 hours.
func (s *Static) TTL() time.Duration { return 24 * time.Hour }

// File is the path of the QR image on disk.
func (s *Static) File() string { return s.file }

// ImageURL is where the QR image is served.
func (s *Static) ImageURL() string { return "/static/pay/" + s.method + ".png" }

// Available reports whether the QR image exists.
func (s *Static) Available() bool {
	st, err := os.Stat(s.file)
	return err == nil && st.Mode().IsRegular() && st.Size() > 0
}

// Create implements Provider.
func (s *Static) Create(_ context.Context, _ Order) (Info, error) {
	return Info{Type: TypeStaticQR, QRImage: s.ImageURL()}, nil
}
