// Package mailer sends plain-text UTF-8 email over SMTP. Port 465 uses
// implicit TLS (Tencent Cloud blocks port 25); other ports use STARTTLS.
package mailer

import (
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"mime"
	"net"
	"net/mail"
	"net/smtp"
	"strconv"
	"strings"
	"time"
)

// Mailer sends one message.
type Mailer interface {
	Send(ctx context.Context, to, subject, body string) error
}

// SMTP is a Mailer that talks to an SMTP server.
type SMTP struct {
	Host     string
	Port     int
	User     string
	Pass     string
	From     string // "name <addr>" or "addr"
	FromName string // display name used when From has none
	Timeout  time.Duration
}

// Send delivers the message.
func (s *SMTP) Send(ctx context.Context, to, subject, body string) error {
	rcpt, err := mail.ParseAddress(to)
	if err != nil || rcpt.Address != to {
		return fmt.Errorf("bad recipient %q", to)
	}
	from, err := mail.ParseAddress(s.From)
	if err != nil {
		return fmt.Errorf("bad SMTP_FROM: %w", err)
	}
	if from.Name == "" {
		from.Name = s.FromName
	}
	msg := Compose(from, rcpt, subject, body, time.Now())

	timeout := s.Timeout
	if timeout == 0 {
		timeout = 30 * time.Second
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	addr := net.JoinHostPort(s.Host, strconv.Itoa(s.Port))
	tlsConf := &tls.Config{ServerName: s.Host, MinVersion: tls.VersionTLS12}
	var conn net.Conn
	if s.Port == 465 {
		conn, err = (&tls.Dialer{Config: tlsConf}).DialContext(ctx, "tcp", addr)
	} else {
		conn, err = (&net.Dialer{}).DialContext(ctx, "tcp", addr)
	}
	if err != nil {
		return err
	}
	deadline, _ := ctx.Deadline()
	conn.SetDeadline(deadline)
	c, err := smtp.NewClient(conn, s.Host)
	if err != nil {
		conn.Close()
		return err
	}
	defer c.Close()
	if s.Port != 465 {
		if ok, _ := c.Extension("STARTTLS"); ok {
			if err := c.StartTLS(tlsConf); err != nil {
				return err
			}
		} else if s.User != "" {
			return errors.New("SMTP server does not offer STARTTLS; refusing to send the password in clear text")
		}
	}
	if s.User != "" {
		if err := c.Auth(smtp.PlainAuth("", s.User, s.Pass, s.Host)); err != nil {
			return err
		}
	}
	if err := c.Mail(from.Address); err != nil {
		return err
	}
	if err := c.Rcpt(rcpt.Address); err != nil {
		return err
	}
	w, err := c.Data()
	if err != nil {
		return err
	}
	if _, err := w.Write(msg); err != nil {
		return err
	}
	if err := w.Close(); err != nil {
		return err
	}
	return c.Quit()
}

// Compose builds the RFC 5322 message with a base64 UTF-8 text body.
func Compose(from, to *mail.Address, subject, body string, now time.Time) []byte {
	var sb strings.Builder
	id := make([]byte, 12)
	rand.Read(id)
	domain := "localhost"
	if _, d, ok := strings.Cut(from.Address, "@"); ok {
		domain = d
	}
	h := func(k, v string) { sb.WriteString(k + ": " + v + "\r\n") }
	h("From", from.String())
	h("To", to.String())
	h("Subject", mime.BEncoding.Encode("UTF-8", subject))
	h("Date", now.Format(time.RFC1123Z))
	h("Message-ID", "<"+hex.EncodeToString(id)+"@"+domain+">")
	h("MIME-Version", "1.0")
	h("Content-Type", "text/plain; charset=UTF-8")
	h("Content-Transfer-Encoding", "base64")
	sb.WriteString("\r\n")
	enc := base64.StdEncoding.EncodeToString([]byte(strings.ReplaceAll(body, "\n", "\r\n")))
	for len(enc) > 76 {
		sb.WriteString(enc[:76] + "\r\n")
		enc = enc[76:]
	}
	sb.WriteString(enc + "\r\n")
	return []byte(sb.String())
}
