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
5. The workflow creates Sigstore keyless provenance for both the immutable image
   digest and the exact generated `CloudronVersions.json`. It verifies the
   catalog attestation bundle against this repository, the publishing workflow,
   and the `main` source ref before committing only the generated catalog,
   atomically pushing that commit with the matching `v<VERSION>` tag, and
   creating the GitHub release. Existing published versions reverify the
   anonymous image and tagged catalog digest, attest and verify the current
   catalog without a version bump, then reconcile a missing GitHub release.
   Mutable, unpublished, or conflicting entries fail closed.
6. For release qualification, test a clean install with
   `cloudron install --versions-url <PUBLIC_VERSIONS_URL> --location worker-test`.
   Also verify upgrade, restart, health checks, and backup/restore.
7. Optionally sign in to [Cloudron Community Apps](https://ca.cloudron.io), add
   the same versions URL, and verify the imported icon, screenshot/hero,
   description, changelog, and install URL.

The workflow is the only supported catalog writer. A merge that does not bump
`CloudronManifest.json` is a verified no-op and does not create another release.

GitHub Actions OIDC supplies the short-lived identity used for the image and
catalog attestations, so publication requires no stored signing key. These
attestations provide independently verifiable provenance, but Cloudron does not
currently enforce Sigstore provenance when it imports a catalog or installs an
image.

## Release credential

The protected `main` branch requires the repository secret
`CLOUDRON_RELEASE_PAT`. Use a separate fine-grained PAT for this repository,
owned by a repository administrator and limited to this repository with only
`Contents: Read and write`. Do not grant workflow permissions or reuse the
credential in another repository. The workflow exposes it only to the final
validated catalog commit and atomic tag push; GHCR, attestations, and GitHub
release operations continue to use `GITHUB_TOKEN`. The generated catalog commit
includes `[skip ci]` so its PAT-authenticated branch and tag push cannot launch
duplicate publication workflows.

If the PAT is absent, expired, or revoked, publication fails before the push
without changing the catalog or tag. Rotate the repository secret and rerun the
workflow from `main`.

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
