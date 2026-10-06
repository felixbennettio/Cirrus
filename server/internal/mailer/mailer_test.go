package mailer

import (
	"bytes"
	"context"
	"encoding/base64"
	"io"
	"mime"
	"net/mail"
	"strings"
	"testing"
	"time"
)

func TestCompose(t *testing.T) {
	from := &mail.Address{Name: "卷云 Cirrus", Address: "noreply@example.com"}
	to := &mail.Address{Address: "buyer@example.com"}
	body := "您的许可证：CIRRUS-ABCDE-FGH01-JKMNP-QRSTV\n谢谢"
	raw := Compose(from, to, "您的卷云许可证", body, time.Unix(1767225600, 0))

	m, err := mail.ReadMessage(bytes.NewReader(raw))
	if err != nil {
		t.Fatal(err)
	}
	subj, err := new(mime.WordDecoder).DecodeHeader(m.Header.Get("Subject"))
	if err != nil || subj != "您的卷云许可证" {
		t.Fatalf("subject %q %v", subj, err)
	}
	if !strings.Contains(m.Header.Get("From"), "noreply@example.com") || m.Header.Get("To") != "<buyer@example.com>" {
		t.Fatalf("from/to: %q %q", m.Header.Get("From"), m.Header.Get("To"))
	}
	b64, _ := io.ReadAll(m.Body)
	got, err := base64.StdEncoding.DecodeString(strings.ReplaceAll(string(b64), "\r\n", ""))
	if err != nil || string(got) != strings.ReplaceAll(body, "\n", "\r\n") {
		t.Fatalf("body %q %v", got, err)
	}
	for _, line := range strings.Split(string(raw), "\r\n") {
		if len(line) > 78 {
			t.Fatalf("line too long: %d", len(line))
		}
	}
}

func TestSendRejectsHeaderInjection(t *testing.T) {
	s := &SMTP{Host: "127.0.0.1", Port: 1, From: "a@example.com"}
	err := s.Send(context.Background(), "victim@example.com\r\nBcc: x@example.com", "s", "b")
	if err == nil || !strings.Contains(err.Error(), "bad recipient") {
		t.Fatalf("err = %v", err)
	}
}
