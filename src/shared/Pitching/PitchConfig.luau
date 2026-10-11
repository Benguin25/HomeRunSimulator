--!strict
-- Shared, data-only configuration for the pitching system.
--
-- Real-world quantities are authored in SI units / mph / rpm and converted
-- through Units. Values marked "readability" intentionally deviate from MLB
-- reality to make the game more fun; the realistic baseline is noted beside them.
--
-- This module must stay free of Roblox services so it can be loaded by the
-- pure-Luau test runner.

local PitchConfig = {}

PitchConfig.Units = {
	MetersPerStud = 0.28,
}

PitchConfig.Environment = {
	GravityMetersPerSecondSq = 9.80665,
	AirDensityKgPerCubicMeter = 1.225, -- sea level, 15 C
}

PitchConfig.Ball = {
	MassKg = 0.145, -- official 5-5.25 oz
	RadiusMeters = 0.0366, -- official 9-9.25 in circumference
	-- Rendering only: the physical radius above drives drag/Magnus and strike
	-- calls. A real-size ball is only a few pixels wide from behind the plate,
	-- so the visual can be scaled up for readability (realistic = 1).
	VisualScale = 1.6,
	VisualSpinRpmScale = 0.04, -- real spin (~2300 rpm) reads as a blur; slow it down visually
	Color = { 0.97, 0.96, 0.93 },
	SeamColor = { 0.78, 0.12, 0.12 },
	TrailLifetime = 0.09,
	-- Optional texture for the ball. Leave empty to use the built-in seam bands.
	TextureId = "",
}

-- Physics integration. The trajectory is integrated with RK4 at this fixed
-- step on both server and client, then sampled with cubic Hermite
-- interpolation at render time, so motion is independent of frame rate.
PitchConfig.Simulation = {
	FixedStepSeconds = 1 / 240,
	MaxFlightSeconds = 4, -- hard cap so a bad config can never run forever
	-- How far past the strike-zone plane the ball keeps flying (into the
	-- catcher's mitt) before the pitch is considered finished.
	CatchDistanceMeters = 1.1,
	SolverMaxIterations = 16,
	SolverToleranceMeters = 0.0005, -- 0.5 mm
}

-- Lane geometry fallbacks used when markers don't specify something better.
PitchConfig.Geometry = {
	MoundToPlateMeters = 18.44, -- 60 ft 6 in (rubber to plate point)
	ReleaseExtensionMeters = 1.85, -- release this far in front of the rubber toward the plate
	ReleaseHeightMeters = 1.75, -- above the pitcher marker's ground level
	ReleaseSideMeters = 0.45, -- toward the pitcher's throwing-arm side
	PitcherHand = "Right" :: "Right" | "Left",
	BatterSide = "Right" :: "Right" | "Left",
	BatterOffsetFromPlateMeters = 0.95, -- lateral distance plate center -> batter, if no batter marker
	-- Offset of the strike-zone plane from the plate marker, toward the pitcher.
	-- 0 = plane through the plate marker's center. The real plate's front edge
	-- is ~0.11 m in front of its centroid.
	ZonePlaneOffsetMeters = 0.11,
}

PitchConfig.StrikeZone = {
	WidthMeters = 0.4318, -- 17 in plate width
	BottomMeters = 0.48, -- above plate ground (hollow of the knee)
	TopMeters = 1.07, -- midpoint between shoulders and belt
	-- Targets are sampled uniformly inside the zone scaled by this factor
	-- (around the zone center). 1.0 = anywhere in the zone, >1 allows balls.
	TargetRegionScaleX = 1.0,
	TargetRegionScaleY = 1.0,
}

export type PitchTypeConfig = {
	DisplayName: string,
	-- Added to the active difficulty tier's speed range (a changeup would be negative).
	SpeedOffsetMph: number,
	DragCoefficient: number,
	SpinRpm: number,
	SpinRpmJitter: number,
	-- Fraction of spin that is transverse (produces Magnus movement); the
	-- remainder is gyro spin and produces none.
	SpinEfficiency: number,
	-- Direction of Magnus movement, as seen from the catcher, rotated from
	-- straight up. 0 = pure "ride" (backspin), +90 = toward pitcher's arm side,
	-- 180 = pure drop (topspin, curveball).
	MovementTiltDegrees: number,
	MovementTiltJitterDegrees: number,
	ReleaseJitterMeters: number,
}

-- Pitch types. Only the fastball is enabled for Phase 1; others are listed in
-- PitchTypesFuture below as tuning starting points.
PitchConfig.PitchTypes = {
	Fastball = {
		DisplayName = "Four-Seam Fastball",
		-- Speed comes from the active difficulty tier (PitchConfig.Difficulty).
		SpeedOffsetMph = 0,
		DragCoefficient = 0.35,
		SpinRpm = 2250,
		SpinRpmJitter = 120,
		SpinEfficiency = 0.92,
		MovementTiltDegrees = 25, -- ~12:45 tilt for a RHP: rides with slight arm-side run
		MovementTiltJitterDegrees = 6,
		ReleaseJitterMeters = 0.03,
	} :: PitchTypeConfig,
} :: { [string]: PitchTypeConfig }

-- Not active yet; kept here so Phase 2+ can promote them into PitchTypes.
PitchConfig.PitchTypesFuture = {
	Curveball = { SpeedOffsetMph = -7, SpinRpm = 2600, SpinEfficiency = 0.75, MovementTiltDegrees = 200 },
	Slider = { SpeedOffsetMph = -3, SpinRpm = 2400, SpinEfficiency = 0.35, MovementTiltDegrees = -100 },
	Changeup = { SpeedOffsetMph = -8, SpinRpm = 1750, SpinEfficiency = 0.9, MovementTiltDegrees = 60 },
}

-- Which pitch types the server may choose, with relative weights.
PitchConfig.PitchMix = {
	{ Type = "Fastball", Weight = 1 },
}

-- Difficulty tiers. Each tier sets how fast pitches are thrown and how long
-- the telegraphed windup lasts, so slower pitches also get a longer
-- "get ready" cue. Speeds are real release speeds (the trajectory is solved
-- for them; nothing is slowed down visually). MLB is ~90-100 mph, so the
-- Advanced tier is the old Phase 1 tuning. Only `Active` is used for now;
-- picking a tier per player/lane later means passing a tier name into
-- Pitch.generate and Pitch.getTiming instead of reading `Active`.
export type DifficultyTier = {
	DisplayName: string,
	SpeedMphMin: number,
	SpeedMphMax: number,
	WindupSeconds: number, -- windup start -> release; also the latency budget for clients
	ReadySeconds: number, -- idle between the reset and the next windup
}

PitchConfig.Difficulty = {
	Active = "Beginner",
	Tiers = {
		Beginner = {
			DisplayName = "Beginner",
			SpeedMphMin = 50,
			SpeedMphMax = 55,
			WindupSeconds = 1.6,
			ReadySeconds = 1.0,
		},
		Intermediate = {
			DisplayName = "Intermediate",
			SpeedMphMin = 64,
			SpeedMphMax = 72,
			WindupSeconds = 1.35,
			ReadySeconds = 0.85,
		},
		Advanced = {
			DisplayName = "Advanced",
			SpeedMphMin = 78,
			SpeedMphMax = 85,
			WindupSeconds = 1.1,
			ReadySeconds = 0.75,
		},
	} :: { [string]: DifficultyTier },
}

function PitchConfig.getTier(name: string?): DifficultyTier
	local tierName = name or PitchConfig.Difficulty.Active
	local tier = PitchConfig.Difficulty.Tiers[tierName]
	assert(tier, `Unknown difficulty tier "{tierName}"`)
	return tier
end

-- Pitch lifecycle timing (seconds). Windup/Ready follow the tier.
export type Timing = {
	ReadySeconds: number,
	WindupSeconds: number,
	ResetSeconds: number,
	FirstPitchDelaySeconds: number,
}

function PitchConfig.getTiming(tierName: string?): Timing
	local tier = PitchConfig.getTier(tierName)
	return {
		ReadySeconds = tier.ReadySeconds,
		WindupSeconds = tier.WindupSeconds,
		ResetSeconds = 1.25, -- after the pitch finishes, before the next Ready
		FirstPitchDelaySeconds = 1.5, -- after a batter is assigned
	}
end

PitchConfig.Timing = PitchConfig.getTiming()

-- Marker discovery. Names are matched case-insensitively against descendants
-- of Workspace.GameplayMarkers (then Workspace.Stadium as a secondary source
-- for exact names only). Exact matches win over substring matches.
PitchConfig.Markers = {
	FolderName = "GameplayMarkers",
	StadiumName = "Stadium",
	FallbackFolderName = "PitchingFallbackMarkers",
	Pitcher = { "PitcherMarker", "PitcherSpawn", "PitchingMarker", "PitcherMound", "Mound", "PitchingRubber", "Rubber", "Pitcher" },
	Release = { "ReleasePoint", "PitchRelease", "PitchReleasePoint", "ReleaseMarker" },
	Batter = { "BatterMarker", "BatterSpawn", "BattingMarker", "BatterBox", "BattersBox", "Batter" },
	Plate = { "HomePlateMarker", "HomePlate", "PlateMarker", "Plate", "StrikeZoneMarker", "StrikeZone" },
	-- Substrings used when no exact name matches.
	PitcherHints = { "pitcher", "mound", "rubber" },
	ReleaseHints = { "release" },
	BatterHints = { "batter", "batting" },
	PlateHints = { "homeplate", "plate", "strikezone" },
}

PitchConfig.Camera = {
	-- Offsets relative to the home plate, in meters.
	BackMeters = 3.4, -- behind the plate (away from the pitcher)
	HeightMeters = 1.6, -- above plate ground
	SideMeters = 0.25, -- toward the batter's side (positive) to frame the batter
	-- The camera looks at a point this fraction of the way from the zone
	-- center to the release point, raised slightly.
	LookFraction = 0.45,
	LookRaiseMeters = 0.2,
	FieldOfView = 55,
	BlendInSeconds = 0.45,
}

PitchConfig.Batter = {
	LockMovement = true,
	HeightAboveMarkerStuds = 3, -- HumanoidRootPart height above the batter marker's ground
}

PitchConfig.Debug = {
	-- Studio-only. Ignored in live servers regardless of this flag.
	Enabled = true,
	ToggleKey = "F7",
	ShowTrajectory = true,
	ShowStrikeZone = true,
	ShowReleasePoint = true,
	ShowTarget = true,
	ShowCrossing = true,
	ShowHud = true,
	TrajectoryDotEverySteps = 4,
	KeepTrajectories = 3,
	LogPitchesToOutput = true,
	RunTestsOnStart = true, -- run the pure-Luau tests once when a Studio server starts
}

return PitchConfig
