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

Go to the GitHub releases page for the repository and create a new release. Use the tag `vX.Y.Z` and upload the following files:

- `ndg-vX.Y.Z-aarch64.tar.gz`
- `ndg-vX.Y.Z-aarch64.tar.gz.asc`
- `ndg-vX.Y.Z-aarch64.tar.gz.asc.ots`

Describe main changes in the release notes.

## Step 5: Add new release to sysupdates

Update `ndg/env` in the [sysupdates repository](https://github.com/nakamochi/sysupdates) with the new version and its SHA256 checksum.

