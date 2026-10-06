package money

import "testing"

func TestParseFormat(t *testing.T) {
	ok := map[string]int64{"198": 19800, "198.0": 19800, "198.00": 19800, "39.99": 3999, "0.01": 1, " 5.5 ": 550}
	for in, want := range ok {
		got, err := Parse(in)
		if err != nil || got != want {
			t.Errorf("Parse(%q) = %d, %v; want %d", in, got, err, want)
		}
	}
	for _, in := range []string{"", ".5", "5.", "1.234", "-1", "1e3", "abc", "1,00"} {
		if got, err := Parse(in); err == nil {
			t.Errorf("Parse(%q) = %d, want error", in, got)
		}
	}
	fmts := map[int64]string{19800: "198.00", 3999: "39.99", 1: "0.01", 0: "0.00", 105: "1.05"}
	for in, want := range fmts {
		if got := Format(in); got != want {
			t.Errorf("Format(%d) = %q, want %q", in, got, want)
		}
	}
	if Short(19800) != "198" || Short(3999) != "39.99" {
		t.Error("Short")
	}
}
