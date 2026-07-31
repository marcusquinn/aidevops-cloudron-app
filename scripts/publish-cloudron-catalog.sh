#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

set -euo pipefail

fail() {
	local message="$1"
	printf 'ERROR: %s\n' "$message" >&2
	return 1
}

resolve_version_key() {
	local catalog_path="$1"
	local expected_version="$2"
	local image_ref="$3"
	local matching_keys=""
	local key_count=""
	local manifest_version=""

	matching_keys="$(jq -r --arg image "$image_ref" '[.versions | to_entries[] | select(.value.manifest.dockerImage == $image) | .key] | .[]' "$catalog_path")" || return 1
	key_count="$(printf '%s\n' "$matching_keys" | awk 'NF { count += 1 } END { print count + 0 }')"
	[[ "$key_count" == "1" ]] || fail "Expected exactly one generated catalog entry for ${image_ref}, found ${key_count}" || return 1
	[[ "$matching_keys" == "$expected_version" ]] || fail "Generated catalog key ${matching_keys} does not match expected version ${expected_version}" || return 1

	manifest_version="$(jq -r --arg version "$expected_version" '.versions[$version].manifest.version // empty' "$catalog_path")" || return 1
	[[ "$manifest_version" == "$expected_version" ]] || fail "Generated manifest version ${manifest_version:-<missing>} does not match ${expected_version}" || return 1

	printf '%s\n' "$matching_keys"
	return 0
}

verify_entry() {
	local catalog_path="$1"
	local expected_version="$2"
	local expected_state="$3"
	local expected_image="$4"
	local catalog_image=""
	local catalog_state=""

	catalog_image="$(jq -r --arg version "$expected_version" '.versions[$version].manifest.dockerImage // empty' "$catalog_path")" || return 1
	catalog_state="$(jq -r --arg version "$expected_version" '.versions[$version].publishState // empty' "$catalog_path")" || return 1

	[[ "$catalog_image" == "$expected_image" ]] || fail "Catalog image ${catalog_image:-<missing>} does not match ${expected_image}" || return 1
	[[ "$catalog_state" == "$expected_state" ]] || fail "Catalog state ${catalog_state:-<missing>} does not match ${expected_state}" || return 1
	return 0
}

main() {
	local catalog_path="${1:-CloudronVersions.json}"
	local image_ref="${2:-${EXPECTED_IMAGE_REF:-}}"
	local expected_version="${3:-${EXPECTED_VERSION:-}}"
	local generated_key=""

	[[ -f "$catalog_path" ]] || fail "Catalog not found: ${catalog_path}" || return 1
	[[ "$catalog_path" == "CloudronVersions.json" ]] || fail "Cloudron CLI 8.2.6 requires the catalog path CloudronVersions.json" || return 1
	[[ -n "$image_ref" ]] || fail "An immutable image reference is required" || return 1
	[[ "$image_ref" == *@sha256:* ]] || fail "Image reference must use an immutable sha256 digest" || return 1
	[[ -n "$expected_version" ]] || fail "An expected package version is required" || return 1
	[[ "$(jq -r '.version // empty' CloudronManifest.json)" == "$expected_version" ]] || fail "CloudronManifest.json version does not match ${expected_version}" || return 1
	if jq -e --arg version "$expected_version" '.versions[$version] != null' "$catalog_path" >/dev/null; then
		fail "Catalog already contains version ${expected_version}" || return 1
	fi

	cloudron versions add --state testing --image "$image_ref"
	generated_key="$(resolve_version_key "$catalog_path" "$expected_version" "$image_ref")" || return 1
	verify_entry "$catalog_path" "$generated_key" testing "$image_ref" || return 1
	cloudron versions update --version="$generated_key" --state=published --image "$image_ref"
	verify_entry "$catalog_path" "$generated_key" published "$image_ref" || return 1
	cloudron versions verify
	return 0
}

main "$@"
