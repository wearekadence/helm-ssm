//go:build integration

package integration

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	hssm "github.com/codacy/helm-ssm/internal"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/awserr"
	"github.com/aws/aws-sdk-go/aws/credentials"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/ssm"
)

// LocalStack accepts any non-empty credentials. Tests set them explicitly so the
// developer's real AWS profile can never leak into the test run.
const (
	testRegion    = "us-east-1"
	testAccessKey = "test"
	testSecretKey = "test"
)

// requireLocalstack mirrors the helper edge-ingress uses: skip cleanly when the
// LocalStack endpoint env var isn't set, so `go test -tags=integration ./...` is
// safe to run on a developer machine without a running LocalStack.
func requireLocalstack(t *testing.T) string {
	t.Helper()
	if testing.Short() {
		t.Skip("skipping integration test in short mode")
	}
	endpoint := os.Getenv("LOCALSTACK_ENDPOINT")
	if endpoint == "" {
		t.Skip("LOCALSTACK_ENDPOINT not set")
	}
	// helm-ssm reads AWS_ENDPOINT_URL_SSM internally; set it for the duration of
	// the test so ExecuteTemplate goes to LocalStack.
	t.Setenv("AWS_ENDPOINT_URL_SSM", endpoint)
	t.Setenv("AWS_REGION", testRegion)
	t.Setenv("AWS_ACCESS_KEY_ID", testAccessKey)
	t.Setenv("AWS_SECRET_ACCESS_KEY", testSecretKey)
	return endpoint
}

// newSeederClient builds an SSM client used only by the test to seed parameters.
// Kept separate from helm-ssm's internal session so the test can never depend on
// the same code path it's exercising.
func newSeederClient(t *testing.T, endpoint string) *ssm.SSM {
	t.Helper()
	return newSeederClientForRegion(t, endpoint, testRegion)
}

// newSeederClientForRegion is the region-aware variant — needed when seeding
// parameters across multiple regions, since LocalStack scopes SSM state per
// region.
func newSeederClientForRegion(t *testing.T, endpoint, region string) *ssm.SSM {
	t.Helper()
	sess, err := session.NewSessionWithOptions(session.Options{
		SharedConfigState: session.SharedConfigDisable,
		Config: aws.Config{
			Endpoint:    aws.String(endpoint),
			Region:      aws.String(region),
			Credentials: credentials.NewStaticCredentials(testAccessKey, testSecretKey, ""),
		},
	})
	if err != nil {
		t.Fatalf("build seeder session: %v", err)
	}
	return ssm.New(sess)
}

func putParameter(t *testing.T, client *ssm.SSM, name, value, paramType string) {
	t.Helper()
	overwrite := true
	_, err := client.PutParameter(&ssm.PutParameterInput{
		Name:      aws.String(name),
		Value:     aws.String(value),
		Type:      aws.String(paramType),
		Overwrite: &overwrite,
	})
	if err != nil {
		t.Fatalf("put parameter %s: %v", name, err)
	}
	t.Cleanup(func() {
		_, _ = client.DeleteParameter(&ssm.DeleteParameterInput{Name: aws.String(name)})
	})
}

func TestGetSSMParameter_Existing(t *testing.T) {
	endpoint := requireLocalstack(t)
	client := newSeederClient(t, endpoint)

	putParameter(t, client, "/integration/get/exists", "hello", ssm.ParameterTypeString)

	defaultValue := "ignored"
	got, err := hssm.GetSSMParameter(client, "/integration/get/exists", &defaultValue, false)
	if err != nil {
		t.Fatalf("GetSSMParameter: %v", err)
	}
	if got == nil || *got != "hello" {
		t.Fatalf("expected %q, got %v", "hello", got)
	}
}

func TestGetSSMParameter_MissingWithDefault(t *testing.T) {
	endpoint := requireLocalstack(t)
	client := newSeederClient(t, endpoint)

	defaultValue := "fallback"
	got, err := hssm.GetSSMParameter(client, "/integration/get/missing", &defaultValue, false)
	if err != nil {
		t.Fatalf("GetSSMParameter: %v", err)
	}
	if got == nil || *got != defaultValue {
		t.Fatalf("expected default %q, got %v", defaultValue, got)
	}
}

func TestGetSSMParameter_MissingNoDefault(t *testing.T) {
	endpoint := requireLocalstack(t)
	client := newSeederClient(t, endpoint)

	_, err := hssm.GetSSMParameter(client, "/integration/get/also-missing", nil, false)
	if err == nil {
		t.Fatal("expected ParameterNotFound error, got nil")
	}
	var aerr awserr.Error
	if !errors.As(err, &aerr) || aerr.Code() != ssm.ErrCodeParameterNotFound {
		t.Fatalf("expected ParameterNotFound, got %v", err)
	}
}

func TestGetSSMParameter_SecureStringDecrypted(t *testing.T) {
	endpoint := requireLocalstack(t)
	client := newSeederClient(t, endpoint)

	putParameter(t, client, "/integration/get/secret", "s3cret", ssm.ParameterTypeSecureString)

	got, err := hssm.GetSSMParameter(client, "/integration/get/secret", nil, true)
	if err != nil {
		t.Fatalf("GetSSMParameter: %v", err)
	}
	if got == nil || *got != "s3cret" {
		t.Fatalf("expected decrypted secret, got %v", got)
	}
}

func TestExecuteTemplate_EndToEnd(t *testing.T) {
	endpoint := requireLocalstack(t)
	client := newSeederClient(t, endpoint)

	putParameter(t, client, "/integration/subdomain", "example.com", ssm.ParameterTypeString)
	putParameter(t, client, "/integration/secret", "shhh", ssm.ParameterTypeSecureString)
	putParameter(t, client, "/integration/regional", "regional-value", ssm.ParameterTypeString)

	funcMap := hssm.GetFuncMap("", "", false, "")
	out, err := hssm.ExecuteTemplate(filepath.Join("testdata", "values.yaml"), funcMap, false)
	if err != nil {
		t.Fatalf("ExecuteTemplate: %v", err)
	}

	expected := []string{
		"hostname: api.example.com",
		"fallback: fallback-value",
		"secret: shhh",
		"prefixed: example.com",
		"regional: regional-value",
	}
	for _, line := range expected {
		if !strings.Contains(out, line) {
			t.Errorf("expected rendered output to contain %q\n--- got ---\n%s", line, out)
		}
	}
}

func TestExecuteTemplate_GlobalPrefixApplied(t *testing.T) {
	endpoint := requireLocalstack(t)
	client := newSeederClient(t, endpoint)

	putParameter(t, client, "/integration/global-prefix/host", "prefixed.example.com", ssm.ParameterTypeString)

	tmpl := `host: {{ssm "/host" }}` + "\n"
	tmplPath := filepath.Join(t.TempDir(), "values.yaml")
	if err := os.WriteFile(tmplPath, []byte(tmpl), 0644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}

	funcMap := hssm.GetFuncMap("", "/integration/global-prefix", false, "")
	out, err := hssm.ExecuteTemplate(tmplPath, funcMap, false)
	if err != nil {
		t.Fatalf("ExecuteTemplate: %v", err)
	}
	if !strings.Contains(out, "host: prefixed.example.com") {
		t.Fatalf("expected global prefix to be applied\n--- got ---\n%s", out)
	}
}
