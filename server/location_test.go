package main

import (
	"database/sql"
	"encoding/json"
	"path/filepath"
	"testing"
	"time"
)

func TestCaptureLocationMetadata(t *testing.T) {
	h := setup(t)
	owner, _ := enrollTest(t, h)
	other, _ := enrollTest(t, h)
	id := "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
	lat, lon, accuracy, timestamp := 40.7128, -74.0060, 12.5, time.Now().Unix()
	location := &captureLocation{&lat, &lon, &accuracy, &timestamp}
	create := map[string]any{"kind": "photo", "location": location}
	for range 2 {
		status, body := request(t, h.server.URL, "PUT", "/captures/"+id, owner, create)
		mustStatus(t, 200, status, body)
	}
	status, body := request(t, h.server.URL, "GET", "/captures", owner, nil)
	mustStatus(t, 200, status, body)
	var listed struct {
		Captures []struct {
			Location *captureLocation `json:"location"`
		} `json:"captures"`
	}
	if err := json.Unmarshal(body, &listed); err != nil || len(listed.Captures) != 1 || listed.Captures[0].Location == nil || *listed.Captures[0].Location.Latitude != lat {
		t.Fatalf("location missing from list: %s (%v)", body, err)
	}
	status, body = request(t, h.server.URL, "GET", "/captures/"+id, owner, nil)
	mustStatus(t, 200, status, body)
	var detail struct {
		Location *captureLocation `json:"location"`
	}
	if err := json.Unmarshal(body, &detail); err != nil || detail.Location == nil || *detail.Location.Longitude != lon || *detail.Location.HorizontalAccuracyM != accuracy || *detail.Location.Timestamp != timestamp {
		t.Fatalf("location missing from capture: %s (%v)", body, err)
	}
	status, body = request(t, h.server.URL, "GET", "/captures/"+id, other, nil)
	mustStatus(t, 404, status, body)
	status, body = request(t, h.server.URL, "GET", "/captures", other, nil)
	mustStatus(t, 200, status, body)
	if err := json.Unmarshal(body, &listed); err != nil || len(listed.Captures) != 0 {
		t.Fatalf("location visible to another account: %s (%v)", body, err)
	}
	changed := 40.0
	location.Latitude = &changed
	status, body = request(t, h.server.URL, "PUT", "/captures/"+id, owner, create)
	mustStatus(t, 409, status, body)
	status, body = request(t, h.server.URL, "DELETE", "/captures/"+id, owner, nil)
	mustStatus(t, 202, status, body)
	var storedLatitude sql.NullFloat64
	if err := h.db.QueryRow("SELECT latitude FROM captures WHERE id=?", id).Scan(&storedLatitude); err != nil || storedLatitude.Valid {
		t.Fatalf("deletion retained location: %v (%v)", storedLatitude, err)
	}
}

func TestCaptureLocationValidationAndLegacyCapture(t *testing.T) {
	h := setup(t)
	token, _ := enrollTest(t, h)
	id := "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
	for _, location := range []any{
		map[string]any{"latitude": 91, "longitude": 0, "horizontal_accuracy_m": 1, "timestamp": time.Now().Unix()},
		map[string]any{"latitude": 1, "horizontal_accuracy_m": 1, "timestamp": time.Now().Unix()},
		map[string]any{"latitude": 1, "longitude": 2, "horizontal_accuracy_m": -1, "timestamp": time.Now().Unix()},
	} {
		status, body := request(t, h.server.URL, "PUT", "/captures/"+id, token, map[string]any{"kind": "photo", "location": location})
		mustStatus(t, 400, status, body)
	}
	status, body := request(t, h.server.URL, "PUT", "/captures/"+id, token, map[string]string{"kind": "photo"})
	mustStatus(t, 200, status, body)
	status, body = request(t, h.server.URL, "GET", "/captures/"+id, token, nil)
	mustStatus(t, 200, status, body)
	var detail struct {
		Location *captureLocation `json:"location"`
	}
	if err := json.Unmarshal(body, &detail); err != nil || detail.Location != nil {
		t.Fatalf("legacy capture gained a location: %s (%v)", body, err)
	}
}

func TestLocationMigrationKeepsOlderCaptures(t *testing.T) {
	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "older.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if err := migrate(db, migrations[:2]); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec("INSERT INTO accounts(id,created_at) VALUES('owner',1); INSERT INTO captures(id,account_id,kind,created_at) VALUES('old','owner','photo',2)"); err != nil {
		t.Fatal(err)
	}
	if err := migrate(db, migrations); err != nil {
		t.Fatal(err)
	}
	var lat sql.NullFloat64
	if err := db.QueryRow("SELECT latitude FROM captures WHERE id='old'").Scan(&lat); err != nil || lat.Valid {
		t.Fatalf("older capture changed: %v (%v)", lat, err)
	}
}
