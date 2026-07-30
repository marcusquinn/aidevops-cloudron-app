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

main() {
	jq -e '.manifestVersion == 2 and .version == "0.1.7" and .upstreamVersion == "3.32.189" and .minBoxVersion == "9.1.0" and .iconUrl != "" and .packagerName != "" and .packagerUrl == "https://github.com/marcusquinn" and (has("packageUrl") | not) and (.mediaLinks | length) > 0 and .changelog == "file://CHANGELOG"' \
		"${ROOT_DIR}/CloudronManifest.json" >/dev/null || fail "Manifest version contract failed" || return 1
	[[ -f "${ROOT_DIR}/CloudronVersions.json" ]] || fail "CloudronVersions.json is missing" || return 1
	[[ -f "${ROOT_DIR}/PUBLISHING.md" ]] || fail "PUBLISHING.md is missing" || return 1
	[[ -f "${ROOT_DIR}/media/hero.png" ]] || fail "media/hero.png is missing" || return 1
	jq -e '.stable == true and (.versions | type == "object")' "${ROOT_DIR}/CloudronVersions.json" >/dev/null || fail "Version catalog contract failed" || return 1
	jq -e '[.versions[].manifest | has("packageUrl")] | all(. == false)' "${ROOT_DIR}/CloudronVersions.json" >/dev/null || fail "Historical catalog entries must not use Cloudron-10-only packageUrl" || return 1
	assert_contains CHANGELOG '* Update the bundled aidevops CLI to 3.32.189.' || return 1
	assert_contains CHANGELOG.md "- Updated and pinned the bundled aidevops CLI to \`3.32.189\`." || return 1
	assert_contains PUBLISHING.md 'is standing authorization for the managed publication' || return 1
	assert_contains PUBLISHING.md 'ghcr.io/marcusquinn/aidevops-cloudron-worker' || return 1
	jq -e '.versions["0.1.3"].publishState == "published"' "${ROOT_DIR}/CloudronVersions.json" >/dev/null || fail "Published catalog state contract failed" || return 1
	assert_contains Dockerfile 'cloudron/base:5.0.0@sha256:04fd70dbd8ad6149c19de39e35718e024417c3e01dc9c6637eaf4a41ec4e596c' || return 1
	assert_contains Dockerfile 'LABEL org.opencontainers.image.source="https://github.com/marcusquinn/aidevops-cloudron-app"' || return 1
	assert_contains Dockerfile '    ripgrep' || return 1
	assert_contains Dockerfile 'ARG OPENCODE_VERSION=1.18.4' || return 1
	assert_contains Dockerfile 'ARG AIDEVOPS_VERSION=3.32.189' || return 1
	assert_contains Dockerfile "releases/download/v\${OPENCODE_VERSION}/opencode-linux-x64.tar.gz" || return 1
	assert_contains Dockerfile "npm install -g \"aidevops@\${AIDEVOPS_VERSION}\"" || return 1
	if grep -Eq '/releases/latest([/?#]|$)' "${ROOT_DIR}/Dockerfile"; then
		fail "Dockerfile contains a moving latest release download" || return 1
	fi
	assert_contains .github/workflows/cloudron-package-release.yml "- 'v*'" || return 1
	assert_contains .github/workflows/cloudron-package-release.yml 'uses: marcusquinn/aidevops/.github/workflows/cloudron-package-release-reusable.yml@22a6b4b29087ce2fcf3857596a40ff7b2c436482' || return 1
	assert_contains .github/workflows/cloudron-package-release.yml 'aidevops_ref: 22a6b4b29087ce2fcf3857596a40ff7b2c436482' || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml 'IMAGE_REPOSITORY: ghcr.io/marcusquinn/aidevops-cloudron-worker' || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml 'pull_request:' || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml "github.event_name != 'pull_request'" || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml 'Require trusted publication source' || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml 'EXPECTED_REF: refs/heads/main' || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml 'attestations: write' || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml 'scripts/publish-cloudron-catalog.sh' || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml ".versions[\$version].manifest.dockerImage" || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml 'persist-credentials: false' || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml 'Verify the build source stayed immutable' || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml 'Verify anonymous registry visibility' || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml 'Verify existing immutable image is anonymously pullable' || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml "docker buildx imagetools inspect \"\${EXPECTED_IMAGE_REF}\"" || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml "docker buildx imagetools inspect \"\${IMMUTABLE_REF}\"" || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml "git push --atomic origin HEAD:main \"v\${RELEASE_VERSION}\"" || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml 'Reconcile GitHub release' || return 1
	assert_contains .github/workflows/cloudron-catalog-publish.yml "git show \"v\${RELEASE_VERSION}:CloudronVersions.json\"" || return 1
	if grep -Fq 'git push origin HEAD:main' "${ROOT_DIR}/.github/workflows/cloudron-catalog-publish.yml"; then
		fail "Release workflow publishes the catalog and tag non-atomically" || return 1
	fi
	if grep -Fq 'include-hidden-files: true' "${ROOT_DIR}/.github/workflows/cloudron-catalog-publish.yml"; then
		fail "Release workflow uploads hidden checkout credentials" || return 1
	fi
	assert_contains .github/workflows/cloudron-catalog-publish.yml "git diff --exit-code \"\${before_sha}\" -- CloudronManifest.json CHANGELOG CHANGELOG.md" || return 1
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
