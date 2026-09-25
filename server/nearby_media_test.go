package main

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

// Real Swift encoder, TLS/media protocol, durable receiver and native relay
// uploader against the Go API and actual local object storage. No radio claim.
func TestSwiftNearbyMediaRecovery(t *testing.T) {
	probe := os.Getenv("NEARBY_MEDIA_PROBE")
	if probe == "" || os.Getenv("TEST_S3") != "1" {
		t.Skip("run tools/verify-nearby-media.sh with local RustFS")
	}
	h := setup(t)
	store, err := newS3()
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer((&api{db: h.db, store: store, relayEnabled: true}).handler())
	defer server.Close()
	h.server = server
	defer func() {
		rows, err := h.db.Query("SELECT object_key FROM objects")
		if err != nil {
			t.Error(err)
			return
		}
		var keys []string
		for rows.Next() {
			var key string
			if err = rows.Scan(&key); err != nil {
				t.Error(err)
				break
			}
			keys = append(keys, key)
		}
		rows.Close()
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		for _, key := range keys {
			if err := store.remove(ctx, key); err != nil {
				t.Error("nearby storage fixture cleanup failed")
			}
		}
	}()
	var sessions []map[string]string
	var owner string
	for i := 0; i < 4; i++ {
		token, account := enrollTest(t, h)
		if i == 0 {
			owner = account
		}
		sessions = append(sessions, map[string]string{"token": token, "account_id": account, "role": "member"})
	}
	root := t.TempDir()
	config, err := json.Marshal(map[string]any{"base_url": server.URL, "root": "file://" + root + "/", "sessions": sessions})
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, "config.json")
	if err = os.WriteFile(path, config, 0600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 150*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, probe, path).CombinedOutput()
	if err != nil {
		t.Fatalf("Native nearby checks failed: %v\n%s", err, out)
	}
	if !bytes.Contains(out, []byte("PASS: native nearby recovery")) {
		t.Fatalf("Missing native result: %s", out)
	}
	t.Logf("%s", out)
	var captures, wrongOwner, duplicates, incomplete int
	if err = h.db.QueryRow("SELECT count(*),coalesce(sum(account_id!=?),0) FROM captures WHERE deleted_at IS NULL", owner).Scan(&captures, &wrongOwner); err != nil {
		t.Fatal(err)
	}
	if err = h.db.QueryRow("SELECT count(*) FROM (SELECT capture_id,sequence FROM objects GROUP BY capture_id,sequence HAVING count(*)>1)").Scan(&duplicates); err != nil {
		t.Fatal(err)
	}
	if err = h.db.QueryRow("SELECT count(*) FROM objects WHERE acknowledged=0").Scan(&incomplete); err != nil {
		t.Fatal(err)
	}
	if captures < 2 || wrongOwner != 0 || duplicates != 0 || incomplete != 0 {
		t.Fatalf("Invalid ownership/coverage: %d %d %d %d", captures, wrongOwner, duplicates, incomplete)
	}
}
