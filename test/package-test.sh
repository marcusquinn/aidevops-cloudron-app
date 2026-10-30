#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
ROOT_DIR="${TEST_DIR%/*}"

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	return 1
}

assert_contains() {
	local relative_path="$1"
	local expected="$2"
	grep -Fq -- "$expected" "${ROOT_DIR}/${relative_path}" || fail "${relative_path} is missing: ${expected}" || return 1
	return 0
}

assert_precedes() {
	local relative_path="$1"
	local first="$2"
	local second="$3"
	local first_line=""
	local second_line=""
	first_line="$(grep -nF -- "$first" "${ROOT_DIR}/${relative_path}" | cut -d: -f1)"
	second_line="$(grep -nF -- "$second" "${ROOT_DIR}/${relative_path}" | cut -d: -f1)"
	[[ -n "$first_line" && -n "$second_line" && "$first_line" -lt "$second_line" ]] || fail "${relative_path} must place ${first} before ${second}" || return 1
	return 0
}

main() {
	jq -e '.manifestVersion == 2 and .version == "0.1.40" and .upstreamVersion == "3.39.75" and .minBoxVersion == "9.1.0" and .iconUrl != "" and .packagerName != "" and .packagerUrl == "https://github.com/marcusquinn" and (has("packageUrl") | not) and (.mediaLinks | length) > 0 and .changelog == "file://CHANGELOG"' \
		"${ROOT_DIR}/CloudronManifest.json" >/dev/null || fail "Manifest version contract failed" || return 1
	[[ -f "${ROOT_DIR}/CloudronVersions.json" ]] || fail "CloudronVersions.json is missing" || return 1
	[[ -f "${ROOT_DIR}/PUBLISHING.md" ]] || fail "PUBLISHING.md is missing" || return 1
	[[ -f "${ROOT_DIR}/media/hero.png" ]] || fail "media/hero.png is missing" || return 1
	jq -e '.stable == true and (.versions | type == "object")' "${ROOT_DIR}/CloudronVersions.json" >/dev/null || fail "Version catalog contract failed" || return 1
	jq -e '[.versions[].manifest | has("packageUrl")] | all(. == false)' "${ROOT_DIR}/CloudronVersions.json" >/dev/null || fail "Historical catalog entries must not use Cloudron-10-only packageUrl" || return 1
	assert_contains CHANGELOG '[0.1.40]' || return 1
	assert_contains CHANGELOG '* Update the bundled aidevops CLI to 3.39.75.' || return 1
	assert_contains CHANGELOG.md '## [0.1.40]' || return 1
	assert_contains CHANGELOG.md "- Updated and pinned the bundled aidevops CLI to \`3.39.75\`." || return 1
	assert_contains PUBLISHING.md 'is standing authorization for the managed publication' || return 1
	assert_contains PUBLISHING.md 'ghcr.io/marcusquinn/aidevops-cloudron-worker' || return 1
	jq -e '.versions["0.1.3"].publishState == "published"' "${ROOT_DIR}/CloudronVersions.json" >/dev/null || fail "Published catalog state contract failed" || return 1
	assert_contains Dockerfile 'cloudron/base:6.0.1@sha256:7b1e729960c3ca312d26e886917ba89483241bba0219ff292858e10d9d5768ee' || return 1
	assert_contains Dockerfile 'LABEL org.opencontainers.image.source="https://github.com/marcusquinn/aidevops-cloudron-app"' || return 1
	assert_contains Dockerfile '    ripgrep' || return 1
	assert_contains Dockerfile 'ARG OPENCODE_VERSION=1.18.4' || return 1
	assert_contains Dockerfile 'ARG AIDEVOPS_VERSION=3.39.75' || return 1
	assert_contains Dockerfile "releases/download/v\${OPENCODE_VERSION}/opencode-linux-x64.tar.gz" || return 1
	assert_contains Dockerfile "npm install -g \"aidevops@\${AIDEVOPS_VERSION}\"" || return 1
	assert_contains Dockerfile "npm install -g \"aidevops@\${AIDEVOPS_VERSION}\" --allow-scripts=aidevops" || return 1
	assert_precedes Dockerfile 'npm install -g npm@11.21.1' "npm install -g \"aidevops@\${AIDEVOPS_VERSION}\"" || return 1
	if grep -Eq '/releases/latest([/?#]|$)' "${ROOT_DIR}/Dockerfile"; then
		fail "Dockerfile contains a moving latest release download" || return 1
	fi
	assert_contains .github/workflows/cloudron-package-release.yml "- 'v*'" || return 1
	assert_contains .github/workflows/cloudron-package-release.yml 'uses: marcusquinn/aidevops/.github/workflows/cloudron-package-release-reusable.yml@22a6b4b29087ce2fcf3857596a40ff7b2c436482' || return 1
	assert_contains .github/workflows/cloudron-package-release.yml 'aidevops_ref: 22a6b4b29087ce2fcf3857596a40ff7b2c436482' || return 1
	# Publisher implementation and provenance policy live in the pinned reusable workflow.
	# Keep this package's caller contract covered without asserting upstream inline steps.
	assert_contains .github/workflows/cloudron-catalog-publish.yml 'uses: marcusquinn/aidevops/.github/workflows/cloudron-catalog-publish-reusable.yml@4366037537f8a9aaf7f738a37465a6b1433dd6d5' || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml 'aidevops_ref: 4366037537f8a9aaf7f738a37465a6b1433dd6d5' || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml 'image_repository: ghcr.io/marcusquinn/aidevops-cloudron-worker' || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml 'pull_request:' || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml 'branches: [main]' || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml 'workflow_dispatch:' || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml 'attestations: write' || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml "cli_version: '8.2.6'" || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml 'cli_integrity: sha512-LHd+4u6pJxDtHX1JuVuWqrUuTbkDu+iH4jjNWW6JgB4+iDLusp08rpt6gifTFPbQjbCZHhnD8LbAGzM1NzDCXw==' || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml 'bash ./test/package-test.sh' || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml 'bash ./test/publish-catalog-test.sh' || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml "CLOUDRON_RELEASE_PAT: \${{ secrets.CLOUDRON_RELEASE_PAT }}" || return 1
	if grep -Eq '^[[:space:]]+(steps:|run:)|secrets: inherit' "${ROOT_DIR}/.github/workflows/cloudron-catalog-publish.yml"; then
		fail "Catalog caller must delegate implementation and map secrets explicitly" || return 1
	fi
	[[ "$(grep -Fc 'secrets.CLOUDRON_RELEASE_PAT' "${ROOT_DIR}/.github/workflows/cloudron-catalog-publish.yml")" -eq 1 ]] || fail "Release PAT must be mapped exactly once" || return 1
	if grep -Fq -- '--versions-file' "${ROOT_DIR}/scripts/publish-cloudron-catalog.sh"; then
		fail "Publisher uses unsupported Cloudron CLI --versions-file option" || return 1
	fi
	bash "${ROOT_DIR}/test/publish-catalog-test.sh" || return 1
	bash -n "${ROOT_DIR}/start.sh"
	shellcheck "${ROOT_DIR}/test/package-test.sh" "${ROOT_DIR}/test/publish-catalog-test.sh" "${ROOT_DIR}/scripts/publish-cloudron-catalog.sh"
	printf 'PASS: deterministic Cloudron package and publishing lifecycle contract\n'
	return 0
}

main "$@"
