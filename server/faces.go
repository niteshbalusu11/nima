package main

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"math"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

const maxFaceGroups = 128
const faceMatchThreshold = 0.45

type detectedFace struct {
	JPEG    []byte
	Feature []float64
}

type faceJob struct {
	CaptureID string
	Sequence  int
	Kind      string
	Key       string
	InitKey   string
	StartTime float64
}

func (a *api) nextFaceJob(ctx context.Context) (faceJob, error) {
	var job faceJob
	err := a.db.QueryRowContext(ctx, `SELECT o.capture_id,o.sequence,o.kind,o.object_key,o.start_time,
		COALESCE((SELECT i.object_key FROM objects i WHERE i.capture_id=o.capture_id AND i.sequence=0 AND i.kind='init' AND i.acknowledged=1),'')
		FROM objects o JOIN captures c ON c.id=o.capture_id
		WHERE c.deleted_at IS NULL AND o.acknowledged=1
		AND (o.kind='photo' OR (o.kind='media' AND o.sequence%3=1))
		AND NOT EXISTS (SELECT 1 FROM face_jobs j WHERE j.capture_id=o.capture_id AND j.sequence=o.sequence)
		AND (o.kind='photo' OR EXISTS (SELECT 1 FROM objects i WHERE i.capture_id=o.capture_id AND i.sequence=0 AND i.kind='init' AND i.acknowledged=1))
		ORDER BY c.created_at,o.sequence LIMIT 1`).Scan(&job.CaptureID, &job.Sequence, &job.Kind, &job.Key, &job.StartTime, &job.InitKey)
	return job, err
}

func runFaceDetector(ctx context.Context, source, kind string) ([]detectedFace, error) {
	var stdout, stderr bytes.Buffer
	command := exec.CommandContext(ctx, env("FACE_PYTHON", "python3"), env("FACE_DETECTOR_SCRIPT", "face_detector.py"), source, kind, filepath.Dir(source))
	command.Stdout, command.Stderr = &stdout, &stderr
	if err := command.Run(); err != nil {
		return nil, fmt.Errorf("face detector: %w: %s", err, stderr.String())
	}
	var files []struct {
		File    string    `json:"file"`
		Feature []float64 `json:"feature"`
	}
	if err := json.Unmarshal(stdout.Bytes(), &files); err != nil {
		return nil, err
	}
	faces := make([]detectedFace, 0, len(files))
	for _, file := range files {
		if filepath.Dir(file.File) != filepath.Dir(source) || len(file.Feature) != 128 {
			return nil, errors.New("invalid face detector output")
		}
		jpeg, err := os.ReadFile(file.File)
		if err != nil || len(jpeg) > 100<<10 {
			return nil, errors.New("invalid face crop")
		}
		faces = append(faces, detectedFace{JPEG: jpeg, Feature: file.Feature})
	}
	return faces, nil
}

func (a *api) processFaceJob(ctx context.Context) (bool, error) {
	job, err := a.nextFaceJob(ctx)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	media, err := a.store.read(ctx, job.Key)
	if err != nil {
		return true, err
	}
	if job.Kind == "media" {
		init, err := a.store.read(ctx, job.InitKey)
		if err != nil {
			return true, err
		}
		media = append(init, media...)
	}
	dir, err := os.MkdirTemp("", "nima-faces-")
	if err != nil {
		return true, err
	}
	defer os.RemoveAll(dir)
	extension := ".jpg"
	if job.Kind == "media" {
		extension = ".mp4"
	}
	source := filepath.Join(dir, "source"+extension)
	if err := os.WriteFile(source, media, 0600); err != nil {
		return true, err
	}
	detect := a.faceDetector
	if detect == nil {
		detect = runFaceDetector
	}
	faces, err := detect(ctx, source, job.Kind)
	if err != nil {
		return true, err
	}
	return true, a.saveFaces(ctx, job, faces)
}

func faceSimilarity(a, b []float64) float64 {
	if len(a) != len(b) || len(a) == 0 {
		return -1
	}
	var dot, aa, bb float64
	for i := range a {
		dot += a[i] * b[i]
		aa += a[i] * a[i]
		bb += b[i] * b[i]
	}
	if aa == 0 || bb == 0 {
		return -1
	}
	return dot / math.Sqrt(aa*bb)
}

func (a *api) saveFaces(ctx context.Context, job faceJob, faces []detectedFace) error {
	tx, err := a.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var deleted sql.NullInt64
	if err := tx.QueryRowContext(ctx, "SELECT deleted_at FROM captures WHERE id=?", job.CaptureID).Scan(&deleted); err != nil || deleted.Valid {
		return err
	}
	rows, err := tx.QueryContext(ctx, "SELECT id,embedding FROM face_groups WHERE capture_id=?", job.CaptureID)
	if err != nil {
		return err
	}
	type group struct {
		id      string
		feature []float64
	}
	groups := []group{}
	for rows.Next() {
		var id, encoded string
		if err := rows.Scan(&id, &encoded); err != nil {
			rows.Close()
			return err
		}
		var feature []float64
		if err := json.Unmarshal([]byte(encoded), &feature); err != nil {
			rows.Close()
			return err
		}
		groups = append(groups, group{id, feature})
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return err
	}
	used := map[string]bool{}
	for _, face := range faces {
		if len(face.JPEG) == 0 || len(face.JPEG) > 100<<10 || len(face.Feature) != 128 {
			continue
		}
		best, score := "", faceMatchThreshold
		for _, group := range groups {
			if similarity := faceSimilarity(face.Feature, group.feature); !used[group.id] && similarity > score {
				best, score = group.id, similarity
			}
		}
		if best != "" {
			if _, err := tx.ExecContext(ctx, "UPDATE face_groups SET sightings=sightings+1 WHERE id=?", best); err != nil {
				return err
			}
			used[best] = true
			continue
		}
		if len(groups) >= maxFaceGroups {
			continue
		}
		encoded, err := json.Marshal(face.Feature)
		if err != nil {
			return err
		}
		id := newID()
		when := int64(math.Round(job.StartTime * 1000))
		if when <= 0 && job.Kind == "media" {
			when = int64(job.Sequence-1) * 1000
		}
		if _, err := tx.ExecContext(ctx, "INSERT INTO face_groups(id,capture_id,embedding,jpeg,first_seen_ms) VALUES(?,?,?,?,?)", id, job.CaptureID, string(encoded), face.JPEG, when); err != nil {
			return err
		}
		groups = append(groups, group{id, face.Feature})
		used[id] = true
	}
	if _, err := tx.ExecContext(ctx, "INSERT INTO face_jobs(capture_id,sequence,processed_at) VALUES(?,?,?)", job.CaptureID, job.Sequence, time.Now().Unix()); err != nil {
		return err
	}
	return tx.Commit()
}

func (a *api) processFaces(ctx context.Context) {
	for ctx.Err() == nil {
		deadline, cancel := context.WithTimeout(ctx, 45*time.Second)
		processed, err := a.processFaceJob(deadline)
		cancel()
		pause := 10 * time.Second
		if processed {
			pause = time.Second
		}
		if err != nil {
			log.Printf("face processing will retry: %v", err)
			pause = 30 * time.Second
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(pause):
		}
	}
}

func (a *api) listFaces(w http.ResponseWriter, r *http.Request) {
	if !a.requireSuperAdmin(w, r) {
		return
	}
	rows, err := a.db.QueryContext(r.Context(), `SELECT g.id,g.first_seen_ms,g.sightings FROM face_groups g
		JOIN captures c ON c.id=g.capture_id WHERE g.capture_id=? AND c.deleted_at IS NULL
		ORDER BY g.first_seen_ms,g.id`, r.PathValue("id"))
	if err != nil {
		failure(w, 503, "Unavailable")
		return
	}
	defer rows.Close()
	type face struct {
		ID          string `json:"id"`
		FirstSeenMS int64  `json:"first_seen_ms"`
		Sightings   int    `json:"sightings"`
	}
	faces := []face{}
	for rows.Next() {
		var f face
		if err := rows.Scan(&f.ID, &f.FirstSeenMS, &f.Sightings); err != nil {
			failure(w, 503, "Unavailable")
			return
		}
		faces = append(faces, f)
	}
	if rows.Err() != nil {
		failure(w, 503, "Unavailable")
		return
	}
	jsonResponse(w, 200, map[string]any{"faces": faces})
}

func (a *api) faceImage(w http.ResponseWriter, r *http.Request) {
	if !a.requireSuperAdmin(w, r) {
		return
	}
	var jpeg []byte
	err := a.db.QueryRowContext(r.Context(), `SELECT g.jpeg FROM face_groups g JOIN captures c ON c.id=g.capture_id
		WHERE g.id=? AND g.capture_id=? AND c.deleted_at IS NULL`, r.PathValue("face"), r.PathValue("id")).Scan(&jpeg)
	if err != nil {
		failure(w, 404, "Not found")
		return
	}
	w.Header().Set("Content-Type", "image/jpeg")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	_, _ = w.Write(jpeg)
}
