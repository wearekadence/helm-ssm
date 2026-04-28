package hssm

import (
	"bytes"
	"fmt"
	"io/ioutil"
	"os"
	"strings"
	"text/template"

	"github.com/Masterminds/sprig"
	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/ssm"
	"github.com/aws/aws-sdk-go/service/ssm/ssmiface"
)

// endpointOverride matches the env-var convention used by aws-sdk-go-v2 so the same
// override works after a future SDK upgrade. Unset in normal use; set to a LocalStack
// URL during integration tests.
func endpointOverride() string {
	if e := os.Getenv("AWS_ENDPOINT_URL_SSM"); e != "" {
		return e
	}
	return os.Getenv("AWS_ENDPOINT_URL")
}

// WriteFileD dumps a given content on the file with path `targetDir/fileName`.
func WriteFileD(fileName string, targetDir string, content string) error {
	targetFilePath := targetDir + "/" + fileName
	_ = os.Mkdir(targetDir, os.ModePerm)
	return WriteFile(targetFilePath, content)
}

// WriteFile dumps a given content on the file with path `targetFilePath`.
func WriteFile(targetFilePath string, content string) error {
	return ioutil.WriteFile(targetFilePath, []byte(content), 0777)
}

// ExecuteTemplate loads a template file, executes is against a given function map and writes the output
func ExecuteTemplate(sourceFilePath string, funcMap template.FuncMap, verbose bool) (string, error) {
	fileContent, err := ioutil.ReadFile(sourceFilePath)
	if err != nil {
		return "", err
	}
	return renderTemplate(string(fileContent), funcMap, verbose)
}

// ExecuteTemplateWithBatching renders the template at sourceFilePath in two
// passes. The first pass runs against a func map whose `ssm` is a stub that
// records every (path, region) it sees and returns an empty string; the
// rendered output is discarded. Recorded paths are then resolved via
// ssm:GetParameters in batches of up to ten names, grouped by region. The
// second pass renders the real output using a func map whose `ssm` looks up
// the resolved value from the cache. When clean is true, no AWS calls are
// made and the function falls back to a single-pass render with the cleaning
// func map.
func ExecuteTemplateWithBatching(sourceFilePath, profile, prefix, tagCleaned string, clean, verbose bool) (string, error) {
	fileContent, err := ioutil.ReadFile(sourceFilePath)
	if err != nil {
		return "", err
	}
	if clean {
		return renderTemplate(string(fileContent), GetFuncMap(profile, prefix, true, tagCleaned), verbose)
	}

	defaults := map[ssmKey]string{}
	calls := map[ssmKey]bool{}
	discoveryMap := sprigFuncMap()
	discoveryMap["ssm"] = func(ssmPath string, options ...string) (string, error) {
		opts, err := handleOptions(applyDefaultPrefix(options, prefix))
		if err != nil {
			return "", err
		}
		key := ssmKey{path: opts["prefix"] + ssmPath, region: opts["region"]}
		if !calls[key] {
			calls[key] = true
			if d, ok := opts["default"]; ok {
				defaults[key] = d
			}
		}
		return "", nil
	}
	if _, err := renderTemplate(string(fileContent), discoveryMap, false); err != nil {
		return "", err
	}

	resolved, err := resolveBatched(newAWSSession(profile), calls, defaults)
	if err != nil {
		return "", err
	}

	renderMap := sprigFuncMap()
	renderMap["ssm"] = func(ssmPath string, options ...string) (string, error) {
		opts, err := handleOptions(applyDefaultPrefix(options, prefix))
		if err != nil {
			return "", err
		}
		key := ssmKey{path: opts["prefix"] + ssmPath, region: opts["region"]}
		v, ok := resolved[key]
		if !ok {
			return "", fmt.Errorf("internal: %q (region=%q) not pre-resolved", key.path, key.region)
		}
		return v, nil
	}
	return renderTemplate(string(fileContent), renderMap, verbose)
}

// ssmKey identifies a unique parameter request by post-prefix path and region.
// Region "" means "use the session default region".
type ssmKey struct {
	path   string
	region string
}

func renderTemplate(content string, funcMap template.FuncMap, verbose bool) (string, error) {
	t := template.New("ssmtpl").Funcs(funcMap)
	if _, err := t.Parse(content); err != nil {
		return "", err
	}
	var buf bytes.Buffer
	if err := t.Execute(&buf, map[string]interface{}{}); err != nil {
		return "", err
	}
	if verbose {
		fmt.Println(buf.String())
	}
	return buf.String(), nil
}

func sprigFuncMap() template.FuncMap {
	fm := template.FuncMap{}
	for k, v := range sprig.GenericFuncMap() {
		fm[k] = v
	}
	return fm
}

func applyDefaultPrefix(options []string, prefix string) []string {
	for _, s := range options {
		if strings.HasPrefix(s, "prefix=") {
			return options
		}
	}
	return append(options, "prefix="+prefix)
}

// resolveBatched fetches every recorded (path, region) tuple via
// ssm:GetParameters, grouped by region and chunked at ten names per call (the
// SSM API limit). Missing parameters fall back to the recorded default; if no
// default was set, a not-found error propagates.
func resolveBatched(sess *session.Session, calls map[ssmKey]bool, defaults map[ssmKey]string) (map[ssmKey]string, error) {
	resolved := map[ssmKey]string{}
	if len(calls) == 0 {
		return resolved, nil
	}

	byRegion := map[string][]ssmKey{}
	for k := range calls {
		byRegion[k.region] = append(byRegion[k.region], k)
	}

	decrypt := true
	for region, keys := range byRegion {
		var svc ssmiface.SSMAPI
		if region != "" {
			svc = ssm.New(sess, aws.NewConfig().WithRegion(region))
		} else {
			svc = ssm.New(sess)
		}
		const batchSize = 10
		for i := 0; i < len(keys); i += batchSize {
			end := i + batchSize
			if end > len(keys) {
				end = len(keys)
			}
			chunk := keys[i:end]
			names := make([]string, len(chunk))
			byName := make(map[string]ssmKey, len(chunk))
			for j, k := range chunk {
				names[j] = k.path
				byName[k.path] = k
			}
			out, err := svc.GetParameters(&ssm.GetParametersInput{
				Names:          aws.StringSlice(names),
				WithDecryption: &decrypt,
			})
			if err != nil {
				return nil, err
			}
			for _, p := range out.Parameters {
				k := byName[aws.StringValue(p.Name)]
				resolved[k] = aws.StringValue(p.Value)
			}
			for _, name := range out.InvalidParameters {
				k := byName[aws.StringValue(name)]
				if d, ok := defaults[k]; ok {
					resolved[k] = d
					continue
				}
				return nil, fmt.Errorf("ParameterNotFound: %s (region=%q)", k.path, k.region)
			}
		}
	}
	return resolved, nil
}

// GetFuncMap builds the relevant function map to helm_ssm
func GetFuncMap(profile string, prefix string, clean bool, tagCleaned string) template.FuncMap {

	cleanFunc := func(...interface{}) (string, error) {
		return tagCleaned, nil
	}
	// Clone the func map because we are adding context-specific functions.
	var funcMap template.FuncMap = map[string]interface{}{}
	for k, v := range sprig.GenericFuncMap() {
		if clean {
			funcMap[k] = cleanFunc
		} else {
			funcMap[k] = v
		}
	}

	awsSession := newAWSSession(profile)
	if clean {
		funcMap["ssm"] = cleanFunc
	} else {
		funcMap["ssm"] = func(ssmPath string, options ...string) (string, error) {
			var hasPrefix = false
			for _, s := range options {
				if strings.HasPrefix(s, "prefix") {
					hasPrefix = true
				}
			}

			if !hasPrefix {
				options = append(options, fmt.Sprintf("prefix=%s", prefix))
			}

			optStr, err := resolveSSMParameter(awsSession, ssmPath, options)
			str := ""
			if optStr != nil {
				str = *optStr
			}
			return str, err
		}
	}
	return funcMap
}

func resolveSSMParameter(session *session.Session, ssmPath string, options []string) (*string, error) {
	opts, err := handleOptions(options)
	if err != nil {
		return nil, err
	}

	var defaultValue *string
	if optDefaultValue, exists := opts["default"]; exists {
		defaultValue = &optDefaultValue
	}

	var svc ssmiface.SSMAPI
	if region, exists := opts["region"]; exists {
		svc = ssm.New(session, aws.NewConfig().WithRegion(region))
	} else {
		svc = ssm.New(session)
	}

	return GetSSMParameter(svc, opts["prefix"]+ssmPath, defaultValue, true)
}

func handleOptions(options []string) (map[string]string, error) {
	validOptions := []string{
		"required",
		"prefix",
		"region",
	}
	opts := map[string]string{}
	for _, o := range options {
		split := strings.Split(o, "=")
		if len(split) != 2 {
			return nil, fmt.Errorf("Invalid option: %s. Valid options: %s", o, validOptions)
		}
		opts[split[0]] = split[1]
	}
	if _, exists := opts["required"]; !exists {
		opts["required"] = "true"
	}
	if _, exists := opts["prefix"]; !exists {
		opts["prefix"] = ""
	}
	return opts, nil
}

func newAWSSession(profile string) *session.Session {
	// Specify profile for config and region for requests
	opts := session.Options{
		SharedConfigState: session.SharedConfigEnable,
		Profile:           profile,
	}
	if endpoint := endpointOverride(); endpoint != "" {
		opts.Config = aws.Config{Endpoint: aws.String(endpoint)}
	}
	return session.Must(session.NewSessionWithOptions(opts))
}
