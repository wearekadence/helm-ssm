//go:build integration

package integration

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"testing"

	"github.com/aws/aws-sdk-go/service/ssm"
)

type seed struct {
	path, region, value string
}

// TestHelmTemplate_E2E builds the helm-ssm binary, runs it against a values
// file containing SSM placeholders, then renders the result through `helm
// template`, while a counting reverse-proxy in front of LocalStack records
// every SSM API call. Asserts the rendered manifest carries the resolved
// values, and reports the call count today vs. what a batched implementation
// would achieve.
func TestHelmTemplate_E2E(t *testing.T) {
	endpoint := requireLocalstack(t)
	if _, err := exec.LookPath("helm"); err != nil {
		t.Skip("helm not on PATH")
	}

	paramsByRegion := map[string]int{
		"us-east-1": 15,
		"eu-west-1": 10,
	}

	var seeds []seed
	for region, count := range paramsByRegion {
		client := newSeederClientForRegion(t, endpoint, region)
		regionTag := strings.ReplaceAll(region, "-", "")
		for i := 0; i < count; i++ {
			s := seed{
				path:   fmt.Sprintf("/e2e/%s/p%d", regionTag, i),
				region: region,
				value:  fmt.Sprintf("%s-v%d", region, i),
			}
			putParameter(t, client, s.path, s.value, ssm.ParameterTypeString)
			seeds = append(seeds, s)
		}
	}

	target, err := url.Parse(endpoint)
	if err != nil {
		t.Fatalf("parse LOCALSTACK_ENDPOINT: %v", err)
	}
	rp := httputil.NewSingleHostReverseProxy(target)
	var (
		mu             sync.Mutex
		callsPerRegion = map[string]int{}
		callsTotal     int
		callOps        = map[string]int{}
	)
	credRegionRe := regexp.MustCompile(`Credential=[^/]+/[^/]+/([^/]+)/ssm/`)
	proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if op := r.Header.Get("X-Amz-Target"); op != "" {
			mu.Lock()
			callsTotal++
			callOps[op]++
			if m := credRegionRe.FindStringSubmatch(r.Header.Get("Authorization")); len(m) == 2 {
				callsPerRegion[m[1]]++
			}
			mu.Unlock()
		}
		rp.ServeHTTP(w, r)
	}))
	defer proxy.Close()

	repoRoot, err := filepath.Abs("../..")
	if err != nil {
		t.Fatalf("abs repo root: %v", err)
	}
	binPath := filepath.Join(t.TempDir(), "helm-ssm")
	build := exec.Command("go", "build", "-o", binPath, "./cmd")
	build.Dir = repoRoot
	if out, err := build.CombinedOutput(); err != nil {
		t.Fatalf("go build helm-ssm: %v\n%s", err, out)
	}

	chartDir := filepath.Join(t.TempDir(), "mychart")
	writeChart(t, chartDir)
	// Source values file lives outside the chart so helm doesn't try to load
	// it as the chart's default values.yaml (which would fail on the
	// unresolved {{ssm}} placeholders).
	srcValuesDir := t.TempDir()
	valuesPath := filepath.Join(srcValuesDir, "values.yaml")
	if err := os.WriteFile(valuesPath, []byte(buildValuesYAML(seeds)), 0644); err != nil {
		t.Fatalf("write values.yaml: %v", err)
	}

	resolvedDir := t.TempDir()
	helmSsm := exec.Command(binPath, "-f", valuesPath, "-o", resolvedDir)
	helmSsm.Env = awsCleanEnv(map[string]string{
		"AWS_ENDPOINT_URL_SSM":  proxy.URL,
		"AWS_REGION":            "us-east-1",
		"AWS_ACCESS_KEY_ID":     testAccessKey,
		"AWS_SECRET_ACCESS_KEY": testSecretKey,
	})
	if out, err := helmSsm.CombinedOutput(); err != nil {
		t.Fatalf("helm-ssm: %v\n%s", err, out)
	}

	resolvedValues := filepath.Join(resolvedDir, "values.yaml")
	tmpl := exec.Command("helm", "template", "e2e", chartDir, "-f", resolvedValues)
	rendered, err := tmpl.CombinedOutput()
	if err != nil {
		t.Fatalf("helm template: %v\n%s", err, rendered)
	}
	for _, s := range seeds {
		if !strings.Contains(string(rendered), s.value) {
			t.Errorf("rendered manifest missing %q for %s (region=%s)", s.value, s.path, s.region)
		}
	}

	mu.Lock()
	regions := snapshotMap(callsPerRegion)
	ops := snapshotMap(callOps)
	total := callsTotal
	mu.Unlock()

	var totalParams, expectedBatched int
	regionList := make([]string, 0, len(paramsByRegion))
	for r, n := range paramsByRegion {
		totalParams += n
		expectedBatched += (n + 9) / 10
		regionList = append(regionList, r)
	}
	sort.Strings(regionList)

	t.Log("--- helm template e2e summary ---")
	t.Logf("Parameters: %d total across %d regions", totalParams, len(paramsByRegion))
	for _, r := range regionList {
		t.Logf("  region %s: %d params, %d API calls observed", r, paramsByRegion[r], regions[r])
	}
	for op, n := range ops {
		t.Logf("  operation %s: %d", op, n)
	}
	t.Logf("Total SSM API calls observed: %d", total)
	t.Logf("Sequential (one GetParameter per placeholder): %d", totalParams)
	t.Logf("Batched (≤10 GetParameters names per region):  %d", expectedBatched)

	if total != expectedBatched {
		t.Errorf("expected %d batched API calls (≤10 names per GetParameters call, grouped by region), observed %d", expectedBatched, total)
	}
	if got := ops["AmazonSSM.GetParameters"]; got != expectedBatched {
		t.Errorf("expected %d AmazonSSM.GetParameters calls, got %d (ops=%v)", expectedBatched, got, ops)
	}
	if got := ops["AmazonSSM.GetParameter"]; got != 0 {
		t.Errorf("expected zero singleton AmazonSSM.GetParameter calls under batching, got %d", got)
	}
	for _, r := range regionList {
		expectedForRegion := (paramsByRegion[r] + 9) / 10
		if regions[r] != expectedForRegion {
			t.Errorf("region %s: expected %d batched calls, got %d", r, expectedForRegion, regions[r])
		}
	}
}

func writeChart(t *testing.T, dir string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Join(dir, "templates"), 0755); err != nil {
		t.Fatalf("mkdir chart: %v", err)
	}
	const chart = "apiVersion: v2\nname: e2e\nversion: 0.0.1\n"
	if err := os.WriteFile(filepath.Join(dir, "Chart.yaml"), []byte(chart), 0644); err != nil {
		t.Fatalf("write Chart.yaml: %v", err)
	}
	const tmpl = `apiVersion: v1
kind: ConfigMap
metadata:
  name: e2e
data:
{{- range $k, $v := .Values.params }}
  {{ $k }}: {{ $v | quote }}
{{- end }}
`
	if err := os.WriteFile(filepath.Join(dir, "templates", "cm.yaml"), []byte(tmpl), 0644); err != nil {
		t.Fatalf("write template: %v", err)
	}
}

func buildValuesYAML(seeds []seed) string {
	sort.Slice(seeds, func(i, j int) bool { return seeds[i].path < seeds[j].path })
	var b strings.Builder
	b.WriteString("params:\n")
	for i, s := range seeds {
		b.WriteString(fmt.Sprintf("  k%03d: {{ssm %q %q }}\n", i, s.path, "region="+s.region))
	}
	return b.String()
}

func awsCleanEnv(overrides map[string]string) []string {
	src := os.Environ()
	out := make([]string, 0, len(src)+len(overrides))
	for _, kv := range src {
		key := kv
		if i := strings.IndexByte(kv, '='); i >= 0 {
			key = kv[:i]
		}
		if strings.HasPrefix(key, "AWS_") {
			continue
		}
		out = append(out, kv)
	}
	for k, v := range overrides {
		out = append(out, k+"="+v)
	}
	return out
}

func snapshotMap(m map[string]int) map[string]int {
	cp := make(map[string]int, len(m))
	for k, v := range m {
		cp[k] = v
	}
	return cp
}
