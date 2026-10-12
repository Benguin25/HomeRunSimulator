# Home Run Simulator

Build a satisfying arcade batting loop grounded in deterministic physics. Stages 1-5, Stage 6A economy/Power, Stage 6A.1 skip/preview and Stage 6B stadium progression are implemented. Progression remains session-only. The implementation is the source of truth when older documentation disagrees.

## Architecture and constraints

- Rojo maps `src/shared`, `src/server`, and `src/client`. Preserve `default.project.json` and Studio-managed `Workspace.Stadium` assets unless the task requires a change.
- Pitching uses server-authoritative precomputed 240 Hz trajectories. Beginner pitches are already 50–55 mph; preserve pitching speeds, solver, timing and replication.
- `SwingModel` positions the sweet spot on the mouse aim plane and provides analytic bat poses. `BatCollision` sweeps two capsules using conservative advancement. Keep the rendered and collision poses identical.
- `SwingValidator` validates intent, timestamps, aim bounds, rate limits and one swing per pitch. The server resolves against its stored trajectory; never trust client positions or outcomes.
- `ContactQuality` measures geometry and grades contact. Labels describe outcomes; never use labels to assign launch angles, power or distance.
- `BattedBall.computeLaunch` and `ImpactModel` are shared by client prediction and server authority. Flight uses fixed-step 120 Hz RK4 with gravity, drag, Magnus lift and spin decay. Keep nearby inputs continuous and results deterministic.
- `LandingDetector` performs authoritative first-impact sweeps. Flat-field carry projections are benchmarks, not stadium landing outcomes.
- `CameraDirector`, `HitPresentation`, and client effects/HUD own Stage 4 presentation. Preserve their behavior, animations, aiming responsiveness and networking when tuning contact.
- `GameplayServer` integrates validated server events with pure `SessionStats`, `RecordRules` and `ReturnGate`. Records use confirmed, non-provisional fair ground carry only. All accepted contacts remain successful hits. Keep snapshot versions and hit/assignment deduplication.
- Production hit completion waits for validated camera readiness; `HitLifecycle`'s fixed hold is a legacy fallback. No client message may resolve/cancel a flight, report distance, or unlock a lane before server resolution and the minimum return interval.
- SI units inside impact/flight; world studs at Roblox boundaries. Use the existing `Units`/`FieldFrame` conversions.

## Workflow

1. Read relevant source, README and this file; check `git status` and preserve existing work.
2. Implement the requested scope without large refactors or unrelated progression features.
3. Put meaningful tuning values and baseline comparison settings in shared configuration.
4. Add focused tests for changed mechanics; compare balance using identical deterministic inputs, including imperfect swings and separate ideal-contact benchmarks.
5. Run Rojo build, strict luau-lsp, Selene, all Lune specs and the balance analysis. Report unavailable checks and failures accurately.
6. Update README with changes, measured results, tradeoffs and Studio playtest instructions. Do not claim visual/gameplay success from CLI tests alone.
7. Do not commit, push, or overwrite Studio-managed assets without explicit authorization.

## Stage 6B world contract

- `Worlds/WorldConfig` owns stable IDs (`rookie`, `power`, `sky`), origins, rotations, lane counts, landing extents and free unlock thresholds (475 / 1,750 ft). Stage 6A economy and Power formulas stay unchanged.
- `WorldRegistry` owns ONLY runtime `Workspace.GeneratedWorlds`. `Workspace.Stadium` and `Workspace.GameplayMarkers` remain Studio-managed. Do not map generated models into Rojo or overwrite the original place with a CLI build.
- `Construction` and `StadiumBuilder` generate bounded, repeatable geometry. Power and Sky each have four lanes. Rookie uses the existing lanes and a separate catchment surrounding its measured bounding box, below plate level. No original geometry or marker is moved.
- Marker coordinates are world studs. New lane IDs include the world (`power/Lane1`); original lane IDs are preserved. Home, pitcher, batter, foul poles and bases are marker-relative; the existing solvers and SI conversions remain authoritative.
- `WorldCollision` uses explicit per-world inclusion lists. Visible architecture and ground collide; clouds, markers, markings and light trim do not. Global Terrain, unrelated world parts and other worlds cannot terminate a hit. Add intended Rookie collision assets under its Stadium; do not silently rely on unrelated Workspace geometry.
- Unlock qualification uses the same valid, confirmed, non-provisional fair ground carry requirements as records/rewards, within existing numeric limits. Never use a projection or client distance. Snapshots are schema 2, versioned and detached; pending hit deduplication remains intact.
- `BatterService.travel` is a non-yielding reservation/assignment transaction. Reject locked/unknown/full worlds, stale/replayed/spam requests, missing characters, active hits and incomplete camera return. Travel never cancels an authoritative flight. Stop only the incoming pitch, release the old gate, preserve progression/stats, place at the destination and require fresh character/camera readiness.
- Reset keeps the current lane/world. Waiting players are assigned in order to free lanes in their selected world. Disconnect cleans ownership and returns capacity. Late swing intent carries lane ID and must postdate assignment; sequence/cooldown guards survive travel while per-pitch swing use is cleared.
- Client World UI closes/suppresses batting intent while open; lane changes clear predictions, effects, preview and camera context. Atmosphere changes are local. Generated worlds use PersistentPerPlayer streaming, retained only for the player's current world so long cinematic flights retain geometry.
- The flight solver remains 120 Hz, bounded to 30 seconds / 3,600 steps / 10 km horizontal range. New ground extends 6,500 studs forward; paths outside supported geometry resolve explicit OUT OF RANGE/NoImpact with no carry reward or unlock. Do not fabricate distances or remove limits.
- Stage 6C may persist stable unlock IDs, current world, qualifying best, coins and Power. Validate saved IDs and always restore Rookie unlocked. Do not serialize runtime hit IDs, request clocks, assignments or deduplication state. No DataStore writes yet; no rebirths, pets, monetization or unrelated progression.
- Run all CLI checks, both baseline balance analyses and `--worlds docs/stage6b-worlds.json`. Studio-only construction/collision tests run through the existing runner. `tools/stage6b-multiplayer.server.luau` is an opt-in temporary fixture, never production/Rojo mapped. Its seeded qualification checks adapters, not earned gameplay.
- README's Stage 6B section is the current integration/playtest checklist. Never infer visual quality, camera feel or production multiplayer performance from CLI tests alone.
