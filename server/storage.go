package main

import (
	"context"
	"crypto/sha256"
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
	remove(context.Context, string) error
}
type s3Store struct {
	client *s3.Client
	signer *s3.PresignClient
	bucket string
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
	u, err := url.Parse(endpoint)
	if err != nil || u.Host == "" || (u.Scheme != "https" && !(u.Scheme == "http" && os.Getenv("APP_ENV") == "development")) {
		return nil, errors.New("S3_ENDPOINT must be HTTPS (HTTP requires APP_ENV=development)")
	}
	client := s3.New(s3.Options{
		Region: env("S3_REGION", env("AWS_REGION", "auto")), BaseEndpoint: aws.String(endpoint), UsePathStyle: os.Getenv("S3_PATH_STYLE") == "true",
		Credentials:                credentials.NewStaticCredentialsProvider(values["S3_ACCESS_KEY_ID"], values["S3_SECRET_ACCESS_KEY"], ""),
		RequestChecksumCalculation: aws.RequestChecksumCalculationWhenRequired,
		ResponseChecksumValidation: aws.ResponseChecksumValidationWhenRequired,
	})
	return &s3Store{client: client, signer: s3.NewPresignClient(client), bucket: values["S3_BUCKET"]}, nil
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
	p, err := s.signer.PresignGetObject(ctx, &s3.GetObjectInput{Bucket: aws.String(s.bucket), Key: aws.String(key)}, func(p *s3.PresignOptions) { p.Expires = 2 * time.Minute })
	if err != nil {
		return "", err
	}
	return p.URL, nil
}

func (s *s3Store) remove(ctx context.Context, key string) error {
	_, err := s.client.DeleteObject(ctx, &s3.DeleteObjectInput{Bucket: aws.String(s.bucket), Key: aws.String(key)})
	return err
}
