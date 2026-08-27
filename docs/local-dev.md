# Local development process

Fork of [ianyh/Amethyst](https://github.com/ianyh/Amethyst) for Terran/local fixes.
**One working line of history:** `master` on `dwiel/Amethyst`. Do not open feature branches on the fork.

| | |
|---|---|
| Checkout | `/Users/zdwiel/src/assistant/amethyst` |
| Remote `fork` | `https://github.com/dwiel/Amethyst.git` (push here) |
| Remote `origin` | `https://github.com/ianyh/Amethyst.git` (upstream only; never force-push) |
| Branch | `master` → tracks `fork/master` |
| Installed app | `/Applications/Amethyst.app` |
| Log | `~/Library/Logs/Amethyst/Amethyst.log` |

## Branch rules

- All work lands on **`master`**. Push to `fork`.
- Do **not** create `fix/*` (or other) branches on the fork. One working version only.
- Pull upstream when needed: `git fetch origin` then merge `origin/development` into `master` (upstream’s default is `development`, not `master`).

## Build / sign / install / relaunch

Signing identity must stay stable so macOS Accessibility permission is not re-prompted.

```bash
cd /Users/zdwiel/src/assistant/amethyst

# Build Release + sign with persistent local cert
MARKETING_VERSION=0.24.3.N CURRENT_PROJECT_VERSION=129.N ./scripts/build-local.sh

# Install (backup previous if you care)
pkill -x Amethyst || true
trash /Applications/Amethyst.app
cp -R .build/DerivedData/Build/Products/Release/Amethyst.app /Applications/
codesign --force --deep --sign 5ACFCCF4BC98802BBE98D36A3499B4847395764A --timestamp=none /Applications/Amethyst.app
open -g -a /Applications/Amethyst.app
```

Agents: `open -a` (no `-g`) is focus-guard denied (exit 77) because it steals keystrokes. `open -g` launches without activating. `rm -rf` of the app is PreToolUse-denied; `trash` then `cp -R`. After relaunch, wait ~15s and `attention doctor` should show `capture: native Amethyst`.

- Script: `scripts/build-local.sh`
- Identity: **Amethyst Local Development** (`5ACFCCF4BC98802BBE98D36A3499B4847395764A`)
- Bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` each install so the log shows a clear build.
- Re-signing after `cp` changes the binary MD5 vs DerivedData; that is expected. Trust version string + process path + inode.

### Verify the running binary is the one you just installed

```bash
plutil -p /Applications/Amethyst.app/Contents/Info.plist | rg 'CFBundleShortVersionString|CFBundleVersion'
pgrep -lx Amethyst
# log launch line
rg 'Amethyst launch: version=' ~/Library/Logs/Amethyst/Amethyst.log | tail -3
# same inode = process is the installed file
ls -li /Applications/Amethyst.app/Contents/MacOS/Amethyst
lsof -c Amethyst | rg 'MacOS/Amethyst$'
```

If Accessibility breaks after a **new** signing identity: remove Amethyst from System Settings → Privacy & Security → Accessibility, re-add `/Applications/Amethyst.app`, enable. Same identity = no re-approve.

## Logging / debugging reflow

Persistent file logging is always on (Release included):

`~/Library/Logs/Amethyst/Amethyst.log`

Useful patterns:

```bash
rg 'Reflow (scheduling|completed|skipped|retry)|Frame assignment|Window Change: (add|remove)' \
  ~/Library/Logs/Amethyst/Amethyst.log | tail -80
```

| Log line | Meaning |
|---|---|
| `Reflow scheduling: ... windows=N assignments=N` | Layout ran; N should match managed windows |
| `Frame assignment applying: ... captured=… target=…` | Intended resize (captured ≠ target = change) |
| `Frame assignment applied: ... requested=… observed=…` | AX result; mismatch often min-size clamp (Telegram/WhatsApp) |
| `Reflow retry for stale Space` | Space race; patch should resync + re-queue |
| `Active window set drift: … — reflowing` | Silent active-set reconcile (0.24.3.4+); live membership ≠ last reflow snapshot |
| `windows=0 assignments=0` | Often Accessibility not trusted yet |
| `Failed to add observer ... -25211` | Accessibility disabled for this binary |

Live frames (no Amethyst API):

```bash
swift -e 'import Cocoa; import CoreGraphics
let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
if let wins = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] {
  for w in wins {
    guard (w[kCGWindowLayer as String] as? Int) == 0 else { continue }
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let h = (b["Height"] as? NSNumber)?.doubleValue ?? 0
    let ww = (b["Width"] as? NSNumber)?.doubleValue ?? 0
    guard h > 80, ww > 80 else { continue }
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    if ["Window Server","Dock","Control Center","SystemUIServer"].contains(owner) { continue }
    print(owner, b)
  }
}'
```

## Local control CLI

The installed binary exposes one constrained control hook to the already-running,
Accessibility-approved Amethyst process:

```bash
/Applications/Amethyst.app/Contents/MacOS/Amethyst control move-window \
  --window-id 60 --desktop 2

amethyst control swap-windows --window-id 60 --other-window-id 99
```

`--window-id` is the CG window ID printed by `window-layout` or
`Amethyst debug windows`. `--desktop` is the one-based Desktop number shown by
Mission Control, not the durable `ManagedSpaceID` recorded by `window-layout`.
The commands accept only exact window IDs (and Desktop 1–19 for a move), wait for
an acknowledgement, and verify moves before reporting success. `move-window`
uses the direct Space IDs and never activates the app or visits the source or
destination Desktop. It fails instead of falling back to an interactive Desktop
switch. macOS 15 blocks this operation for windows owned by other apps, so the
command reports that limitation immediately without moving or focusing anything.
`swap-windows` only accepts windows already on the same Desktop and swaps their
tiling order. Neither command exposes arbitrary keystrokes, shell commands, app
activation, or a general remote-control channel.

## Known bugs fixed on this fork (context for agents)

1. **Stale Space skip** — accessibility/space race used to drop reflows forever; `ScreenManager.reflow` resyncs Space and re-queues.
2. **Accessibility recovery** — if trust appears after launch, poll once/sec then `reevaluateWindows()`.
3. **Cross-screen throw leaves source stale** — `moveWindowToScreen` used to send `remove`+reflow to the **target** only. Fix: remove+reflow **source**, add+reflow **target**. Same idea: reflow source on space throw. Symptom: empty pane gap after throwing a window to another display.
4. **Silent active-set drift / empty pane** — a window can leave the current Space (Mission Control drag, app self-move, missed AX remove) without any remove/space notification. Remaining windows keep old frames (e.g. half-width alone). Fix: regenerate on-screen cache every reflow + 1s reconcile timer compares live active IDs vs last reflow snapshot and reflows on drift. Log: `Active window set drift: … — reflowing`.
5. **Native context capture** — `ContextCapture.swift` replaces Hammerspoon as the producer of `~/.context/YYYY-MM-DD.jsonl`. It preserves focus/space, 15s input-count pulses, idle, sleep/wake, lock/unlock, and the existing problem-tag state. It also records deduplicated `window_snapshot` events every 15s and before sleep/lock, covering manageable top-level windows across all Spaces. Reboot recovery is PATH `window-layout previous-startup` (last snapshot before **machine boot**). Amethyst relaunch is `window-layout previous-launch` — do not treat an agent install/`pkill` as a reboot. Consumers remain `hscontext`, `attention`, `focus-time`, `context-search`, `life-timeline`, and `life-metrics`. Health: `attention doctor`; launch proof: `rg 'Context capture started' ~/Library/Logs/Amethyst/Amethyst.log | tail -3`. It intentionally drops iTerm AppleScript CWD lookup (Atuin remains the shell/CWD source).

## Commit / push

```bash
git add -A  # never .build/ or artifacts/
git commit -m "..."
git push fork master
```

Do not push to `origin`. Do not create remote branches on `fork`.

## Artifacts (local only, gitignored-ish / untracked)

`artifacts/` holds previous `/Applications` backups and upstream binaries for rollback. Not committed.
`./build/` / `.build/` is DerivedData — not committed.
