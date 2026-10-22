# Releasing Repo Sync

Releases are built by GitHub Actions when a version tag is pushed. The workflow is `.github/workflows/release.yml`, and releases are published from the public repo `erikmaday-charterup/repo-sync`, which is where installed copies look for updates.

## Cut a release

Make sure `main` has what you want to ship, then tag it and push the tag:

```bash
git tag v1.2.3
git push origin v1.2.3
```

The tag must look like `vX.Y.Z`. The workflow runs `swift test`, builds a universal (Apple silicon and Intel) app with the version from the tag, and publishes a GitHub release named "Repo Sync X.Y.Z" with `Repo-Sync.zip` attached (the README links to `releases/latest/download/Repo-Sync.zip`, so keep that name). The release page shows the first-install steps from `.github/release-notes.md`.

Installed copies find the new release on their own: the updater reads the latest release, compares its tag to the app's `CFBundleShortVersionString`, and swaps in the zip.

## GitHub access

The build carries no GitHub credentials. Installed copies borrow the `gh` tool's login (`gh auth token`) to read the latest release, so anyone without `gh` signed in won't see updates until they run `gh auth login`.

## Building locally

```bash
scripts/build-app.sh                                         # build and install to ~/Applications
scripts/make-icon.sh  # only after changing scripts/make-icon.swift
scripts/build-app.sh --universal --version 1.2.3 --no-install  # build the release zip at .build/Repo-Sync.zip
```
