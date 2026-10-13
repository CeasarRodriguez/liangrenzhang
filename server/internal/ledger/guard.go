package ledger

import (
	"math"
	"net/url"
	"regexp"
	"strings"
	"time"

	"github.com/pocketbase/dbx"
	validation "github.com/pocketbase/ozzo-validation/v4"
	"github.com/pocketbase/pocketbase/core"

	"couple-ledger/server/internal/budget"
)

// PocketBase does not apply the related collection's API rules when a
// client filter/sort traverses a relation, so a partner could otherwise
// infer private notes with e.g. filter=entry_details_via_entry.note~'x'.
// Client-supplied expressions must never mention the private collection
// or use @collection joins.
func forbiddenExpr(expr string) bool {
	check := func(s string) bool {
		s = strings.ToLower(s)
		return strings.Contains(s, "entry_details") || strings.Contains(s, "@collection")
	}
	if check(expr) {
		return true
	}
	if decoded, err := url.QueryUnescape(expr); err == nil && check(decoded) {
		return true
	}
	return false
}

const forbiddenMsg = "查询条件里不能引用私密数据"

func privacyGuard(e *core.RequestEvent) error {
	if !strings.HasPrefix(e.Request.URL.Path, "/api/") || e.HasSuperuserAuth() {
		return e.Next()
	}
	q := e.Request.URL.Query()
	for _, key := range []string{"filter", "sort", "expand"} {
		for _, v := range q[key] {
			if forbiddenExpr(v) {
				return e.ForbiddenError(forbiddenMsg, nil)
			}
		}
	}
	return e.Next()
}

func guardSubscriptions(e *core.RealtimeSubscribeRequestEvent) error {
	if e.HasSuperuserAuth() {
		return e.Next()
	}
	for _, sub := range e.Subscriptions {
		if i := strings.IndexByte(sub, '?'); i >= 0 && forbiddenExpr(sub[i+1:]) {
			return e.ForbiddenError(forbiddenMsg, nil)
		}
	}
	return e.Next()
}

func validateEntry(e *core.RecordEvent) error {
	date := e.Record.GetString("occurred_on")
	if _, err := time.Parse(time.DateOnly, date); err != nil {
		return validation.Errors{"occurred_on": validation.NewError("invalid_date", "日期不正确")}
	}
	return e.Next()
}

const maxGoalMonths = 36

func validateGoal(e *core.RecordEvent) error {
	start, err1 := budget.ParseMonth(e.Record.GetString("start_month"))
	end, err2 := budget.ParseMonth(e.Record.GetString("end_month"))
	if err1 != nil || err2 != nil {
		return validation.Errors{"start_month": validation.NewError("invalid_month", "月份格式不正确")}
	}
	if end.Index() < start.Index() {
		return validation.Errors{"end_month": validation.NewError("end_before_start", "结束月份不能早于开始月份")}
	}
	if end.Index()-start.Index()+1 > maxGoalMonths {
		return validation.Errors{"end_month": validation.NewError("too_long", "计划期最长 36 个月")}
	}

	if err := validateIncomePlan(e.Record); err != nil {
		return err
	}

	overlap, err := e.App.CountRecords("goals",
		dbx.HashExp{"household": e.Record.GetString("household")},
		dbx.Not(dbx.HashExp{"id": e.Record.Id}),
		dbx.NewExp("start_month <= {:end} AND end_month >= {:start}", dbx.Params{
			"start": start.String(),
			"end":   end.String(),
		}),
	)
	if err != nil {
		return err
	}
	if overlap > 0 {
		return validation.Errors{"start_month": validation.NewError("overlap", "和已有的攒钱计划时间重叠了")}
	}

	return e.Next()
}

var recordIdPattern = regexp.MustCompile(`^[a-z0-9]{15}$`)

// validateIncomePlan accepts {"<user id>" | "*": cents} with at most one
// key per member plus "*".
func validateIncomePlan(r *core.Record) error {
	invalid := validation.Errors{"income_plan": validation.NewError("invalid_income_plan", "预期收入格式不正确")}
	var plan map[string]float64
	if err := r.UnmarshalJSONField("income_plan", &plan); err != nil {
		return invalid
	}
	if len(plan) > 3 {
		return invalid
	}
	for k, v := range plan {
		if k != budget.OthersKey && !recordIdPattern.MatchString(k) {
			return invalid
		}
		if v < 0 || v > 1e10 || v != math.Trunc(v) {
			return invalid
		}
	}
	return nil
}

// dedupeDeviceToken lets a push token move to whoever logged in last on
// that phone instead of failing the unique index.
func dedupeDeviceToken(e *core.RecordEvent) error {
	token := e.Record.GetString("push_token")
	if token != "" {
		dupes, err := e.App.FindAllRecords("devices",
			dbx.HashExp{"push_token": token},
			dbx.Not(dbx.HashExp{"id": e.Record.Id}),
		)
		if err != nil {
			return err
		}
		for _, d := range dupes {
			if err := e.App.Delete(d); err != nil {
				return err
			}
		}
	}
	return e.Next()
}
