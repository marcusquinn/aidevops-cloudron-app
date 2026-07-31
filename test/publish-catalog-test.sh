#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
ROOT_DIR="${TEST_DIR%/*}"
TMP_ROOT=""

cleanup() {
	local status="$?"
	if [[ -n "$TMP_ROOT" && -d "$TMP_ROOT" ]]; then
		rm -rf "$TMP_ROOT"
	fi
	return "$status"
}

trap cleanup EXIT

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	return 1
}

make_fixture() {
	local fixture_name="$1"
	local fixture_dir="${TMP_ROOT}/${fixture_name}"
	local initial_version="${2:-0.1.3}"

	mkdir -p "${fixture_dir}/bin"
	cp "${ROOT_DIR}/scripts/publish-cloudron-catalog.sh" "${fixture_dir}/publish-cloudron-catalog.sh"
	cat >"${fixture_dir}/CloudronManifest.json" <<JSON
{"version":"0.1.7","upstreamVersion":"3.32.189","manifestVersion":2}
JSON
	cat >"${fixture_dir}/CloudronVersions.json" <<JSON
{"stable":true,"versions":{"${initial_version}":{"manifest":{"version":"${initial_version}","dockerImage":"registry.example/worker@sha256:old"},"publishState":"published"}}}
JSON
	cat >"${fixture_dir}/bin/cloudron" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

[[ "${1:-}" == "versions" ]] || exit 2
subcommand="${2:-}"
shift 2
catalog="CloudronVersions.json"
image=""
version=""
state=""

for argument in "$@"; do
	case "$argument" in
		--image=*) image="${argument#*=}" ;;
		--image) ;;
		--version=*) version="${argument#*=}" ;;
		--state=*) state="${argument#*=}" ;;
		testing|published) state="$argument" ;;
		*)
			if [[ -z "$catalog" && "$argument" == *.json ]]; then
				catalog="$argument"
			elif [[ -z "$image" && "$argument" == *@sha256:* ]]; then
				image="$argument"
			fi
			;;
	esac
done

case "$subcommand" in
	add)
		manifest_version="$(jq -r '.version' CloudronManifest.json)"
		generated_key="${FAKE_GENERATED_KEY:-$manifest_version}"
		generated_manifest_version="${FAKE_MANIFEST_VERSION:-$manifest_version}"
		if [[ "$generated_manifest_version" == "__missing__" ]]; then
			generated_manifest="$(jq -cn --arg image "$image" '{dockerImage:$image}')"
		else
			generated_manifest="$(jq -cn --arg version "$generated_manifest_version" --arg image "$image" '{version:$version,dockerImage:$image}')"
		fi
		jq \
			--arg key "$generated_key" \
			--arg image "$image" \
			--arg state "${state:-testing}" \
			--argjson manifest "$generated_manifest" \
			'.versions[$key] = {manifest:$manifest,publishState:$state}' \
			"$catalog" >"${catalog}.tmp"
		if [[ -n "${FAKE_SECOND_GENERATED_KEY:-}" ]]; then
			jq \
				--arg key "$FAKE_SECOND_GENERATED_KEY" \
				--arg image "$image" \
				--arg state "${state:-testing}" \
				--argjson manifest "$generated_manifest" \
				'.versions[$key] = {manifest:$manifest,publishState:$state}' \
				"${catalog}.tmp" >"${catalog}.second"
			mv "${catalog}.second" "${catalog}.tmp"
		fi
		mv "${catalog}.tmp" "$catalog"
		;;
	update)
		if [[ -z "$image" ]]; then
			printf 'missing immutable image during update\n' >&2
			exit 8
		fi
		if [[ -n "${FAKE_EXPECT_UPDATE_VERSION:-}" && "$version" != "$FAKE_EXPECT_UPDATE_VERSION" ]]; then
			printf 'wrong update target: %s\n' "$version" >&2
			exit 9
		fi
		jq --arg version "$version" --arg state "$state" --arg image "$image" '.versions[$version].publishState = $state | .versions[$version].manifest.dockerImage = $image' "$catalog" >"${catalog}.tmp"
		mv "${catalog}.tmp" "$catalog"
		;;
	verify)
		jq -e '.stable == true and (.versions | type == "object")' "$catalog" >/dev/null
		;;
	*) exit 3 ;;
esac
STUB
	chmod +x "${fixture_dir}/bin/cloudron" "${fixture_dir}/publish-cloudron-catalog.sh"
	printf '%s\n' "$fixture_dir"
	return 0
}

assert_successful_publish() {
	local fixture_dir=""
	local image_ref="registry.example/worker@sha256:0123456789abcdef"
	fixture_dir="$(make_fixture success)" || return 1

	(
		cd "$fixture_dir" || exit 1
		PATH="${fixture_dir}/bin:${PATH}" \
			./publish-cloudron-catalog.sh CloudronVersions.json "$image_ref" 0.1.7
	)

	jq -e --arg image "$image_ref" \
		'.versions["0.1.7"].manifest.version == "0.1.7" and .versions["0.1.7"].manifest.dockerImage == $image and .versions["0.1.7"].publishState == "published"' \
		"${fixture_dir}/CloudronVersions.json" >/dev/null || fail "Successful publish did not create the verified published entry" || return 1
	return 0
}

assert_wrong_generated_key_fails() {
	local fixture_dir=""
	local output_file=""
	fixture_dir="$(make_fixture wrong-key)" || return 1
	output_file="${fixture_dir}/output.log"

	if (
		cd "$fixture_dir" || exit 1
		PATH="${fixture_dir}/bin:${PATH}" \
			FAKE_GENERATED_KEY="0.1.70" \
			./publish-cloudron-catalog.sh CloudronVersions.json registry.example/worker@sha256:wrong 0.1.7
	) >"$output_file" 2>&1; then
		fail "Publisher accepted a generated key that differed from the manifest version" || return 1
	fi
	grep -Fq 'does not match expected version 0.1.7' "$output_file" || fail "Wrong-key failure did not explain the mismatch" || return 1
	return 0
}

assert_missing_manifest_version_fails() {
	local fixture_dir=""
	local output_file=""
	fixture_dir="$(make_fixture missing-manifest-version)" || return 1
	output_file="${fixture_dir}/output.log"

	if (
		cd "$fixture_dir" || exit 1
		PATH="${fixture_dir}/bin:${PATH}" \
			FAKE_MANIFEST_VERSION="__missing__" \
			./publish-cloudron-catalog.sh CloudronVersions.json registry.example/worker@sha256:missing 0.1.7
	) >"$output_file" 2>&1; then
		fail "Publisher accepted an entry without manifest.version" || return 1
	fi
	grep -Fq 'Generated manifest version <missing> does not match 0.1.7' "$output_file" || fail "Missing manifest-version failure was not diagnostic" || return 1
	return 0
}

assert_no_generated_entry_fails() {
	local fixture_dir=""
	local output_file=""
	fixture_dir="$(make_fixture no-entry)" || return 1
	output_file="${fixture_dir}/output.log"

	if (
		cd "$fixture_dir" || exit 1
		PATH="${fixture_dir}/bin:${PATH}" \
			FAKE_GENERATED_KEY="0.1.70" \
			FAKE_MANIFEST_VERSION="0.1.70" \
			./publish-cloudron-catalog.sh CloudronVersions.json registry.example/worker@sha256:no-entry 0.1.7
	) >"$output_file" 2>&1; then
		fail "Publisher accepted a catalog without the expected key" || return 1
	fi
	grep -Fq 'does not match expected version 0.1.7' "$output_file" || fail "Missing-entry failure was not diagnostic" || return 1
	return 0
}

assert_multiple_generated_entries_fail() {
	local fixture_dir=""
	local output_file=""
	fixture_dir="$(make_fixture multiple-entries)" || return 1
	output_file="${fixture_dir}/output.log"

	if (
		cd "$fixture_dir" || exit 1
		PATH="${fixture_dir}/bin:${PATH}" \
			FAKE_SECOND_GENERATED_KEY="0.1.70" \
			./publish-cloudron-catalog.sh CloudronVersions.json registry.example/worker@sha256:multiple 0.1.7
	) >"$output_file" 2>&1; then
		fail "Publisher accepted multiple generated entries for one image" || return 1
	fi
	grep -Fq 'Expected exactly one generated catalog entry' "$output_file" || fail "Multiple-entry failure was not diagnostic" || return 1
	return 0
}

assert_update_targets_expected_version() {
	local fixture_dir=""
	fixture_dir="$(make_fixture update-target)" || return 1

	(
		cd "$fixture_dir" || exit 1
		PATH="${fixture_dir}/bin:${PATH}" \
			FAKE_EXPECT_UPDATE_VERSION="0.1.7" \
			./publish-cloudron-catalog.sh CloudronVersions.json registry.example/worker@sha256:update-target 0.1.7
	) || fail "Publisher did not promote the expected manifest version" || return 1
	return 0
}

assert_mutable_image_fails() {
	local fixture_dir=""
	local output_file=""
	fixture_dir="$(make_fixture mutable-image)" || return 1
	output_file="${fixture_dir}/output.log"

	if (
		cd "$fixture_dir" || exit 1
		PATH="${fixture_dir}/bin:${PATH}" \
			./publish-cloudron-catalog.sh CloudronVersions.json registry.example/worker:0.1.7 0.1.7
	) >"$output_file" 2>&1; then
		fail "Publisher accepted a mutable image tag" || return 1
	fi
	grep -Fq 'Image reference must use an immutable sha256 digest' "$output_file" || fail "Mutable-image failure was not diagnostic" || return 1
	return 0
}

assert_duplicate_version_fails() {
	local fixture_dir=""
	local output_file=""
	fixture_dir="$(make_fixture duplicate-version 0.1.7)" || return 1
	output_file="${fixture_dir}/output.log"

	if (
		cd "$fixture_dir" || exit 1
		PATH="${fixture_dir}/bin:${PATH}" \
			./publish-cloudron-catalog.sh CloudronVersions.json registry.example/worker@sha256:duplicate 0.1.7
	) >"$output_file" 2>&1; then
		fail "Publisher accepted a duplicate catalog version" || return 1
	fi
	grep -Fq 'Catalog already contains version 0.1.7' "$output_file" || fail "Duplicate-version failure was not diagnostic" || return 1
	return 0
}

assert_non_default_catalog_fails() {
	local fixture_dir=""
	local output_file=""
	fixture_dir="$(make_fixture non-default-catalog)" || return 1
	output_file="${fixture_dir}/output.log"
	cp "${fixture_dir}/CloudronVersions.json" "${fixture_dir}/AlternateVersions.json"

	if (
		cd "$fixture_dir" || exit 1
		PATH="${fixture_dir}/bin:${PATH}" \
			./publish-cloudron-catalog.sh AlternateVersions.json registry.example/worker@sha256:alternate 0.1.7
	) >"$output_file" 2>&1; then
		fail "Publisher accepted a catalog filename unsupported by Cloudron CLI 8.2.6" || return 1
	fi
	grep -Fq 'requires the catalog path CloudronVersions.json' "$output_file" || fail "Unsupported catalog-path failure was not diagnostic" || return 1
	return 0
}

main() {
	local temp_base="${AIDEVOPS_TEMP_DIR:-${TMPDIR:-/tmp}}"
	mkdir -p "$temp_base"
	TMP_ROOT="$(mktemp -d "${temp_base%/}/cloudron-catalog-test.XXXXXX")"
	assert_successful_publish || return 1
	assert_wrong_generated_key_fails || return 1
	assert_missing_manifest_version_fails || return 1
	assert_no_generated_entry_fails || return 1
	assert_multiple_generated_entries_fail || return 1
	assert_update_targets_expected_version || return 1
	assert_mutable_image_fails || return 1
	assert_duplicate_version_fails || return 1
	assert_non_default_catalog_fails || return 1
	printf 'PASS: fail-closed Cloudron catalog publisher contract\n'
	return 0
}

main "$@"
