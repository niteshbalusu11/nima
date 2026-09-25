package main

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/smithy-go"
)

const uploadURLLifetime = 2 * time.Minute

type signedUpload struct {
	URL     string            `json:"url"`
	Headers map[string]string `json:"headers"`
}
type objectStore interface {
	upload(context.Context, object) (signedUpload, error)
	verify(context.Context, object) (bool, error)
	download(context.Context, string) (string, error)
	downloadDashboard(context.Context, string) (string, error)
	read(context.Context, string) ([]byte, error)
	remove(context.Context, string) error
}
type relayObjectStore interface {
	uploadRelay(context.Context, object, time.Duration) (signedUpload, error)
}
type s3Store struct {
	client          *s3.Client
	signer          *s3.PresignClient
	dashboardSigner *s3.PresignClient
	bucket          string
}

func newS3() (*s3Store, error) {
	// Fly provisions Tigris using AWS_* and BUCKET_NAME secrets. Explicit S3_*
	// settings still support local RustFS and other S3-compatible providers.
	values := map[string]string{
		"S3_ENDPOINT":          env("S3_ENDPOINT", os.Getenv("AWS_ENDPOINT_URL_S3")),
		"S3_BUCKET":            env("S3_BUCKET", os.Getenv("BUCKET_NAME")),
		"S3_ACCESS_KEY_ID":     env("S3_ACCESS_KEY_ID", os.Getenv("AWS_ACCESS_KEY_ID")),
		"S3_SECRET_ACCESS_KEY": env("S3_SECRET_ACCESS_KEY", os.Getenv("AWS_SECRET_ACCESS_KEY")),
	}
	for _, key := range []string{"S3_ENDPOINT", "S3_BUCKET", "S3_ACCESS_KEY_ID", "S3_SECRET_ACCESS_KEY"} {
		if values[key] == "" {
			return nil, fmt.Errorf("%s is required", key)
		}
	}
	endpoint := values["S3_ENDPOINT"]
	if !validS3Endpoint(endpoint) {
		return nil, errors.New("S3_ENDPOINT must be HTTPS (HTTP requires APP_ENV=development)")
	}
	publicEndpoint := env("S3_PUBLIC_ENDPOINT", endpoint)
	if !validS3Endpoint(publicEndpoint) {
		return nil, errors.New("S3_PUBLIC_ENDPOINT must be HTTPS (HTTP requires APP_ENV=development)")
	}
	dashboardEndpoint := env("S3_DASHBOARD_ENDPOINT", publicEndpoint)
	if !validS3Endpoint(dashboardEndpoint) {
		return nil, errors.New("S3_DASHBOARD_ENDPOINT must be HTTPS (HTTP requires APP_ENV=development)")
	}
	options := s3.Options{
		Region: env("S3_REGION", env("AWS_REGION", "auto")), BaseEndpoint: aws.String(endpoint), UsePathStyle: os.Getenv("S3_PATH_STYLE") == "true",
		Credentials:                credentials.NewStaticCredentialsProvider(values["S3_ACCESS_KEY_ID"], values["S3_SECRET_ACCESS_KEY"], ""),
		RequestChecksumCalculation: aws.RequestChecksumCalculationWhenRequired,
		ResponseChecksumValidation: aws.ResponseChecksumValidationWhenRequired,
	}
	client := s3.New(options)
	signerClient := client
	if publicEndpoint != endpoint {
		options.BaseEndpoint = aws.String(publicEndpoint)
		signerClient = s3.New(options)
	}
	dashboardClient := signerClient
	if dashboardEndpoint != publicEndpoint {
		options.BaseEndpoint = aws.String(dashboardEndpoint)
		dashboardClient = s3.New(options)
	}
	return &s3Store{client: client, signer: s3.NewPresignClient(signerClient), dashboardSigner: s3.NewPresignClient(dashboardClient), bucket: values["S3_BUCKET"]}, nil
}

func validS3Endpoint(endpoint string) bool {
	u, err := url.Parse(endpoint)
	return err == nil && u.Host != "" && (u.Scheme == "https" || (u.Scheme == "http" && os.Getenv("APP_ENV") == "development"))
}
func (s *s3Store) upload(ctx context.Context, o object) (signedUpload, error) {
	p, err := s.signer.PresignPutObject(ctx, &s3.PutObjectInput{
		Bucket: aws.String(s.bucket), Key: aws.String(o.Key), ContentLength: aws.Int64(o.Size),
		ContentType: aws.String(o.contentType()), ContentMD5: aws.String(o.MD5), IfNoneMatch: aws.String("*"),
	}, func(p *s3.PresignOptions) { p.Expires = uploadURLLifetime })
	if err != nil {
		return signedUpload{}, err
	}
	headers := map[string]string{}
	for k, v := range p.SignedHeader {
		if k != "Host" && len(v) > 0 {
			headers[k] = v[0]
		}
	}
	return signedUpload{p.URL, headers}, nil
}
func (s *s3Store) uploadRelay(ctx context.Context, o object, lifetime time.Duration) (signedUpload, error) {
	sha, err := hex.DecodeString(o.SHA256)
	if err != nil || len(sha) != 32 || lifetime <= 0 || lifetime > uploadURLLifetime {
		return signedUpload{}, errors.New("invalid relay upload authorization")
	}
	// SHA-256 is enforced by storage before the immutable key can be occupied.
	// Content-MD5 is intentionally unnecessary on this path.
	p, err := s.signer.PresignPutObject(ctx, &s3.PutObjectInput{
		Bucket: aws.String(s.bucket), Key: aws.String(o.Key), ContentLength: aws.Int64(o.Size),
		ContentType: aws.String(o.contentType()), ChecksumSHA256: aws.String(base64.StdEncoding.EncodeToString(sha)),
		IfNoneMatch: aws.String("*"),
	}, s3.WithPresignExpires(lifetime))
	if err != nil {
		return signedUpload{}, err
	}
	headers := map[string]string{}
	for k, v := range p.SignedHeader {
		if k != "Host" && len(v) > 0 {
			headers[k] = v[0]
		}
	}
	return signedUpload{p.URL, headers}, nil
}
func (s *s3Store) verify(ctx context.Context, o object) (bool, error) {
	// Verify bytes, including recovery after a successful PUT whose acknowledgment was lost.
	out, err := s.client.GetObject(ctx, &s3.GetObjectInput{Bucket: aws.String(s.bucket), Key: aws.String(o.Key)})
	if err != nil {
		var api smithy.APIError
		if errors.As(err, &api) && (api.ErrorCode() == "NoSuchKey" || api.ErrorCode() == "NotFound") {
			return false, nil
		}
		return false, err
	}
	defer out.Body.Close()
	if aws.ToInt64(out.ContentLength) != o.Size {
		return false, errors.New("stored object size mismatch")
	}
	h := sha256.New()
	n, err := io.Copy(h, io.LimitReader(out.Body, o.Size+1))
	if err != nil {
		return false, err
	}
	if n != o.Size || hex.EncodeToString(h.Sum(nil)) != o.SHA256 {
		return false, errors.New("stored object digest mismatch")
	}
	return true, nil
}
func (s *s3Store) download(ctx context.Context, key string) (string, error) {
	return s.presignDownload(ctx, s.signer, key)
}

func (s *s3Store) downloadDashboard(ctx context.Context, key string) (string, error) {
	return s.presignDownload(ctx, s.dashboardSigner, key)
}

func (s *s3Store) presignDownload(ctx context.Context, signer *s3.PresignClient, key string) (string, error) {
	p, err := signer.PresignGetObject(ctx, &s3.GetObjectInput{Bucket: aws.String(s.bucket), Key: aws.String(key)}, func(p *s3.PresignOptions) { p.Expires = 2 * time.Minute })
	if err != nil {
		return "", err
	}
	return p.URL, nil
}

func (s *s3Store) read(ctx context.Context, key string) ([]byte, error) {
	out, err := s.client.GetObject(ctx, &s3.GetObjectInput{Bucket: aws.String(s.bucket), Key: aws.String(key)})
	if err != nil {
		return nil, err
	}
	defer out.Body.Close()
	return io.ReadAll(io.LimitReader(out.Body, maxObjectSize+1))
}

func (s *s3Store) remove(ctx context.Context, key string) error {
	_, err := s.client.DeleteObject(ctx, &s3.DeleteObjectInput{Bucket: aws.String(s.bucket), Key: aws.String(key)})
	return err
}
