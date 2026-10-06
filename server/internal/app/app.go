// Package app is the HTTP side of the licence server: the JSON API from
// docs/licensing.md, the sales website and the admin pages.
package app

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"html/template"
	"log/slog"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"cirrus/server/internal/config"
	"cirrus/server/internal/license"
	"cirrus/server/internal/mailer"
	"cirrus/server/internal/pay"
	"cirrus/server/internal/ratelimit"
	"cirrus/server/internal/store"
)

// Options are the dependencies of the App.
type Options struct {
	Config *config.Config
	Store  *store.Store
	Key    ed25519.PrivateKey
	Mailer mailer.Mailer // nil: no email delivery
	Alipay *pay.Alipay   // nil: Alipay Face-to-Face is off
	Logger *slog.Logger
	Now    func() time.Time
}

// App serves everything.
type App struct {
	cfg    *config.Config
	st     *store.Store
	key    ed25519.PrivateKey
	pubB64 string
	mail   mailer.Mailer
	alipay *pay.Alipay
	static map[string]*pay.Static
	log    *slog.Logger
	now    func() time.Time

	// Per-IP limits for POST APIs; stricter for orders, reset and resend.
	apiLimit, orderLimit, resetLimit, resendLimit *ratelimit.Limiter
	// Per-email limit for resend, and failed admin logins per IP.
	emailLimit, authLimit *ratelimit.Limiter

	pages    map[string]*template.Template
	assetVer string
	handler  http.Handler
	bg       sync.WaitGroup
}

// Self-service device reset is allowed once per this period.
const resetCooldown = 30 * 24 * time.Hour

// New wires the App.
func New(o Options) (*App, error) {
	if o.Config == nil || o.Store == nil || o.Key == nil {
		return nil, errors.New("app: config, store and key are required")
	}
	if o.Logger == nil {
		o.Logger = slog.Default()
	}
	if o.Now == nil {
		o.Now = time.Now
	}
	const maxKeys = 10000
	a := &App{
		cfg:    o.Config,
		st:     o.Store,
		key:    o.Key,
		pubB64: license.PublicKeyBase64(o.Key),
		mail:   o.Mailer,
		alipay: o.Alipay,
		static: map[string]*pay.Static{
			"alipay": pay.NewStatic("alipay", o.Config.DataDir),
			"wechat": pay.NewStatic("wechat", o.Config.DataDir),
		},
		log:         o.Logger,
		now:         o.Now,
		apiLimit:    ratelimit.New(2*time.Second, 30, maxKeys),
		orderLimit:  ratelimit.New(2*time.Minute, 6, maxKeys),
		resetLimit:  ratelimit.New(10*time.Minute, 5, maxKeys),
		resendLimit: ratelimit.New(10*time.Minute, 3, maxKeys),
		emailLimit:  ratelimit.New(15*time.Minute, 1, maxKeys),
		authLimit:   ratelimit.New(3*time.Minute, 10, maxKeys),
	}
	if err := a.loadTemplates(); err != nil {
		return nil, err
	}
	a.handler = a.middleware(a.routes())
	return a, nil
}

// Handler is the root HTTP handler.
func (a *App) Handler() http.Handler { return a.handler }

// PublicKey is the standard base64 Ed25519 public key.
func (a *App) PublicKey() string { return a.pubB64 }

func (a *App) limiters() []*ratelimit.Limiter {
	return []*ratelimit.Limiter{a.apiLimit, a.orderLimit, a.resetLimit, a.resendLimit, a.emailLimit, a.authLimit}
}

// SetLimiterClock makes the rate limiters use now (for tests).
func (a *App) SetLimiterClock(now func() time.Time) {
	for _, l := range a.limiters() {
		l.SetClock(now)
	}
}

func (a *App) routes() *http.ServeMux {
	m := http.NewServeMux()
	m.HandleFunc("GET /healthz", a.healthz)

	m.HandleFunc("GET /api/v1/pubkey", a.apiPubkey)
	m.Handle("POST /api/v1/activate", a.limit(a.apiLimit, a.apiActivate))
	m.Handle("POST /api/v1/deactivate", a.limit(a.apiLimit, a.apiDeactivate))
	m.Handle("POST /api/v1/validate", a.limit(a.apiLimit, a.apiValidate))
	m.Handle("POST /api/v1/reset", a.limit(a.resetLimit, a.apiReset))
	m.Handle("POST /api/v1/resend", a.limit(a.resendLimit, a.apiResend))
	m.Handle("POST /api/v1/orders", a.limit(a.orderLimit, a.apiCreateOrder))
	m.HandleFunc("GET /api/v1/orders/{order_no}", a.apiGetOrder)
	m.HandleFunc("GET /api/v1/orders/{order_no}/qr.png", a.apiOrderQR)
	m.HandleFunc("/api/", a.apiNotFound)

	m.HandleFunc("POST /pay/alipay/notify", a.alipayNotify)

	m.HandleFunc("GET /static/pay/{file}", a.payImage)
	m.Handle("GET /static/", a.staticHandler())
	m.HandleFunc("GET /favicon.ico", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, a.asset("favicon.svg"), http.StatusMovedPermanently)
	})
	m.HandleFunc("GET /robots.txt", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.Write([]byte("User-agent: *\nDisallow: /admin\nDisallow: /api/\n"))
	})

	m.HandleFunc("GET /{$}", a.pageHandler("index"))
	m.HandleFunc("GET /buy", a.buyPage)
	m.HandleFunc("GET /license", a.pageHandler("license"))
	m.HandleFunc("GET /privacy", a.pageHandler("privacy"))
	m.HandleFunc("GET /terms", a.pageHandler("terms"))
	m.HandleFunc("GET /support", a.pageHandler("support"))

	m.HandleFunc("GET /admin", a.admin(a.adminOrders))
	m.HandleFunc("GET /admin/licenses", a.admin(a.adminLicenses))
	m.HandleFunc("GET /admin/licenses/{id}", a.admin(a.adminLicense))
	m.HandleFunc("POST /admin/orders/{no}/confirm", a.admin(a.adminConfirm))
	m.HandleFunc("POST /admin/orders/{no}/cancel", a.admin(a.adminCancel))
	m.HandleFunc("POST /admin/licenses/{id}/{action}", a.admin(a.adminLicenseAction))
	m.HandleFunc("POST /admin/licenses/{id}/devices/{device}/remove", a.admin(a.adminRemoveDevice))
	m.HandleFunc("POST /admin/issue", a.admin(a.adminIssue))

	m.HandleFunc("/", a.notFound)
	return m
}

func (a *App) healthz(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	if err := a.st.Ping(ctx); err != nil {
		http.Error(w, "database unavailable", http.StatusServiceUnavailable)
		return
	}
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Write([]byte("ok\n"))
}

type ctxKey int

const ipKey ctxKey = 0

// clientIP is the address the request came from. With TRUST_PROXY, and only
// when the direct peer is a loopback or private address (the reverse
// proxy), X-Real-IP and then the last X-Forwarded-For entry are used.
func (a *App) clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	peer := net.ParseIP(host)
	if !a.cfg.TrustProxy || peer == nil || !(peer.IsLoopback() || peer.IsPrivate()) {
		return host
	}
	if v := strings.TrimSpace(r.Header.Get("X-Real-IP")); net.ParseIP(v) != nil {
		return v
	}
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		parts := strings.Split(xff, ",")
		for i := len(parts) - 1; i >= 0; i-- {
			if v := strings.TrimSpace(parts[i]); net.ParseIP(v) != nil {
				return v
			}
		}
	}
	return host
}

func ipFrom(r *http.Request) string {
	if v, ok := r.Context().Value(ipKey).(string); ok {
		return v
	}
	return ""
}

type statusWriter struct {
	http.ResponseWriter
	status int
	wrote  bool
}

func (s *statusWriter) WriteHeader(code int) {
	if !s.wrote {
		s.status, s.wrote = code, true
	}
	s.ResponseWriter.WriteHeader(code)
}

func (s *statusWriter) Write(b []byte) (int, error) {
	if !s.wrote {
		s.status, s.wrote = http.StatusOK, true
	}
	return s.ResponseWriter.Write(b)
}

const csp = "default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; connect-src 'self'; " +
	"object-src 'none'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'"

func (a *App) middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		ip := a.clientIP(r)
		r = r.WithContext(context.WithValue(r.Context(), ipKey, ip))
		sw := &statusWriter{ResponseWriter: w, status: http.StatusOK}
		h := sw.Header()
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Referrer-Policy", "same-origin")
		h.Set("Content-Security-Policy", csp)
		defer func() {
			if rec := recover(); rec != nil {
				if rec == http.ErrAbortHandler {
					panic(rec)
				}
				a.log.Error("panic", "path", r.URL.Path, "err", rec)
				if !sw.wrote {
					http.Error(sw, "internal error", http.StatusInternalServerError)
				}
			}
			// The path only: query strings can carry order tokens.
			if r.URL.Path != "/healthz" && !strings.HasPrefix(r.URL.Path, "/static/") {
				a.log.Info("http", "method", r.Method, "path", r.URL.Path, "status", sw.status,
					"ms", time.Since(start).Milliseconds(), "ip", ip)
			}
		}()
		next.ServeHTTP(sw, r)
	})
}

// limit applies a per-IP rate limit.
func (a *App) limit(l *ratelimit.Limiter, h http.HandlerFunc) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if ok, wait := l.Allow(ipFrom(r)); !ok {
			secs := int(wait/time.Second) + 1
			w.Header().Set("Retry-After", itoa(secs))
			writeError(w, http.StatusTooManyRequests, "rate_limited", "请求太频繁，请稍后再试", nil)
			return
		}
		h(w, r)
	})
}

// Run does periodic housekeeping until ctx is done.
func (a *App) Run(ctx context.Context) {
	a.housekeeping(ctx)
	t := time.NewTicker(time.Minute)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			a.housekeeping(ctx)
		}
	}
}

func (a *App) housekeeping(ctx context.Context) {
	for _, l := range a.limiters() {
		l.Sweep()
	}
	now := a.now()
	if n, err := a.st.ExpireOrders(ctx, now); err != nil {
		a.log.Error("expire orders", "err", err)
	} else if n > 0 {
		a.log.Info("orders expired", "count", n)
	}
	// IP addresses in the audit log are kept for 180 days; unpaid orders
	// (an email address and nothing else) for 90 days.
	if _, err := a.st.ScrubIPs(ctx, now.Add(-180*24*time.Hour)); err != nil {
		a.log.Error("scrub ips", "err", err)
	}
	if _, err := a.st.PurgeUnpaidOrders(ctx, now.Add(-90*24*time.Hour)); err != nil {
		a.log.Error("purge orders", "err", err)
	}
}

// Wait blocks until background work (emails) has finished.
func (a *App) Wait() { a.bg.Wait() }

func (a *App) event(ctx context.Context, kind, licenseID, orderNo, ip, detail string) {
	if err := a.st.Log(ctx, store.Event{At: a.now(), Kind: kind, LicenseID: licenseID, OrderNo: orderNo, IP: ip, Detail: detail}); err != nil {
		a.log.Error("audit log", "err", err)
	}
}

func randHex(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}
