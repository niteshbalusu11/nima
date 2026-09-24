package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"path/filepath"
	"testing"
	"time"
)

func reserveTestPhoto(t *testing.T, h *testAPI, token string) (string, string) {
	t.Helper()
	id := newID()
	s, b := request(t, h.server.URL, "PUT", "/captures/"+id, token, map[string]string{"kind": "photo"})
	mustStatus(t, 200, s, b)
	o := makeObject([]byte("delete fixture"), "photo", 0)
	s, b = request(t, h.server.URL, "POST", "/captures/"+id+"/objects/reserve", token, o)
	mustStatus(t, 200, s, b)
	var key string
	if err := h.db.QueryRow("SELECT object_key FROM objects WHERE capture_id=?", id).Scan(&key); err != nil {
		t.Fatal(err)
	}
	h.store.Lock()
	h.store.data[key] = []byte("delete fixture")
	h.store.Unlock()
	return id, key
}

func TestDeleteOwnershipIdempotencyAndNoResurrection(t *testing.T) {
	h := setup(t)
	token, _ := enrollTest(t, h)
	other, _ := enrollTest(t, h)
	admin := adminTest(t, h)
	id, key := reserveTestPhoto(t, h, token)
	for _, outsider := range []string{other, admin.Token} {
		s, b := request(t, h.server.URL, "DELETE", "/captures/"+id, outsider, nil)
		mustStatus(t, 404, s, b)
	}
	s, b := request(t, h.server.URL, "DELETE", "/captures/"+id, "", nil)
	mustStatus(t, 401, s, b)
	for range 2 {
		s, b = request(t, h.server.URL, "DELETE", "/captures/"+id, token, nil)
		mustStatus(t, 202, s, b)
	}
	h.store.Lock()
	_, exists := h.store.data[key]
	h.store.Unlock()
	if exists {
		t.Fatal("object not removed")
	}
	for _, endpoint := range []struct {
		method, path string
		body         any
	}{
		{"PUT", "", map[string]string{"kind": "photo"}}, {"GET", "", nil},
		{"POST", "/objects/reserve", makeObject([]byte("delete fixture"), "photo", 0)},
		{"POST", "/objects/ack", map[string]int{"sequence": 0}}, {"POST", "/finish", nil},
	} {
		s, b = request(t, h.server.URL, endpoint.method, "/captures/"+id+endpoint.path, token, endpoint.body)
		mustStatus(t, 410, s, b)
	}
	s, b = request(t, h.server.URL, "GET", "/captures", token, nil)
	mustStatus(t, 200, s, b)
	var list struct{ Captures []any }
	if err := json.Unmarshal(b, &list); err != nil {
		t.Fatal(err)
	}
	if len(list.Captures) != 0 {
		t.Fatal("deleted capture still listed")
	}
	// A capture still entirely in the phone's queue must also stay deleted.
	pending := newID()
	s, b = request(t, h.server.URL, "DELETE", "/captures/"+pending, token, nil)
	mustStatus(t, 202, s, b)
	s, b = request(t, h.server.URL, "PUT", "/captures/"+pending, token, map[string]string{"kind": "video"})
	mustStatus(t, 410, s, b)
}

func TestDeleteCleanupRetriesAndLateUpload(t *testing.T) {
	h := setup(t)
	token, _ := enrollTest(t, h)
	id, key := reserveTestPhoto(t, h, token)
	h.store.Lock()
	h.store.removeErr = errors.New("storage unavailable")
	h.store.Unlock()
	s, b := request(t, h.server.URL, "DELETE", "/captures/"+id, token, nil)
	mustStatus(t, 202, s, b)
	var count int
	h.db.QueryRow("SELECT COUNT(*) FROM objects WHERE capture_id=?", id).Scan(&count)
	if count != 1 {
		t.Fatal("lost cleanup key after storage failure")
	}
	// A newly constructed server can resume from SQLite alone.
	restarted := &api{db: h.db, store: h.store}
	h.store.Lock()
	h.store.removeErr = nil
	h.store.Unlock()
	if err := restarted.cleanDeleted(context.Background(), time.Now()); err != nil {
		t.Fatal(err)
	}
	h.store.Lock()
	_, exists := h.store.data[key]
	h.store.data[key] = []byte("late signed PUT")
	h.store.Unlock()
	if exists {
		t.Fatal("retry did not remove object")
	}
	h.db.QueryRow("SELECT COUNT(*) FROM objects WHERE capture_id=?", id).Scan(&count)
	if count != 1 {
		t.Fatal("forgot key before signed URL expired")
	}
	if err := restarted.cleanDeleted(context.Background(), time.Now().Add(deletionGrace+time.Second)); err != nil {
		t.Fatal(err)
	}
	h.store.Lock()
	_, exists = h.store.data[key]
	h.store.Unlock()
	if exists {
		t.Fatal("late upload survived cleanup")
	}
	h.db.QueryRow("SELECT COUNT(*) FROM objects WHERE capture_id=?", id).Scan(&count)
	if count != 0 {
		t.Fatal("completed cleanup retained object metadata")
	}
	s, b = request(t, h.server.URL, "PUT", "/captures/"+id, token, map[string]string{"kind": "photo"})
	mustStatus(t, 410, s, b)
}

func TestDeleteFreesQuotaBeforeStorageCleanup(t *testing.T) {
	h := setup(t)
	token, _ := enrollTest(t, h)
	id, _ := reserveTestPhoto(t, h, token)
	if _, err := h.db.Exec("UPDATE objects SET size=? WHERE capture_id=?", accountQuota, id); err != nil {
		t.Fatal(err)
	}
	s, b := request(t, h.server.URL, "DELETE", "/captures/"+id, token, nil)
	mustStatus(t, 202, s, b)
	reserveTestPhoto(t, h, token)
}

func TestDeletionMigrationPreservesExistingCaptures(t *testing.T) {
	path := filepath.Join(t.TempDir(), "v1.sqlite")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	if err = migrate(db, migrations[:1]); err != nil {
		t.Fatal(err)
	}
	if _, err = db.Exec("INSERT INTO accounts(id,created_at) VALUES('owner',1); INSERT INTO captures(id,account_id,kind,created_at) VALUES('existing','owner','video',2)"); err != nil {
		t.Fatal(err)
	}
	db.Close()
	db, err = openDB(path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var kind string
	var deleted sql.NullInt64
	if err = db.QueryRow("SELECT kind,deleted_at FROM captures WHERE id='existing'").Scan(&kind, &deleted); err != nil || kind != "video" || deleted.Valid {
		t.Fatalf("existing capture changed: %v", err)
	}
}
