package main

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

func TestSwiftSignedMediaAndReceivedStorage(t *testing.T) {
	probe := os.Getenv("SIGNED_MEDIA_PROBE")
	if probe == "" {
		t.Skip("run tools/verify-signed-media.sh")
	}
	h := setup(t)
	a, accountA := enrollTest(t, h)
	b, accountB := enrollTest(t, h)
	root := t.TempDir()
	config, err := json.Marshal(map[string]any{"base_url": h.server.URL, "root": "file://" + root + "/",
		"session_a": map[string]string{"token": a, "account_id": accountA, "role": "member"},
		"session_b": map[string]string{"token": b, "account_id": accountB, "role": "member"}})
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, "config.json")
	if err = os.WriteFile(path, config, 0600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, probe, path).CombinedOutput()
	if err != nil {
		t.Fatalf("Swift media checks failed: %v %s", err, out)
	}
	if !bytes.Contains(out, []byte("PASS: signed records")) {
		t.Fatalf("missing Swift result: %s", out)
	}
	t.Logf("%s", out)
	data, err := os.ReadFile(filepath.Join(root, "vectors.json"))
	if err != nil {
		t.Fatal(err)
	}
	checkMediaVectors(t, data)
	if os.Getenv("UPDATE_SIGNED_MEDIA_FIXTURES") == "1" {
		var formatted bytes.Buffer
		if err = json.Indent(&formatted, data, "", "  "); err != nil {
			t.Fatal(err)
		}
		if err = os.MkdirAll("testdata", 0755); err != nil {
			t.Fatal(err)
		}
		if err = os.WriteFile("testdata/signed-media-v1.json", formatted.Bytes(), 0644); err != nil {
			t.Fatal(err)
		}
	}
}

func TestMediaRecordGoldenVectors(t *testing.T) {
	data, err := os.ReadFile("testdata/signed-media-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	checkMediaVectors(t, data)
}

func checkMediaVectors(t *testing.T, data []byte) {
	t.Helper()
	var fixtures struct {
		Recorder device
		Approval peerApproval
		Vectors  []struct {
			Name, Kind      string
			Capture, Record signedMediaRecord
			Valid           bool
		}
	}
	if err := json.Unmarshal(data, &fixtures); err != nil {
		t.Fatal(err)
	}
	recorder, approval := fixtures.Recorder, fixtures.Approval
	for _, vector := range fixtures.Vectors {
		t.Run(vector.Name, func(t *testing.T) {
			capture, err := verifyMediaCapture(vector.Capture, recorder)
			if err != nil {
				t.Fatal(err)
			}
			if !capture.validAt(capture.Descriptor.CreatedAt) || capture.validAt(capture.Descriptor.CreatedAt-301) {
				t.Fatal("capture clock skew not enforced")
			}
			switch vector.Kind {
			case "capture":
				_, err = verifyMediaCapture(vector.Record, recorder)
			case "grant":
				var grant mediaGrant
				grant, err = capture.grant(vector.Record, approval)
				if err == nil && (!grant.activeAt(grant.IssuedAt) || grant.activeAt(grant.ExpiresAt) || grant.activeAt(grant.IssuedAt-301)) {
					t.Fatal("grant expiry/skew not enforced")
				}
			case "object":
				var object object
				object, err = capture.manifest(vector.Record)
				if err == nil && (object.CaptureID != capture.Descriptor.CaptureID || object.Size <= 0) {
					t.Fatal("wrong object fields")
				}
			case "completion":
				_, err = capture.completion(vector.Record)
			default:
				t.Fatal("unknown fixture kind")
			}
			if (err == nil) != vector.Valid {
				t.Fatalf("Go validation = %v, want valid=%v", err, vector.Valid)
			}
		})
	}
}
