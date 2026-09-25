package main

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"math"
)

const mediaGrantLifetime int64 = 30 * 86400
const mediaClockSkew int64 = 300
const maxSharedCapture int64 = 3 << 30

var errMediaRecord = errors.New("invalid signed media record")

type signedMediaRecord struct {
	Payload   string `json:"payload"`
	Signature string `json:"signature"`
}
type mediaDescriptor struct {
	CaptureID, AccountID, DeviceID string
	KeyHash                        []byte
	Kind                           string
	CreatedAt                      int64
}
type verifiedMediaCapture struct {
	Envelope   signedMediaRecord
	Recorder   device
	Descriptor mediaDescriptor
	Digest     []byte
}

func (c verifiedMediaCapture) validAt(now int64) bool {
	return now >= 0 && now <= math.MaxInt64-mediaClockSkew && c.Descriptor.CreatedAt <= now+mediaClockSkew
}

type mediaGrant struct {
	ID, SenderDeviceID, RecipientAccountID, RecipientDeviceID, ApprovalID string
	DescriptorHash                                                        []byte
	IssuedAt, ExpiresAt, ByteLimit                                        int64
}
type mediaCompletion struct {
	DescriptorHash            []byte
	Ending                    string
	LastSequence, ObjectCount int
	TotalBytes                int64
}

func mediaURLBytes(s string, limit int) ([]byte, error) {
	if len(s) > (limit*4+2)/3 {
		return nil, errMediaRecord
	}
	b, err := base64.RawURLEncoding.Strict().DecodeString(s)
	if err != nil || len(b) > limit || base64.RawURLEncoding.EncodeToString(b) != s {
		return nil, errMediaRecord
	}
	return b, nil
}

func signedMediaReader(e signedMediaRecord, recorder device, domain string) (*mediaReader, []byte, error) {
	payload, err := mediaURLBytes(e.Payload, 512)
	if err != nil {
		return nil, nil, err
	}
	signature, err := mediaURLBytes(e.Signature, 80)
	if err != nil {
		return nil, nil, err
	}
	key, ok := decodeURLBytes(recorder.SigningPublicKey, 65)
	if !ok {
		return nil, nil, errMediaRecord
	}
	public, err := ecdsa.ParseUncompressedPublicKey(elliptic.P256(), key)
	hash := sha256.Sum256(payload)
	if err != nil || !ecdsa.VerifyASN1(public, hash[:], signature) {
		return nil, nil, errMediaRecord
	}
	prefix := []byte("uploadvideo.media." + domain + ".v1\x00")
	if !bytes.HasPrefix(payload, prefix) {
		return nil, nil, errMediaRecord
	}
	return &mediaReader{data: payload[len(prefix):]}, hash[:], nil
}

func verifyMediaCapture(e signedMediaRecord, recorder device) (verifiedMediaCapture, error) {
	r, digest, err := signedMediaReader(e, recorder, "capture")
	if err != nil {
		return verifiedMediaCapture{}, err
	}
	rawID := r.id()
	// r.id always returns 32 hex characters, even after a truncated read.
	d := mediaDescriptor{CaptureID: rawID[:8] + "-" + rawID[8:12] + "-" + rawID[12:16] + "-" + rawID[16:20] + "-" + rawID[20:],
		AccountID: r.id(), DeviceID: r.id(), KeyHash: r.take(32)}
	switch r.byte() {
	case 1:
		d.Kind = "video"
	case 2:
		d.Kind = "photo"
	default:
		r.bad = true
	}
	d.CreatedAt = r.number()
	key, _ := decodeURLBytes(recorder.SigningPublicKey, 65)
	keyHash := sha256.Sum256(key)
	if !r.done() || d.CreatedAt <= 0 || d.AccountID != recorder.AccountID || d.DeviceID != recorder.ID || !bytes.Equal(d.KeyHash, keyHash[:]) {
		return verifiedMediaCapture{}, errMediaRecord
	}
	return verifiedMediaCapture{e, recorder, d, digest}, nil
}

func (c verifiedMediaCapture) grant(e signedMediaRecord, approval peerApproval) (mediaGrant, error) {
	r, _, err := signedMediaReader(e, c.Recorder, "grant")
	if err != nil {
		return mediaGrant{}, err
	}
	g := mediaGrant{ID: r.id(), DescriptorHash: r.take(32), SenderDeviceID: r.id(), RecipientAccountID: r.id(), RecipientDeviceID: r.id(), ApprovalID: r.id()}
	if r.byte() != 1 || r.byte() != 1 {
		r.bad = true
	} // primary destination; upload signed material only
	g.IssuedAt, g.ExpiresAt, g.ByteLimit = r.number(), r.number(), r.number()
	if !r.done() || g.IssuedAt <= 0 || g.ExpiresAt <= g.IssuedAt || g.ExpiresAt-g.IssuedAt > mediaGrantLifetime || g.ByteLimit <= 0 || g.ByteLimit > maxSharedCapture ||
		!bytes.Equal(g.DescriptorHash, c.Digest) || g.SenderDeviceID != c.Recorder.ID || approval.Sender != c.Recorder || g.ApprovalID != approval.ID ||
		g.RecipientAccountID != approval.Recipient.AccountID || g.RecipientDeviceID != approval.Recipient.ID || g.SenderDeviceID == g.RecipientDeviceID ||
		(c.Descriptor.Kind == "photo" && g.ByteLimit > maxObjectSize) {
		return mediaGrant{}, errMediaRecord
	}
	return g, nil
}
func (g mediaGrant) activeAt(now int64) bool {
	return now >= 0 && now <= math.MaxInt64-mediaClockSkew && g.IssuedAt <= now+mediaClockSkew && g.ExpiresAt > now
}

func (c verifiedMediaCapture) manifest(e signedMediaRecord) (object, error) {
	r, _, err := signedMediaReader(e, c.Recorder, "object")
	if err != nil {
		return object{}, err
	}
	hash := r.take(32)
	o := object{CaptureID: c.Descriptor.CaptureID, Sequence: r.sequence()}
	switch r.byte() {
	case 1:
		o.Kind = "init"
	case 2:
		o.Kind = "media"
	case 3:
		o.Kind = "photo"
	default:
		r.bad = true
	}
	o.Size, o.SHA256, o.MD5 = r.number(), hex.EncodeToString(r.take(32)), base64.StdEncoding.EncodeToString(r.take(16))
	o.Duration, o.StartTime = math.Float64frombits(r.bits()), math.Float64frombits(r.bits())
	validKind := (c.Descriptor.Kind == "photo" && o.Kind == "photo" && o.Sequence == 0) ||
		(c.Descriptor.Kind == "video" && ((o.Kind == "init" && o.Sequence == 0) || (o.Kind == "media" && o.Sequence > 0)))
	if !r.done() || !bytes.Equal(hash, c.Digest) || !validKind || o.Sequence > 100000 || o.Size <= 0 || o.Size > maxObjectSize ||
		!mediaTime(o.Duration, 60) || !mediaTime(o.StartTime, 6000000) || (o.Kind != "media" && (o.Duration != 0 || o.StartTime != 0)) {
		return object{}, errMediaRecord
	}
	return o, nil
}
func mediaTime(n, max float64) bool {
	return !math.IsNaN(n) && !math.IsInf(n, 0) && n >= 0 && n <= max && (n != 0 || !math.Signbit(n))
}

func (c verifiedMediaCapture) completion(e signedMediaRecord) (mediaCompletion, error) {
	r, _, err := signedMediaReader(e, c.Recorder, "completion")
	if err != nil {
		return mediaCompletion{}, err
	}
	end := mediaCompletion{DescriptorHash: r.take(32)}
	switch r.byte() {
	case 1:
		end.Ending = "stopped"
	case 2:
		end.Ending = "interrupted"
	default:
		r.bad = true
	}
	end.LastSequence, end.ObjectCount, end.TotalBytes = r.sequence(), r.sequence(), r.number()
	if !r.done() || !bytes.Equal(end.DescriptorHash, c.Digest) || end.LastSequence > 100000 || end.ObjectCount != end.LastSequence+1 ||
		end.TotalBytes < int64(end.ObjectCount) || end.TotalBytes > maxSharedCapture || end.TotalBytes > int64(end.ObjectCount)*maxObjectSize ||
		(c.Descriptor.Kind == "photo" && (end.LastSequence != 0 || end.TotalBytes > maxObjectSize)) {
		return mediaCompletion{}, errMediaRecord
	}
	return end, nil
}

type mediaReader struct {
	data   []byte
	offset int
	bad    bool
}

func (r *mediaReader) take(n int) []byte {
	if n > len(r.data)-r.offset {
		r.bad = true
		return make([]byte, n)
	}
	b := r.data[r.offset : r.offset+n]
	r.offset += n
	return b
}
func (r *mediaReader) byte() byte   { return r.take(1)[0] }
func (r *mediaReader) id() string   { return hex.EncodeToString(r.take(16)) }
func (r *mediaReader) bits() uint64 { return binary.BigEndian.Uint64(r.take(8)) }
func (r *mediaReader) number() int64 {
	n := r.bits()
	if n > math.MaxInt64 {
		r.bad = true
		return 0
	}
	return int64(n)
}
func (r *mediaReader) sequence() int {
	n := binary.BigEndian.Uint32(r.take(4))
	if n > 100001 {
		r.bad = true
		return 0
	}
	return int(n)
}
func (r *mediaReader) done() bool { return !r.bad && r.offset == len(r.data) }
