#!/usr/bin/env bash
set -Eeuo pipefail

image="${GITHUB_REPOSITORY##*/}" # "python", "golang", etc

[ -x ./generate-stackbrew-library.sh ] # sanity check

tmp="$(mktemp -d)"
trap "$(printf 'rm -rf %q' "$tmp")" EXIT

# just to be safe
unset "${!BASHBREW_@}"

if ! command -v bashbrew &> /dev/null; then
	echo 'Downloading bahbrew ...'
	mkdir "$tmp/bin"
	wget -qO "$tmp/bin/bashbrew" 'https://doi-janky.infosiftr.net/job/bashbrew/lastSuccessfulBuild/artifact/bin/bashbrew-amd64'
	chmod +x "$tmp/bin/bashbrew"
	export PATH="$tmp/bin:$PATH"
	bashbrew --help > /dev/null
fi

mkdir "$tmp/library"
export BASHBREW_LIBRARY="$tmp/library"

./generate-stackbrew-library.sh > "$BASHBREW_LIBRARY/$image"

tags="$(bashbrew list --build-order --uniq "$image")"

order=()
declare -A metas=()
for tag in $tags; do
	echo "Processing $tag ..."
	meta="$(
		bashbrew cat --format '
			{{- $e := .TagEntry -}}
			{{- "{" -}}
				"name": {{- json ($e.Tags | first) -}},
				"tags": {{- json ($.Tags "" false $e) -}},
				"directory": {{- json $e.Directory -}},
				"file": {{- json $e.File -}},
				"constraints": {{- json $e.Constraints -}}
			{{- "}" -}}
		' "$tag" | jq -c '
			{
				name: .name,
				os: (
					if (.constraints | contains(["windowsservercore-1809"])) or (.constraints | contains(["nanoserver-1809"])) then
						"windows-2019"
					elif .constraints | contains(["windowsservercore-ltsc2016"]) then
						"windows-2016"
					elif .constraints == [] or .constraints == ["aufs"] then
						"ubuntu-latest"
					else
						# use an intentionally invalid value so that GitHub chokes and we notice something is wrong
						"invalid-or-unknown"
					end
				),
				steps: [
					{
						name: ("Build " + .tags[0]),
						run: (
							[
								"docker build"
							]
							+ (
								.tags
								| map(
									"--tag " + (. | @sh)
								)
							)
							+ if .file != "Dockerfile" then
								[ "--file", (.file | @sh) ]
							else
								[]
							end
							+ [
								"--pull",
								(.directory | @sh)
							]
							| join(" ")
						)
					},
					{
						name: ("History " + .tags[0]),
						run: ("docker history " + (.tags[0] | @sh))
					},
					{
						name: ("Test " + .tags[0]),
						run: ("~/oi/test/run.sh " + (.tags[0] | @sh))
					}
				]
			}
		'
	)"

	parent="$(bashbrew parents "$tag" | tail -1)" # if there ever exists an image with TWO parents in the same repo, this will break :)
	if [ -n "$parent" ]; then
		parent="$(bashbrew list --uniq "$parent")" # normalize
		parentMeta="${metas["$parent"]}"
		parentMeta="$(jq -c --argjson meta "$meta" '.steps += $meta.steps | .name += ", " + $meta.name' <<<"$parentMeta")"
		metas["$parent"]="$parentMeta"
	else
		metas["$tag"]="$meta"
		order+=( "$tag" )
	fi
done

strategy="$(
	for tag in "${order[@]}"; do
		jq -c '.name' <<<"${metas["$tag"]}"
	done | jq -cs '
		{
			"fail-fast": false,
			matrix: { name: . }
		}
	'
)"
meta="$(
	for tag in "${order[@]}"; do
		jq -c '
			.defaults = {
				run: {
					shell: "bash -Eeuo pipefail -x {0}"
				}
			}
			| .steps = [
				{ uses: "actions/checkout@v1" },
				{
					name: "Prepare Environment",
					run: ([
						"git clone --depth 1 https://github.com/docker-library/official-images.git ~/oi",
						".github/workflows/prune.sh" # TODO move this to oi
					] | join("\n"))
				}
			]
			+ (
				if .os | startswith("windows-") then
					[]
				else
					[
						{
							name: "PGP Happy Eyeballs",
							run: ([
								"git clone --depth 1 https://github.com/tianon/pgp-happy-eyeballs.git ~/phe",
								"~/phe/hack-my-builds.sh",
								"rm -rf ~/phe"
							] | join("\n"))
						}
					]
				end
			)
			+ .steps
			+ [
				{
					name: "\"docker images\"",
					run: "docker images"
				}
			]
			| { (.name) : . }
		' <<<"${metas["$tag"]}"
	done | jq -cs 'add'
)"

if [ "${GITHUB_ACTIONS:-}" = 'true' ]; then
	echo "::set-output name=strategy::$strategy"
	echo "::set-output name=meta::$meta"
else
	jq <<<"$meta"
	jq <<<"$strategy"
fi
