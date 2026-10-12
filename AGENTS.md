# Home Run Simulator

Build a satisfying arcade batting loop grounded in deterministic physics. Stages 1–4 are implemented; Stage 5A tunes contact forgiveness and beginner power. The implementation is the source of truth when older documentation disagrees.

## Architecture and constraints

- Rojo maps `src/shared`, `src/server`, and `src/client`. Preserve `default.project.json` and Studio-managed `Workspace.Stadium` assets unless the task requires a change.
- Pitching uses server-authoritative precomputed 240 Hz trajectories. Beginner pitches are already 50–55 mph; preserve pitching speeds, solver, timing and replication.
- `SwingModel` positions the sweet spot on the mouse aim plane and provides analytic bat poses. `BatCollision` sweeps two capsules using conservative advancement. Keep the rendered and collision poses identical.
- `SwingValidator` validates intent, timestamps, aim bounds, rate limits and one swing per pitch. The server resolves against its stored trajectory; never trust client positions or outcomes.
- `ContactQuality` measures geometry and grades contact. Labels describe outcomes; never use labels to assign launch angles, power or distance.
- `BattedBall.computeLaunch` and `ImpactModel` are shared by client prediction and server authority. Flight uses fixed-step 120 Hz RK4 with gravity, drag, Magnus lift and spin decay. Keep nearby inputs continuous and results deterministic.
- `LandingDetector` performs authoritative first-impact sweeps. Flat-field carry projections are benchmarks, not stadium landing outcomes.
- `CameraDirector`, `HitPresentation`, and client effects/HUD own Stage 4 presentation. Preserve their behavior, animations, aiming responsiveness and networking when tuning contact.
- SI units inside impact/flight; world studs at Roblox boundaries. Use the existing `Units`/`FieldFrame` conversions.

## Workflow

1. Read relevant source, README and this file; check `git status` and preserve existing work.
2. Implement the requested scope without large refactors or unrelated progression features.
3. Put meaningful tuning values and baseline comparison settings in shared configuration.
4. Add focused tests for changed mechanics; compare balance using identical deterministic inputs, including imperfect swings and separate ideal-contact benchmarks.
5. Run Rojo build, strict luau-lsp, Selene, all Lune specs and the balance analysis. Report unavailable checks and failures accurately.
6. Update README with changes, measured results, tradeoffs and Studio playtest instructions. Do not claim visual/gameplay success from CLI tests alone.
7. Do not commit, push, or overwrite Studio-managed assets without explicit authorization.

Do not add coins, shops, upgrades, stadium unlocking, rebirths or personal-best tracking during Stage 5A. Future tuning hooks are configuration only.
