# Home Run Simulator — MVP release checklist

Audit: October 12, 2026. Branch: `main`; starting working tree clean. Status: **NOT READY for public release**. Ready for the developer's focused desktop playtest; public release requires the gates below. No commit, push, publishing, API-security change or production data write was performed.

This document and README's MVP/Stage 7A sections are current. Earlier stage documentation is historical. Scope is the existing three worlds, Power, rebirths and permanent profiles, with desktop mouse/keyboard controls.

## Completed and verified

“Automated” means code/spec/engine verification. “Desktop smoke” means automated real input and state inspection, with screenshots where stated. Neither means a human has signed off gameplay feel or live-service reliability.

| Feature | Fresh evidence | Remaining human/live check |
| --- | --- | --- |
| New-player load and free-roam spawn | Studio Mock/New: Ready, zero coins/Power, no lane, Custom camera, visible cursor, unanchored root | Published fresh-account join |
| Movement/jump and respawn | W/Space delivered; position changed, Freefall observed, speed 16; selected-world respawn restored Custom/free roam | Walking routes, edges, reset at every phase |
| Both handed boxes | Native E entered right then left; authoritative hand, Scriptable camera and movement lock; E restored free roam | Every lane/hand, grips and mouse aiming feel |
| Pitch release | Pitcher-motion/release specs; real pitches reached strike plane; procedural presentation visible in desktop screenshots | Ordinary release/one-ball inspection per world |
| Aim/swing/contact | Intent-only timed requests used the existing validator; two accepted contacts | Unscripted imperfect swings, timing/reticle feel |
| Flight, landing, distance and best | Engine sweeps: 120.989 m (397.0 ft), then 115.488 m (378.9 ft); one personal best, two fair hits | Walls/fouls/grounders/NoImpact in authored geometry |
| Coins | 198 then 190, total 388; unchanged until authoritative result; replay/isolation specs | Repeated ordinary hits under latency |
| Power purchase | Actual button in seeded returning mock: Level 8 -> 9, 3,000 -> 1,036; replay DuplicateRequest | Earn and buy naturally; compare captured next launch |
| World unlocks | Threshold/deduplication specs; fixture seeded qualification uses actual engine sweep | Earn 475 / 1,750 ft normally |
| Travel | Three-client adapter tests; actual Worlds button reached Power from Sky, preserved 1,000 coins, stayed free roam | Repeated UI round trips, same-time travel under latency |
| Rebirth | Actual two-click button in seeded mock: coins/Power -> 0, rebirths -> 1, strength 1.25x; world/unlocks/600 m best preserved; replay rejected | Earn first rebirth without seeds |
| Save/reload and restored records | 22 persistence specs: mock round trips, fresh owners, rewards/Power/worlds/best/lifetime/rebirth retention; returning mock seeded best without session counters | **Real DEV-store fresh-server reload** |
| Load/save failures and leases | 22 persistence specs; fresh Studio LoadFailure/SaveFailure: DataUnavailable transactions; no load snapshot/lane; unchanged save timestamp | Live contention, shutdown and recovery |
| Exit/reset lifecycle | E exits; Space smoke stayed Flying without early reward; Custom camera/cursor/unanchoring after completion; fixture reset during flight | Queued E during each phase and disconnect during flight |
| Shop, Worlds, Rebirth, Stats | Actual buttons and G opened panels; 1278x753 screenshots readable; menu clicks added no swings | Desktop resolution/shift-lock/CoreGui/text-focus sweep |
| Space/F6/F7 | Space delivered during flight; F6 delivered independently of hidden F7; pure toggle/public-policy specs pass | Physical Escape/F7; published-client absence |
| Audio | Used Pitch/Swing/Landing/Result built-in cues reported IsLoaded=true; configured flight loop remains off | Listen and check permissions in published client |
| Multiplayer | Fresh three-client Stage 7A fixture returned `ok=true` | Churn, simultaneous transactions, latency and soak |

The multiplayer fixture checks free roam, both hands, three simultaneous worlds, two lanes in one world, proximity/occupancy/replay rejection, incoming exit, queued flight exit, travel refusal during flight, actual camera gates, reset during flight and profile/reward isolation. Its seeded unlocks and synthetic server contacts verify adapters; they are not earned gameplay. It does not establish disconnect-during-flight or production concurrency performance.

### Issues fixed

1. Disabled automatic full-suite execution at Studio startup; tests remain explicitly runnable. This audit's suite occupied 8.35 seconds.
2. Restricted routine character-grip binding/rebinding and harmless pose-reapplication logs to Studio; kept pose correction and actual rig-failure warnings.
3. Enforced Mock/New and per-player ProfileMock checks before either temporary multiplayer fixture can seed progression.
4. Corrected setup documentation so the CLI validation build is not used to replace the authored stadium place.

No balance, physics, authority, progression rules, Rojo mappings or authored geometry were changed. No major performance defect was demonstrated in the available bounded samples.

### Exact automated validation

| Check | Result |
| --- | --- |
| Rojo build and sourcemap | Passed, output in `%TEMP%\hrs-mvp-validation` |
| Strict luau-lsp 1.70.1 | Exit 0, zero type errors; watched-files registration notice only |
| Selene 0.32.0, `src tools` | Exit 0, 0 errors / 0 warnings / 0 parse errors |
| Lune 0.11.0 full suite | 279 passed / 0 failed / 6 skipped |
| Studio explicit full suite | 285 passed / 0 failed / 0 skipped |
| Three-client Stage 7A fixture | `ok=true`, 3 clients |
| Five balance/progression analyses | All exit 0; comparisons below |
| Git whitespace validation | `git diff --check` passed |

The six Lune skips require Roblox Instances: engine collision/construction, playback/cleanup and movement restoration. All passed in Studio. Specs include the 50-cycle gameplay/camera loop, 25 powered/skip cycles, maximum-Power convergence/determinism, engine-safe sweep splitting, 10,000-foot flight measurement, 22 persistence/failure/lease cases and six rebirth cases. No failing game spec remains.

Baseline comparison recursively excludes only CPU timing keys `elapsedSeconds`, `cpuMs`, `simMs`, `sweepMs`:

- `--balance` vs `docs/stage5a-balance.json`: zero remaining differences.
- `--worlds` vs `docs/stage6b-worlds.json`: zero remaining differences.
- `--rebirths` and `--rebirths-baseline` vs their Stage 6C reports: zero remaining differences.
- `--economy` vs `docs/stage6a-progression.json`: identical outcomes/pacing; six historical metadata differences: `configuration.SchemaVersion` 1 -> 3, added `Rebirth`, added `RebirthBalance`, and added three `Hud.Rebirth*` settings. These predate this audit.

Original reports were preserved. Logs, new reports and a recursive difference report are under `%TEMP%\hrs-mvp-validation`; they are local audit artifacts, not shipped assets.

### Performance evidence and limits

Six synthetic Studio engine samples, one at each setting/world:

| World | Power / rebirths | Flight ms | Sweep ms | Steps / casts | Outcome |
| --- | --- | ---: | ---: | --- | --- |
| Rookie | 0 / 0 | 0.87 | 0.45 | 717 / 91 | Landed |
| Power | 0 / 0 | 0.85 | 0.31 | 713 / 90 | Landed |
| Sky | 0 / 0 | 0.98 | 0.32 | 714 / 91 | Landed |
| Rookie | 40 / 12 | 3.78 | 1.62 | 2,445 / 408 | NoImpact |
| Power | 40 / 12 | 3.30 | 1.07 | 2,439 / 392 | Landed |
| Sky | 40 / 12 | 3.60 | 1.50 | 2,443 / 396 | Landed |

The unsupported Rookie path did not fabricate carry. Engine construction tests passed the <650 descendants per generated stadium budget. Pitch smoke reported three solver iterations and accurate strike-plane crossings. Existing fixed steps, finite flight/range limits, bounded pending histories, connection teardown and audio cue caps remain. These measurements do not cover client GPU/UI cost, low-end hardware, concurrent peak frame time, streaming stalls, long-session memory growth or DataStore latency. No live DataStore performance claim is possible.

Harness limitations: one initial AssistantCommand queried a separately loaded PitchServer without runtime state and raised a nil-geometry error; the probe was corrected to replicated lane attributes. One duplicate-named GUI-row path could not select a travel button; runtime-only unique row names allowed the real button smoke. These were automation errors, not observed gameplay crashes. Studio virtual input refuses Escape/F7 as CoreGui bindings; physical delivery remains manual.

## Release blockers

- [ ] **Live permanent saving:** authorize API access only in an isolated development experience and pass real DEV save/fresh-server load, lease-contention, shutdown and recovery checks below. Current read-only probe: `502 / error 7: Studio access to APIs is not allowed`; zero live writes.
- [ ] **Critical human integration signoff:** complete ordinary mouse/keyboard batting, earned coins/Power/unlocks/rebirth, exits/resets, and a private published-client join/rejoin. Automated integration covers the systems but does not replace this final playtest.
- [ ] **Device/settings signoff:** confirm the intended experience/start place and restrict playable devices to Computer. Touch/gamepad batting is incomplete; Phone, Tablet, Console and VR are unsupported for this MVP. Settings were not changed.

Post-MVP visual/audio polish is not a release blocker. Remaining multiplayer stress checks below are required pre-release evidence, not confirmed defects.

## Manual verification required

### Developer's final desktop playtest

1. Open the authored place and connect `rojo serve`. Keep Mock/New, normal intervals and startup tests off. Confirm zero progression, normal camera/movement/jump, no reserved lane and no automatic pitches. Inspect spawn ground and all intended walking routes.
2. Enter both boxes with E on every Rookie/Power/Sky lane (use Returning mock only for inspecting locked worlds). Check hand side, grip, aiming, one release ball and unchanged timing. Earn several fair hits with imperfect aim/timing. Compare displayed confirmed distance and one coin award per hit; try a foul, obstacle and unsupported path.
3. Earn Power using the real shop. Check one debit and that only subsequent contact captures the upgrade. Earn a new best, 475 ft Power access, then 1,750 ft Sky access. Travel through the UI repeatedly; verify free roam, preserved progression and no cross-world collision.
4. Earn the first Level-8 rebirth normally. Inspect both confirmation clicks/consequences: only coins/Power reset, 1.25x permanent strength, records/worlds/lifetime retained. Seeds are useful for UI checks but do not satisfy earned pacing.
5. Open/close all four panels and the Roblox menu/text focus while batting. Click panel interiors/open/close buttons; no swing. Exercise shift-lock, G, Space at flight/landing/return, physical F6/F7 and Escape. Check hidden default overlays and normal pointer restoration.
6. E-exit preparing/windup/pitch/swing/flight/landing/return; reset at each phase, including after skip and during SaveDelayed. Confirm authoritative results finish once and lane ownership releases only after gates. Check Custom camera/current Humanoid, cursor, WalkSpeed, both jump modes, AutoRotate, anchoring and default animations.
7. Inspect desktop windowed/maximized and representative 1280x720, 1920x1080 and 1024x768 layouts. Listen to cues. Run a 20–30 minute session, including high Power/12-rebirth synthetic stress in Mock only; watch client/server frame time, memory/Instance counts, UI/camera work and streaming. Record hardware and observations.

### Multiplayer and latency

- [ ] Repeat the Stage 7A three-client fixture and human two-client play. Inspect each client's camera/cursor; independent progression and rewards; no ownership theft.
- [ ] Upgrade player A while B bats; rebirth A while B's flight is active. Include simultaneous travels and opposite-box entry. Check expected versions/epochs, one debit/reset and no shared state.
- [ ] Disconnect during an unresolved flight; reconnect a disposable test player. Reset another during an incoming pitch. Join/leave additional clients while the server remains active; confirm lane, grip, ball and connection cleanup.
- [ ] Apply supported Studio network emulation for representative 100–250 ms latency and packet loss; repeat swings/skips/menu closures/travel/purchases/rebirths. Inspect stale/replayed requests and prediction correction. No latency-emulated run was performed in this audit.
- [ ] Run simultaneous high-Power flights and a streaming/memory soak on target desktop hardware. Local three-client success is not public-server load certification.

To rerun the fixture, install `tools/stage7a-multiplayer.server.luau` temporarily as a Script under ServerScriptService in Edit and, while LoadingConfig.Enabled is true, install `tools/stage7a-loading.client.luau` as a LocalScript under StarterPlayerScripts. Ensure Mock/New, then use the Edit Command Bar:

```lua
return game:GetService("StudioTestService"):ExecuteMultiplayerTestAsync(3, "Stage7ABatting")
```

Inspect the returned `ok`/error and remove both temporary scripts and probe attributes afterward. Never map or publish them. The loading companion waits for enabled Play, uses the production UI command, and verifies automatic stadium-travel reveal. Stage 6B's preserved fixture assumes obsolete FIFO/automatic assignment and is not the current gameplay regression.

The October 13 manual Play correction passed 343 Studio specs. The updated three-client fixture also passed with normal loading enabled; its companion requires explicit Play for both full-ready and capped joins, and automatic travel; it does not call capped entry full rendering. The 30-second budget deliberately permits remaining scenery to load afterward and supersedes the preceding long render-warmup policy. See README for measured timing and remaining hardware/client checks.

### Real persistence: safe exact procedure

Current source selection: published servers use `ProductionStore = "HomeRunProfiles_v1"`; Studio DataStore mode uses `DevelopmentStore = "HomeRunProfiles_DEV_v1"`; Studio defaults Mock/New. Stores belong to an experience/universe. The connected authored place was **HRS V2**, place **86670038769777**, universe **10770437456**. Confirm those are the intended release IDs before any publishing action. Code selects live storage outside Studio regardless of the Studio mock setting; actual published saving is still unverified.

1. Create a private **separate development experience** from a copy of the authored place and an isolated repository copy. Use disposable tester accounts only. Preserve the original place and real profiles. Choose fresh names, e.g. Studio `HomeRunProfiles_DEV_MVP_STUDIO_20261012` and published development copy `HomeRunProfiles_DEV_MVP_PUBLISHED_20261012`; keep them distinct. Change only that isolated copy's `DevelopmentStore`/`ProductionStore`. Never point tests at production player keys or reset an existing namespace.
2. For that development experience, open **File > Experience Settings > Security**, enable **Enable Studio Access to API Services**, set `StudioMode = "DataStore"` in the isolated copy, and restart Play. Do not change production security. Roblox explicitly recommends a separate test experience for API access. [Data-store setup and isolation](https://create.roblox.com/docs/cloud-services/data-stores).
3. Confirm `ProfileMock=false`, `ProfileState=Ready` and a valid lease. Earn coins, buy Power, unlock/select a world and establish a best/milestones. Capture coins, earnedCoins, Power, rebirths, selected/unlocked IDs, best, milestones and lifetime counters using the server's progression records or client snapshot. Session swing/contact/average counters should start fresh on the next session.
4. Wait at least 70 seconds for a normal save; confirm `ProfileLastSave` advanced and `ProfileUnsaved=false`, without failure state. Leave normally, stop the server, and start a **fresh server** using the same disposable identity/namespace. Compare every saved field. A respawn or returning mock seed is not a fresh-server durability test.
5. Perform a rebirth, record the preserved fields/reset values and repeat leave/fresh-server reload. Validate 1.25x is derived correctly, with no duplicate award/debit/reset from repeated requests.
6. In the isolated DEV namespace, use two independent ProfileStore managers with different GUID owners against the **same disposable key**. The second load while the first lease is active must fail Locked; it must install no state and make no default save. Close/release the first; a fresh owner must then restore exactly. After lease-expiry recovery, a stale owner's save must fail and never overwrite the new owner. Allow the 180-second recovery bound; do not erase a lock to force success.
7. Stop a server with dirty test progression and verify the next server restores the bounded final save. Test a crashed/expired disposable session and safe recovery; do not expect unsaved changes since the last successful periodic write to survive a crash. A hung UpdateAsync cannot be forcibly canceled; the 25-second close deadline bounds waiting/new attempts, not Roblox's underlying call.
8. Run LoadFailure/SaveFailure in **Mock only**, or injected adapter failures around the real DEV test key, to verify no defaults overwrite existing data and stale/lost ownership blocks mutation. Do not manipulate production security/data to simulate an outage. Record real service errors/throttling and retries if encountered; unencountered service failures remain simulation-only.
9. In the private published **development** copy, use actual Roblox clients to repeat join/earn/save/leave/fresh-server/rejoin, then the shutdown/contention checks. This exercises the non-Studio storage branch only in the disposable development namespace. No production account/profile is a test fixture.
10. Restore this working repository and authored Studio place to Mock/New, 60-second autosave and normal namespace names. Remove harnesses/attributes and stop Play. Preserve the dated test values/results and account/experience ownership evidence. Do not mark this blocker closed until real cross-session results exist.

## Publishing checklist — owner actions only

- [ ] Confirm release universe/start-place IDs, creator/group ownership, access and permissions; keep the candidate restricted to testers until release gates pass.
- [ ] Open and sync the authored place; preserve Stadium/GameplayMarkers. Verify all changes are synced. **Do not upload the CLI validation build as the stadium release.**
- [ ] Restore production `HomeRunProfiles_v1`, distinct DEV name, Mock/New Studio defaults, normal timers and `RunTestsOnStart=false`. Do not rename an established live store during release. Confirm production DataStore branch in the private development-client test.
- [ ] Set playable devices to **Computer only**; disable Phone/Tablet/Console/VR. Publish no mobile/gamepad compatibility claim. Roblox supports selecting device types in the experience's playable-device settings. [Roblox device-setting guidance](https://devforum.roblox.com/t/roblox-is-coming-to-meta-quest/2465291).
- [ ] Confirm no temporary test Scripts/LocalScripts, probe attributes, runtime GeneratedWorlds or development fixture models remain. Stage 2.1 intentionally retains verified Studio-managed RookieEnvironment and its rollback backup; see README. ServerScriptService should contain the intended `Server` entry only; Tests remain dormant child modules. Runtime GeneratedWorlds must be rebuilt on a fresh server.
- [ ] Check asset access/listen in the published client. Current procedural pitcher requires no animation IDs; used built-in audio loads; optional flight loop is off. New audio must be licensed and accessible.
- [ ] Complete name/description/icon/thumbnail and current Roblox content-maturity/audience requirements. Choose a measured player cap after multiplayer/soak testing; do not assume unlimited capacity from CLI tests.
- [ ] Owner publishes the authored candidate for restricted testing, performs the final published-client persistence/controls smoke, then explicitly authorizes audience/public release. Check the current publishing dialog carefully because publishing/audience workflows can change. [Roblox publishing and audience workflow](https://create.roblox.com/docs/production/publishing/publish-games-and-places).
- [ ] Retain the preceding place version/configuration, monitor joins/profile failures/server errors and first-session exits after release. Never roll back to an incompatible storage schema or delete profiles to address a release issue.

No publishing or live experience-setting changes were made during this audit.

## Reproduce CLI validation

Use installed tools on PATH and a current Roblox definitions file. This audit used the existing binaries under `%TEMP%\hrs-stage6c-tools` (Lune 0.11.0, luau-lsp 1.70.1, Selene 0.32.0) and `globalTypes.d.luau` there. Outputs belong outside the repository:

```powershell
$validationDir = Join-Path $env:TEMP 'hrs-mvp-validation'
New-Item -ItemType Directory -Force -Path $validationDir | Out-Null
rojo build default.project.json --output (Join-Path $validationDir 'validation.rbxlx')
rojo sourcemap default.project.json --output (Join-Path $validationDir 'sourcemap.json')
luau-lsp analyze --platform roblox --sourcemap (Join-Path $validationDir 'sourcemap.json') --definitions PATH_TO_ROBLOX_DEFINITIONS src
selene src tools
lune run tools/run-tests.luau
lune run tools/run-tests.luau --balance (Join-Path $validationDir 'balance.json')
lune run tools/run-tests.luau --economy (Join-Path $validationDir 'economy.json')
lune run tools/run-tests.luau --worlds (Join-Path $validationDir 'worlds.json')
lune run tools/run-tests.luau --rebirths (Join-Path $validationDir 'rebirths.json')
lune run tools/run-tests.luau --rebirths-baseline (Join-Path $validationDir 'rebirths-baseline.json')
git diff --check
```

During Studio Play, explicitly invoke the existing suite from the server Command Bar:

```lua
return require(game.ServerScriptService.Server.Tests).run(true)
```

## Post-MVP backlog

| Priority | Improvement | Player impact |
| --- | --- | --- |
| 1 | Better pitcher animation/release presentation | Improves anticipation and readability on every pitch |
| 1 | Improved character stance/swing animation | Makes each contact more convincing; retain rendered/collision identity |
| 1 | More exciting licensed arcade sound effects | Stronger contact/result feedback, bounded mixing and accessible fallbacks |
| 2 | Improved stadium geometry/environment design | Clearer navigation, stronger world identity; preserve landing/collision contracts |
| 2 | Additional UI polish and desktop layout/accessibility | Clearer onboarding, panel consistency and readable smaller windows |
| 2 | General gameplay balancing after real playtests | Tune pitch/contact/reward/upgrade/rebirth pacing using measured imperfect inputs |
| 3 | Minimum touch/gamepad controls and device testing | Enables additional platforms; remain disabled until implemented and verified |
| 3 | Future content/progression ideas | Evaluate after retention/feedback; no new systems, pets or monetization in this MVP |

## Files changed in this audit

`AGENTS.md`, `README.md`, this checklist, `src/shared/Pitching/PitchConfig.luau`, `src/client/CharacterGrip.luau`, and the two unmapped `tools/stage6b-multiplayer.server.luau` / `tools/stage7a-multiplayer.server.luau` fixtures. Existing physics/economy reports and `default.project.json` are unchanged. Final Studio source checks matched repository configuration/adapter/PitchConfig/CharacterGrip after cleanup.
