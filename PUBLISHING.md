# Cloudron community publishing

`CloudronVersions.json` is the public package catalog. Merging a completed
package update to `main` is standing authorization for the managed publication
workflow to build and publish that manifest version. Never hand-write an image
tag or digest into the catalog.

## Release workflow

1. Finish the package release and update `CloudronManifest.json`, `CHANGELOG`,
   and `CHANGELOG.md` together.
2. Confirm `logo.png` is a 256×256 PNG and `media/hero.png` is a
   privacy-reviewed 3:1 image. Verify every `iconUrl` and `mediaLinks` URL
   returns an image over public HTTPS.
3. Merge the completed package update to `main`. The
   `cloudron-catalog-publish.yml` workflow validates the package, builds the
   amd64 image, pushes it to
   `ghcr.io/marcusquinn/aidevops-cloudron-worker`, and resolves the immutable
   registry digest. The OCI source label links the package to this public
   repository so Cloudron can pull it anonymously.
4. The workflow runs `scripts/publish-cloudron-catalog.sh`, which adds the new
   manifest version in testing state, verifies the generated entry and digest,
   promotes that exact version to published, and verifies the final catalog.
5. The workflow commits only the generated `CloudronVersions.json`, pushes the
   matching `v<VERSION>` tag, attests the image digest, and creates the GitHub
   release, but only after an anonymous pull probe resolves that exact digest.
   Existing published versions are a verified no-op; mutable, unpublished, or
   conflicting entries fail closed.
6. For release qualification, test a clean install with
   `cloudron install --versions-url <PUBLIC_VERSIONS_URL> --location worker-test`.
   Also verify upgrade, restart, health checks, and backup/restore.
7. Optionally sign in to [Cloudron Community Apps](https://ca.cloudron.io), add
   the same versions URL, and verify the imported icon, screenshot/hero,
   description, changelog, and install URL.

The workflow is the only supported catalog writer. A merge that does not bump
`CloudronManifest.json` is a verified no-op and does not create another release.

Published entries are append-only. For a critical bad release, run
`cloudron versions revoke`, bump the package version, rebuild, and add a new
entry. Do not mutate the manifest or image of a published version.

Cloudron validates the complete catalog before selecting a compatible version.
Every historical manifest must therefore remain parseable by the oldest
supported Cloudron release. Do not add fields introduced by a newer Cloudron
to any catalog entry while older releases remain supported. The append-only
rule has one narrow exception: incompatible catalog metadata may be corrected
only when it otherwise makes the complete catalog unusable. Published images
and runtime package contents remain immutable.

## Visual assets

- `logo.png`: canonical 256×256 package icon.
- `media/hero.png`: canonical 1200×400 3:1 listing image.
- `CloudronManifest.json` records the current public HTTPS assets. Prefer a
  package-controlled stable URL when replacing either reference.
