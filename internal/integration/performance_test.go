//go:build integration

package integration

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	hssm "github.com/codacy/helm-ssm/internal"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/service/ssm"
)

// TestPerformance_TemplateRenderScalesLinearly times ExecuteTemplate against an
// increasing number of {{ssm}} references. Each placeholder triggers a separate
// GetParameter round-trip — wall time should grow ~linearly with N. LocalStack
// RTT is much lower than real AWS (sub-ms vs 50-200 ms), so absolute numbers
// here are not predictive of production; the slope is.
func TestPerformance_TemplateRenderScalesLinearly(t *testing.T) {
	endpoint := requireLocalstack(t)
	client := newSeederClient(t, endpoint)

	counts := []int{1, 5, 10, 20}
	results := make(map[int]time.Duration, len(counts))

	for _, n := range counts {
		var lines []string
		for i := 0; i < n; i++ {
			name := fmt.Sprintf("/perf/seq-%d/p%d", n, i)
			putParameter(t, client, name, fmt.Sprintf("v%d", i), ssm.ParameterTypeString)
			lines = append(lines, fmt.Sprintf("  k%d: {{ssm \"%s\" }}", i, name))
		}
		body := "values:\n" + strings.Join(lines, "\n") + "\n"
		path := filepath.Join(t.TempDir(), fmt.Sprintf("values-%d.yaml", n))
		if err := os.WriteFile(path, []byte(body), 0644); err != nil {
			t.Fatalf("write fixture: %v", err)
		}

		funcMap := hssm.GetFuncMap("", "", false, "")
		start := time.Now()
		if _, err := hssm.ExecuteTemplate(path, funcMap, false); err != nil {
			t.Fatalf("ExecuteTemplate(%d): %v", n, err)
		}
		results[n] = time.Since(start)
	}

	t.Log("ExecuteTemplate latency (sequential GetParameter calls against LocalStack):")
	for _, n := range counts {
		perCall := float64(results[n].Microseconds()) / float64(n) / 1000.0
		t.Logf("  %2d params → %8s total  (%.2f ms/param)", n, results[n].Round(time.Millisecond), perCall)
	}
}

// TestPerformance_BatchedVsSequential compares the current per-call GetParameter
// path with the SSM GetParameters batch API (up to 10 names per call). This is
// the speedup a batch-fetch refactor would deliver.
func TestPerformance_BatchedVsSequential(t *testing.T) {
	endpoint := requireLocalstack(t)
	client := newSeederClient(t, endpoint)

	const n = 20
	names := make([]string, n)
	for i := 0; i < n; i++ {
		name := fmt.Sprintf("/perf/batch/p%d", i)
		names[i] = name
		putParameter(t, client, name, fmt.Sprintf("v%d", i), ssm.ParameterTypeString)
	}

	// Sequential — what the plugin does today.
	start := time.Now()
	for _, name := range names {
		if _, err := hssm.GetSSMParameter(client, name, nil, false); err != nil {
			t.Fatalf("sequential GetSSMParameter: %v", err)
		}
	}
	sequential := time.Since(start)

	// Batched — GetParameters with up to 10 names per call.
	decrypt := true
	start = time.Now()
	for i := 0; i < n; i += 10 {
		end := i + 10
		if end > n {
			end = n
		}
		out, err := client.GetParameters(&ssm.GetParametersInput{
			Names:          aws.StringSlice(names[i:end]),
			WithDecryption: &decrypt,
		})
		if err != nil {
			t.Fatalf("batched GetParameters: %v", err)
		}
		if len(out.Parameters) != end-i {
			t.Fatalf("batch %d-%d: expected %d params, got %d", i, end, end-i, len(out.Parameters))
		}
	}
	batched := time.Since(start)

	speedup := float64(sequential) / float64(batched)
	t.Logf("Sequential GetParameter ×%d: %s", n, sequential.Round(time.Millisecond))
	t.Logf("Batched GetParameters (≤10/call): %s", batched.Round(time.Millisecond))
	t.Logf("Speedup: %.1fx", speedup)
}
