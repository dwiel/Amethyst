# Amethyst (local fork)

Working copy for local window-manager fixes. **Dev process:** [docs/local-dev.md](docs/local-dev.md).

Short version:

- One branch: **`master`** on remote **`fork`** (`dwiel/Amethyst`). No feature branches.
- Build/sign/install: `./scripts/build-local.sh` then replace `/Applications/Amethyst.app` with the same signing identity.
- Logs: `~/Library/Logs/Amethyst/Amethyst.log`
- Verify running build via version string + process path + inode (see local-dev.md).
