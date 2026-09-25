package main

import (
	"encoding/json"
	"sync"
	"testing"
)

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

func TestPeerConsentIsolationAndRevocation(t *testing.T) {
	h := setup(t)
	a, ownerA := enrollTest(t, h)
	b, ownerB := enrollTest(t, h)
	c, ownerC := enrollTest(t, h)
	unregistered := sessionTest(t, h, ownerA)
	ka, kb := newTestDeviceKeys(t), newTestDeviceKeys(t)
	deviceA := registerTest(t, h, a, ownerA, ka)
	deviceB := registerTest(t, h, b, ownerB, kb)
	registerTest(t, h, c, ownerC, newTestDeviceKeys(t))
	otherB := sessionTest(t, h, ownerB)
	registerTest(t, h, otherB, ownerB, newTestDeviceKeys(t))
	execTest(t, h.db, "UPDATE accounts SET name='Recorder' WHERE id=?", ownerA)
	authority, _ := nearbyCredentialTest(t, h, a)
	p := signedPermissionTest(t, authority, deviceA, deviceB, ka, kb)
	route := "/peer-approvals/" + p.Approval.ID
	input := map[string]any{"permission": p}
	s, body := request(t, h.server.URL, "GET", "/peer-approvals", unregistered, nil)
	mustStatus(t, 409, s, body)
	s, body = request(t, h.server.URL, "PUT", route, unregistered, input)
	mustStatus(t, 409, s, body)
	if len(approvalListTest(t, h, a)) != 0 || len(approvalListTest(t, h, b)) != 0 {
		t.Fatal("approval exists before consent is synchronized")
	}
	for _, wrong := range []string{c, otherB} {
		s, body = request(t, h.server.URL, "PUT", route, wrong, input)
		mustStatus(t, 403, s, body)
	}
	s, body = request(t, h.server.URL, "PUT", route, b, input)
	mustStatus(t, 200, s, body)
	for _, token := range []string{a, b} {
		list := approvalListTest(t, h, token)
		if len(list) != 1 || list[0].Sender != deviceA || list[0].Recipient != deviceB || list[0].SenderName != "Recorder" {
			t.Fatalf("wrong participants: %+v", list)
		}
	}
	if len(approvalListTest(t, h, c)) != 0 || len(approvalListTest(t, h, otherB)) != 0 {
		t.Fatal("approval keys leaked to unrelated device")
	}
	s, body = request(t, h.server.URL, "DELETE", route, c, nil)
	mustStatus(t, 404, s, body)
	for range 2 {
		s, body = request(t, h.server.URL, "DELETE", route, b, nil)
		mustStatus(t, 200, s, body)
	}
	s, body = request(t, h.server.URL, "PUT", route, b, input)
	mustStatus(t, 410, s, body)
	if len(approvalListTest(t, h, a)) != 0 || len(approvalListTest(t, h, b)) != 0 {
		t.Fatal("revoked approval still active")
	}
	renewed := signedPermissionTest(t, authority, deviceA, deviceB, ka, kb)
	s, body = request(t, h.server.URL, "PUT", "/peer-approvals/"+renewed.Approval.ID, b, map[string]any{"permission": renewed})
	mustStatus(t, 200, s, body)
	// Fresh consent cannot make an old signed permission usable again.
	s, body = request(t, h.server.URL, "PUT", route, a, input)
	mustStatus(t, 410, s, body)
	s, body = request(t, h.server.URL, "DELETE", "/devices/"+deviceA.ID, a, nil)
	mustStatus(t, 200, s, body)
	if len(approvalListTest(t, h, b)) != 0 {
		t.Fatal("revoked sender still approved")
	}
	s, body = request(t, h.server.URL, "GET", "/me", a, nil)
	mustStatus(t, 200, s, body)
}

func TestPeerAccountRevocation(t *testing.T) {
	h := setup(t)
	a, ownerA := enrollTest(t, h)
	b, ownerB := enrollTest(t, h)
	ka, kb := newTestDeviceKeys(t), newTestDeviceKeys(t)
	deviceA := registerTest(t, h, a, ownerA, ka)
	deviceB := registerTest(t, h, b, ownerB, kb)
	authority, _ := nearbyCredentialTest(t, h, a)
	p := signedPermissionTest(t, authority, deviceA, deviceB, ka, kb)
	execTest(t, h.db, "UPDATE accounts SET active=0 WHERE id=?", ownerA)
	s, body := request(t, h.server.URL, "PUT", "/peer-approvals/"+p.Approval.ID, b, map[string]any{"permission": p})
	mustStatus(t, 403, s, body)
	if len(approvalListTest(t, h, b)) != 0 {
		t.Fatal("revoked account acquired consent")
	}
}

func TestPeerDeviceRevocationRacesSync(t *testing.T) {
	h := setup(t)
	a, ownerA := enrollTest(t, h)
	b, ownerB := enrollTest(t, h)
	ka, kb := newTestDeviceKeys(t), newTestDeviceKeys(t)
	deviceA := registerTest(t, h, a, ownerA, ka)
	deviceB := registerTest(t, h, b, ownerB, kb)
	authority, _ := nearbyCredentialTest(t, h, a)
	p := signedPermissionTest(t, authority, deviceA, deviceB, ka, kb)
	start := make(chan struct{})
	var wait sync.WaitGroup
	wait.Go(func() {
		<-start
		s, body := request(t, h.server.URL, "DELETE", "/devices/"+deviceA.ID, a, nil)
		mustStatus(t, 200, s, body)
	})
	wait.Go(func() {
		<-start
		s, body := request(t, h.server.URL, "PUT", "/peer-approvals/"+p.Approval.ID, b, map[string]any{"permission": p})
		if s != 200 && s != 403 {
			t.Errorf("sync race: %d %s", s, body)
		}
	})
	close(start)
	wait.Wait()
	if len(approvalListTest(t, h, b)) != 0 {
		t.Fatal("revocation race left active approval")
	}
}

func TestPeerApprovalSnapshotLimit(t *testing.T) {
	h := setup(t)
	a, ownerA := enrollTest(t, h)
	b, ownerB := enrollTest(t, h)
	ka, kb := newTestDeviceKeys(t), newTestDeviceKeys(t)
	deviceA := registerTest(t, h, a, ownerA, ka)
	deviceB := registerTest(t, h, b, ownerB, kb)
	for range maxPeerApprovals {
		keys := newTestDeviceKeys(t)
		id := newID()
		execTest(t, h.db, "INSERT INTO devices(id,account_id,signing_public_key,tls_public_key,created_at) VALUES(?,?,?,?,1)", id, ownerA, keys.public.SigningPublicKey, keys.public.TLSPublicKey)
		execTest(t, h.db, "INSERT INTO peer_approvals(id,sender_device_id,recipient_device_id,created_at) VALUES(?,?,?,1)", newID(), id, deviceA.ID)
	}
	authority, _ := nearbyCredentialTest(t, h, a)
	p := signedPermissionTest(t, authority, deviceA, deviceB, ka, kb)
	s, body := request(t, h.server.URL, "PUT", "/peer-approvals/"+p.Approval.ID, b, map[string]any{"permission": p})
	mustStatus(t, 409, s, body)
	if len(approvalListTest(t, h, a)) != maxPeerApprovals || len(approvalListTest(t, h, b)) != 0 {
		t.Fatal("partial approval committed after limit")
	}
}

func TestPeerCodeRoutesRemoved(t *testing.T) {
	h := setup(t)
	token, _ := enrollTest(t, h)
	for _, route := range []string{"/peer-invitations", "/peer-invitations/preview", "/peer-invitations/accept"} {
		s, body := request(t, h.server.URL, "POST", route, token, map[string]string{})
		mustStatus(t, 404, s, body)
	}
}
