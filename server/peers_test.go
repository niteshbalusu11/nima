package main

import (
	"encoding/json"
	"sync"
	"testing"
)

func peerInvitationTest(t *testing.T, h *testAPI, sender string, recipient device) invitation {
	t.Helper()
	s, b := request(t, h.server.URL, "POST", "/peer-invitations", sender, map[string]string{"recipient_account_id": recipient.AccountID, "recipient_device_id": recipient.ID})
	mustStatus(t, 201, s, b)
	var invite invitation
	if err := json.Unmarshal(b, &invite); err != nil {
		t.Fatal(err)
	}
	return invite
}
func approvalListTest(t *testing.T, h *testAPI, token string) []peerApproval {
	t.Helper()
	s, b := request(t, h.server.URL, "GET", "/peer-approvals", token, nil)
	mustStatus(t, 200, s, b)
	var result struct {
		Approvals []peerApproval `json:"approvals"`
	}
	if err := json.Unmarshal(b, &result); err != nil {
		t.Fatal(err)
	}
	if result.Approvals == nil {
		t.Fatal("snapshot must encode an empty array")
	}
	return result.Approvals
}

func TestPeerConsentIsolationConcurrentAcceptanceAndRevocation(t *testing.T) {
	h := setup(t)
	a, ownerA := enrollTest(t, h)
	b, ownerB := enrollTest(t, h)
	c, ownerC := enrollTest(t, h)
	legacy := sessionTest(t, h, ownerA)
	deviceA := registerTest(t, h, a, ownerA, newTestDeviceKeys(t))
	deviceB := registerTest(t, h, b, ownerB, newTestDeviceKeys(t))
	registerTest(t, h, c, ownerC, newTestDeviceKeys(t))
	otherB := sessionTest(t, h, ownerB)
	registerTest(t, h, otherB, ownerB, newTestDeviceKeys(t))
	s, body := request(t, h.server.URL, "GET", "/peer-approvals", legacy, nil)
	mustStatus(t, 409, s, body)
	s, body = request(t, h.server.URL, "POST", "/peer-invitations", legacy, map[string]string{"recipient_account_id": ownerB, "recipient_device_id": deviceB.ID})
	mustStatus(t, 409, s, body)
	s, body = request(t, h.server.URL, "POST", "/peer-invitations", a, map[string]string{"recipient_account_id": ownerC, "recipient_device_id": deviceB.ID})
	mustStatus(t, 404, s, body)
	s, body = request(t, h.server.URL, "POST", "/peer-invitations", a, map[string]string{"recipient_account_id": ownerA, "recipient_device_id": deviceA.ID})
	mustStatus(t, 404, s, body)
	invite := peerInvitationTest(t, h, a, deviceB)
	if len(approvalListTest(t, h, a)) != 0 || len(approvalListTest(t, h, b)) != 0 {
		t.Fatal("approval exists before recipient consent")
	}
	for _, wrong := range []string{a, c, otherB} {
		s, body = request(t, h.server.URL, "POST", "/peer-invitations/accept", wrong, map[string]string{"token": invite.Token})
		mustStatus(t, 404, s, body)
	}
	type result struct {
		status int
		body   []byte
	}
	results := make(chan result, 2)
	var wait sync.WaitGroup
	for range 2 {
		wait.Go(func() {
			s, body := request(t, h.server.URL, "POST", "/peer-invitations/accept", b, map[string]string{"token": invite.Token})
			results <- result{s, body}
		})
	}
	wait.Wait()
	close(results)
	counts := map[int]int{}
	ids := map[string]bool{}
	for r := range results {
		counts[r.status]++
		var p peerApproval
		if err := json.Unmarshal(r.body, &p); err != nil {
			t.Fatal(err)
		}
		ids[p.ID] = true
	}
	if counts[201] != 1 || counts[200] != 1 || len(ids) != 1 || ids[""] {
		t.Fatalf("acceptance race: %v %v", counts, ids)
	}
	var approved peerApproval
	for _, token := range []string{a, b} {
		list := approvalListTest(t, h, token)
		if len(list) != 1 || list[0].Sender != deviceA || list[0].Recipient != deviceB {
			t.Fatalf("wrong participants: %+v", list)
		}
		approved = list[0]
	}
	if len(approvalListTest(t, h, c)) != 0 || len(approvalListTest(t, h, otherB)) != 0 {
		t.Fatal("approval keys leaked to unrelated device")
	}
	s, body = request(t, h.server.URL, "DELETE", "/peer-approvals/"+approved.ID, c, nil)
	mustStatus(t, 404, s, body)
	s, body = request(t, h.server.URL, "POST", "/peer-invitations", a, map[string]string{"recipient_account_id": ownerB, "recipient_device_id": deviceB.ID})
	mustStatus(t, 409, s, body)
	for range 2 {
		s, body = request(t, h.server.URL, "DELETE", "/peer-approvals/"+approved.ID, b, nil)
		mustStatus(t, 200, s, body)
	}
	s, body = request(t, h.server.URL, "POST", "/peer-invitations/accept", b, map[string]string{"token": invite.Token})
	mustStatus(t, 410, s, body)
	if len(approvalListTest(t, h, a)) != 0 || len(approvalListTest(t, h, b)) != 0 {
		t.Fatal("revoked approval still active")
	}
	newInvite := peerInvitationTest(t, h, a, deviceB)
	s, body = request(t, h.server.URL, "POST", "/peer-invitations/accept", b, map[string]string{"token": newInvite.Token})
	mustStatus(t, 201, s, body)
	var renewed peerApproval
	if err := json.Unmarshal(body, &renewed); err != nil || renewed.ID == approved.ID {
		t.Fatal("reactivated old approval", err)
	}
	// Fresh consent cannot make an old consumed token refer to a new approval.
	s, body = request(t, h.server.URL, "POST", "/peer-invitations/accept", b, map[string]string{"token": invite.Token})
	mustStatus(t, 410, s, body)
	s, body = request(t, h.server.URL, "DELETE", "/devices/"+deviceA.ID, a, nil)
	mustStatus(t, 200, s, body)
	if len(approvalListTest(t, h, b)) != 0 {
		t.Fatal("revoked sender still approved")
	}
	s, body = request(t, h.server.URL, "POST", "/peer-invitations/accept", b, map[string]string{"token": newInvite.Token})
	mustStatus(t, 404, s, body)
	// Sharing revocation leaves the account's existing camera API access unchanged.
	s, body = request(t, h.server.URL, "GET", "/me", a, nil)
	mustStatus(t, 200, s, body)
}

func TestPeerInvitationExpiryReplacementAndAccountRevocation(t *testing.T) {
	h := setup(t)
	a, ownerA := enrollTest(t, h)
	b, ownerB := enrollTest(t, h)
	registerTest(t, h, a, ownerA, newTestDeviceKeys(t))
	deviceB := registerTest(t, h, b, ownerB, newTestDeviceKeys(t))
	first := peerInvitationTest(t, h, a, deviceB)
	second := peerInvitationTest(t, h, a, deviceB)
	s, body := request(t, h.server.URL, "POST", "/peer-invitations/accept", b, map[string]string{"token": first.Token})
	mustStatus(t, 404, s, body)
	execTest(t, h.db, "UPDATE peer_invitations SET expires_at=0 WHERE hash=?", digest(second.Token))
	s, body = request(t, h.server.URL, "POST", "/peer-invitations/accept", b, map[string]string{"token": second.Token})
	mustStatus(t, 410, s, body)
	third := peerInvitationTest(t, h, a, deviceB)
	execTest(t, h.db, "UPDATE accounts SET active=0 WHERE id=?", ownerA)
	s, body = request(t, h.server.URL, "POST", "/peer-invitations/accept", b, map[string]string{"token": third.Token})
	mustStatus(t, 404, s, body)
	if len(approvalListTest(t, h, b)) != 0 {
		t.Fatal("revoked account acquired consent")
	}
}

func TestPeerDeviceRevocationRacesAcceptance(t *testing.T) {
	h := setup(t)
	a, ownerA := enrollTest(t, h)
	b, ownerB := enrollTest(t, h)
	deviceA := registerTest(t, h, a, ownerA, newTestDeviceKeys(t))
	deviceB := registerTest(t, h, b, ownerB, newTestDeviceKeys(t))
	invite := peerInvitationTest(t, h, a, deviceB)
	start := make(chan struct{})
	done := make(chan bool, 2)
	go func() {
		defer func() { done <- true }()
		<-start
		s, body := request(t, h.server.URL, "DELETE", "/devices/"+deviceA.ID, a, nil)
		mustStatus(t, 200, s, body)
	}()
	go func() {
		defer func() { done <- true }()
		<-start
		s, body := request(t, h.server.URL, "POST", "/peer-invitations/accept", b, map[string]string{"token": invite.Token})
		if s != 201 && s != 404 {
			t.Errorf("acceptance race: %d %s", s, body)
		}
	}()
	close(start)
	<-done
	<-done
	if len(approvalListTest(t, h, b)) != 0 {
		t.Fatal("revocation race left active approval")
	}
}

func TestPeerApprovalSnapshotLimit(t *testing.T) {
	h := setup(t)
	a, ownerA := enrollTest(t, h)
	b, ownerB := enrollTest(t, h)
	deviceA := registerTest(t, h, a, ownerA, newTestDeviceKeys(t))
	deviceB := registerTest(t, h, b, ownerB, newTestDeviceKeys(t))
	for range maxPeerApprovals {
		keys := newTestDeviceKeys(t)
		id := newID()
		execTest(t, h.db, "INSERT INTO devices(id,account_id,signing_public_key,tls_public_key,created_at) VALUES(?,?,?,?,1)", id, ownerA, keys.public.SigningPublicKey, keys.public.TLSPublicKey)
		execTest(t, h.db, "INSERT INTO peer_approvals(id,sender_device_id,recipient_device_id,created_at) VALUES(?,?,?,1)", newID(), id, deviceA.ID)
	}
	invite := peerInvitationTest(t, h, a, deviceB)
	s, body := request(t, h.server.URL, "POST", "/peer-invitations/accept", b, map[string]string{"token": invite.Token})
	mustStatus(t, 409, s, body)
	if len(approvalListTest(t, h, a)) != maxPeerApprovals || len(approvalListTest(t, h, b)) != 0 {
		t.Fatal("partial approval committed after limit")
	}
}

func TestPeerInvitationPreviewIsRecipientOnlyAndDoesNotGrantConsent(t *testing.T) {
	h := setup(t)
	a, ownerA := enrollTest(t, h)
	b, ownerB := enrollTest(t, h)
	c, ownerC := enrollTest(t, h)
	deviceA := registerTest(t, h, a, ownerA, newTestDeviceKeys(t))
	deviceB := registerTest(t, h, b, ownerB, newTestDeviceKeys(t))
	registerTest(t, h, c, ownerC, newTestDeviceKeys(t))
	otherB := sessionTest(t, h, ownerB)
	registerTest(t, h, otherB, ownerB, newTestDeviceKeys(t))
	execTest(t, h.db, "UPDATE accounts SET name='Recorder' WHERE id=?", ownerA)
	invite := peerInvitationTest(t, h, a, deviceB)
	for _, wrong := range []string{a, c, otherB} {
		s, body := request(t, h.server.URL, "POST", "/peer-invitations/preview", wrong, map[string]string{"token": invite.Token})
		mustStatus(t, 404, s, body)
	}
	s, body := request(t, h.server.URL, "POST", "/peer-invitations/preview", b, map[string]string{"token": invite.Token})
	mustStatus(t, 200, s, body)
	var preview struct {
		Sender     device `json:"sender"`
		SenderName string `json:"sender_name"`
		ExpiresAt  int64  `json:"expires_at"`
	}
	if err := json.Unmarshal(body, &preview); err != nil || preview.Sender != deviceA || preview.SenderName != "Recorder" || preview.ExpiresAt != invite.ExpiresAt {
		t.Fatalf("invalid invitation preview: %s (%v)", body, err)
	}
	if len(approvalListTest(t, h, b)) != 0 {
		t.Fatal("preview granted consent")
	}
	s, body = request(t, h.server.URL, "POST", "/peer-invitations/accept", b, map[string]string{"token": invite.Token})
	mustStatus(t, 201, s, body)
	approval := approvalListTest(t, h, b)[0]
	if approval.SenderName != "Recorder" {
		t.Fatal("snapshot omitted sender name")
	}
	s, body = request(t, h.server.URL, "DELETE", "/peer-approvals/"+approval.ID, b, nil)
	mustStatus(t, 200, s, body)
	s, body = request(t, h.server.URL, "POST", "/peer-invitations/preview", b, map[string]string{"token": invite.Token})
	mustStatus(t, 410, s, body)
	expired := peerInvitationTest(t, h, a, deviceB)
	execTest(t, h.db, "UPDATE peer_invitations SET expires_at=0 WHERE hash=?", digest(expired.Token))
	s, body = request(t, h.server.URL, "POST", "/peer-invitations/preview", b, map[string]string{"token": expired.Token})
	mustStatus(t, 410, s, body)
	active := peerInvitationTest(t, h, a, deviceB)
	s, body = request(t, h.server.URL, "DELETE", "/devices/"+deviceA.ID, a, nil)
	mustStatus(t, 200, s, body)
	s, body = request(t, h.server.URL, "POST", "/peer-invitations/preview", b, map[string]string{"token": active.Token})
	mustStatus(t, 404, s, body)
}
