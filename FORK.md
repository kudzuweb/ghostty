# Mauria's Ghostty fork

This file lists everything in this fork that differs from stock Ghostty, how to use each difference, and how to maintain the fork. Every change that adds, removes or alters a deviation, setting, theme, build step or gotcha updates this file in the same commit. Facts were checked against the code and git history on 2026-10-07 unless marked unverified.

## What this fork is

The fork is `kudzuweb/ghostty` on GitHub, a public fork of `ghostty-org/ghostty`. Locally `origin` is the fork and `upstream` is Ghostty's repository. `main` is Mauria's build. It follows Ghostty's releases, not upstream's development branch, and today it is based on the tag `v1.3.1`. Work happens on topic branches that merge into `main`. Only the macOS app has been changed or tested; the Linux GTK app is untouched and unused.

## Install and update

| Step | What to do |
|---|---|
| Toolchain | Install Zig 0.15.2 at `~/.local/opt/zig-aarch64-macos-0.15.2`, linked from `~/.local/bin/zig`, and Xcode 26 with the iOS SDK and the Metal toolchain. |
| Core library, after any change outside `macos/` | Run `zig build -Demit-macos-app=false` from the repo root. |
| Debug app | Run `env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin xcodebuild -project macos/Ghostty.xcodeproj -scheme Ghostty -configuration Debug SYMROOT="$PWD/macos/build" build`. This replaces `macos/build.nu`, because Nushell is not installed. The output is `macos/build/Debug/Ghostty.app` with bundle id `com.mitchellh.ghostty.debug`, which keeps its own preferences and saved window state. |
| Daily app | Run `zig build -Doptimize=ReleaseFast`, then replace `/Applications/Ghostty.app` with `zig-out/Ghostty.app`. Replacing it closes the open tabs, and they come back resumed. |
| Work machine or any other Mac | Clone the fork, build the daily app as above, then copy `fork/config.ghostty` to `~/Library/Application Support/com.mitchellh.ghostty/config.ghostty` and the files in `fork/themes/` to `~/.config/ghostty/themes/`. |
| Lint Swift | Run `swiftlint lint --strict` in `macos/`. |

The built-in updater is off, because `SUEnableAutomaticChecks` is `false` in `macos/Ghostty-Info.plist` (this is upstream's value at `v1.3.1`, not a fork change). That matters because a stock Ghostty update would replace the fork's changes. The app reports version `0.1` because `MARKETING_VERSION` is `0.1` in `macos/Ghostty.xcodeproj/project.pbxproj`; this is cosmetic for source builds.

## Deviations in the code

Each row is a commit on `main` after `v1.3.1`, listed with its hash. Find the full set with `git log --oneline v1.3.1..main`.

### AppleScript additions

| Addition | How to use it |
|---|---|
| The `tab color` property on a tab (`7452aee75`) | Read or set it with one of ten values: `no color`, `blue`, `purple`, `pink`, `red`, `orange`, `yellow`, `green`, `teal` or `graphite`. It is the same setter the tab's context menu uses, so the color redraws and persists with window state. |
| The `group name` and `group color` properties on a tab (`447a1e979`) | `group name` reads or sets the tab's sidebar group, and `group color` reads or sets the color shared by every tab in that group. `group color` is ignored for a tab that is in no group. |
| The `keep alive` property on a tab (see "Keep alive") | Read or set it with `true` or `false`. It is the same switch the tab's context menu uses, and it persists with window state. |
| The `pid` and `tty` properties on a terminal (`452171c48`) | Both are read-only: `pid` is the foreground process id and `tty` is the terminal's device path. They also appear on the App Intents terminal entity. |

### Vertical tab sidebar and tab groups

| Feature | How it works |
|---|---|
| Vertical tab sidebar (`f64c71e7d` through `3662e40eb`, then `5739a5365`) | The sidebar was cherry-picked from upstream pull request 14562, which is open and unreviewed upstream, and adapted to `v1.3.1` with conflict fixes. Mauria does not track that pull request. Turn it on with `macos-titlebar-style = vertical-tabs`. The same range adds a collapsed mode that lists numbered tiles, and the native tab context menu on sidebar tabs. |
| Config key history (`3b3919477`, `5739a5365`) | The pull request's separate `macos-vertical-tabs` key was replaced by the `vertical-tabs` value of `macos-titlebar-style`, so only the latter exists now. |
| Tab groups (`447a1e979`) | A tab belongs to a named group, shown as one tinted, collapsible, flat block with a header. Right-click a tab for Move to Group or New Group, and right-click a group header to rename, recolor or ungroup it. Membership is saved with window state and in close-tab undo. Each group's color and collapsed state are stored per group name in `UserDefaults` (`TerminalTabGroupColors` and `TerminalTabGroupsCollapsed`). A tab opened beside a grouped tab joins that group, and joining a group moves the tab next to the group's other tabs. |
| Flat, square sidebar (`447a1e979`) | The same commit restyled the whole sidebar from the pull request: full-width square rows, hairline separators and a solid highlight for the selected tab in place of the glass capsule. This was Mauria's choice. |
| Theme-colored sidebar (`3a96d5c16`) | Group colors and tab dots take the active theme's 16 ANSI colors, so the sidebar changes with the theme. Orange mixes the theme's red and yellow because palettes have no orange. Without a palette the colors fall back to system colors. |

### Session resume

The change is `93ca93c65`, in `macos/Sources/Features/Terminal/AgentSessionResume.swift`.

| Part | Detail |
|---|---|
| What it does | When window state is saved, each terminal records the command that resumes the Claude Code or Codex session in its foreground. When the window is restored, that command is typed into the terminal's shell. Quitting marks every terminal window's state as changed so the saved state is current. |
| Where the session id comes from | For Claude Code it is `sessionId` in `~/.claude/sessions/<pid>.json`. For Codex it is the id at the end of the `rollout-<timestamp>-<uuid>.jsonl` file the process holds open under `~/.codex/sessions/`. |
| Failure mode | Both sources are undocumented files of those tools. When either changes, nothing is found and the terminal restores as a plain shell. |
| Required setting | `window-save-state = always` must be set. The default follows the macOS "close windows when quitting" setting, which is on for Mauria, so a normal quit would save nothing. |

### Sleep guard

The change is `04dc7d039` plus `122dbdc44`, in `macos/Sources/Features/SleepGuard/SleepGuard.swift`. It ports Mauria's retired NoDoz app.

| Part | Detail |
|---|---|
| The control | A button in the sidebar header shows whether the Mac may sleep with the lid closed, by reading `pmset -g` for the `disablesleep` flag. Its menu has the current state, a manual toggle and a Mode submenu; choosing a mode writes `sleep-guard-mode` to the config file and reloads. |
| Manual and Auto modes | The mode is the `sleep-guard-mode` config key (see "Settings panel and fork config keys"); it was a `UserDefaults` value before. Manual leaves the flag to the toggle. Auto blocks sleep while any terminal has a foreground program that is not an idle shell, or any process named `claude` or `codex` on a terminal's TTY, and allows sleep after a grace period. |
| Grace period | It is the `sleep-guard-grace` config key and defaults to 120 seconds. |
| Failed flips | A floating Sleep Guard panel states the error. It closes itself after 30 seconds and is reused rather than stacked. Auto retries after 30 seconds. |
| Quitting | Quitting Ghostty in Auto mode undoes a block that Auto set, so a forgotten block does not drain a laptop in a bag. |
| Requirement | An existing `NOPASSWD` sudoers rule must allow exactly `/usr/bin/pmset -a disablesleep 1` and `/usr/bin/pmset -a disablesleep 0`. Without it Auto fails every retry and the panel appears. The rule is outside this repo; on `home-laptop` it was confirmed with `sudo -n -l` on 2026-10-07. |
| Menu bar icon | The icon is switched off. The code that creates the menu bar status item is commented out in `SleepGuard.swift`, with a note, so it can be restored by uncommenting it. |
| NoDoz leftovers | NoDoz's unported code (commented out) and its icon are in `macos/Sources/Features/SleepGuard/NoDoz/`. |

### Settings panel and fork config keys

The change is in `src/config/Config.zig` (the keys), `macos/Sources/Features/Settings/` (the editor and the panel) and `macos/Sources/Features/SleepGuard/SleepGuard.swift`. The panel edits the live config file, so the file stays the single source: Mauria uses the panel, and agents can edit the same file by hand. The panel does not watch the file, and a hand edit made while the window is open shows there only after the window is closed and Ghostty is relaunched. Ghostty itself applies a hand edit on its normal config reload.

| Part | Detail |
|---|---|
| Config keys | `sleep-guard-mode` is an enum, `manual` or `auto`, default `manual`. `sleep-guard-grace` is a Ghostty duration such as `120s` or `2m` (a bare number is rejected), default `120s`. Both sit in one block in `Config.zig` marked as the fork's, just before the `_arena` field. Swift reads them through `ghostty_config_get`, in `Ghostty.Config.sleepGuardMode` and `sleepGuardGrace`. |
| Sleep guard reads the config | `SleepGuard.apply(_:)` takes both values at launch and on every config reload, from `AppDelegate.ghosttyConfigDidChange(config:)`. The old `UserDefaults` keys `SleepGuardMode` and `SleepGuardGraceSeconds` are gone and any value stored in them is ignored. |
| Config file editor | `ConfigFileEditor` (text only) and `ConfigFile` (file and reload). The file is the path `ghostty_config_open_path()` returns, which Ghostty creates when missing. Setting a key rewrites the last active `key = ...` line (the last occurrence wins in Ghostty, so rewriting an earlier line would have no effect), or appends it, and every other line is kept byte for byte. Fork keys are appended under a `# Mauria's fork settings` comment created once. The write is atomic through the resolved symlink target, then `reloadConfig()` runs. |
| Panel | A gear button in the sidebar header, in the expanded and collapsed sidebar, opens the Settings window (`ForkSettingsPanelController`). Appearance has a searchable theme list of the custom themes in `~/.config/ghostty/themes/` (or `$XDG_CONFIG_HOME`) and the themes bundled in the app, marks the current `theme` line, and writes `theme = <name>` when one is chosen. It also shows `macos-titlebar-style` read-only. Sleep guard has the mode picker and the grace period in seconds (applied on Return). Keep alive has the six `keep-alive-*` keys. Usage cutoff has the overnight toggle and the `usage-cutoff-*` keys. Release check has the `release-check` toggle, the base version, the last check time and a "Check now" button. The footer has "Open config file" and "Fork notes". |
| Adding a section | Write a view that wraps its controls in `ForkSettingsSection` and list it in `ForkSettingsView` in `ForkSettingsPanel.swift`. |
| Limits | The current theme is read from the config file, because `theme` is not exposed through `ghostty_config_get`. A value set on the command line overrides the file after a reload. A `light:...,dark:...` theme value is shown as "not in the list". |

### Keep alive

Keep alive replaces the watchdog daemon that lived at `scripts/watchdog` in `claudemonorepo`; it was retired on 2026-10-07 and remains in that repo's git history. The code is in `macos/Sources/Features/KeepAlive/`: `KeepAliveLogic.swift` holds the decisions as pure functions, `UsageCutoff.swift` the usage cutoff computation, `KeepAlive.swift` the timer and the actions, and `KeepAliveRelaunchJob.swift` the launchd job. This is phase 3a; phase 3b, the Claude Code Mod that turns events into prompts, is the `keepalive-mod` plugin (see "Orchestrator Mod" below).

| Part | Detail |
|---|---|
| The toggle | Right-click a tab in the sidebar and choose "Keep alive" (a checkmark shows when it is on). The state is saved with window state, like the tab group, and a tab restored with it on is watched again. The sidebar row shows a refresh icon while the tab is watched and a red warning triangle once keep alive has given up on it. A gave-up tab's menu item reads "Keep alive: gave up, try again", which clears the crash count. The gave-up mark is not saved. |
| The timer | One timer ticks every 30 seconds (`KeepAlive.tickInterval`) over the tabs with keep alive on, every terminal in a split tab included. A session that starts and dies inside one tick is never seen, so it is never relaunched. |
| What is remembered | Each tick, the Claude Code or Codex session in a terminal's foreground is found with `AgentSessionResume.session(forProcess:)` and remembered, so it is still known after its process dies. |
| Crash relaunch | When the remembered session's process is gone, the terminal's foreground is an idle shell again, and the shell reported a crash-like exit status, keep alive types `claude --resume <id>` or `codex resume <id>` into the terminal and presses Enter. The text goes through the surface's text input and Enter is a separate key press 300 ms later, because Claude Code reads a burst of text ending in a newline as a paste. |
| Deliberate exit versus crash | The signal is the exit status of the command that just finished, which Ghostty's shell integration reports (the `command_finished` action). Status 0 (`/exit`, Ctrl-D) and 130 (Ctrl-C) count as deliberate; any other status, such as 137 for `kill -9`, is a crash. When no status arrives, as when shell integration is off, the session is not relaunched and a line is logged. This applies to Codex too, and it is untested whether Codex exits with 0 on a deliberate quit. Claude Code leaves no usable mark in its transcript: no transcript on this machine contains `/exit`, and the only difference seen was one run each, where the tail ended with `cost-state` after `/exit` and with `bridge-session` after `kill -9`. Neither is used. |
| Crash limit | At most `keep-alive-max-crashes` relaunches in any 60 minutes per terminal. The next crash marks the tab "gave up", writes a `gave_up` event and shows a notification, and nothing more is typed until the mark is cleared. |
| API errors | Claude Code only; Codex sessions are not checked for API errors. When the session process is alive and `claude agents --json --all` reports its status as `idle`, and the last conversation entry of its transcript (`~/.claude/projects/*/<session id>.jsonl`, last 64 KB) has `"isApiErrorMessage": true`, the `error` field picks the policy in the next table. A `busy` or `waiting` session, or a failed `claude agents` call, is never typed into. `claude agents` runs once per tick. |
| Background sessions | Each tick, entries of `claude agents --json --all` with `kind` `background` and `state` `failed` get `claude respawn <id>`, at most `keep-alive-max-crashes` times per hour per session, then a `gave_up` event and a notification, and that session is not respawned again while it stays `failed`, however long that is (`KeepAliveRespawnLimiter`). Once its state leaves `failed`, for example because someone respawned it by hand, the count starts fresh. A session that fails again after each respawn keeps its count and runs out of attempts. `stopped` and `done` are never respawned. This runs whether or not any tab has keep alive on, controlled by `keep-alive-background`. On 2026-10-07 this machine had only `done` and `blocked` background sessions, so the `failed` and `stopped` states come from Mauria's description and are checked only by a test on a synthetic list. Respawns stop after the usage cutoff, as the next section describes. |
| Ghostty relaunch job | See the next table. |
| Events file | One JSON line per event is appended to `keep-alive-events-file`, creating missing directories. Fields: `time` (ISO 8601, UTC), `event` (`relaunched`, `gave_up`, `nudged`, `error_notified`, `respawned`, `cutoff_warning` or `cutoff_reached`), `tool`, `session_id`, `tab_title`, and `error_type` and `message` when relevant. |
| Notifications | Every keep alive notification goes through `KeepAlive.notifyKeepAlive(title:body:)`, which skips the notification while `KeepAlive.notificationsSuppressed()` returns true. It returns true while the overnight switch is on, and the skipped notification is logged. Notifications are for `gave_up`, for errors that are not retried, and for a rate limit with no usable reset time. A debug build is not authorized for notifications by macOS, so the notification path was exercised only as far as the authorization refusal. |
| Orchestrator Mod (phase 3b) | The `keepalive-mod` plugin in `claudemonorepo` (`skills/keepalive-mod/`, loaded in every session) tails the events file and submits one `[keep-alive]` prompt into a session when events concern that session's own workers, so an orchestrator can handle them unattended. It learns workers from the session's own Bash calls (`claude --bg`, `claude --resume <id> --bg`, the handoff launcher's `launch.sh`), because no record links a background session or a tab to the session that started it. Matching is by `session_id` prefix (a background session's is the 8-hex id) or `tab_title`. It needs no change in this fork. Set `KEEPALIVE_EVENTS_FILE` if `keep-alive-events-file` is changed. Built 2026-10-07; its tests ran under `claude plugin test`, and it has not yet run against a live Ghostty event. |
| Config keys | `keep-alive-max-crashes`, `keep-alive-server-error-interval`, `keep-alive-rate-limit-interval`, `keep-alive-background`, `keep-alive-relaunch-ghostty` and `keep-alive-events-file`, in the fork block of `Config.zig`, read through `Ghostty.Config` and re-read on reload. The Settings window has a Keep alive section for them. |

What each API error does:

| Error | What keep alive does |
|---|---|
| `rate_limit` with "session limit · resets 3:20am (America/Chicago)" | Types `continue` and Enter once, 60 seconds after the next occurrence of that time in that zone after the error's timestamp. If the same error is still the last entry after `keep-alive-rate-limit-interval`, it nudges again. |
| `rate_limit` without a reset time ("out of usage credits"), or with one that can't be parsed | Notifies once, then nudges every `keep-alive-rate-limit-interval` (default 15 minutes), counted from the error's timestamp. |
| `server_error` | Nudges every `keep-alive-server-error-interval` (default 5 minutes), counted from the error's timestamp. |
| `authentication_failed`, `model_not_found` and every other type | Notifies once and never retries. |

How the Ghostty relaunch job works, and where it differs from the plan:

| Part | Detail |
|---|---|
| Plan and why it changed | The plan was a job running the Ghostty binary with `KeepAlive` `SuccessfulExit` false. `man launchd.plist` says that key implies `RunAtLoad`, so loading the job would start a second Ghostty at once, and launchd only restarts a process it started, which a Ghostty opened from the Dock is not. The launched-binary behavior itself was not tested. |
| What is installed | `~/Library/LaunchAgents/com.mauria.ghostty-relaunch.plist`, loaded with `launchctl bootstrap gui/<uid>`. It runs a short shell watcher with the running Ghostty's pid, the app's path and a marker file path. The plist keeps `KeepAlive` `SuccessfulExit` false, so a failed `open` is retried and a normal exit is not, and `RunAtLoad` true, which that key needs. |
| What the watcher does | It waits until the pid is gone. If the marker file `~/.local/state/ghostty/clean-quit.<label>` exists, Ghostty quit normally, so the watcher deletes it and exits 0. Otherwise it runs `open` on the app, which is a relaunch after a crash or a force quit. |
| Lifecycle | Ghostty deletes the marker, boots out any loaded job and installs a fresh one at launch and on a reload that changes the key. It writes the marker as it quits. With the key `false` it boots the job out and deletes the plist. The job is also associated with Ghostty's bundle id, so Login Items shows it under Ghostty instead of "sh". |
| Debug builds | A debug build uses the label `com.mauria.ghostty-relaunch.debug`, so testing it cannot replace or remove the job of the Ghostty in daily use. |
| Checked on 2026-10-07 | With the debug build: install and removal with the key toggled, a normal quit (no relaunch) and `kill -9` (relaunched within seconds). |
| Limits | A SIGTERM sent from outside can race the marker write and read as a crash. If a Mac shuts down while the marker is absent, Ghostty opens at the next login. |

### Usage cutoff and overnight switch

The usage cutoff is ported from the watchdog's `usage_cutoff()`. The computation is `UsageCutoff.cutoff` in `macos/Sources/Features/KeepAlive/UsageCutoff.swift`; the actions are in `KeepAlive.swift`. The Settings window has a "Usage cutoff" section with every key below and the overnight toggle.

| Part | Detail |
|---|---|
| What it computes | It rebuilds five-hour usage windows from the `timestamp` of every assistant line in `~/.claude/projects/**/*.jsonl` files modified in the last 36 hours, then returns when work must stop so the workday starts in a window that resets within `usage-cutoff-latest-reset` of it and is at most about `usage-cutoff-usable` used. It returns nothing while a later window still ends before the workday. The files are read off the main thread and the stamps are reused for 5 minutes. The result matched `watch.py` on 12 synthetic cases covering every branch and on Mauria's real transcripts at six workday times. |
| Quirk inherited from the watchdog | A transcript modified in the last 36 hours contributes all its timestamps, including old ones (a stamp from 2026-08-31 was found on 2026-10-07), so window rebuilding starts from the oldest stamp in any recently touched file. |
| Which tabs it covers | A tab with keep alive on while `usage-cutoff` is true, and every tab running an agent while the overnight switch is on. |
| Warning phase | From `usage-cutoff-warning` before the cutoff, each covered Claude Code session that `claude agents --json` reports as `idle` gets `Usage cutoff at HH:MM: finish the current step, commit, write down where you are, and stop.` typed once per workday, with a `cutoff_warning` event. A busy or waiting session is retried each tick. Codex sessions are never typed into, because they have no idle status. A session that dies in this phase is not relaunched, as the watchdog did after `STOP_SOON`. |
| Reached | At the cutoff each covered session gets a `cutoff_reached` event and nothing is relaunched or nudged until the workday start. Reaching it holds even if a later computation moves the cutoff. `watch.py` also sent SIGTERM to the session at this point; that is the `usage-cutoff-stop-sessions` key, off by default. Background session respawns are held too while the cutoff applies (`usage-cutoff` or the overnight switch is on, whether or not any tab is watched): once the cutoff has passed, `claude respawn` is not run for `failed` background sessions until the workday start (`UsageCutoff.holdsRespawn`, with a log line when the hold starts and ends). |
| Overnight switch | `overnight-run` (the moon button in the sidebar header, or the toggle in Settings, or the config file). While it is on, every tab is watched and treated as kept alive without changing its saved flag, the usage cutoff covers every tab running an agent, the sleep guard behaves as Auto without rewriting `sleep-guard-mode`, and `KeepAlive.notificationsSuppressed()` is true. Events still reach the events file. The end is the first workday start after it was turned on, kept in `UserDefaults` (`OvernightRunEndsAt`) so a restart in the night still ends it. At that time Ghostty writes `overnight-run = false` through `ConfigFile` and reloads, within one 30-second tick. Going back to the configured mode releases a block that the overnight Auto set. |
| Config keys | `usage-cutoff` (bool, false), `usage-cutoff-workday-start` (`H:MM` or `HH:MM`, 24-hour local time, default `10:00`, a `TimeOfDay` type in `Config.zig` that rejects anything else), `usage-cutoff-usable` (2h), `usage-cutoff-latest-reset` (2h), `usage-cutoff-margin` (15m), `usage-cutoff-warning` (25m), `usage-cutoff-stop-sessions` (false) and `overnight-run` (false). All are re-read on reload. |
| Test hooks | `GHOSTTY_CLAUDE_PROJECTS_DIR` replaces the transcript folder, and `GHOSTTY_FORK_CONFIG_FILE` replaces the file `ConfigFile` reads and writes (pair it with `--config-file`), so a test never writes the live config. |
| Checked on 2026-10-07 | With the debug build and a scratch config: the wrap-up prompt, `cutoff_warning` and `cutoff_reached` events, relaunch resuming after the workday start, overnight watching tabs without keep alive, notification suppression, `stop-sessions` sending SIGTERM with no relaunch afterwards, the switch writing `overnight-run = false` at the workday start, and the sleep guard's effective mode changing to auto and back (by log). Not checked: the guard flipping `pmset` in Auto, because `SleepDisabled` was already 1 and was left alone. |

### Weekly release check

The check reports a new upstream minor or major release and never downloads or installs anything. The code is in `macos/Sources/Features/ReleaseCheck/`: `ForkBase.swift` records the base version, `ReleaseCheckLogic.swift` holds the pure decisions, and `ReleaseCheck.swift` runs the check. Tests are in `macos/Tests/Update/ReleaseCheckTests.swift`.

| Part | Detail |
|---|---|
| Base version | `ForkBase.version` in `ForkBase.swift`, `1.3.1` today. Update it on every upstream merge (see "Upgrading from upstream"). |
| Source | `https://api.github.com/repos/ghostty-org/ghostty/tags?per_page=100`, unauthenticated. Ghostty publishes no GitHub Releases for its versions (checked 2026-10-07: `/releases` lists only the `tip` prerelease and `/releases/latest` returns 404), so the check reads tags. Only tags of the form `vMAJOR.MINOR.PATCH` count, so `tip`, release candidates and malformed names are ignored. |
| What is reported | The newest tag whose major.minor is greater than the base's: base `1.3.1` reports `1.4.0` or `2.0.0`, never `1.3.2`. The link is `https://github.com/ghostty-org/ghostty/releases/tag/<tag>`. |
| Schedule | A check runs at Ghostty launch and then hourly if one is due. One is due a week after the last successful check. After a failure (offline, rate limited) it is logged only and retried after six hours. The last check and last attempt times are in `UserDefaults` (`ReleaseCheckLastCheck`, `ReleaseCheckLastAttempt`). |
| Pill | A new `UpdateState.releaseAvailable` case in `UpdateViewModel.swift` makes the existing update pill read "Ghostty 1.4.0 is out" with a gift icon. The pill shows only while no Sparkle state is showing. Clicking it opens a popover with "View Release" (opens the page) and "Not Now" (dismisses). |
| Notification | One macOS notification per version, "Ghostty 1.4.0 is out", sent when the check first finds it; clicking it opens the release page (handled in `AppDelegate.userNotificationCenter(_:didReceive:)`). A debug build is not authorized to show notifications. |
| Dismissal | "Not Now" stores the version's major.minor (`ReleaseCheckDismissed`). The pill and notification stay quiet until a release with a greater major.minor appears, so a later patch of the dismissed minor stays quiet. The result of the last check is stored (`ReleaseCheckLatest`) so the pill returns after a relaunch until dismissed. |
| Config key | `release-check` (bool, default `true`), in the fork block of `Config.zig`. Off, the check stops and the pill clears. |
| Settings panel | A "Release check" section has the toggle, the base version, the last check time and a "Check now" button, which ignores the weekly throttle and any dismissal. |
| Limits | Unauthenticated GitHub allows 60 requests per hour per IP, far above the use here. The pill is a Sparkle-coupled view, so the new state is a small addition to upstream files (`UpdateViewModel.swift`, `UpdatePopoverView.swift`), which a merge may need to reconcile. |

### Agent environment stripping
| Item | Detail |
|---|---|
| What it does | `Ghostty.stripAgentEnvironment()` in `macos/Sources/Ghostty/Ghostty.AgentEnvironment.swift` runs first in `macos/Sources/App/macOS/main.swift`, before `ghostty_init`, so no surface or pty sees the variables. It calls `unsetenv` and logs one line of names, never values. |
| Names removed | Every name starting with `CLAUDE` (which covers `CLAUDECODE` and `CLAUDE_*`), `CODEX_THREAD_ID`, `CODEX_SESSION_ID`, and names starting with `CODEX_SANDBOX` or `CODEX_MANAGED_`. User-configured names such as `CODEX_HOME` stay. |
| Why settings-derived variables go too | Claude Code re-reads its settings when it starts, so a `claude` in a new tab still gets them. |

### Backports from upstream

These came in so the foreground process id and tty could exist. Each is in upstream's development branch and will arrive in a later release, where a merge may show them as already applied.

| Backport | Detail |
|---|---|
| Foreground pid and tty name in the C API and core (`eb8b7dcd3`, `a67002713`) | The core surface can report the foreground process id and the pty name. Both return null when the platform cannot supply them. |
| Process-info macro fixes (`9a3ffd27a`, `328bfe9a6`) | These fix C macro comparisons and simplify the macro use in `src/pty.zig`. |
| Build fix (`80362ef21`) | `src/build/SharedDeps.zig` translates `pty.c` only for platforms that have PTYs, because the backported version also translated it for the iOS library and failed. Upstream later restored the same per-OS switch. |

## Mauria's config and themes

The live config is `~/Library/Application Support/com.mitchellh.ghostty/config.ghostty`. A copy is `fork/config.ghostty`; update the copy whenever the live file changes.

| Line | What it does and why |
|---|---|
| `macos-titlebar-style = vertical-tabs` | Turns on the vertical tab sidebar. |
| `theme = Nu-er Disco` | Selects the custom theme below. A `background`, `foreground` or `palette` line in the config would override any theme, so the config has none. |
| `working-directory = ~/Documents/Projects` | The first window opens in the projects folder. It applies to the first window only, and new tabs inherit the current tab's folder. |
| `window-save-state = always` | Restores windows after a normal quit, which session resume depends on. |

Custom themes live in `~/.config/ghostty/themes/`, and copies are in `fork/themes/`. Install them on another machine by copying those files to that folder.

| Theme | Detail |
|---|---|
| `Black` | Black background with white text, matching Mauria's Warp setup. |
| `Nu Disco` | Adapted from the MIT-licensed VS Code theme by dbanksdesign (`dbanksdesign/nu-disco-vscode-theme`). Translucent colors are flattened onto the background because Ghostty palettes have no alpha, and the normal and bright ANSI sets are swapped so terminal output matches the editor's look. |
| `Nu-er Disco` | Mauria's active theme since 2026-10-07: a warmer, darker, softer palette sampled from a neon-lit reference image. It has a plum background (`#190920`), and its accents are about 10% darker and 15% less saturated than the raw sampling, because she found saturated accents tiring ("my eyes don't settle"). The original `Nu Disco` is kept as an option. |
| `Solarized Dark Higher Contrast` | This is a built-in theme, not a file in the fork, and it is Mauria's Solarized option. |

## Integrations elsewhere

| Integration | Detail |
|---|---|
| Handoff launcher, `skills/handoff/launch.sh` in `claudemonorepo` | Opens a new Claude session in a Ghostty tab through AppleScript and pins the tab title with `perform action "set_tab_title:<name>"`. |
| Quipu keeper launcher, `my-quipu/.claude/launch-keeper.sh` | Does the same for the resident quipu keeper session. |
| Smithy Ghostty module, `skills/smithy/references/ghostty/guide.md` in `claudemonorepo` | Holds the design and evaluation guidance for changing Ghostty, and points here for facts. |

Both launchers address `/Applications/Ghostty.app` by absolute path.

## Maintenance

### Upgrading from upstream

1. Fetch tags with `git fetch upstream --tags`.
2. On a topic branch from `main`, merge the new release tag, for example `git merge v1.4.0`. Sessions may resolve the conflicts.
3. Build the core library and the debug app, run `swiftlint lint --strict` in `macos/`, and launch the debug build.
4. Merge the topic branch into `main`, rebuild the daily app, and update the base version named in "What this fork is" and `ForkBase.version` in `macos/Sources/Features/ReleaseCheck/ForkBase.swift`, which the release check compares against.

### Conflict hot spots

| File | Why it conflicts |
|---|---|
| `macos/Sources/Features/Terminal/TerminalTabSidebar.swift` | The sidebar came from an unmerged upstream pull request and was restyled and extended with groups, theme colors and the sleep guard button. This is the main hot spot. |
| `src/config/Config.zig` | The fork's config keys live in one marked block before the `_arena` field, plus the `SleepGuardMode` and `KeepAliveBackground` enums and the `TimeOfDay` struct next to `MacTitlebarStyle`. Keep all of them when merging. |
| `include/ghostty.h` | Upstream renamed every C API declaration with a `GHOSTTY_API` prefix after 1.3, so backports touching it conflict. Keep the release's style and add the new declarations. |
| `src/pty.zig`, `src/build/SharedDeps.zig` and `src/termio/` | These hold the backported process-info code and may already be applied upstream. |
| `macos/Ghostty.sdef` | The fork adds properties here, and `macos/AGENTS.md` fixes the order of top-level definitions: classes, records, enums, commands. |

### Gotchas

| Gotcha | What to do |
|---|---|
| A test Ghostty launched from inside a Claude Code session inherits the `CLAUDE*` environment variables, and a `claude` started in it never registers its session. | Strip every `CLAUDE*` variable when launching a test build. |
| An app launched from inside a Claude Code or Codex session (for example `open Ghostty.app` from an agent's shell) inherits that session's identity variables, and every tab's shell passes them on, so a `claude` in a tab shows "Transcript saving is off" and never registers its session. | The app strips them at launch (see Agent environment stripping), so no manual stripping is needed for test builds. |
| An interrupted `zig build` leaves `macos/GhosttyKit.xcframework`, which breaks the next build with code 70. | Delete that folder and rebuild. |
| The clone is a blob-less partial clone, and a stale commit graph broke history searches. | Delete `.git/objects/info/commit-graph*`. |
| AppleScript `input text` pastes without running the line. | Follow it with `send key "enter"`, or use a surface configuration's `initial input`. |
| A debug build started with `open`, or by the Ghostty relaunch job, asks macOS for access to the Documents folder and does not finish launching until the prompt is answered. | Start debug builds from a shell, as the launch script does. |
| A debug build restores the tabs of its last session, with their keep alive flags and the saved resume commands, so a test run starts with earlier tabs and sessions. | Check each tab's `keep alive` over AppleScript before relying on it. |
| The live app and a debug build both have the process name `ghostty`. | Address a debug build by its absolute path in AppleScript, and never touch a process you did not start. |

## Planned work

Nothing is planned right now. Everything decided so far is built; see the sections above.
