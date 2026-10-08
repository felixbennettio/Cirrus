package app

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/mail"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"cirrus/server/internal/license"
	"cirrus/server/internal/store"
)

func itoa(n int) string { return strconv.Itoa(n) }

// writeJSON writes v as JSON. Responses are not cached unless the handler
// set Cache-Control first.
func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	if w.Header().Get("Cache-Control") == "" {
		w.Header().Set("Cache-Control", "no-store")
	}
	w.WriteHeader(status)
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(false)
	enc.Encode(v)
}

// writeError writes {"error": code, "message": msg} plus any extra fields.
func writeError(w http.ResponseWriter, status int, code, msg string, extra map[string]any) {
	body := map[string]any{"error": code, "message": msg}
	for k, v := range extra {
		body[k] = v
	}
	writeJSON(w, status, body)
}

func (a *App) internalError(w http.ResponseWriter, r *http.Request, err error) {
	a.log.Error("request failed", "path", r.URL.Path, "err", err)
	writeError(w, http.StatusInternalServerError, "internal", tr(r, "api.internal"), nil)
}

func decodeJSON(w http.ResponseWriter, r *http.Request, dst any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, 16<<10)
	if err := json.NewDecoder(r.Body).Decode(dst); err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", tr(r, "api.bad_request"), nil)
		return false
	}
	return true
}

// clean trims, drops control characters and caps the length in runes.
func clean(s string, max int) string {
	s = strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return -1
		}
		return r
	}, strings.TrimSpace(s))
	if utf8.RuneCountInString(s) > max {
		s = string([]rune(s)[:max])
	}
	return s
}

func validEmail(s string) bool {
	if s == "" || len(s) > 254 {
		return false
	}
	addr, err := mail.ParseAddress(s)
	if err != nil || addr.Address != s {
		return false
	}
	local, domain, ok := strings.Cut(s, "@")
	return ok && local != "" && strings.Contains(domain, ".") &&
		!strings.HasPrefix(domain, ".") && !strings.HasSuffix(domain, ".") && !strings.ContainsAny(s, " \"\\")
}

var platformNames = map[string]string{"windows": "Windows", "macos": "macOS", "linux": "Linux", "android": "Android"}

func platformName(p string) string {
	if n, ok := platformNames[p]; ok {
		return n
	}
	return p
}

func (a *App) apiPubkey(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"ed25519": a.pubB64})
}

func (a *App) apiNotFound(w http.ResponseWriter, r *http.Request) {
	writeError(w, http.StatusNotFound, "not_found", tr(r, "api.not_found"), nil)
}

type licenseReq struct {
	LicenseKey string `json:"license_key"`
	DeviceID   string `json:"device_id"`
	DeviceName string `json:"device_name"`
	Platform   string `json:"platform"`
	AppVersion string `json:"app_version"`
	Email      string `json:"email"`
}

func invalidKey(w http.ResponseWriter, r *http.Request) {
	writeError(w, http.StatusNotFound, "invalid_key", tr(r, "api.invalid_key"), nil)
}

func revoked(w http.ResponseWriter, r *http.Request) {
	writeError(w, http.StatusGone, "revoked", tr(r, "api.revoked"), nil)
}

// readKeyDevice decodes the request and normalises the key and device id.
// It writes the error response and returns false when they are unusable.
func readKeyDevice(w http.ResponseWriter, r *http.Request, needDevice bool) (licenseReq, string, bool) {
	var req licenseReq
	if !decodeJSON(w, r, &req) {
		return req, "", false
	}
	key, err := license.NormalizeKey(req.LicenseKey)
	if err != nil {
		invalidKey(w, r)
		return req, "", false
	}
	req.DeviceID = strings.TrimSpace(req.DeviceID)
	if needDevice && !license.ValidDeviceID(req.DeviceID) {
		writeError(w, http.StatusBadRequest, "bad_request", tr(r, "api.bad_device"), nil)
		return req, "", false
	}
	return req, key, true
}

type deviceJSON struct {
	Name        string `json:"name"`
	ActivatedAt string `json:"activated_at"`
}

func rfc3339(t time.Time) string { return t.UTC().Format(time.RFC3339) }

func (a *App) apiActivate(w http.ResponseWriter, r *http.Request) {
	req, key, ok := readKeyDevice(w, r, true)
	if !ok {
		return
	}
	in := store.ActivateInput{
		DeviceID:   req.DeviceID,
		DeviceName: clean(req.DeviceName, 100),
		Platform:   strings.ToLower(clean(req.Platform, 20)),
		AppVersion: clean(req.AppVersion, 40),
	}
	now := a.now()
	ip := ipFrom(r)
	l, err := a.st.Activate(r.Context(), key, in, now)
	var limit *store.LimitError
	switch {
	case errors.Is(err, store.ErrNotFound):
		invalidKey(w, r)
		return
	case errors.Is(err, store.ErrRevoked):
		revoked(w, r)
		return
	case errors.Is(err, store.ErrWrongPlatform):
		writeError(w, http.StatusForbidden, "wrong_platform",
			tr(r, "api.wrong_platform", "licensed", platformName(l.Platform), "requested", platformName(in.Platform)),
			map[string]any{"platform": l.Platform})
		return
	case errors.As(err, &limit):
		devs := make([]deviceJSON, 0, len(limit.Devices))
		for _, d := range limit.Devices {
			devs = append(devs, deviceJSON{Name: d.DeviceName, ActivatedAt: rfc3339(d.ActivatedAt)})
		}
		a.event(r.Context(), "activate_limit", l.ID, "", ip, in.DeviceName)
		writeError(w, http.StatusConflict, "activation_limit", trN(r, "api.activation_limit", len(devs)),
			map[string]any{"devices": devs})
		return
	case err != nil:
		a.internalError(w, r, err)
		return
	}
	tok, err := license.Sign(a.key, license.Claims{
		V: 1, Lic: l.ID, Product: l.Product, Platform: l.Platform, Device: in.DeviceID,
		Iat: now.Unix(), Owner: license.MaskEmail(l.Email),
	})
	if err != nil {
		a.internalError(w, r, err)
		return
	}
	a.event(r.Context(), "activate", l.ID, "", ip, fmt.Sprintf("%s · %s · %s", in.DeviceName, in.Platform, in.AppVersion))
	writeJSON(w, http.StatusOK, map[string]any{
		"activation": tok,
		"license": map[string]any{
			"product": l.Product, "platform": l.Platform, "max_devices": l.MaxDevices, "devices_used": l.DevicesUsed,
		},
	})
}

func (a *App) apiDeactivate(w http.ResponseWriter, r *http.Request) {
	req, key, ok := readKeyDevice(w, r, false)
	if !ok {
		return
	}
	l, removed, err := a.st.Deactivate(r.Context(), key, req.DeviceID)
	switch {
	case errors.Is(err, store.ErrNotFound):
		invalidKey(w, r)
		return
	case err != nil:
		a.internalError(w, r, err)
		return
	}
	if removed {
		a.event(r.Context(), "deactivate", l.ID, "", ipFrom(r), "")
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (a *App) apiValidate(w http.ResponseWriter, r *http.Request) {
	req, key, ok := readKeyDevice(w, r, false)
	if !ok {
		return
	}
	_, status, err := a.st.Validate(r.Context(), key, req.DeviceID, a.now())
	switch {
	case errors.Is(err, store.ErrNotFound):
		invalidKey(w, r)
		return
	case err != nil:
		a.internalError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": status})
}

func (a *App) apiReset(w http.ResponseWriter, r *http.Request) {
	req, key, ok := readKeyDevice(w, r, false)
	if !ok {
		return
	}
	l, n, err := a.st.SelfReset(r.Context(), key, req.Email, a.now(), resetCooldown)
	var soon *store.TooSoonError
	switch {
	case errors.Is(err, store.ErrNotFound):
		invalidKey(w, r)
		return
	case errors.Is(err, store.ErrEmailMismatch):
		a.event(r.Context(), "reset_mismatch", l.ID, "", ipFrom(r), "")
		writeError(w, http.StatusForbidden, "email_mismatch", tr(r, "api.email_mismatch"), nil)
		return
	case errors.Is(err, store.ErrRevoked):
		revoked(w, r)
		return
	case errors.As(err, &soon):
		days := int((soon.Wait + 24*time.Hour - time.Second) / (24 * time.Hour))
		writeError(w, http.StatusTooManyRequests, "too_soon", trN(r, "api.too_soon", days),
			map[string]any{"retry_after_days": days})
		return
	case err != nil:
		a.internalError(w, r, err)
		return
	}
	a.event(r.Context(), "reset", l.ID, "", ipFrom(r), fmt.Sprintf("released %d", n))
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// apiResend emails every licence key bought with an address. The answer is
// the same whether or not the address has licences.
func (a *App) apiResend(w http.ResponseWriter, r *http.Request) {
	if a.mail == nil {
		writeError(w, http.StatusNotFound, "not_available", tr(r, "api.not_available"), nil)
		return
	}
	var req licenseReq
	if !decodeJSON(w, r, &req) {
		return
	}
	email := store.NormEmail(req.Email)
	if !validEmail(email) {
		writeError(w, http.StatusBadRequest, "invalid_email", tr(r, "api.invalid_email"), nil)
		return
	}
	if ok, _ := a.emailLimit.Allow(email); ok {
		ip := ipFrom(r)
		lang := apiLang(r)
		a.background(func(ctx context.Context) {
			lics, err := a.st.LicensesByEmail(ctx, email)
			if err != nil {
				a.log.Error("resend lookup", "err", err)
				return
			}
			if len(lics) == 0 {
				return
			}
			a.event(ctx, "resend", "", "", ip, license.MaskEmail(email))
			a.sendMail(ctx, email, "", lang, lics)
		})
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}
