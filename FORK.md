# Mauria's Ghostty fork

This file lists everything in this fork that differs from stock Ghostty, how to use each difference, and how to maintain the fork. Every change that adds, removes or alters a deviation, setting, theme, build step or gotcha updates this file in the same commit. Facts were checked against the code and git history on 2026-10-07 unless marked unverified.

## What this fork is

The fork is `kudzuweb/ghostty` on GitHub, a public fork of `ghostty-org/ghostty`. Locally `origin` is the fork and `upstream` is Ghostty's repository. `main` is Mauria's build. It follows Ghostty's releases, not upstream's development branch, and today it is based on the tag `v1.3.1`. Work happens on topic branches that merge into `main`. Only the macOS app has been changed or tested; the Linux GTK app is untouched and unused.

## Install and update

The reliability changes have passed the acceptance checks listed below and await remaining drag/permission checks; repaired daily installation and normal quit/reopen have passed for two real Claude sessions. Building or staging a bundle does not update the running application. The production bundle ID remains `com.mitchellh.ghostty` so existing saved state stays in its current domain.

| Step | What to do |
|---|---|
| Toolchain | Zig 0.15.2 at `~/.local/opt/zig-aarch64-macos-0.15.2`, linked from `~/.local/bin/zig`, and Xcode 26 with the iOS SDK and Metal toolchain. |
| Core library | After changes outside `macos/`, run `zig build -Demit-macos-app=false` from the repo root before building Swift. |
| Isolated test app | Run `fork/scripts/test-app.sh build reliability`. It builds `macos/build/Test-reliability/Debug/Ghostty.app` with ID `com.mauria.ghostty.test.reliability`. `path reliability` prints the path; `run reliability` explicitly launches it. The helper uses sanitized xcodebuild because Nushell is unavailable here. |
| Test profile | Every nonproduction bundle has `~/Library/Application Support/<bundle-id>/fork-profile/config/ghostty/config` and sibling `state/`. Startup selects this absolute config before core initialization; both loading and Open Configuration use it. No daily defaults are loaded. The core Sentry cache also moves to `<config-override>.cache/sentry`, away from the daily cache. CLI config overrides are skipped for the nonproduction GUI. Edit this profile's owned file for tests. Defaults set `keep-alive-background = off` and disable app relaunch; independent guards prevent global background respawn and real sleep-setting mutation. |
| Daily candidate | Run `fork/scripts/build-daily.sh`. It always rebuilds the core with `ReleaseFast` using a candidate-local Zig cache before building Swift with `ReleaseLocal`. Output: `macos/build/DailyCandidate/ReleaseLocal/Ghostty.app`. This builds, stamps and signs; it does not install or launch. |
| Staging | `fork/scripts/stage-daily.sh dry-run /candidate/Ghostty.app /new/staging-directory /actual-active/Ghostty.app` requires the actual running bundle path; never infer it from `/Applications`. `prepare` preserves separate `previous-active` and `previous-installed` bundles, `transaction.json` with executable hashes/paths, signature receipts, preliminary config/preferences/state/job backups and `INSTALL-AND-ROLLBACK.txt`. It does not quit apps or replace `/Applications`. |
| Installation | Follow the staged plan after approval for the daily quit/relaunch. Capture window/surface/session mapping, quit gracefully, verify the owning executable stopped, refresh backups after quit, replace on the same volume, and open the canonical absolute `/Applications/Ghostty.app` path. Verify running executable, stamp and restored associations before enabling automatic actions. Inspect/update only the relevant old launch references and registration so permission relaunch uses the canonical path; do not reset LaunchServices or TCC. Rollback restores installed files separately and reopens the recorded prior active runtime, which may have been the repo's `macos/build/ReleaseLocal/Ghostty.app`. Review newer config/session changes before restoring any backup. |
| Work machine | Build and stage the candidate there, then copy `fork/config.ghostty` to `~/Library/Application Support/com.mitchellh.ghostty/config.ghostty` and `fork/themes/` to `~/.config/ghostty/themes/`. The native Claude bridge and narrow sleep privilege are separate setup below. |
| Lint Swift | Run `swiftlint lint --strict` in `macos/`. |

Build helpers embed `GhosttyForkRevision` (Git HEAD plus a hash of Git-visible source, including untracked helpers) and `GhosttyForkProfile`, reject source changes during the build, then sign ad hoc and verify. Preserve the reviewed diff and build receipt with the candidate. The existing version `0.1`/build `1` values alone cannot identify a fork revision. Signing and macOS permission continuity still need installed acceptance. Multiple release bundles have the same production ID; absolute path and the actual running executable matter, especially after a permission relaunch.

For the first upgrade from the old app, `fork/scripts/capture-migration.sh PID /exact/active/Ghostty.app /new/absolute/capture-directory` makes a read-only, PID-addressed capture using the typed resolver, bounded to 45 seconds. `fork/scripts/prepare-migration.py /completed/capture /new/staging-seed` validates surface/binding/process-birth evidence and prepares journal plus migration UUID allowlist in staging only. Neither writes the live recovery journal. Refresh the mapping immediately before the authorized quit and use the transaction plan to seed it only while the daily app is stopped. Unknown or stale identities remain visibly unbound; the allowlist prevents a mismatched legacy archive from silently gaining recovery authority.

Stock Sparkle installation is disabled at the controller boundary: its updater is private, never started and cannot install. Both Check for Updates and Settings' Check now run the informational upstream release check. This protection does not rely on `SUEnableAutomaticChecks` alone.

## Deviations in the code

Historical hashes below identify the original additions on `main` after `v1.3.1`; the behavior includes the current reliability changes. Find committed history with `git log --oneline v1.3.1..main` and review the current diff before installing.

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
| Tab groups (`447a1e979`) | A tab belongs to a named, tinted, collapsible flat group. Membership is saved with window state and close-tab undo. Color/collapse are globally shared by name in `TerminalTabGroupColors` and `TerminalTabGroupsCollapsed`. New tabs inherit their neighbor's group. Rename refuses a live target-name collision or a group also present in another native window; it never silently merges groups. Obsolete stored names can be reused. |
| Flat, square sidebar (`447a1e979`) | The same commit restyled the whole sidebar from the pull request: full-width square rows, hairline separators and a solid highlight for the selected tab in place of the glass capsule. This was Mauria's choice. |
| Theme-colored sidebar (`3a96d5c16`) | Group colors and tab dots take the active theme's 16 ANSI colors, so the sidebar changes with the theme. Orange mixes the theme's red and yellow because palettes have no orange. Without a palette the colors fall back to system colors. |
| Drops over the sidebar (`eb8ffbacb`) | A drop on a tab row goes to that row's focused terminal, then selects/focuses that window after insertion succeeds. A row with no target rejects the drop. Group headers and empty/sidebar rail space use the current focused terminal. File/URL escaping and text insertion use `SurfaceView.insertDropped(from:)`; ordinary row clicks still pass through the transparent context-menu area. |

### Session resume and recovery

`AgentSessionResume`, `AgentSessionRecovery`, `AgentSessionRecoveryState` and `GuardedTerminalInput` share one restore/crash recovery path. `window-save-state = always` is required for normal-quit window restoration. Recovery operates on the original surface UUID, including separate split panes; tab labels are mutable presentation and never recovery keys. Duplicate titles retain their names and gain a small first-terminal UUID badge in the sidebar.

| Part | Detail |
|---|---|
| Saved association | Tool, session UUID, process-specific configuration root and launch cwd are typed data attached to each surface UUID. A profile-scoped `state/agent-recovery.json` journal checkpoints changed associations every two seconds and overlays AppKit state. Safe legacy `claude --resume UUID`/`codex resume UUID` strings migrate to data; arbitrary archived shell strings are never executed. |
| Claude launch context | Recovery records whether `CLAUDE_CONFIG_DIR` was explicitly present in the original process. An inferred Claude root resumes with that variable unset; an intentionally explicit root, including an explicit default path, is preserved. Earlier records without this optional field unset it for the normal `~/.claude` root and retain custom root assignments. `CODEX_HOME` behavior is unchanged. |
| Discovery | Foreground process-group members are checked with PID birth identity before/after lookup. Claude needs a fresh matching `<config-root>/sessions/<pid>.json`; Codex needs matching first-line `session_meta` from its open rollout file. Wrappers/pipeline children are considered. Ambiguous or inaccessible evidence pauses recovery; absence alone does not erase a saved target. These tool files remain undocumented interfaces. |
| Before resume | The original terminal must report a verified empty shell prompt through OSC 133 integration, with unchanged foreground/input identity. A session already claimed in another surface or verified live elsewhere is not launched twice; unavailable ownership checks fail closed. Text and Enter are sent in one main-actor transaction. No input is sent into an agent TUI. |
| Readiness | `ghostty_surface_prompt_ready` requires primary main-screen input state after OSC 133 B, no draft text, spaces, combining/wide glyph residue or continuation row, and rejects alternate/read-only/exited screens. Missing integration or conservative redraw rejection leaves the terminal waiting. No prompt-text guessing. |
| Status and control | Sidebar pending/launching/failed badges explain the reason in help. Sidebar recovery submenus identify each split as `Terminal N` plus tool and short session ID, and offer Retry resume when a binding is known and Forget saved resume. Right-clicking the terminal itself offers the same actions for that exact surface. When no session is known, it explains that rather than offering an inert retry. Launching cannot be retried. Resume waits for actual tool registration; after 30 seconds without it, the terminal reports failure. Actions stay in that exact terminal and never make new tabs. |
| Persistence and exits | Failed/pending targets survive another immediate restart; stopped tombstones prevent older saved state reviving a deliberate exit. Deliberate/unknown completion clears stale remembered agents. Shutdown cancels input/discovery and saves cached associations. The journal cannot recreate layout newer than AppKit or create an absent tab. |
| Addressing from automation | Capture the created tab's terminal UUID or enumerate existing terminal UUIDs, then recheck session, cwd, PID and TTY before acting. AppleScript tab/window IDs are current-object identifiers and change on restart; titles and tab positions are not unique identities. |

A controlled real-Claude comparison on 2026-10-07 reproduced a launch-context regression: ordinary resume of the same session and cwd registered within 2.21 seconds, while adding only `CLAUDE_CONFIG_DIR=~/.claude` failed to register within 90 seconds and logged that hooks were waiting for workspace trust. Recovery therefore does not turn an inferred default directory into an explicit configuration override. The repaired production installation then passed normal quit/reopen on 2026-10-07: both real Claude sessions resumed automatically in their original surface UUIDs and working directories, with new process IDs, fresh native capability readiness, and `configurationRootWasExplicit=false`. No recovery journal edits occurred between quit and reopen. The user confirmed closing the empty third tab, so the restored two-surface layout was expected; the third session remained running in Warp by her choice. Evidence: `outputs/Ghostty-restoration-repair/normal-reopen-acceptance.json` in the repair workspace. Custom roots are covered by unit tests; installed permission-driven restart and production Codex recovery remain unverified.

A disposable GUI fixture verified manual retry and normal quit/reopen automatic resume for four exact surface/session UUID pairs. Installed permission-driven restart and production Codex registration still need their own acceptance; restoring a window is not a promise that every session can resume.

### Sleep guard

The sidebar button reads `pmset -g` and offers Manual/Auto plus a manual toggle. `sleep-guard-mode` defaults to `manual`; `sleep-guard-grace` defaults to `120s`. Auto blocks sleep while terminals have work, including Claude/Codex on their TTY, then releases after the grace period. Overnight temporarily uses Auto without rewriting the configured mode.

| Part | Detail |
|---|---|
| Ownership | Auto and overnight share one serialized ownership service. Auto→Auto keeps its lease; Manual, idle expiry and normal quit release only an automatic block this instance acquired. An existing external/manual block is preserved. Manual blocking is deliberate persistent state. |
| Crash cleanup | The daily profile writes `sleep-guard.lease` before acquisition and requires its per-user launchd recovery watcher to bootstrap first. App/watcher share a kernel advisory lock and token. After the owner releases or loses the lock, the watcher clears only the matching lease; a new owner handles a stale lease under the same lock. Commands have deadlines. |
| Privilege | An administrator must supply the narrow `NOPASSWD` sudoers rule for exactly `/usr/bin/pmset -a disablesleep 1` and `/usr/bin/pmset -a disablesleep 0`. The code runs `sudo -n`; it does not open a privileged prompt or install the rule. Failure is visible in the reused Sleep Guard panel. Failed release retains the lease for retry; crash cleanup cannot complete until that privilege works again. |
| Test profiles | Nonproduction bundles cannot change real `pmset`, even with Auto copied into their config. Ownership tests use injected read/set/recovery functions. |
| Interface | Failed flips appear in one reused floating panel, closing after 30 seconds; Auto retries. The menu-bar icon remains disabled. Unported NoDoz code/assets remain in `SleepGuard/NoDoz/`. |

Fake-backend lease checks and an independently checked owner-SIGKILL crash fixture passed. This fixture verifies lease cleanup ordering without claiming the installed app's real sudo permission or a real pmset transition; those remain pending.

### Settings panel and fork config keys

The change is in `src/config/Config.zig` (the keys), `macos/Sources/Features/Settings/` (the editor and the panel) and `macos/Sources/Features/SleepGuard/SleepGuard.swift`. The panel edits the profile's displayed configuration root. Changes refresh on successful writes and Ghostty config reloads without rebuilding the whole panel; field refresh preserves unsaved drafts, search and focus. External edits need a normal config reload. Applied values are shown for controls; theme comes from the root file and may be overridden by included files or CLI settings.

| Part | Detail |
|---|---|
| Config keys | `sleep-guard-mode` is an enum, `manual` or `auto`, default `manual`. `sleep-guard-grace` is a Ghostty duration such as `120s` or `2m` (a bare number is rejected), default `120s`. Both sit in one block in `Config.zig` marked as the fork's, just before the `_arena` field. Swift reads them through `ghostty_config_get`, in `Ghostty.Config.sleepGuardMode` and `sleepGuardGrace`. |
| Sleep guard reads the config | `SleepGuard.apply(_:)` takes both values at launch and on every config reload, from `AppDelegate.ghosttyConfigDidChange(config:)`. The old `UserDefaults` keys `SleepGuardMode` and `SleepGuardGraceSeconds` are gone and any value stored in them is ignored. |
| Config file editor | `ConfigFileEditor` preserves unrelated lines and rewrites the last active setting. `ConfigFile` selects the prepared profile root, a single daily `--config-file` root, or the normal default file; multiple daily roots disable panel writes. Core loading/editing honor the same absolute `GHOSTTY_FORK_CONFIG_FILE`; invalid roots fail without daily fallback. Writes resolve symlinks, coordinate replacement, reread and compare original bytes before atomic save. An intervening conflict is preserved and reported. Arbitrary uncoordinated writers still have a final compare/rename race; this is not universal filesystem compare-and-swap. |
| Panel | A gear button in the sidebar header, in the expanded and collapsed sidebar, opens the Settings window (`ForkSettingsPanelController`). Appearance has a searchable theme list of the custom themes in `~/.config/ghostty/themes/` (or `$XDG_CONFIG_HOME`) and the themes bundled in the app, marks the current `theme` line, and writes `theme = <name>` when one is chosen. It also shows `macos-titlebar-style` read-only. Sleep guard has the mode picker and the grace period in seconds (applied on Return). Keep alive has the six `keep-alive-*` keys. Usage cutoff has the overnight toggle and the `usage-cutoff-*` keys. Release check has the `release-check` toggle, the base version, the last check time and a "Check now" button. The footer has "Open config file" and "Fork notes". |
| Adding a section | Write a view that wraps its controls in `ForkSettingsSection` and list it in `ForkSettingsView` in `ForkSettingsPanel.swift`. |
| Limits | The current theme is read from the config file, because `theme` is not exposed through `ghostty_config_get`. A value set on the command line overrides the file after a reload. A `light:...,dark:...` theme value is shown as "not in the list". |

### Keep alive

Keep alive replaces the retired `claudemonorepo/scripts/watchdog` daemon. Retirement preceded proven replacement acceptance; no fallback recovery is established in this branch. The 30-second timer watches enabled tabs, including splits; overnight covers all agent tabs. Right-click Keep alive to enable it. The refresh icon indicates watching; repeated crashes reach the configured limit, produce a gave-up mark/event and require explicit retry.

| Part | Detail |
|---|---|
| Crash resume | The observed typed session binding and process birth identity feed shared recovery in the original surface. Shell completion is consumed once: 0/130 are deliberate, missing/unknown evidence clears stale memory, and a nonzero completion with unobserved user input is ambiguous. Crash-like exits within `keep-alive-max-crashes` use the verified empty-shell path above. No delayed Enter or TUI keystroke retry remains. |
| API errors | Claude only: an alive exact session, idle CLI snapshot and last assistant API-error entry select retry policy below. Native Mod capability/readiness must also verify the exact session/process. Busy/waiting, missing bridge or failed lookup never falls back to terminal typing. |
| Background sessions | The daily profile alone may scan `claude agents --json --all` and respawn failed background sessions, controlled by `keep-alive-background = failed` or `off`. Respawns are bounded per session/hour and cease at the usage cutoff. Stopped/done sessions are not respawned. Nonproduction profiles cannot perform this global action. |
| External commands | Claude lookup/agents/respawn have five-second cancellable deadlines, capped output and TERM/KILL cleanup only for the subprocess owned by Ghostty. Results recheck config generation and current surface/session/input evidence. |
| Events and notifications | Events append JSON lines (`time`, `event`, `tool`, `session_id`, `tab_title`, optional `error_type`/`message`) to `keep-alive-events-file`. Overnight suppresses notifications while events remain. A `nudged`/`cutoff_warning` event means a native prompt was accepted, not task completion. |
| Config keys | `keep-alive-max-crashes`, `keep-alive-server-error-interval`, `keep-alive-rate-limit-interval`, `keep-alive-background`, `keep-alive-relaunch-ghostty`, `keep-alive-events-file`; Settings edits them and reload applies them. |

#### Native Claude prompt bridge

Install/load `claudemonorepo/skills/keepalive-mod` in the intended Claude sessions and enable `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1`; the Mod does not change this setting. Its function hooks and `$.prompt.submit` are early-access APIs, checked with Claude Code **2.1.292**'s synthetic harness on 2026-10-07. A disposable real Claude trial on 2026-10-07 (evidence at 08:10:49 UTC) verified native delivery, Unicode draft preservation before/during/after the turn and hot reload, then resumed the same session in a new process/mailbox and ignored an old-process request. The trial recorded three user turns, with the latest two exact request UUIDs accepted in the transcript/receipts. This does not install or validate the bridge in daily sessions, and future versions may change the API.

The Mod verifies its exact session UUID/PID/incarnation and publishes a version-1 capability in `~/.local/state/ghostty/agent-bridge/<session UUID>/<pid>/capability.json`. `GHOSTTY_AGENT_BRIDGE_DIR` selects an isolated mailbox root. Ghostty requests fixed continue/wrap-up templates using a two-second authorization lease; the Mod polls at 250 ms and Ghostty observes/revokes at 200 ms. The Mod submits only when the main turn is idle; it never fills/edits a draft or uses keyboard APIs. Foreground, input, session, config, tab and cutoff changes revoke authority.

Connection failure is explicit: missing/unverifiable capability records `error_type = prompt_bridge` and a "Keep alive needs the agent bridge" notification. A claimed request without acknowledgement is uncertain delivery, reports "Keep alive prompt needs checking", and is not blindly repeated. Accepted means the engine accepted a turn; dropped/rejected are distinct receipts. An already claimed native call may finish after revocation, so its eventual receipt is observed without renewing authority. Missing connection or uncertain delivery remains visible as sidebar attention in expanded rows and compact tiles while keep alive or overnight is authorized, with details in help/accessibility and the context menu. Recovery waiting/failed status takes visual priority. Events and notifications retain the same diagnosis. Uncertain delivery offers no automatic retry.

The same Mod batches events about its own workers into native `[keep-alive]` prompts. Ownership comes from explicit session IDs/Bash launch output and preallocated handoff UUIDs; a title alone never establishes ownership. Set `KEEPALIVE_EVENTS_FILE` when changing the event path. Synthetic validation/test commands are in the Mod README; live installation and native delivery are separate from building Ghostty.

| API error | Policy through the verified native bridge |
|---|---|
| Rate limit with parsed reset time | Request continue 60 seconds after the next reset occurrence in its timezone; subsequent unchanged errors follow `keep-alive-rate-limit-interval`. |
| Rate limit without usable reset time | Notify, then eligible retry every rate-limit interval (default 15m). |
| Server error | Eligible retry every server-error interval (default 5m). |
| Authentication/model/other error | Notify once; no automatic retry. |

#### Ghostty crash relaunch job

When enabled, `~/Library/LaunchAgents/com.mauria.ghostty-relaunch.<bundle-id>.plist` watches this app's PID birth identity and opens its owning absolute bundle path if it dies without its incarnation-specific `state/clean-quit.<UUID>` marker. It does not start another Ghostty when installed. Reconciliation is serial, skips superseded requests and retries failed bootstrap on later config applies. Shutdown closes submissions, drains the active operation and writes the clean-quit receipt. Disable removes the job. Full bundle-ID labels separate profiles and retire only their corresponding old daily/debug label.

The watcher uses launchd RunAtLoad/KeepAlive SuccessfulExit=false to retry a failed open; it cannot itself establish restored session correctness. Normal quit/crash/permission-relaunch acceptance for this revised watcher is pending.

### Usage cutoff and overnight switch

The usage cutoff is ported from the watchdog's `usage_cutoff()`. The computation is `UsageCutoff.cutoff` in `macos/Sources/Features/KeepAlive/UsageCutoff.swift`; the actions are in `KeepAlive.swift`. The Settings window has a "Usage cutoff" section with every key below and the overnight toggle.

| Part | Detail |
|---|---|
| What it computes | It rebuilds five-hour usage windows from the `timestamp` of every assistant line in `~/.claude/projects/**/*.jsonl` files modified in the last 36 hours, then returns when work must stop so the workday starts in a window that resets within `usage-cutoff-latest-reset` of it and is at most about `usage-cutoff-usable` used. It returns nothing while a later window still ends before the workday. The files are read off the main thread and the stamps are reused for 5 minutes. The result matched `watch.py` on 12 synthetic cases covering every branch and on Mauria's real transcripts at six workday times. |
| Quirk inherited from the watchdog | A transcript modified in the last 36 hours contributes all its timestamps, including old ones (a stamp from 2026-08-31 was found on 2026-10-07), so window rebuilding starts from the oldest stamp in any recently touched file. |
| Which tabs it covers | A tab with keep alive on while `usage-cutoff` is true, and every tab running an agent while the overnight switch is on. |
| Warning phase | Before cutoff, covered idle Claude sessions request a fixed wrap-up through the verified native bridge once per workday. Busy/waiting sessions are reconsidered; missing/uncertain bridge delivery is reported without TUI input. Accepted delivery records `cutoff_warning`. Codex has no native bridge here and gets no prompt. A session that dies in warning phase is not relaunched. |
| Reached | At cutoff, covered sessions record `cutoff_reached`; warning and reached routing are exclusive, so reached sends no wrap-up. Resume/nudge/background respawn remain held until the next workday even if estimates move, stamps disappear or Ghostty restarts. The optional `usage-cutoff-stop-sessions` sends SIGTERM and defaults false. Hold state is saved in profile defaults and clears at the next local civil workday. |
| Overnight switch | `overnight-run` (the moon button in the sidebar header, or the toggle in Settings, or the config file). While it is on, every tab is watched and treated as kept alive without changing its saved flag, the usage cutoff covers every tab running an agent, the sleep guard behaves as Auto without rewriting `sleep-guard-mode`, and `KeepAlive.notificationsSuppressed()` is true. Events still reach the events file. The end is the first workday start after it was turned on, kept in `UserDefaults` (`OvernightRunEndsAt`) so a restart in the night still ends it. At that time Ghostty writes `overnight-run = false` through `ConfigFile` and reloads, within one 30-second tick. Going back to the configured mode releases a block that the overnight Auto set. |
| Config keys | `usage-cutoff` (bool, false), `usage-cutoff-workday-start` (`H:MM` or `HH:MM`, 24-hour local time, default `10:00`, a `TimeOfDay` type in `Config.zig` that rejects anything else), `usage-cutoff-usable` (2h), `usage-cutoff-latest-reset` (2h), `usage-cutoff-margin` (15m), `usage-cutoff-warning` (25m), `usage-cutoff-stop-sessions` (false) and `overnight-run` (false). All are re-read on reload. |
| Test hooks | `GHOSTTY_CLAUDE_PROJECTS_DIR` supplies isolated usage transcripts. Nonproduction GUI profiles use their bootstrapped config file; legacy scratch `--config-file` launch recipes are replaced by the test-profile helper. Core loading/editing accept an explicit absolute `GHOSTTY_FORK_CONFIG_FILE` and fail closed on invalid/missing load roots. Native mailbox tests use `GHOSTTY_AGENT_BRIDGE_DIR`. |
| Checked on 2026-10-07 | Historical trials exercised the old implementation. Current pure lifecycle/DST/hold/readiness checks pass; revised native wrap-up, GUI overnight control and real sleep transitions remain pending integrated acceptance below. |

### Weekly release check

The check reports a new upstream minor or major release and never downloads or installs anything. The code is in `macos/Sources/Features/ReleaseCheck/`: `ForkBase.swift` records the base version, `ReleaseCheckLogic.swift` holds the pure decisions, and `ReleaseCheck.swift` runs the check. Tests are in `macos/Tests/Update/ReleaseCheckTests.swift`.

| Part | Detail |
|---|---|
| Base version | `ForkBase.version` in `ForkBase.swift`, `1.3.1` today. Update it on every upstream merge (see "Upgrading from upstream"). |
| Source | `https://api.github.com/repos/ghostty-org/ghostty/tags?per_page=100`, unauthenticated. Ghostty publishes no GitHub Releases for its versions (checked 2026-10-07: `/releases` lists only the `tip` prerelease and `/releases/latest` returns 404), so the check reads tags. Only tags of the form `vMAJOR.MINOR.PATCH` count, so `tip`, release candidates and malformed names are ignored. |
| What is reported | The newest tag whose major.minor is greater than the base's: base `1.3.1` reports `1.4.0` or `2.0.0`, never `1.3.2`. The link is `https://github.com/ghostty-org/ghostty/releases/tag/<tag>`. |
| Schedule | A check runs at Ghostty launch and then hourly if one is due. One is due a week after the last successful check. After a failure (offline, rate limited) it is logged only and retried after six hours. The last check and last attempt times are in `UserDefaults` (`ReleaseCheckLastCheck`, `ReleaseCheckLastAttempt`). |
| Pill | The update pill reads "Ghostty 1.4.0 is out" with a gift icon; its popover offers View Release and Not Now. Stock downloading/installing is unavailable. |
| Notification | Notification permission is awaited and a version is marked notified only after successful submission to macOS. Permission refusal or delivery error stays retryable. Clicking opens the release page. Actual presentation depends on authorization for that bundle. |
| Dismissal | "Not Now" stores the version's major.minor (`ReleaseCheckDismissed`). The pill and notification stay quiet until a release with a greater major.minor appears, so a later patch of the dismissed minor stays quiet. The result of the last check is stored (`ReleaseCheckLatest`) so the pill returns after a relaunch until dismissed. |
| Config key | `release-check` controls automatic weekly checking. Off cancels/invalidates outstanding automatic work and clears the pill. An explicit Check now or Check for Updates still performs one informational check without enabling the schedule. |
| Settings panel | A "Release check" section has the toggle, the base version, the last check time and a "Check now" button, which ignores the weekly throttle and any dismissal. |
| Limits | Unauthenticated GitHub allows 60 requests per hour per IP, far above the use here. The pill is a Sparkle-coupled view, so the new state is a small addition to upstream files (`UpdateViewModel.swift`, `UpdatePopoverView.swift`), which a merge may need to reconcile. |

### Agent environment stripping
| Item | Detail |
|---|---|
| What it does | `Ghostty.stripAgentEnvironment()` in `macos/Sources/Ghostty/Ghostty.AgentEnvironment.swift` runs first in `macos/Sources/App/macOS/main.swift`, before `ghostty_init`, so no surface or pty sees the variables. It calls `unsetenv` and logs one line of names, never values. |
| Names removed | Explicit Claude/Codex process identity and transport keys (`CLAUDECODE`, session/parent/process IDs, entrypoint/SSE port, Codex session/thread/sandbox/pipe/originator identity keys) and `CODEX_MANAGED_*`. The exact set is `Ghostty.agentEnvironmentNames`. Configuration/auth values such as `CLAUDE_CODE_USE_BEDROCK`, `ANTHROPIC_*`, function-hook enablement and `CODEX_HOME` survive. |
| Why settings-derived variables go too | Only identity/transport keys are removed; provider/authentication/configuration variables remain available to sessions launched in tabs. |

### Backports from upstream

Each is in upstream's development branch and will arrive in a later release, where a merge may show them as already applied. The first three came in so the foreground process id and tty could exist; the last fixes non-ASCII text in `initial input`.

| Backport | Detail |
|---|---|
| Foreground pid and tty name in the C API and core (`eb8b7dcd3`, `a67002713`) | The core surface can report the foreground process id and the pty name. Both return null when the platform cannot supply them. |
| Process-info macro fixes (`9a3ffd27a`, `328bfe9a6`) | These fix C macro comparisons and simplify the macro use in `src/pty.zig`. |
| Build fix (`80362ef21`) | `src/build/SharedDeps.zig` translates `pty.c` only for platforms that have PTYs, because the backported version also translated it for the iOS library and failed. Upstream later restored the same per-OS switch. |
| UTF-8 in config string escapes (upstream `29b82dd80`, cherry-picked) | `src/config/string.zig` now reads a `\xNN` escape as one byte instead of a codepoint. Before, an AppleScript `initial input` (and the session resume and handoff launchers that use it) containing non-ASCII text reached the shell double-encoded, because `src/apprt/embedded.zig` escapes the string with `std.zig.stringEscape`, which writes each non-ASCII byte as `\xNN`, and the parser re-encoded each as a codepoint. It includes upstream's unit test. |

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
| `Nu-er Disco` | Mauria's active theme since 2026-10-07: a warmer, darker, softer palette sampled from a neon-lit reference image. It has a plum background (`#170920`), with the purple hues nudged just 4 degrees toward blue while preserving brightness and saturation, and its accents are about 10% darker and 15% less saturated than the raw sampling, because she found saturated accents tiring ("my eyes don't settle"). Pale foreground (`#e5dce3`) and ANSI 7 (`#c1b7c0`) have slightly less pink saturation at the same lightness. The original `Nu Disco` is kept as an option. |
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
3. Build the core library and isolated test profile, run `swiftlint lint --strict` in `macos/`, and complete scratch acceptance before daily staging.
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
| An app launched from inside a Claude Code or Codex session (for example `open Ghostty.app` from an agent's shell) inherits that session's identity variables, and every tab's shell passes them on, so a `claude` in a tab shows "Transcript saving is off" and never registers its session. | The app strips them at launch (see Agent environment stripping), so no manual stripping is needed for test builds. |
| An interrupted `zig build` leaves `macos/GhosttyKit.xcframework`, which breaks the next build with code 70. | Delete that folder and rebuild. |
| The clone is a blob-less partial clone, and a stale commit graph broke history searches. | Delete `.git/objects/info/commit-graph*`. |
| AppleScript `input text` pastes without running the line. | Follow it with `send key "enter"`, or use a surface configuration's `initial input`. |
| A new test bundle may need macOS Documents permission and may be asked to Quit & Reopen. | Use its unique profile, then verify the actual relaunched executable/stamp and recovery statuses. Permission restart acceptance remains pending. |
| A test profile restores its own prior tabs and associations. | Use a fresh named profile for a clean trial; inspect existing surface UUIDs and recovery states before creating or resuming anything. |
| The live app and a debug build both have the process name `ghostty`. | Address a debug build by its absolute path in AppleScript, and never touch a process you did not start. |

## Reliability acceptance status

Acceptance on 2026-10-07 for the reviewed source. These include bounded fixture results and the repaired installed-app normal quit/reopen acceptance described above; permission-driven restart remains separate.

| Check | Result |
|---|---|
| Core + Swift builds/unit tests | Core/readiness/profile isolation and app/build-for-testing compilation passed. Final unit run: 255 passed, 1 intentional benchmark skip, 0 failed; 298 passing parameterized runs. |
| Test isolation | Fresh hidden LSUIElement unit-only profile opened no visible windows in three CGWindow samples; daily config SHA was unchanged. |
| Lifecycle / native Mod | Lifecycle: 33 tests in 5 suites passed. Mod: 25 synthetic tests and strict validation passed on Claude Code 2.1.292; busy/uncertain delivery remains synthetic-only acceptance. |
| GUI recovery | All four manual retries and normal quit/reopen automatic resumes preserved each original surface/session UUID exactly once. Fixture grew from 2 tabs/3 surfaces to 3 tabs/4 surfaces for the fourth case. Split recovery/menu actions were checked against the journal. Real deliberate/unknown GUI exits were not tested; coordinator tests cover them. |
| GUI controls | Row selection, invalid-duration error, and draft preservation across unrelated apply/reload passed. AppKit selector/target-retention regression passed after repairing silent sidebar menu actions. End-to-end drag acceptance remains pending. |
| Native Claude turn | Real isolated trial verified accepted request receipts, Unicode draft preservation before/during/after a native turn and hot reload, independent resumed-process mailbox and rejection of old-process requests (08:10:49 UTC evidence). |
| Sleep | Owner-SIGKILL cleanup passed with the fixture backend. Installed narrow sudo privilege/real pmset and macOS permission continuity remain untested. |
| Daily migration/install | Repaired production installation and normal quit/reopen passed for two real Claude sessions with exact original surface/session UUIDs and cwd, new PIDs, and fresh native capability readiness, without journal edits between quit/reopen. The user intentionally closed the empty third tab and kept its session running in Warp. TCC restart, production Codex recovery and rollback remain unverified. |

## Planned work

Complete end-to-end drag, installed permission-driven restart and production Codex recovery acceptance. All concrete review findings have been addressed in source. Duplicate ownership checks prevent known live/recovering sessions from being launched again, but cannot atomically arbitrate a simultaneous start by an unrelated application. Tool metadata and Claude function-hook API compatibility remain maintenance dependencies.
