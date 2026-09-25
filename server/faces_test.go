package main

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"testing"
	"time"
)

func TestFaceProcessingGroupsWithinCaptureAndDeletesCrops(t *testing.T) {
	h := setup(t)
	member, _ := enrollTest(t, h)
	invite, err := issueSuperAdminInvite(h.db, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	super := redeem(t, h, invite)
	id := newID()
	s, b := request(t, h.server.URL, "PUT", "/captures/"+id, member, map[string]string{"kind": "video"})
	mustStatus(t, 200, s, b)
	for sequence := 0; sequence <= 4; sequence++ {
		kind := "media"
		if sequence == 0 {
			kind = "init"
		}
		key := newID()
		if _, err := h.db.Exec(`INSERT INTO objects(capture_id,sequence,kind,object_key,sha256,md5,size,duration,start_time,acknowledged)
			VALUES(?,?,?,?, '', '', 4,1,?,1)`, id, sequence, kind, key, float64(sequence)); err != nil {
			t.Fatal(err)
		}
		h.store.data[key] = []byte("part")
	}
	feature := make([]float64, 128)
	feature[0] = 1
	worker := &api{db: h.db, store: h.store, faceDetector: func(_ context.Context, source, kind string) ([]detectedFace, error) {
		if kind != "media" {
			t.Fatalf("unexpected media kind %s", kind)
		}
		data, err := os.ReadFile(source)
		if err != nil || string(data) != "partpart" {
			t.Fatalf("video init was not joined: %q %v", data, err)
		}
		return []detectedFace{{JPEG: []byte("test-jpeg"), Feature: feature}}, nil
	}}
	for range 2 {
		processed, err := worker.processFaceJob(context.Background())
		if err != nil || !processed {
			t.Fatalf("face job: %t %v", processed, err)
		}
	}
	processed, err := worker.processFaceJob(context.Background())
	if err != nil || processed {
		t.Fatalf("sampled an extra fragment: %t %v", processed, err)
	}
	var groups, sightings int
	if err := h.db.QueryRow("SELECT COUNT(*),MAX(sightings) FROM face_groups WHERE capture_id=?", id).Scan(&groups, &sightings); err != nil || groups != 1 || sightings != 2 {
		t.Fatalf("wrong grouping: %d groups, %d sightings, %v", groups, sightings, err)
	}
	var version string
	if err := h.db.QueryRow("SELECT model_version FROM face_groups WHERE capture_id=?", id).Scan(&version); err != nil || version != faceModelVersion {
		t.Fatalf("worker did not tag its model: %q %v", version, err)
	}
	s, b = request(t, h.server.URL, "GET", "/super-admin/captures/"+id+"/faces", member, nil)
	mustStatus(t, 403, s, b)
	s, b = request(t, h.server.URL, "GET", "/super-admin/captures/"+id+"/faces", super.Token, nil)
	mustStatus(t, 200, s, b)
	var list struct {
		Faces []struct {
			ID        string `json:"id"`
			Sightings int    `json:"sightings"`
		} `json:"faces"`
	}
	if err := json.Unmarshal(b, &list); err != nil || len(list.Faces) != 1 || list.Faces[0].Sightings != 2 {
		t.Fatalf("wrong face gallery: %s %v", b, err)
	}
	path := "/super-admin/captures/" + id + "/faces/" + list.Faces[0].ID
	s, b = request(t, h.server.URL, "GET", path, member, nil)
	mustStatus(t, 403, s, b)
	s, b = request(t, h.server.URL, "GET", path, super.Token, nil)
	if s != 200 || !bytes.Equal(b, []byte("test-jpeg")) {
		t.Fatalf("wrong crop response: %d %q", s, b)
	}
	s, b = request(t, h.server.URL, "DELETE", "/captures/"+id, member, nil)
	mustStatus(t, 202, s, b)
	s, b = request(t, h.server.URL, "GET", path, super.Token, nil)
	mustStatus(t, 404, s, b)
	if err := h.db.QueryRow("SELECT COUNT(*) FROM face_groups WHERE capture_id=?", id).Scan(&groups); err != nil || groups != 0 {
		t.Fatalf("deleted crop retained: %d %v", groups, err)
	}
}

func TestPhotoFacesProcessAfterAcknowledgement(t *testing.T) {
	h := setup(t)
	member, _ := enrollTest(t, h)
	id, _ := reserveTestPhoto(t, h, member)
	worker := &api{db: h.db, store: h.store, faceDetector: func(_ context.Context, source, kind string) ([]detectedFace, error) {
		if kind != "photo" {
			t.Fatalf("unexpected kind: %s", kind)
		}
		data, err := os.ReadFile(source)
		if err != nil || string(data) != "delete fixture" {
			t.Fatalf("photo not fetched: %q %v", data, err)
		}
		feature := make([]float64, 128)
		feature[0] = 1
		return []detectedFace{{JPEG: []byte("cropped-face"), Feature: feature}}, nil
	}}
	processed, err := worker.processFaceJob(context.Background())
	if err != nil || processed {
		t.Fatalf("unacknowledged photo processed: %t %v", processed, err)
	}
	s, b := request(t, h.server.URL, "POST", "/captures/"+id+"/objects/ack", member, map[string]int{"sequence": 0})
	mustStatus(t, 200, s, b)
	processed, err = worker.processFaceJob(context.Background())
	if err != nil || !processed {
		t.Fatalf("acknowledged photo not processed: %t %v", processed, err)
	}
	processed, err = worker.processFaceJob(context.Background())
	if err != nil || processed {
		t.Fatalf("photo processed twice: %t %v", processed, err)
	}
	var groups int
	if err := h.db.QueryRow("SELECT COUNT(*) FROM face_groups WHERE capture_id=?", id).Scan(&groups); err != nil || groups != 1 {
		t.Fatalf("photo crop missing: %d %v", groups, err)
	}
}

func TestDeletingWhileFaceDetectionRunsCannotRestoreFaces(t *testing.T) {
	h := setup(t)
	member, _ := enrollTest(t, h)
	id, _ := reserveTestPhoto(t, h, member)
	s, b := request(t, h.server.URL, "POST", "/captures/"+id+"/objects/ack", member, map[string]int{"sequence": 0})
	mustStatus(t, 200, s, b)
	worker := &api{db: h.db, store: h.store, faceDetector: func(_ context.Context, _, _ string) ([]detectedFace, error) {
		s, b := request(t, h.server.URL, "DELETE", "/captures/"+id, member, nil)
		mustStatus(t, 202, s, b)
		feature := make([]float64, 128)
		feature[0] = 1
		return []detectedFace{{JPEG: []byte("face"), Feature: feature}}, nil
	}}
	processed, err := worker.processFaceJob(context.Background())
	if err != nil || !processed {
		t.Fatalf("processing deleted capture: %t %v", processed, err)
	}
	var groups int
	if err := h.db.QueryRow("SELECT COUNT(*) FROM face_groups WHERE capture_id=?", id).Scan(&groups); err != nil || groups != 0 {
		t.Fatalf("deleted capture regained a crop: %d %v", groups, err)
	}
}
