// Command cirrus-license is the Cirrus licence server and sales website.
// Configuration comes from environment variables; see server/README.md.
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"cirrus/server/internal/app"
	"cirrus/server/internal/config"
	"cirrus/server/internal/license"
	"cirrus/server/internal/mailer"
	"cirrus/server/internal/pay"
	"cirrus/server/internal/store"
)

// version is set at build time with -ldflags "-X main.version=…".
var version = "dev"

func main() {
	log := slog.New(slog.NewTextHandler(os.Stdout, nil))
	slog.SetDefault(log)
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "version", "-version", "--version":
			fmt.Println(version)
			return
		case "pubkey":
			// Print the public key of DATA_DIR/signing.key without starting.
			cfg, err := config.Load(os.Getenv)
			if err != nil {
				fatal(log, "config", err)
			}
			key, _, err := license.LoadOrCreateKey(filepath.Join(cfg.DataDir, "signing.key"))
			if err != nil {
				fatal(log, "signing key", err)
			}
			fmt.Println(license.PublicKeyBase64(key))
			return
		case "backup":
			// Consistent online copy of the database:
			//   cirrus-license backup [file]   (default DATA_DIR/backups/cirrus-<time>.db)
			cfg, err := config.Load(os.Getenv)
			if err != nil {
				fatal(log, "config", err)
			}
			dst := filepath.Join(cfg.DataDir, "backups", "cirrus-"+time.Now().Format("20060102-150405")+".db")
			if len(os.Args) > 2 {
				dst = os.Args[2]
			}
			if err := os.MkdirAll(filepath.Dir(dst), 0o700); err != nil {
				fatal(log, "backup", err)
			}
			st, err := store.Open(filepath.Join(cfg.DataDir, "cirrus.db"))
			if err != nil {
				fatal(log, "database", err)
			}
			defer st.Close()
			if err := st.Backup(context.Background(), dst); err != nil {
				fatal(log, "backup", err)
			}
			fmt.Println(dst)
			return
		default:
			fmt.Fprintln(os.Stderr, "usage: cirrus-license [version | pubkey | backup [file]]")
			os.Exit(2)
		}
	}
	if err := run(log); err != nil {
		fatal(log, "fatal", err)
	}
}

func fatal(log *slog.Logger, msg string, err error) {
	log.Error(msg, "err", err)
	os.Exit(1)
}

func run(log *slog.Logger) error {
	cfg, err := config.Load(os.Getenv)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Join(cfg.DataDir, "pay"), 0o755); err != nil {
		return fmt.Errorf("DATA_DIR %s is not writable (on the host: chown -R 10001:10001 ./data): %w", cfg.DataDir, err)
	}
	probe := filepath.Join(cfg.DataDir, ".write-test")
	if err := os.WriteFile(probe, nil, 0o600); err != nil {
		return fmt.Errorf("DATA_DIR %s is not writable (on the host: chown -R 10001:10001 ./data): %w", cfg.DataDir, err)
	}
	os.Remove(probe)

	key, created, err := license.LoadOrCreateKey(filepath.Join(cfg.DataDir, "signing.key"))
	if err != nil {
		return fmt.Errorf("signing key: %w", err)
	}
	pub := license.PublicKeyBase64(key)
	if created {
		log.Warn("created a new signing key: BACK UP data/signing.key NOW", "path", filepath.Join(cfg.DataDir, "signing.key"))
	}
	log.Info("licence signing key", "ed25519_public_key", pub)

	st, err := store.Open(filepath.Join(cfg.DataDir, "cirrus.db"))
	if err != nil {
		return fmt.Errorf("database: %w", err)
	}
	defer st.Close()

	opts := app.Options{Config: cfg, Store: st, Key: key, Logger: log}
	if cfg.SMTP.Enabled() {
		opts.Mailer = &mailer.SMTP{
			Host: cfg.SMTP.Host, Port: cfg.SMTP.Port, User: cfg.SMTP.User, Pass: cfg.SMTP.Pass,
			From: cfg.SMTP.From, FromName: cfg.SiteName,
		}
	}
	if cfg.Alipay.Enabled() {
		ali, err := pay.NewAlipay(cfg.Alipay.AppID, cfg.Alipay.PrivateKey, cfg.Alipay.PublicKey,
			cfg.Alipay.Gateway, cfg.PublicURL+"/pay/alipay/notify")
		if err != nil {
			return err
		}
		ali.Mode = cfg.Alipay.Mode
		opts.Alipay = ali
	}
	if w := cfg.WeChat; w.Enabled() {
		wx, err := pay.NewWeChat(pay.WeChatConfig{
			MchID: w.MchID, AppID: w.AppID, APIv3Key: w.APIv3Key, CertSerial: w.CertSerial,
			PrivateKey: w.PrivateKey, PublicKey: w.PublicKey, PublicKeyID: w.PublicKeyID,
			Gateway: w.Gateway, NotifyURL: cfg.PublicURL + "/pay/wechat/notify",
		})
		if err != nil {
			return err
		}
		opts.WeChat = wx
	}
	a, err := app.New(opts)
	if err != nil {
		return err
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	go a.Run(ctx)

	srv := &http.Server{
		Addr:              cfg.Listen,
		Handler:           a.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       120 * time.Second,
		MaxHeaderBytes:    64 << 10,
	}
	errc := make(chan error, 1)
	go func() { errc <- srv.ListenAndServe() }()
	log.Info("cirrus-license started", "version", version, "listen", cfg.Listen, "public_url", cfg.PublicURL,
		"data_dir", cfg.DataDir, "pay_methods", cfg.PayMethods, "alipay_api", cfg.Alipay.Enabled(),
		"alipay_mode", cfg.Alipay.Mode, "wechat_api", cfg.WeChat.Enabled(), "oauth_client_id", cfg.OAuth.ClientID,
		"oauth_scope_sync", cfg.OAuth.SyncEnabled(), "smtp", cfg.SMTP.Enabled(), "admin", cfg.AdminPassword != "",
		"trust_proxy", cfg.TrustProxy)

	select {
	case err := <-errc:
		if !errors.Is(err, http.ErrServerClosed) {
			return err
		}
	case <-ctx.Done():
		log.Info("shutting down")
		sctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		srv.Shutdown(sctx)
	}
	a.Wait()
	return nil
}
