package main

import (
	"encoding/json"
	"math"
	"strings"
	"testing"
	"time"
)

func researchVector(x, y float64) []float64 {
	v := make([]float64, 128)
	v[0], v[1] = x, y
	return v
}

func addResearchFace(t *testing.T, h *testAPI, owner string, vector []float64, version string) (string, string) {
	t.Helper()
	capture, group := newID(), newID()
	encoded, err := json.Marshal(vector)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := h.db.Exec("INSERT INTO captures(id,account_id,kind,created_at) VALUES(?,?,'photo',?)", capture, owner, time.Now().Unix()); err != nil {
		t.Fatal(err)
	}
	if _, err := h.db.Exec(`INSERT INTO face_groups(id,capture_id,embedding,jpeg,first_seen_ms,model_version)
		VALUES(?,?,?,'jpeg',0,?)`, group, capture, string(encoded), version); err != nil {
		t.Fatal(err)
	}
	return capture, group
}

func researchAdmin(t *testing.T, h *testAPI) string {
	t.Helper()
	invite, err := issueSuperAdminInvite(h.db, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	return redeem(t, h, invite).Token
}

func TestResearchSelection(t *testing.T) {
	a := researchVector(1, 0)
	b := researchVector(0, 1)
	first := researchCandidate{PersonID: "a", DisplayName: "A", CaptureID: "source", Version: faceModelVersion, Feature: a}
	second := researchCandidate{PersonID: "b", DisplayName: "B", CaptureID: "other", Version: faceModelVersion, Feature: a}
	if got := selectFaceCandidate(a, "target", faceModelVersion, []researchCandidate{first}, .8, .05); got.State != "possible_match" || got.PersonID != "a" {
		t.Fatalf("expected possible match: %+v", got)
	}
	if got := selectFaceCandidate(b, "target", faceModelVersion, []researchCandidate{first}, .8, .05); got.State != "unknown" {
		t.Fatalf("expected unknown: %+v", got)
	}
	if got := selectFaceCandidate(a, "target", faceModelVersion, []researchCandidate{first, second}, .8, .05); got.State != "ambiguous" {
		t.Fatalf("expected ambiguity: %+v", got)
	}
	if got := selectFaceCandidate(a, "source", faceModelVersion, []researchCandidate{first}, .8, .05); got.State != "unknown" {
		t.Fatalf("self match was accepted: %+v", got)
	}
	if got := selectFaceCandidate(a, "target", "other-model", []researchCandidate{first}, .8, .05); got.State != "unknown" {
		t.Fatalf("cross-version match was accepted: %+v", got)
	}
	for _, vector := range [][]float64{researchVector(0, 0), {math.NaN()}, {math.Inf(1)}} {
		if got := selectFaceCandidate(vector, "target", faceModelVersion, []researchCandidate{first}, .8, .05); got.State != "unavailable" {
			t.Fatalf("invalid vector was accepted: %+v", got)
		}
	}
	if got := selectFaceCandidate(a, "target", faceModelVersion, []researchCandidate{first}, math.NaN(), .05); got.State != "unavailable" {
		t.Fatalf("invalid calibration was accepted: %+v", got)
	}
	if got := selectFaceCandidate(a, "target", faceModelVersion, []researchCandidate{first}, .8, 0); got.State != "unavailable" {
		t.Fatalf("missing margin was accepted: %+v", got)
	}
}

func TestLocalFaceTrialCannotEnableProduction(t *testing.T) {
	previous := faceResearchCalibration
	faceResearchCalibration = struct {
		threshold, margin float64
		calibrated        bool
	}{}
	defer func() { faceResearchCalibration = previous }()
	t.Setenv("FACE_RESEARCH_LOCAL_TRIAL", "1")
	t.Setenv("FACE_RESEARCH_PRODUCTION_PILOT", "")
	t.Setenv("FACE_RESEARCH_ACCOUNT_ID", "research-account")
	t.Setenv("APP_ENV", "production")
	if calibratedFaceResearch() {
		t.Fatal("local trial enabled matching in production")
	}
	t.Setenv("FACE_RESEARCH_PRODUCTION_PILOT", "1")
	t.Setenv("FACE_RESEARCH_ACCOUNT_ID", "")
	if calibratedFaceResearch() {
		t.Fatal("production pilot enabled matching without a research account")
	}
	t.Setenv("FACE_RESEARCH_ACCOUNT_ID", "research-account")
	if !calibratedFaceResearch() {
		t.Fatal("production pilot did not enable matching for its research account")
	}
	t.Setenv("APP_ENV", "development")
	if !calibratedFaceResearch() {
		t.Fatal("local trial did not enable matching in development")
	}
	t.Setenv("FACE_RESEARCH_LOCAL_TRIAL", "")
	if calibratedFaceResearch() {
		t.Fatal("production pilot enabled matching in development")
	}
}

func TestResearchConsentScopeAndWithdrawal(t *testing.T) {
	h := setup(t)
	ownerToken, owner := enrollTest(t, h)
	_, other := enrollTest(t, h)
	admin := researchAdmin(t, h)
	t.Setenv("FACE_RESEARCH_ACCOUNT_ID", owner)
	previous := faceResearchCalibration
	faceResearchCalibration = struct {
		threshold, margin float64
		calibrated        bool
	}{.8, .05, true}
	defer func() { faceResearchCalibration = previous }()
	source, sourceGroup := addResearchFace(t, h, owner, researchVector(1, 0), faceModelVersion)
	target, _ := addResearchFace(t, h, owner, researchVector(1, 0), faceModelVersion)
	otherCapture, _ := addResearchFace(t, h, other, researchVector(1, 0), faceModelVersion)
	s, body := request(t, h.server.URL, "GET", "/super-admin/captures/"+source+"/summary", admin, nil)
	mustStatus(t, 200, s, body)
	if !strings.Contains(string(body), source) {
		t.Fatalf("source summary missing: %s", body)
	}
	s, body = request(t, h.server.URL, "GET", "/super-admin/captures/"+source+"/summary", ownerToken, nil)
	mustStatus(t, 403, s, body)
	optIn := func(id string, token string, consent bool, expected int) {
		t.Helper()
		s, b := request(t, h.server.URL, "PUT", "/super-admin/captures/"+id+"/face-research", token, map[string]bool{"consent_confirmed": consent})
		mustStatus(t, expected, s, b)
	}
	optIn(source, ownerToken, true, 403)
	optIn(source, admin, false, 400)
	optIn(otherCapture, admin, true, 404)
	optIn(source, admin, true, 200)
	optIn(source, admin, true, 200)
	path := "/super-admin/face-people"
	input := map[string]any{"capture_id": source, "face_group_id": sourceGroup, "display_name": "XYZ", "consent_confirmed": false}
	s, body = request(t, h.server.URL, "POST", path, admin, input)
	mustStatus(t, 400, s, body)
	input["consent_confirmed"] = true
	s, body = request(t, h.server.URL, "POST", path, admin, input)
	mustStatus(t, 201, s, body)
	var enrolled struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(body, &enrolled); err != nil || enrolled.ID == "" {
		t.Fatalf("missing enrollment: %s %v", body, err)
	}
	s, body = request(t, h.server.URL, "POST", path, admin, input)
	mustStatus(t, 409, s, body)
	s, body = request(t, h.server.URL, "GET", "/super-admin/captures/"+target+"/faces", admin, nil)
	mustStatus(t, 200, s, body)
	if strings.Contains(string(body), "XYZ") {
		t.Fatal("unconsented target was named")
	}
	optIn(target, admin, true, 200)
	s, body = request(t, h.server.URL, "GET", "/super-admin/captures/"+target+"/faces", admin, nil)
	mustStatus(t, 200, s, body)
	if !strings.Contains(string(body), `"state":"possible_match"`) || !strings.Contains(string(body), "XYZ") {
		t.Fatalf("missing cross-capture candidate: %s", body)
	}
	s, body = request(t, h.server.URL, "GET", "/super-admin/captures/"+source+"/faces", admin, nil)
	mustStatus(t, 200, s, body)
	if strings.Contains(string(body), `"state":"possible_match"`) || !strings.Contains(string(body), `"reference_name":"XYZ"`) {
		t.Fatalf("reference mislabeled as a match: %s", body)
	}
	s, body = request(t, h.server.URL, "GET", "/super-admin/captures/"+otherCapture+"/faces", admin, nil)
	mustStatus(t, 200, s, body)
	if strings.Contains(string(body), "XYZ") {
		t.Fatal("other account received a candidate")
	}
	s, body = request(t, h.server.URL, "DELETE", path+"/"+enrolled.ID, admin, nil)
	mustStatus(t, 204, s, body)
	s, body = request(t, h.server.URL, "GET", "/super-admin/captures/"+target+"/faces", admin, nil)
	mustStatus(t, 200, s, body)
	if !strings.Contains(string(body), `"state":"unknown"`) || strings.Contains(string(body), "XYZ") {
		t.Fatalf("removed enrollment still matched: %s", body)
	}
	input["consent_confirmed"] = true
	s, body = request(t, h.server.URL, "POST", path, admin, input)
	mustStatus(t, 201, s, body)
	t.Setenv("FACE_RESEARCH_ACCOUNT_ID", "")
	s, body = request(t, h.server.URL, "GET", "/super-admin/captures/"+target+"/faces", admin, nil)
	mustStatus(t, 200, s, body)
	if strings.Contains(string(body), "XYZ") {
		t.Fatal("disabled research leaked a name")
	}
	s, body = request(t, h.server.URL, "DELETE", "/super-admin/captures/"+source+"/face-research", admin, nil)
	mustStatus(t, 204, s, body)
	s, body = request(t, h.server.URL, "GET", path, admin, nil)
	mustStatus(t, 200, s, body)
	if strings.Contains(string(body), "XYZ") {
		t.Fatal("source opt-out retained enrollment")
	}
	s, body = request(t, h.server.URL, "DELETE", "/super-admin/captures/"+source+"/face-research", admin, nil)
	mustStatus(t, 204, s, body)
}

func TestResearchCaptureDeletionCleansEnrollment(t *testing.T) {
	h := setup(t)
	ownerToken, owner := enrollTest(t, h)
	admin := researchAdmin(t, h)
	t.Setenv("FACE_RESEARCH_ACCOUNT_ID", owner)
	source, group := addResearchFace(t, h, owner, researchVector(1, 0), faceModelVersion)
	s, body := request(t, h.server.URL, "PUT", "/super-admin/captures/"+source+"/face-research", admin, map[string]bool{"consent_confirmed": true})
	mustStatus(t, 200, s, body)
	s, body = request(t, h.server.URL, "POST", "/super-admin/face-people", admin, map[string]any{
		"capture_id": source, "face_group_id": group, "display_name": "XYZ", "consent_confirmed": true,
	})
	mustStatus(t, 201, s, body)
	s, body = request(t, h.server.URL, "DELETE", "/captures/"+source, ownerToken, nil)
	mustStatus(t, 202, s, body)
	var count int
	if err := h.db.QueryRow("SELECT COUNT(*) FROM face_people").Scan(&count); err != nil || count != 0 {
		t.Fatalf("person survived deletion: %d %v", count, err)
	}
	if err := h.db.QueryRow("SELECT COUNT(*) FROM face_research_captures").Scan(&count); err != nil || count != 0 {
		t.Fatalf("consent survived deletion: %d %v", count, err)
	}
}
