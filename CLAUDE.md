# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

A Helm 3 plugin (`helm ssm`) that pre-processes Helm values files, replacing `{{ssm "path" "option=value" }}` placeholders with values fetched from AWS SSM Parameter Store. The Sprig template function library is also available inside the templated values files.

Helm 2 is no longer supported (last supporting release was v2.2.1).

## Commands

```sh
make build              # go build → bin/helm-ssm
make test               # unit tests (./internal)
make test-integration   # integration tests against LocalStack (requires LOCALSTACK_ENDPOINT env var)
make dist               # cross-compile linux amd64/arm64, macos amd64, windows amd64 tarballs into _dist/
make install            # builds dist tarballs, then unpacks the host-OS tarball into $HELM_PLUGINS/helm-ssm
```

Run a single test:

```sh
go test -v ./internal -run TestGetSSMParameter
```

Run integration tests locally:

```sh
docker run -d --name ls -p 4576:4566 -e SERVICES=ssm localstack/localstack:3.8.1
LOCALSTACK_ENDPOINT=http://localhost:4576 make test-integration
docker rm -f ls
```

The integration tests live under `internal/integration/` behind a `//go:build integration` tag, so they're invisible to plain `go test ./...` and skip cleanly when `LOCALSTACK_ENDPOINT` is unset. They drive `ExecuteTemplate` and `GetSSMParameter` against a real SSM API surface (LocalStack). The hook that points the production session at LocalStack is the `AWS_ENDPOINT_URL_SSM` env var (matching aws-sdk-go-v2's native convention) — `internal/template.go::endpointOverride`.

`make dist` rewrites the `version:` field in `plugin.yaml` from `.version` as a side effect — don't be surprised if `plugin.yaml` shows up dirty after running it.

## Architecture

Two packages, deliberately tiny:

- `cmd/main.go` — Cobra CLI. Parses flags, iterates the `-f/--values` list, and for each file calls `hssm.ExecuteTemplate` then writes the result back (or to `--target-dir`). Exits non-zero on the first failure.
- `internal/` (package `hssm`) — the template engine and SSM client.
  - `template.go::GetFuncMap` builds the `text/template` FuncMap. It starts from `sprig.GenericFuncMap()` and adds an `ssm` function that closes over a single AWS session. The `--clean` flag swaps every function (Sprig included) for one that returns the `--tag-cleaned` string — used to strip templating from a file rather than resolve it.
  - The `ssm` template function injects the global `--prefix` flag only when the per-call options don't already include a `prefix=` option. Per-call `prefix=` wins.
  - `template.go::resolveSSMParameter` parses the option list (`default=`, `region=`, `prefix=`, `required=`), creates a region-specific `ssm.New` client when `region=` is given, and concatenates `prefix + ssmPath` before lookup.
  - `ssm.go::GetSSMParameter` validates the parameter name against `[a-zA-Z0-9\.\-_/]*`, calls `GetParameter` with `WithDecryption=true`, and falls back to `defaultValue` only on `ParameterNotFound`. Any other AWS error propagates.
  - AWS auth uses `session.SharedConfigEnable` plus the `--profile` flag — standard AWS credential chain otherwise.

Tests in `internal/ssm_test.go` use a hand-rolled `ssmiface.SSMAPI` mock with a fake parameter store map; there is no testify mock framework. `template_test.go` covers template execution.

## Plugin packaging

`plugin.yaml` is the Helm plugin manifest; `command:` points at `$HELM_PLUGIN_DIR/helm-ssm`. `install-binary.sh` is the install hook Helm runs when a user does `helm plugin add` — it pulls the latest release tarball for the host OS/arch from GitHub. `.version` holds the version string baked into the binary via `-ldflags "-X main.version=$VERSION"` and into `plugin.yaml` by `make dist`.
