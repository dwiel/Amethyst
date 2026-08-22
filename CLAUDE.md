# Amethyst (local fork)

Working copy for local window-manager fixes. **Dev process:** [docs/local-dev.md](docs/local-dev.md).

Short version:

- One branch: **`master`** on remote **`fork`** (`dwiel/Amethyst`). No feature branches.
- Build/sign/install: `./scripts/build-local.sh` then `trash` `/Applications/Amethyst.app`, copy the new build, re-sign, and relaunch with `open -g -a` (not `open -a` — that is focus-guard denied). Same signing identity.
- Logs: `~/Library/Logs/Amethyst/Amethyst.log`
- Verify running build via version string + process path + inode (see local-dev.md).
