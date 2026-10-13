package alertcopy

import (
	"strings"
	"testing"

	"couple-ledger/server/internal/budget"
)

func TestFormatYuan(t *testing.T) {
	cases := map[int64]string{
		0:          "0",
		5:          "0.05",
		50:         "0.50",
		100:        "1",
		123456:     "1,234.56",
		100000:     "1,000",
		166666:     "1,666.66",
		1234567890: "12,345,678.90",
		-66667:     "-666.67",
	}
	for in, want := range cases {
		if got := FormatYuan(in); got != want {
			t.Errorf("FormatYuan(%d) = %q, want %q", in, got, want)
		}
	}
}

func TestRender(t *testing.T) {
	s := budget.Snapshot{
		MonthLimit:     333333,
		MonthSpent:     400000,
		MonthRemaining: -66667,
		Saved:          -400000,
		ToTarget:       2400000,
		DaysLeft:       20,
	}
	got := Render("超出 ¥{超出金额}，剩 ¥{本月剩余}，限额 ¥{限额}，还差 ¥{还差}，{剩余天数} 天，{未知}", s, 2000000)
	want := "超出 ¥666.67，剩 ¥0，限额 ¥3,333.33，还差 ¥24,000，20 天，{未知}"
	if got != want {
		t.Errorf("got  %q\nwant %q", got, want)
	}
}

func TestDefaultsCoverEveryLevel(t *testing.T) {
	for _, level := range budget.AllLevels {
		if len(Defaults[level]) < 5 {
			t.Errorf("level %s has %d defaults, want >= 5", level, len(Defaults[level]))
		}
		if Titles[level] == "" || Fallback[level] == "" {
			t.Errorf("level %s is missing title or fallback", level)
		}
		for _, msg := range Defaults[level] {
			if len([]rune(msg)) > 200 {
				t.Errorf("default message too long: %s", msg)
			}
			for _, part := range strings.Split(msg, "{")[1:] {
				ph := "{" + strings.SplitN(part, "}", 2)[0] + "}"
				known := false
				for _, p := range Placeholders {
					known = known || p == ph
				}
				if !known {
					t.Errorf("unknown placeholder %s in %q", ph, msg)
				}
			}
		}
	}
}
