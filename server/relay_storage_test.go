package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/xml"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"
)

// Opt-in capability probe. It writes only new random keys and removes them afterward.
// Passing on RustFS does not establish the behavior of the production Tigris bucket.
func TestRelayStorage(t *testing.T) {
	if os.Getenv("TEST_RELAY_STORAGE") != "1" {
		t.Skip("run tools/verify-relay-storage.sh against the intended storage provider")
	}
	store, err := newS3()
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	key := func(t *testing.T) string {
		k := "nearby-probe/" + newID()
		t.Cleanup(func() {
			cleanup, done := context.WithTimeout(context.Background(), 15*time.Second)
			defer done()
			if err := store.remove(cleanup, k); err != nil {
				t.Errorf("could not remove probe key %s: %v", k, err)
			}
		})
		return k
	}

	t.Run("SHA256RejectsCorruptionBeforeCommit", func(t *testing.T) {
		original := bytes.Repeat([]byte("original"), 4096)
		changed := append([]byte(nil), original...)
		changed[0] ^= 1
		o := makeObject(original, "media", 1)
		o.Key = key(t)
		signed := relayProbeAuthorization(t, ctx, store, o.Key, original)
		status, code, err := relayProbePUT(ctx, signed, changed)
		// Tigris and RustFS use different error codes for a checksum mismatch.
		if err != nil || status != http.StatusBadRequest || (code != "BadDigest" && code != "XAmzContentSHA256Mismatch") {
			t.Fatalf("corrupt bytes must fail SHA-256 validation: status=%d code=%q error=%v", status, code, err)
		}
		// A successful correct retry proves the rejected body did not occupy the immutable key.
		status, code, err = relayProbePUT(ctx, signed, original)
		if err != nil || status != http.StatusOK {
			t.Fatalf("correct retry after corruption: status=%d code=%q error=%v", status, code, err)
		}
		if ok, err := store.verify(ctx, o); err != nil || !ok {
			t.Fatalf("correct retry was not recoverable: verified=%v error=%v", ok, err)
		}
	})

	t.Run("ChecksumIsBoundToAuthorization", func(t *testing.T) {
		original := []byte("signed original bytes")
		changed := []byte("forged original bytes")
		o := makeObject(original, "media", 1)
		o.Key = key(t)
		for _, tamper := range []string{"replace", "omit"} {
			signed := relayProbeAuthorization(t, ctx, store, o.Key, original)
			u, err := url.Parse(signed.URL)
			if err != nil {
				t.Fatal("invalid probe authorization URL")
			}
			hash := sha256.Sum256(changed)
			value := base64.StdEncoding.EncodeToString(hash[:])
			q := u.Query()
			for k := range q {
				if strings.EqualFold(k, "x-amz-checksum-sha256") {
					if tamper == "replace" {
						q.Set(k, value)
					} else {
						q.Del(k)
					}
				}
			}
			for k := range signed.Headers {
				if strings.EqualFold(k, "x-amz-checksum-sha256") {
					if tamper == "replace" {
						signed.Headers[k] = value
					} else {
						delete(signed.Headers, k)
					}
				}
			}
			u.RawQuery = q.Encode()
			signed.URL = u.String()
			status, code, err := relayProbePUT(ctx, signed, changed)
			if err != nil || (status != 400 && status != 403) {
				t.Fatalf("%s checksum must reject authorization: status=%d code=%q error=%v", tamper, status, code, err)
			}
		}
		status, code, err := relayProbePUT(ctx, relayProbeAuthorization(t, ctx, store, o.Key, original), original)
		if err != nil || status != http.StatusOK {
			t.Fatalf("valid authorization after tampering: status=%d code=%q error=%v", status, code, err)
		}
		if ok, err := store.verify(ctx, o); err != nil || !ok {
			t.Fatalf("valid bytes were not recoverable: verified=%v error=%v", ok, err)
		}
	})

	t.Run("ConcurrentCreateHasOneWinner", func(t *testing.T) {
		const writers = 8
		k := key(t)
		type result struct {
			index, status int
			code          string
			err           error
		}
		results := make(chan result, writers)
		start := make(chan struct{})
		bodies := make([][]byte, writers)
		for i := range writers {
			bodies[i] = bytes.Repeat([]byte{byte(i)}, 32*1024)
			signed := relayProbeAuthorization(t, ctx, store, k, bodies[i])
			go func(i int) {
				<-start
				status, code, err := relayProbePUT(ctx, signed, bodies[i])
				// S3 permits a transient conditional conflict; retry against the same key.
				if err == nil && status == http.StatusConflict {
					status, code, err = relayProbePUT(ctx, signed, bodies[i])
				}
				results <- result{i, status, code, err}
			}(i)
		}
		close(start)
		winner, successes := -1, 0
		for range writers {
			r := <-results
			if r.err != nil {
				t.Errorf("writer %d: %v", r.index, r.err)
				continue
			}
			switch r.status {
			case http.StatusOK:
				winner = r.index
				successes++
			case http.StatusPreconditionFailed:
			default:
				t.Errorf("writer %d: status=%d code=%q", r.index, r.status, r.code)
			}
		}
		if successes != 1 {
			t.Fatalf("want one conditional-write winner, got %d", successes)
		}
		o := makeObject(bodies[winner], "media", 1)
		o.Key = k
		if ok, err := store.verify(ctx, o); err != nil || !ok {
			t.Fatalf("winning bytes were overwritten or unavailable: verified=%v error=%v", ok, err)
		}
		// Simulate a lost acknowledgement and an identical recipient retry.
		status, code, err := relayProbePUT(ctx, relayProbeAuthorization(t, ctx, store, k, bodies[winner]), bodies[winner])
		if err != nil || status != http.StatusPreconditionFailed {
			t.Fatalf("identical retry: status=%d code=%q error=%v", status, code, err)
		}
		if ok, err := store.verify(ctx, o); err != nil || !ok {
			t.Fatalf("lost-response reconciliation failed: verified=%v error=%v", ok, err)
		}
	})
}

// Deliberately omit Content-MD5: this probe must establish SHA-256 enforcement independently.
func relayProbeAuthorization(t *testing.T, ctx context.Context, store *s3Store, key string, body []byte) signedUpload {
	t.Helper()
	hash := sha256.Sum256(body)
	checksum := base64.StdEncoding.EncodeToString(hash[:])
	o := makeObject(body, "media", 1)
	o.Key = key
	signed, err := store.uploadRelay(ctx, o, uploadURLLifetime)
	if err != nil {
		t.Fatal("could not sign probe request")
	}
	u, err := url.Parse(signed.URL)
	if err != nil {
		t.Fatal("invalid probe authorization URL")
	}
	bound := false
	for k, value := range signed.Headers {
		if strings.EqualFold(k, "x-amz-checksum-sha256") && value == checksum {
			bound = true
		}
	}
	for k, v := range u.Query() {
		if strings.EqualFold(k, "x-amz-checksum-sha256") && len(v) == 1 && v[0] == checksum {
			bound = true
		}
	}
	if !bound {
		t.Fatal("presigner omitted the expected SHA-256")
	}
	return signed
}

func relayProbePUT(ctx context.Context, signed signedUpload, body []byte) (int, string, error) {
	req, err := http.NewRequestWithContext(ctx, "PUT", signed.URL, bytes.NewReader(body))
	if err != nil {
		return 0, "", fmt.Errorf("invalid probe request")
	}
	for k, v := range signed.Headers {
		req.Header.Set(k, v)
	}
	client := http.Client{Timeout: 15 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	resp, err := client.Do(req)
	if err != nil {
		// url.Error includes the signed URL; never include it in test output.
		if e, ok := err.(*url.Error); ok {
			err = e.Err
		}
		return 0, "", err
	}
	defer resp.Body.Close()
	var result struct {
		Code string `xml:"Code"`
	}
	if resp.StatusCode >= 400 {
		_ = xml.NewDecoder(io.LimitReader(resp.Body, 32*1024)).Decode(&result)
	}
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 32*1024))
	return resp.StatusCode, result.Code, nil
}
