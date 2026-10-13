package ledger

import (
	"crypto/rand"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"regexp"
	"strings"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"

	"couple-ledger/server/internal/alertcopy"
	"couple-ledger/server/internal/budget"
)

const householdCapacity = 2

var inviteCodeRegex = regexp.MustCompile(`^\d{6}$`)

func (l *ledger) createHousehold(e *core.RequestEvent) error {
	var body struct {
		Name string `json:"name"`
	}
	if err := e.BindBody(&body); err != nil {
		return e.BadRequestError("请求格式不正确", err)
	}
	name := strings.TrimSpace(body.Name)
	if name == "" {
		name = "我们的小家"
	}
	if len([]rune(name)) > 30 {
		return e.BadRequestError("家庭名称最多 30 个字", nil)
	}

	l.mu.Lock()
	defer l.mu.Unlock()

	var household *core.Record
	err := e.App.RunInTransaction(func(tx core.App) error {
		user, err := tx.FindRecordById("users", e.Auth.Id)
		if err != nil {
			return err
		}
		if user.GetString("household") != "" {
			return errAlreadyInHousehold
		}

		col, err := tx.FindCollectionByNameOrId("households")
		if err != nil {
			return err
		}
		code, err := uniqueInviteCode(tx)
		if err != nil {
			return err
		}
		household = core.NewRecord(col)
		household.Set("name", name)
		household.Set("invite_code", code)
		household.Set("created_by", user.Id)
		if err := tx.Save(household); err != nil {
			return err
		}

		user.Set("household", household.Id)
		if err := tx.Save(user); err != nil {
			return err
		}

		return seedAlertMessages(tx, household.Id)
	})
	if errors.Is(err, errAlreadyInHousehold) {
		return e.BadRequestError(err.Error(), nil)
	}
	if err != nil {
		return e.InternalServerError("创建家庭失败", err)
	}

	return e.JSON(http.StatusOK, household)
}

func (l *ledger) joinHousehold(e *core.RequestEvent) error {
	var body struct {
		Code string `json:"code"`
	}
	if err := e.BindBody(&body); err != nil {
		return e.BadRequestError("请求格式不正确", err)
	}
	code := strings.TrimSpace(body.Code)
	if !inviteCodeRegex.MatchString(code) {
		return e.BadRequestError("邀请码是 6 位数字", nil)
	}

	l.mu.Lock()
	defer l.mu.Unlock()

	var household *core.Record
	err := e.App.RunInTransaction(func(tx core.App) error {
		user, err := tx.FindRecordById("users", e.Auth.Id)
		if err != nil {
			return err
		}
		if user.GetString("household") != "" {
			return errAlreadyInHousehold
		}

		household, err = tx.FindFirstRecordByData("households", "invite_code", code)
		if err != nil {
			return errInvalidInvite
		}
		members, err := tx.CountRecords("users", dbx.HashExp{"household": household.Id})
		if err != nil {
			return err
		}
		if members >= householdCapacity {
			return errHouseholdFull
		}

		user.Set("household", household.Id)
		return tx.Save(user)
	})
	switch {
	case errors.Is(err, errAlreadyInHousehold), errors.Is(err, errHouseholdFull):
		return e.BadRequestError(err.Error(), nil)
	case errors.Is(err, errInvalidInvite):
		return e.NotFoundError(err.Error(), nil)
	case err != nil:
		return e.InternalServerError("加入家庭失败", err)
	}

	return e.JSON(http.StatusOK, household)
}

var (
	errAlreadyInHousehold = errors.New("你已经加入了一个家庭")
	errInvalidInvite      = errors.New("邀请码不存在，请核对一下")
	errHouseholdFull      = errors.New("这个家庭已经满员啦")
)

func uniqueInviteCode(app core.App) (string, error) {
	for range 20 {
		n, err := rand.Int(rand.Reader, big.NewInt(1_000_000))
		if err != nil {
			return "", err
		}
		code := fmt.Sprintf("%06d", n.Int64())
		exists, err := app.CountRecords("households", dbx.HashExp{"invite_code": code})
		if err != nil {
			return "", err
		}
		if exists == 0 {
			return code, nil
		}
	}
	return "", errors.New("could not generate a unique invite code")
}

func seedAlertMessages(app core.App, householdId string) error {
	col, err := app.FindCollectionByNameOrId("alert_messages")
	if err != nil {
		return err
	}
	for _, level := range budget.AllLevels {
		for _, text := range alertcopy.Defaults[level] {
			r := core.NewRecord(col)
			r.Set("household", householdId)
			r.Set("level", level)
			r.Set("text", text)
			r.Set("is_default", true)
			r.Set("enabled", true)
			if err := app.Save(r); err != nil {
				return err
			}
		}
	}
	return nil
}

func (l *ledger) limitSignups(e *core.RecordRequestEvent) error {
	if e.HasSuperuserAuth() {
		return e.Next()
	}
	total, err := e.App.CountRecords("users")
	if err != nil {
		return err
	}
	if total >= int64(l.cfg.MaxUsers) {
		return e.ForbiddenError("这台服务器只供我们两个人使用，已经满员啦", nil)
	}
	return e.Next()
}
