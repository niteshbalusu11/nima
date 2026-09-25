package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"math"
	"net/http"
	"os"
	"strings"
	"time"
	"unicode/utf8"
)

const maxFacePeople = 20

// Named results remain off until consented recordings establish and validate
// version-specific acceptance and ambiguity values. The pure selector below is
// tested independently; integration must not invent a release threshold.
var faceResearchCalibration = struct {
	threshold, margin float64
	calibrated        bool
}{}

// These values are for the consented local study only. They were frozen from
// the first uploaded video and must not enable matching on a deployed server.
// A separate recording is evaluated before the trial switch is used.
const localFaceThreshold = 0.30
const localFaceMargin = 0.05

func faceResearchThresholds() (threshold, margin float64, calibrated bool) {
	if os.Getenv("APP_ENV") == "development" && os.Getenv("FACE_RESEARCH_LOCAL_TRIAL") == "1" {
		return localFaceThreshold, localFaceMargin, true
	}
	return faceResearchCalibration.threshold, faceResearchCalibration.margin, faceResearchCalibration.calibrated
}

type faceResearchStatus struct {
	Status            string `json:"status"`
	OptInAllowed      bool   `json:"opt_in_allowed"`
	EnrollmentAllowed bool   `json:"enrollment_allowed"`
	MatchingEnabled   bool   `json:"matching_enabled"`
}

type recognitionResult struct {
	State       string `json:"state"`
	PersonID    string `json:"person_id,omitempty"`
	DisplayName string `json:"display_name,omitempty"`
}

type researchCandidate struct {
	PersonID    string
	DisplayName string
	CaptureID   string
	Version     string
	Feature     []float64
}

func validFaceVector(vector []float64) bool {
	if len(vector) != 128 {
		return false
	}
	var norm float64
	for _, value := range vector {
		if math.IsNaN(value) || math.IsInf(value, 0) {
			return false
		}
		norm += value * value
	}
	return norm > 0 && !math.IsInf(norm, 0)
}

func calibratedFaceResearch() bool {
	t, m, calibrated := faceResearchThresholds()
	return calibrated && t >= -1 && t <= 1 && !math.IsNaN(t) && !math.IsInf(t, 0) &&
		m > 0 && !math.IsNaN(m) && !math.IsInf(m, 0)
}

func selectFaceCandidate(vector []float64, captureID, version string, candidates []researchCandidate, threshold, margin float64) recognitionResult {
	if version == "" || !validFaceVector(vector) || math.IsNaN(threshold) || math.IsInf(threshold, 0) || threshold < -1 || threshold > 1 ||
		math.IsNaN(margin) || math.IsInf(margin, 0) || margin <= 0 {
		return recognitionResult{State: "unavailable"}
	}
	best, second := -2.0, -2.0
	var winner researchCandidate
	for _, candidate := range candidates {
		if candidate.CaptureID == captureID || candidate.Version != version || !validFaceVector(candidate.Feature) {
			continue
		}
		score := faceSimilarity(vector, candidate.Feature)
		if score > best {
			second, best, winner = best, score, candidate
		} else if score > second {
			second = score
		}
	}
	if best < threshold {
		return recognitionResult{State: "unknown"}
	}
	if second >= -1 && best-second < margin {
		return recognitionResult{State: "ambiguous"}
	}
	return recognitionResult{State: "possible_match", PersonID: winner.PersonID, DisplayName: winner.DisplayName}
}

func researchAccountID() string { return os.Getenv("FACE_RESEARCH_ACCOUNT_ID") }

func (a *api) optInFaceResearch(w http.ResponseWriter, r *http.Request) {
	if !a.requireSuperAdmin(w, r) {
		return
	}
	var input struct {
		ConsentConfirmed bool `json:"consent_confirmed"`
	}
	if !decode(w, r, &input) {
		return
	}
	if !input.ConsentConfirmed {
		failure(w, 400, "Participant consent must be confirmed")
		return
	}
	owner := researchAccountID()
	if owner == "" {
		failure(w, 409, "Face research is disabled")
		return
	}
	tx, err := a.db.BeginTx(r.Context(), nil)
	if err != nil {
		failure(w, 503, "Unavailable")
		return
	}
	defer tx.Rollback()
	var captureOwner string
	var active bool
	err = tx.QueryRowContext(r.Context(), `SELECT c.account_id,a.active FROM captures c JOIN accounts a ON a.id=c.account_id
		WHERE c.id=? AND c.deleted_at IS NULL`, r.PathValue("id")).Scan(&captureOwner, &active)
	if err == sql.ErrNoRows || (err == nil && captureOwner != owner) {
		failure(w, 404, "Not found")
		return
	}
	if err != nil {
		failure(w, 503, "Unavailable")
		return
	}
	if !active {
		failure(w, 409, "Research account is inactive")
		return
	}
	_, err = tx.ExecContext(r.Context(), `INSERT INTO face_research_captures(capture_id,confirmed_by,confirmed_at)
		VALUES(?,?,?) ON CONFLICT(capture_id) DO NOTHING`, r.PathValue("id"), account(r), time.Now().Unix())
	if err != nil || tx.Commit() != nil {
		failure(w, 503, "Unavailable")
		return
	}
	jsonResponse(w, 200, map[string]bool{"enabled": true})
}

func (a *api) optOutFaceResearch(w http.ResponseWriter, r *http.Request) {
	if !a.requireSuperAdmin(w, r) {
		return
	}
	tx, err := a.db.BeginTx(r.Context(), nil)
	if err != nil {
		failure(w, 503, "Unavailable")
		return
	}
	defer tx.Rollback()
	var owner string
	var optedIn bool
	err = tx.QueryRowContext(r.Context(), `SELECT c.account_id,EXISTS(SELECT 1 FROM face_research_captures rc WHERE rc.capture_id=c.id)
		FROM captures c WHERE c.id=? AND c.deleted_at IS NULL`, r.PathValue("id")).Scan(&owner, &optedIn)
	if err == sql.ErrNoRows || (err == nil && !optedIn && owner != researchAccountID()) {
		w.Header().Set("Cache-Control", "no-store")
		w.WriteHeader(204)
		return
	}
	if err != nil {
		failure(w, 503, "Unavailable")
		return
	}
	if _, err = tx.ExecContext(r.Context(), `DELETE FROM face_people WHERE reference_group_id IN
		(SELECT id FROM face_groups WHERE capture_id=?)`, r.PathValue("id")); err != nil {
		failure(w, 503, "Unavailable")
		return
	}
	if _, err = tx.ExecContext(r.Context(), "DELETE FROM face_research_captures WHERE capture_id=?", r.PathValue("id")); err != nil || tx.Commit() != nil {
		failure(w, 503, "Unavailable")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(204)
}

func (a *api) enrollFacePerson(w http.ResponseWriter, r *http.Request) {
	if !a.requireSuperAdmin(w, r) {
		return
	}
	var input struct {
		CaptureID        string `json:"capture_id"`
		FaceGroupID      string `json:"face_group_id"`
		DisplayName      string `json:"display_name"`
		ConsentConfirmed bool   `json:"consent_confirmed"`
	}
	if !decode(w, r, &input) {
		return
	}
	input.DisplayName = strings.TrimSpace(input.DisplayName)
	if !input.ConsentConfirmed || input.CaptureID == "" || input.FaceGroupID == "" ||
		utf8.RuneCountInString(input.DisplayName) < 1 || utf8.RuneCountInString(input.DisplayName) > 80 {
		failure(w, 400, "Valid name and enrollment consent required")
		return
	}
	owner := researchAccountID()
	if owner == "" {
		failure(w, 409, "Face research is disabled")
		return
	}
	tx, err := a.db.BeginTx(r.Context(), nil)
	if err != nil {
		failure(w, 503, "Unavailable")
		return
	}
	defer tx.Rollback()
	var captureOwner, version, encoded string
	var active, optedIn bool
	err = tx.QueryRowContext(r.Context(), `SELECT c.account_id,a.active,
		EXISTS(SELECT 1 FROM face_research_captures rc WHERE rc.capture_id=c.id),COALESCE(g.model_version,''),g.embedding
		FROM face_groups g JOIN captures c ON c.id=g.capture_id JOIN accounts a ON a.id=c.account_id
		WHERE g.id=? AND c.id=? AND c.deleted_at IS NULL`, input.FaceGroupID, input.CaptureID).
		Scan(&captureOwner, &active, &optedIn, &version, &encoded)
	if err == sql.ErrNoRows || (err == nil && captureOwner != owner) {
		failure(w, 404, "Not found")
		return
	}
	if err != nil {
		failure(w, 503, "Unavailable")
		return
	}
	var vector []float64
	_ = json.Unmarshal([]byte(encoded), &vector)
	if !active || !optedIn || version != faceModelVersion || !validFaceVector(vector) {
		failure(w, 409, "Reference is ineligible")
		return
	}
	var count int
	if err = tx.QueryRowContext(r.Context(), "SELECT COUNT(*) FROM face_people WHERE reference_group_id=?", input.FaceGroupID).Scan(&count); err != nil {
		failure(w, 503, "Unavailable")
		return
	}
	if count != 0 {
		failure(w, 409, "Face is already enrolled")
		return
	}
	if err = tx.QueryRowContext(r.Context(), "SELECT COUNT(*) FROM face_people WHERE account_id=?", owner).Scan(&count); err != nil {
		failure(w, 503, "Unavailable")
		return
	}
	if count >= maxFacePeople {
		failure(w, 409, "Research enrollment is full")
		return
	}
	id := newID()
	_, err = tx.ExecContext(r.Context(), `INSERT INTO face_people
		(id,account_id,reference_group_id,display_name,consent_confirmed_by,consent_confirmed_at)
		VALUES(?,?,?,?,?,?)`, id, owner, input.FaceGroupID, input.DisplayName, account(r), time.Now().Unix())
	if err != nil || tx.Commit() != nil {
		failure(w, 503, "Unavailable")
		return
	}
	jsonResponse(w, 201, map[string]string{"id": id, "display_name": input.DisplayName,
		"capture_id": input.CaptureID, "face_group_id": input.FaceGroupID})
}

func (a *api) listFacePeople(w http.ResponseWriter, r *http.Request) {
	if !a.requireSuperAdmin(w, r) {
		return
	}
	rows, err := a.db.QueryContext(r.Context(), `SELECT p.id,p.display_name,g.capture_id,p.reference_group_id,p.account_id,
		a.active,c.deleted_at IS NULL,rc.capture_id IS NOT NULL,COALESCE(g.model_version,'')
		FROM face_people p JOIN face_groups g ON g.id=p.reference_group_id
		JOIN captures c ON c.id=g.capture_id JOIN accounts a ON a.id=p.account_id
		LEFT JOIN face_research_captures rc ON rc.capture_id=c.id ORDER BY p.consent_confirmed_at,p.id`)
	if err != nil {
		failure(w, 503, "Unavailable")
		return
	}
	defer rows.Close()
	type person struct {
		ID          string `json:"id"`
		DisplayName string `json:"display_name"`
		CaptureID   string `json:"capture_id"`
		FaceGroupID string `json:"face_group_id"`
		Eligible    bool   `json:"eligible"`
	}
	people := []person{}
	for rows.Next() {
		var p person
		var owner, version string
		var active, live, optedIn bool
		if err := rows.Scan(&p.ID, &p.DisplayName, &p.CaptureID, &p.FaceGroupID, &owner, &active, &live, &optedIn, &version); err != nil {
			failure(w, 503, "Unavailable")
			return
		}
		p.Eligible = owner == researchAccountID() && active && live && optedIn && version == faceModelVersion && calibratedFaceResearch()
		people = append(people, p)
	}
	if rows.Err() != nil {
		failure(w, 503, "Unavailable")
		return
	}
	jsonResponse(w, 200, map[string]any{"people": people})
}

func (a *api) removeFacePerson(w http.ResponseWriter, r *http.Request) {
	if !a.requireSuperAdmin(w, r) {
		return
	}
	if _, err := a.db.ExecContext(r.Context(), "DELETE FROM face_people WHERE id=?", r.PathValue("id")); err != nil {
		failure(w, 503, "Unavailable")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(204)
}

func loadResearchCandidates(ctx context.Context, tx *sql.Tx, owner string) ([]researchCandidate, error) {
	rows, err := tx.QueryContext(ctx, `SELECT p.id,p.display_name,g.capture_id,g.model_version,g.embedding
		FROM face_people p JOIN face_groups g ON g.id=p.reference_group_id
		JOIN captures c ON c.id=g.capture_id JOIN accounts a ON a.id=p.account_id
		JOIN face_research_captures rc ON rc.capture_id=c.id
		WHERE p.account_id=? AND c.account_id=p.account_id AND a.active=1 AND c.deleted_at IS NULL
		AND g.model_version=?`, owner, faceModelVersion)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	candidates := []researchCandidate{}
	for rows.Next() {
		var candidate researchCandidate
		var encoded string
		if err := rows.Scan(&candidate.PersonID, &candidate.DisplayName, &candidate.CaptureID, &candidate.Version, &encoded); err != nil {
			return nil, err
		}
		_ = json.Unmarshal([]byte(encoded), &candidate.Feature)
		candidates = append(candidates, candidate)
	}
	return candidates, rows.Err()
}
