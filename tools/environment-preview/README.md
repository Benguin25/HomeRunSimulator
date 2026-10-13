# Environment preview (offline, optional)

Development aid for the Stage 2 Rookie environment. Not Rojo-mapped and never
shipped. It renders the same pure `EnvironmentPlan` the client realizes, so
composition, proportions, sightlines and part placement can be checked without
Studio. The lighting is an approximation (sun + sky ambient, shadow map, haze)
and is **not** Roblox's renderer: materials, atmosphere, text and exact colours
must still be judged in Studio.

```powershell
lune run tools/environment-preview/export.luau $env:TEMP\hrs-env.json
python -m pip install moderngl numpy pillow   # once
python tools/environment-preview/render.py $env:TEMP\hrs-env.json tools/environment-preview/cameras.example.json $env:TEMP\hrs-env-out
```

`export.luau` prints the part count per chunk. Cameras are world positions
(`eye`, `target`, vertical `fov` like `Camera.FieldOfView`). The batter's view
used by the Stage 2 reports is `eye = (-0.9, 6.0, 152.1)`, `target = (0, 4.2, 100)`,
`fov = 55` (right-handed box, authored Rookie lane). The authored stadium parts
that stay visible (bases, plate, rubber, chalk) are not in the export; add your
own scene JSON (comma-separated list) if you need them in a render.
