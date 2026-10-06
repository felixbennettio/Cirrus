// Package money converts between decimal amount strings ("198.00") and
// integer cents, so prices never pass through floating point.
package money

import (
	"errors"
	"strconv"
	"strings"
)

// ErrInvalid is returned for amounts that are not a non-negative decimal with
// at most two fraction digits.
var ErrInvalid = errors.New("invalid amount")

// Parse turns "198", "198.0" or "198.00" into 19800.
func Parse(s string) (int64, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0, ErrInvalid
	}
	whole, frac, hasDot := strings.Cut(s, ".")
	if whole == "" || len(whole) > 12 || (hasDot && (frac == "" || len(frac) > 2)) {
		return 0, ErrInvalid
	}
	if !digits(whole) || !digits(frac) {
		return 0, ErrInvalid
	}
	for len(frac) < 2 {
		frac += "0"
	}
	w, err := strconv.ParseInt(whole, 10, 64)
	if err != nil {
		return 0, ErrInvalid
	}
	f, _ := strconv.ParseInt(frac, 10, 64)
	return w*100 + f, nil
}

func digits(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

// Format turns 19800 into "198.00".
func Format(cents int64) string {
	sign := ""
	if cents < 0 {
		sign, cents = "-", -cents
	}
	f := strconv.FormatInt(cents%100, 10)
	if len(f) == 1 {
		f = "0" + f
	}
	return sign + strconv.FormatInt(cents/100, 10) + "." + f
}

// Short drops a ".00" fraction for display: 19800 → "198", 3999 → "39.99".
func Short(cents int64) string {
	s := Format(cents)
	return strings.TrimSuffix(s, ".00")
}
