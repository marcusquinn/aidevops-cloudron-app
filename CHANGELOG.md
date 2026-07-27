# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.6] - 2026-07-27

### Changed

- Updated and pinned the bundled aidevops CLI to `3.32.186`.

## [0.1.5] - 2026-07-26

### Changed

- Updated and pinned the bundled aidevops CLI to `3.32.181`.

## [0.1.4] - 2026-07-24

### Changed

- Updated and pinned the bundled aidevops CLI to `3.32.180`.

## [0.1.3] - 2026-07-24

### Fixed

- Restored Cloudron 9.1 and 9.2 installation and update compatibility by
  temporarily omitting `packageUrl` until Cloudron 10.0.0 is numerically
  available.

## [0.1.2] - 2026-07-24

### Changed

- Updated and pinned the bundled aidevops CLI to `3.32.177`.

## [0.1.1] - 2026-07-24

### Added

- Managed tag-triggered Cloudron package release validation.
- Cloudron community catalog metadata, publishing runbook, and reviewed icon
  and 3:1 hero assets.

### Changed

- Pinned the final Cloudron base image and OpenCode `1.18.4` instead of
  resolving moving versions during builds.
- Updated and pinned the bundled aidevops CLI to `3.32.176`.
- Require Cloudron `9.1.0` for community-package publishing metadata.
