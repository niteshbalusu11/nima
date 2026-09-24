package main

import (
	"context"
	"testing"
)

func TestFlyTigrisEnvironment(t *testing.T) {
	for _, key := range []string{"S3_ENDPOINT", "S3_BUCKET", "S3_ACCESS_KEY_ID", "S3_SECRET_ACCESS_KEY", "S3_REGION", "S3_PATH_STYLE"} {
		t.Setenv(key, "")
	}
	t.Setenv("APP_ENV", "production")
	t.Setenv("AWS_ENDPOINT_URL_S3", "https://fly.storage.tigris.dev")
	t.Setenv("AWS_ACCESS_KEY_ID", "test-access-key")
	t.Setenv("AWS_SECRET_ACCESS_KEY", "test-secret-key")
	t.Setenv("AWS_REGION", "auto")
	t.Setenv("BUCKET_NAME", "test-private-bucket")
	store, err := newS3()
	if err != nil {
		t.Fatal(err)
	}
	options := store.client.Options()
	if store.bucket != "test-private-bucket" || *options.BaseEndpoint != "https://fly.storage.tigris.dev" || options.Region != "auto" || options.UsePathStyle {
		t.Fatal("Fly's Tigris environment was not applied")
	}
	credentials, err := options.Credentials.Retrieve(context.Background())
	if err != nil || credentials.AccessKeyID != "test-access-key" || credentials.SecretAccessKey != "test-secret-key" {
		t.Fatal("Fly's storage credentials were not applied")
	}
	t.Setenv("S3_ENDPOINT", "http://127.0.0.1:9000")
	if _, err = newS3(); err == nil {
		t.Fatal("production accepted HTTP storage")
	}
	t.Setenv("APP_ENV", "development")
	t.Setenv("S3_BUCKET", "local-bucket")
	t.Setenv("S3_PATH_STYLE", "true")
	local, err := newS3()
	if err != nil {
		t.Fatal(err)
	}
	if local.bucket != "local-bucket" || *local.client.Options().BaseEndpoint != "http://127.0.0.1:9000" || !local.client.Options().UsePathStyle {
		t.Fatal("explicit local storage configuration did not take precedence")
	}
}
