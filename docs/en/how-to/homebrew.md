# Install and Release (Homebrew)

This page covers:

- Installing FastFN via Homebrew (recommended).
- Publishing a new release and updating the Homebrew tap (maintainers).

## Install (users)

```bash
brew tap misaelzapata/homebrew-fastfn
brew install fastfn
fastfn --version
```

Upgrade:

```bash
brew upgrade fastfn
```

Uninstall:

```bash
brew uninstall fastfn
```

## Install from source (contributors)

Requirements: Go and Docker.

```bash
git clone https://github.com/misaelzapata/fastfn
cd fastfn
bash cli/build.sh
./bin/fastfn --help
```

## Publish a release (maintainers)

FastFN uses GoReleaser and GitHub Actions:

- CI runs on pushes to `main`.
- Releases run on tag pushes matching `v*` (for example `v0.1.0`).

### 1) Configure secrets (once)

If you want GoReleaser to update the Homebrew tap automatically, set:

- `HOMEBREW_TAP_GITHUB_TOKEN`: a GitHub token that can push to `misaelzapata/homebrew-fastfn`.

If the secret is not present, the release will still publish GitHub release assets, but it will **skip** updating Homebrew.

### 2) Tag and push

From the repo root:

```bash
git tag -a v0.1.0 -m "v0.1.0"
git push origin v0.1.0
```

### 3) Verify

After the workflow finishes:

- GitHub Releases contains the new version and binary archives.
- `misaelzapata/homebrew-fastfn` has an updated `Formula/fastfn.rb`.

