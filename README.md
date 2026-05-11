# helm-ssm
A low-dependency tool used to retrieves and injects secrets from AWS SSM Parameter Store.

## Installation
```bash
$ helm plugin install https://github.com/wearekadence/helm-ssm
```

## Overview
This plugin provides the ability to encode AWS SSM parameter paths into your
value files to store in version control or just generally less secure places.

During installation or upgrade, the parameters are replaced with their actual values
and passed on to Helm

Usage:
Simply use helm as you would normally, but add 'ssm' before any command,
the plugin will automatically search for values with the pattern:
```
{{ssm /path/to/parameter aws-region}}
```
and replace them with their decrypted value.
>Note: You must have IAM access to the parameters you're trying to decrypt, and their KMS key.

>Note #2: Wrap the template with quotes, otherwise helm will confuse the brackets for json, and will fail rendering.

>Note #3: Currently, helm-ssm does not work when the value of the parameter is in the default chart values.

E.g:
```bash
$ helm ssm install stable/docker-registry --values value-file1.yaml -f value-file2.yaml
```

value-file1.yaml:
```
secrets:
  haSharedSecret: "{{ssm /mgmt/docker-registry/shared-secret us-east-1}}"
  htpasswd: "{{ssm /mgmt/docker-registry/htpasswd us-east-1}}"
```


##Using a Prefix
If your SSM parameters have a preset you can specify it at run time using the -p or --prefix flags followed by a string

E.g:
helm ssm install stable/docker-registry --values value-file1.yaml -f value-file2.yaml -p "/some/prefix/path"

##Overriding the region
If your wantr to globally override the region setting given in each param string you can specify it at run time using 
the -r or --region flags followed by a region string e.g. eu-west-1

E.g:
helm ssm install stable/docker-registry --values value-file1.yaml -f value-file2.yaml -p "/some/prefix/path" -r "eu-west-1"

## Optional parameters
Append the literal word `optional` to a placeholder to mark it as non-fatal. If the parameter does not exist in
SSM, the placeholder is replaced with an empty string and a warning is logged instead of aborting the run.

```
secrets:
  required:    "{{ssm /always/present us-east-1}}"
  maybe:       "{{ssm /maybe/missing us-east-1 optional}}"
```

Works with the global `-r/--region` flag too — drop the region from the placeholder:
```
secrets:
  maybe: "{{ssm /maybe/missing optional}}"
```
```
helm ssm install ... -r "eu-west-1"
```

## Testing
```
$ ./ssm.sh install tests/testchart/ --debug --dry-run -f tests/testchart/values.yaml
```

## Releasing
Bump the `version:` field in `plugin.yaml` as part of your feature PR. On merge to
`master`, `.github/workflows/release.yml` reads that field and creates a matching
`v<version>` git tag + GitHub release if one does not already exist. Forgetting to
bump simply means no new release — never a CI failure.

Consumers (e.g. ami-packer, docker-images) pin by commit SHA today; once tags are
in place they may pin by tag instead (`helm plugin install ... --version vX.Y.Z`).
