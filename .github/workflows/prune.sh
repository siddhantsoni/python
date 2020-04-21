#!/usr/bin/env bash
set -Eeuo pipefail

docker container prune --force
docker volume prune --force

# rmi everything minus a whitelist so this can be kinder on Windows (where base images are large and take time to clone)
images="$(
	docker image ls --no-trunc --digests --format '
		{{- $hasTag := ne .Tag "<none>" -}}
		{{- $hasDigest := ne .Digest "<none>" -}}
		{{- if (or $hasTag $hasDigest) -}}
			{{- .Repository -}}
			{{- if $hasTag -}}
				{{- ":" -}}
				{{- .Tag -}}
			{{- end -}}
			{{- if $hasDigest -}}
				{{- "@" -}}
				{{- .Digest -}}
			{{- end -}}
		{{- else -}}
			{{- .ID -}}
		{{- end -}}
	'
)"
grep -vE '^mcr[.]microsoft[.]com/windows(/[^:@]+)?:' <<<"$images" | xargs -rt echo docker image rm
