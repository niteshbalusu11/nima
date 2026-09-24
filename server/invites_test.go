package main

import (
	"database/sql"
	"encoding/json"
	"testing"
	"time"
)

type enrollment struct {
	Token     string `json:"token"`
	AccountID string `json:"account_id"`
	Role      string `json:"role"`
}

func redeem(t *testing.T, h *testAPI, invite invitation) enrollment {
	t.Helper()
	s, b := request(t, h.server.URL, "POST", "/enroll", "", map[string]string{"token": invite.Token})
	mustStatus(t, 201, s, b)
	var result enrollment
	if err := json.Unmarshal(b, &result); err != nil {
		t.Fatal(err)
	}
	return result
}

func adminTest(t *testing.T, h *testAPI) enrollment {
	t.Helper()
	invite, err := issueInvite(h.db, "", time.Hour, true, "")
	if err != nil {
		t.Fatal(err)
	}
	result := redeem(t, h, invite)
	if result.Role != "admin" {
		t.Fatalf("wrong admin role: %q", result.Role)
	}
	return result
}

func TestAdminInvitesMembersOnly(t *testing.T) {
	h := setup(t)
	admin := adminTest(t, h)
	member, _ := enrollTest(t, h)
	for token, want := range map[string]int{"": 401, member: 403} {
		s, b := request(t, h.server.URL, "POST", "/invites", token, struct{}{})
		mustStatus(t, want, s, b)
	}
	for _, body := range []any{
		map[string]string{"role": "admin"}, map[string]string{"account_id": admin.AccountID},
		map[string]int{"ttl": 900}, map[string]bool{"admin": true},
	} {
		s, b := request(t, h.server.URL, "POST", "/invites", admin.Token, body)
		mustStatus(t, 400, s, b)
	}
	s, b := request(t, h.server.URL, "POST", "/invites", admin.Token, struct{}{})
	mustStatus(t, 201, s, b)
	var invite invitation
	if err := json.Unmarshal(b, &invite); err != nil {
		t.Fatal(err)
	}
	if len(invite.Token) != 43 || time.Until(time.Unix(invite.ExpiresAt, 0)) < 24*time.Hour-5*time.Second {
		t.Fatal("invalid invite token or expiry")
	}
	var hash, role, issuer string
	var target sql.NullString
	if err := h.db.QueryRow("SELECT hash,role,created_by,account_id FROM invites WHERE created_by=?", admin.AccountID).Scan(&hash, &role, &issuer, &target); err != nil {
		t.Fatal(err)
	}
	if hash != digest(invite.Token) || role != "member" || issuer != admin.AccountID || target.Valid {
		t.Fatal("invite must store a hash and create a new member owned by its issuer")
	}
	// An enrollment payload cannot change the role or consume the invite on failure.
	s, b = request(t, h.server.URL, "POST", "/enroll", "", map[string]string{"token": invite.Token, "role": "admin"})
	mustStatus(t, 400, s, b)
	joined := redeem(t, h, invite)
	if joined.Role != "member" || joined.AccountID == admin.AccountID {
		t.Fatal("admin issued a privileged or shared account")
	}
	s, b = request(t, h.server.URL, "POST", "/invites", joined.Token, struct{}{})
	mustStatus(t, 403, s, b)
	s, b = request(t, h.server.URL, "PATCH", "/me", joined.Token, map[string]string{"role": "admin"})
	mustStatus(t, 400, s, b)
	s, b = request(t, h.server.URL, "POST", "/enroll", "", map[string]string{"token": invite.Token})
	mustStatus(t, 401, s, b)
	for _, user := range []enrollment{admin, joined} {
		s, b = request(t, h.server.URL, "GET", "/me", user.Token, nil)
		mustStatus(t, 200, s, b)
		var p profile
		if err := json.Unmarshal(b, &p); err != nil {
			t.Fatal(err)
		}
		if p.Role != user.Role || p.ID != user.AccountID {
			t.Fatal("incorrect profile role")
		}
	}
	// Authorization consults the account rather than a cached client/session role.
	if _, err := h.db.Exec("UPDATE accounts SET role='member' WHERE id=?", admin.AccountID); err != nil {
		t.Fatal(err)
	}
	s, b = request(t, h.server.URL, "POST", "/invites", admin.Token, struct{}{})
	mustStatus(t, 403, s, b)
}

func TestAdminHasNoExtraMediaAccess(t *testing.T) {
	h := setup(t)
	admin := adminTest(t, h)
	member, _ := enrollTest(t, h)
	id := "11111111-1111-1111-1111-111111111111"
	s, b := request(t, h.server.URL, "PUT", "/captures/"+id, member, map[string]string{"kind": "photo"})
	mustStatus(t, 200, s, b)
	for _, path := range []string{"/captures/" + id, "/captures/" + id + "/objects/reserve", "/captures/" + id + "/objects/ack", "/captures/" + id + "/finish"} {
		method := "POST"
		if path == "/captures/"+id {
			method = "GET"
		}
		s, b = request(t, h.server.URL, method, path, admin.Token, struct{}{})
		mustStatus(t, 404, s, b)
	}
}

func TestAdminCLIRulesAndPerAccountRateLimit(t *testing.T) {
	h := setup(t)
	admin := adminTest(t, h)
	if _, err := issueInvite(h.db, admin.AccountID, time.Hour, true, ""); err == nil {
		t.Fatal("--admin must not accept --account")
	}
	if _, err := issueInvite(h.db, "", time.Hour, true, admin.AccountID); err == nil {
		t.Fatal("app issuer must not create admin invites")
	}
	replacement, err := issueInvite(h.db, admin.AccountID, time.Hour, false, "")
	if err != nil {
		t.Fatal(err)
	}
	recovered := redeem(t, h, replacement)
	if recovered.Role != "admin" || recovered.AccountID != admin.AccountID {
		t.Fatal("CLI replacement changed account or role")
	}
	for range 10 {
		s, b := request(t, h.server.URL, "POST", "/invites", admin.Token, struct{}{})
		mustStatus(t, 201, s, b)
	}
	s, b := request(t, h.server.URL, "POST", "/invites", recovered.Token, struct{}{})
	mustStatus(t, 429, s, b)
	other := adminTest(t, h)
	s, b = request(t, h.server.URL, "POST", "/invites", other.Token, struct{}{})
	mustStatus(t, 201, s, b)
}
