# Home Run Simulator — Claude Code project instructions

## Project goal
Build a polished Roblox baseball simulator whose central loop is **hit a pitched baseball as far as possible**. Make the moment-to-moment batting exceptionally satisfying before adding coins, upgrades, stadium progression, pets, or monetization.

**Design priority:** Responsive and fun arcade baseball, grounded in coherent baseball physics. Realistic numbers are a starting point, not a requirement when they make aiming impossible.

## Current project state
- Roblox project using **Rojo** and Luau.
- Stadium is created and managed in Roblox Studio under `Workspace.Stadium`. Preserve it.
- Gameplay markers are expected under `Workspace.GameplayMarkers` (home plate, mound/pitcher, batter; optional release marker). Inspect actual names and log fallbacks rather than assuming them.
- Phase 1 pitching is implemented: fixed-step (240 Hz) precomputed pitch trajectory, server-authoritative state, compact per-pitch replication, client-side position rendering, strike-zone crossing detection, lane lifecycle, and debug overlay (F7).
- Existing CLI checks: `rojo build`, luau-lsp, Selene, and Lune tests. Some tests require Studio. **Do not claim Studio verification unless actually performed.**
- The user playtested Phase 1: pitching looks good, but pitch travel is **too fast to aim and hit comfortably**.

## Design decisions to preserve
1. Keep authoritative pitch trajectories and outcomes on the server. Do not make the client authoritative for hits, distance, or rewards.
2. Retain the deterministic pitch simulation and reuse its server-time trajectory data for batting validation; do not replace it with untested `Touched` events.
3. Avoid networking every rendered frame. Use timestamp-based state plus local smoothing/prediction where suitable.
4. Use frame-rate-independent motion, continuous/swept contact checks, robust cleanup, and repeatable tests.
5. Keep modules small: physics/config, pitching controller, batting logic, client presentation, camera, debug.
6. Keep map/art assets Studio-managed when not mapped by Rojo. Do not modify `default.project.json` or Studio assets without a reason.
7. Preserve existing implementation, functionality, and file conventions; inspect the repo before making changes.

## Gameplay feel — critical
- **Do not assume MLB pitch speeds are good gameplay speeds.** The current 78–85 mph pitches look good but are too fast for players to aim and swing.
- Provide a learnable aiming + swing mechanic. Prefer a readable pitch sequence: windup cue, recognizable release, meaningful reaction window, satisfying contact feedback.
- Separate **visual pitch speed**, **player reaction window**, and **difficulty/progression** in design. Start with easier, clearly telegraphed pitches and expose tuning values in configuration.
- Consider beginner pitches around **45–60 mph as an initial playtest range** (not a mandatory final value) and test whether the ball is readable in the actual camera. Avoid faking physical velocity numbers in the UI.
- Aiming should not require impossible reaction time. Let players pre-position their bat/reticle during windup and track the pitch; use readable trajectory cues only as needed. Later tiers can gradually increase speed.
- High-quality contact should depend on swing timing, aim and collision geometry, not random outcomes or automatic hits. Great hits should produce high exit velocity and dramatic but controlled feedback.
- Target short, repeatable sessions with fast retries and minimal downtime.

## Coordinate systems and physics
- Use one documented studs-to-meters conversion, with validated stadium scale and marker geometry.
- Keep pitch and batted-ball physics modular, deterministic and testable.
- Treat drag/spin as consistent approximations, clearly documenting simplifications.
- Use sweeps/continuous intersection tests for high-speed ball-bat interactions; account for latency with bounded, server-validated timing and positions.
- Do not let visual interpolation change authoritative outcomes.

## Workflow for every prompt
1. Inspect relevant files, README, configs and current architecture before editing.
2. State a short plan, then implement the requested **scope only**. Avoid opportunistic major rewrites.
3. Prefer configurable constants rather than scattered magic numbers.
4. Preserve existing functionality and add appropriate unit/integration tests.
5. Run available checks (`rojo build`, static analysis, lint, automated tests), report exact outcomes.
6. Give concise Studio playtest steps and explicitly list behavior that remains unverified.
7. Include changes made, tradeoffs, known issues, and files touched. Do not say a feature works in Studio unless tested there.
8. Never commit/push or overwrite Studio-managed assets unless explicitly asked.

## Current next task
Before building complete batting, tune the Phase 1 **pitch pacing/readability** in Studio: slower configurable beginner pitches, better release cues and adequate time to acquire/track the ball, without breaking deterministic trajectory calculations or server/client synchronization. Then implement aiming, swing and contact detection in an isolated Phase 2 with playtests between iterations.

## Success criteria
The user can understand an incoming pitch, intentionally aim, time a swing, feel the quality of contact, and watch a ball fly convincingly. **Fun and control come before strict MLB realism or feature count.**
