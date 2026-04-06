# Creating a Release

This document outlines the steps to create a new release for the project. Follow these steps carefully to ensure a smooth release process.

## Prerequisites

- Zig installed (same version used in CI)
- GnuPG with the release signing key available
- [OpenTimestamps client](https://github.com/opentimestamps/opentimestamps-client) (`ots`)
- Access to create GitHub releases and to the [sysupdates repository](https://github.com/nakamochi/sysupdates)

## Step 1: Tag release

```
git tag -s vX.Y.Z -m "Release vX.Y.Z"
```

Replace `X.Y.Z` with the appropriate version number.

## Step 2: Push tag

```
git push origin vX.Y.Z
```

## Step 3: Build and sign aarch64 binaries

```
git submodule update --init --recursive
zig build -Dtarget=aarch64-linux-musl -Ddriver=fbev -Doptimize=ReleaseSafe -Dstrip
cd zig-out/bin
tar czf ndg-vX.Y.Z-aarch64.tar.gz nd ngui
gpg --sign --armor --detach-sign ndg-vX.Y.Z-aarch64.tar.gz
ots stamp ndg-vX.Y.Z-aarch64.tar.gz.asc
```

## Step 4: Create GitHub release

Go to the GitHub [releases page for the repository](https://github.com/nakamochi/ndg/releases) and [create a new release](https://github.com/nakamochi/ndg/releases/new). Use the tag `vX.Y.Z` and upload the following files:

- `ndg-vX.Y.Z-aarch64.tar.gz`
- `ndg-vX.Y.Z-aarch64.tar.gz.asc`
- `ndg-vX.Y.Z-aarch64.tar.gz.asc.ots`

Describe main changes in the release notes.

## Step 5: Add new release to sysupdates

Update `ndg/env` in the [sysupdates repository](https://github.com/nakamochi/sysupdates) with the new version and its SHA256 checksum.

## Versioning

NDG follows semantic versioning (MAJOR.MINOR.PATCH).

The version is either provided at build time (`-Dversion`) or derived from the current git tag when available. If a git tag is present, the version must match it. If no tag is available, `-Dversion` must be provided. This is enforced by the build system.

### How to choose the version

Use the following guidelines when creating a new release:

#### PATCH

Increment PATCH for:

- bug fixes
- small UI fixes or tweaks
- internal refactors with no user-visible impact
- build, CI, or tooling changes

These changes should not introduce new user-facing functionality or alter expected behavior.

#### MINOR

Increment MINOR for:

- new user-facing features
- new capabilities or workflows
- noticeable UX improvements
- expanded hardware or platform support
- behavior changes that improve correctness or visibility

This is the default choice when something new is added or behavior is meaningfully improved.

#### MAJOR

Increment MAJOR for:

- breaking changes in behavior or workflows
- incompatible changes requiring reprovisioning or migration
- significant architectural changes affecting how the system is used or operated
- declaring the system stable and production-ready (e.g. moving from 0.x to 1.0)

### Notes

- The build system validates that the version is a valid semantic version and, when a git tag is present, that it matches the tag.
- Choosing the correct version bump is a maintainer decision based on user-visible impact.
- When unsure between PATCH and MINOR, prefer MINOR.

