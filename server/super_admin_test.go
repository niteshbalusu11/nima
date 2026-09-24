package main

import (
	"encoding/json"
	"fmt"
	"testing"
	"time"
)

func TestSuperAdminDashboardAccessAndLiveFragments(t *testing.T) {
	h := setup(t)
	memberToken, memberID := enrollTest(t, h)
	admin := adminTest(t, h)
	invite, err := issueSuperAdminInvite(h.db, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	super := redeem(t, h, invite)
	if super.Role != "admin" {
		t.Fatalf("super admin invite created %q role", super.Role)
	}
	s, b := request(t, h.server.URL, "GET", "/me", super.Token, nil)
	mustStatus(t, 200, s, b)
	var p profile
	if err := json.Unmarshal(b, &p); err != nil || !p.SuperAdmin {
		t.Fatalf("super admin permission missing: %s %v", b, err)
	}
	replacement, err := issueInvite(h.db, super.AccountID, time.Hour, false, "")
	if err != nil {
		t.Fatal(err)
	}
	recovered := redeem(t, h, replacement)
	s, b = request(t, h.server.URL, "GET", "/me", recovered.Token, nil)
	mustStatus(t, 200, s, b)
	if err := json.Unmarshal(b, &p); err != nil || !p.SuperAdmin {
		t.Fatalf("replacement session lost permission: %s %v", b, err)
	}
	s, b = request(t, h.server.URL, "POST", "/enroll", "", map[string]string{"token": invite.Token})
	mustStatus(t, 401, s, b)

	videoID := "11111111-1111-1111-1111-111111111111"
	s, b = request(t, h.server.URL, "PUT", "/captures/"+videoID, memberToken, map[string]string{"kind": "video"})
	mustStatus(t, 200, s, b)
	for sequence := 0; sequence <= 8; sequence++ {
		data := []byte(fmt.Sprintf("fragment %d", sequence))
		kind := "media"
		if sequence == 0 {
			kind = "init"
		}
		s, b = request(t, h.server.URL, "POST", "/captures/"+videoID+"/objects/reserve", memberToken, makeObject(data, kind, sequence))
		mustStatus(t, 200, s, b)
		var key string
		if err := h.db.QueryRow("SELECT object_key FROM objects WHERE capture_id=? AND sequence=?", videoID, sequence).Scan(&key); err != nil {
			t.Fatal(err)
		}
		h.store.Lock()
		h.store.data[key] = data
		h.store.Unlock()
		s, b = request(t, h.server.URL, "POST", "/captures/"+videoID+"/objects/ack", memberToken, map[string]int{"sequence": sequence})
		mustStatus(t, 200, s, b)
	}

	for token, want := range map[string]int{"": 401, memberToken: 403, admin.Token: 403} {
		for _, path := range []string{"/super-admin/captures", "/super-admin/captures/" + videoID} {
			s, b = request(t, h.server.URL, "GET", path, token, nil)
			mustStatus(t, want, s, b)
		}
	}
	s, b = request(t, h.server.URL, "GET", "/captures/"+videoID, super.Token, nil)
	mustStatus(t, 404, s, b)
	s, b = request(t, h.server.URL, "DELETE", "/captures/"+videoID, super.Token, nil)
	mustStatus(t, 404, s, b)

	s, b = request(t, h.server.URL, "GET", "/super-admin/captures", super.Token, nil)
	mustStatus(t, 200, s, b)
	var feed struct {
		Captures []struct {
			ID                  string `json:"id"`
			AccountID           string `json:"account_id"`
			AcknowledgedObjects int    `json:"acknowledged_objects"`
		} `json:"captures"`
	}
	if err := json.Unmarshal(b, &feed); err != nil || len(feed.Captures) != 1 || feed.Captures[0].ID != videoID || feed.Captures[0].AccountID != memberID || feed.Captures[0].AcknowledgedObjects != 9 {
		t.Fatalf("wrong super admin feed: %s %v", b, err)
	}
	s, b = request(t, h.server.URL, "GET", "/super-admin/captures/"+videoID+"?tail=1", super.Token, nil)
	mustStatus(t, 200, s, b)
	var detail struct {
		Objects []object `json:"objects"`
	}
	if err := json.Unmarshal(b, &detail); err != nil || len(detail.Objects) != 7 || detail.Objects[0].Sequence != 0 || detail.Objects[1].Sequence != 3 || detail.Objects[6].Sequence != 8 {
		t.Fatalf("wrong live tail: %s %v", b, err)
	}
	for _, part := range detail.Objects {
		if !part.Acknowledged || part.URL == "" {
			t.Fatalf("unavailable fragment %d", part.Sequence)
		}
	}
	s, b = request(t, h.server.URL, "GET", "/super-admin/captures/"+videoID+"?after=8", super.Token, nil)
	mustStatus(t, 200, s, b)
	if err := json.Unmarshal(b, &detail); err != nil || len(detail.Objects) != 0 {
		t.Fatalf("cursor repeated fragments: %s %v", b, err)
	}
	if _, err := h.db.Exec("UPDATE accounts SET role='member' WHERE id=?", super.AccountID); err != nil {
		t.Fatal(err)
	}
	s, b = request(t, h.server.URL, "GET", "/super-admin/captures", super.Token, nil)
	mustStatus(t, 403, s, b)
	if _, err := h.db.Exec("UPDATE accounts SET role='admin' WHERE id=?", super.AccountID); err != nil {
		t.Fatal(err)
	}

	if _, err := h.db.Exec("UPDATE accounts SET active=0 WHERE id=?", super.AccountID); err != nil {
		t.Fatal(err)
	}
	s, b = request(t, h.server.URL, "GET", "/super-admin/captures", super.Token, nil)
	mustStatus(t, 401, s, b)
}
