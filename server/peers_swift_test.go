package main

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

func TestSwiftPeerApprovals(t *testing.T) {
	probe := os.Getenv("PEER_PROBE")
	if probe == "" {
		t.Skip("run tools/verify-peers.sh for the actual Swift approval cache")
	}
	h := setup(t)
	a, ownerA := enrollTest(t, h)
	b, ownerB := enrollTest(t, h)
	execTest(t, h.db, "UPDATE accounts SET name='Recorder' WHERE id=?", ownerA)
	execTest(t, h.db, "UPDATE accounts SET name='Recipient' WHERE id=?", ownerB)
	// Capture a real server snapshot, then withhold its delivery until the Swift
	// client has persisted a local removal. Test control routes exist only here.
	var mu sync.Mutex
	var hold bool
	type snapshotGate struct {
		ready, release chan struct{}
		once           sync.Once
	}
	current := &snapshotGate{ready: make(chan struct{}), release: make(chan struct{})}
	unblock := func() {
		mu.Lock()
		gate := current
		mu.Unlock()
		gate.once.Do(func() { close(gate.release) })
	}
	handler := h.server.Config.Handler
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		gate := current
		mu.Unlock()
		switch r.URL.Path {
		case "/test/hold-next-snapshot":
			mu.Lock()
			current = &snapshotGate{ready: make(chan struct{}), release: make(chan struct{})}
			hold = true
			mu.Unlock()
			jsonResponse(w, 200, map[string]bool{"ok": true})
			return
		case "/test/wait-for-snapshot":
			select {
			case <-gate.ready:
			case <-r.Context().Done():
				return
			}
			jsonResponse(w, 200, map[string]bool{"ok": true})
			return
		case "/test/release-snapshot":
			unblock()
			jsonResponse(w, 200, map[string]bool{"ok": true})
			return
		}
		mu.Lock()
		gate = current
		paused := hold && r.Method == "GET" && r.URL.Path == "/peer-approvals" && r.Header.Get("Authorization") == "Bearer "+a
		if paused {
			hold = false
		}
		mu.Unlock()
		if paused {
			response := httptest.NewRecorder()
			handler.ServeHTTP(response, r)
			close(gate.ready)
			select {
			case <-gate.release:
			case <-r.Context().Done():
				return
			}
			for k, v := range response.Header() {
				w.Header()[k] = v
			}
			w.WriteHeader(response.Code)
			_, _ = w.Write(response.Body.Bytes())
			return
		}
		handler.ServeHTTP(w, r)
	}))
	t.Cleanup(func() { unblock(); server.Close() })
	root := t.TempDir()
	config, err := json.Marshal(map[string]any{
		"base_url": server.URL, "cache_root": filepath.Join(root, "cache"),
		"session_a": map[string]string{"token": a, "account_id": ownerA, "role": "member"},
		"session_b": map[string]string{"token": b, "account_id": ownerB, "role": "member"},
	})
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, "sessions.json")
	if err = os.WriteFile(path, config, 0600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, probe, path).CombinedOutput()
	if err != nil {
		t.Fatalf("Swift approvals failed: %v %s", err, out)
	}
	if !bytes.Contains(out, []byte("PASS: Swift peer approvals")) {
		t.Fatalf("missing Swift result: %s", out)
	}
	t.Logf("%s", out)
}
