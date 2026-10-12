--!strict
-- Shared, data-only configuration for batted-ball physics (Phase 3A).
--
-- Every physical quantity is in SI units (m, kg, s, rad/s) unless the name
-- says otherwise (Mph, Rpm, Degrees, Feet). Studs only appear at the boundary
-- with Roblox (FieldFrame converts). Ball mass/radius, gravity and air density
-- are shared with pitching (PitchConfig.Ball / PitchConfig.Environment) so a
-- pitched and a batted ball are the same physical object.
--
-- Values marked "gameplay" deliberately deviate from a real bat-ball
-- collision; the realistic baseline is noted beside them. Must stay free of
-- Roblox services so the pure-Luau test runner can load it.

local BattedBallConfig = {}

-- Bat-ball collision (ImpactModel). Baseline: a 34 in / ~31 oz wood bat
-- (Nathan, "Dynamics of the baseball-bat collision", AJP 68, 2000;
-- Cross, "Physics of Baseball & Softball", 2011).
BattedBallConfig.Impact = {
	Bat = {
		MassKg = 0.88,
		-- Balance point measured from the knob (a 34 in wood bat balances ~22-23 in out).
		CenterOfMassFromKnobMeters = 0.56,
		-- Moment of inertia about the center of mass (kg m^2). Sets how much
		-- the bat's effective mass drops toward the ends.
		MomentOfInertiaKgM2 = 0.040,
	},
	-- Normal coefficient of restitution at the sweet spot (wood ~0.50 at game speeds).
	SweetSpotRestitution = 0.50,
	-- Restitution falls off (Gaussian) with distance from the sweet spot along
	-- the bat, toward this floor (vibrational losses near the handle and tip).
	MinRestitution = 0.20,
	RestitutionFalloffMeters = 0.16,
	-- Tangential (friction) model: impulse needed to make the contact point
	-- stop slipping ("rolling"), capped by Coulomb friction mu * normal impulse.
	FrictionCoefficient = 0.5,
	-- 0 = the contact point ends up rolling; >0 lets it reverse (bouncy tangential).
	TangentialRestitution = 0.0,
	-- Moment of inertia of the ball as a fraction of m*R^2 (solid sphere 0.4; measured baseballs ~0.4).
	BallInertiaFactor = 0.4,
	-- Below this approach speed along the normal (m/s) the bodies are treated
	-- as already separating: no impulse, the ball keeps its velocity (foul tip).
	MinApproachSpeedMps = 0.01,
}

-- Power knobs for future progression. Defaults are the beginner tier.
BattedBallConfig.Power = {
	-- gameplay: the readable Phase 2 swing moves the sweet spot at ~47 mph
	-- (youth-level). The impact uses this multiple of that bat velocity, i.e.
	-- ~56 mph, a high-school-level swing. The visible swing and its collision
	-- timing are unchanged. Realistic for the drawn swing = 1.0.
	BatSpeedMultiplier = 1.2,
	-- Multiplies the position-dependent restitution (clamped to 1). 1 = wood.
	RestitutionScale = 1.0,
	-- Multiplies the outgoing spin vector (Magnus effectiveness). 1 = physical.
	SpinEffectiveness = 1.0,
	-- gameplay (arcade): multiplies the outgoing ball velocity after the
	-- collision. 1 = physical. Intended for future upgrades only.
	ArcadePowerMultiplier = 1.0,
	-- Safety cap on the ball's kinetic energy after the collision (J).
	-- 0.5 * 0.145 kg * (130 mph)^2 ~ 245 J. Raise together with the power knobs.
	MaxLaunchEnergyJoules = 250,
}

-- Flight model (FlightPhysics). Gravity + quadratic drag + Magnus lift.
BattedBallConfig.Flight = {
	-- Fixed RK4 step. Sampling between steps is cubic Hermite, so rendering
	-- never depends on frame rate. Measured against a 960 Hz reference, 120 Hz
	-- changes carry by < 1e-9 m for normal hits and ~1e-5 m at 300 mph, at
	-- half the cost of pitching's 240 Hz.
	FixedStepSeconds = 1 / 120,
	-- Drag coefficient Cd = DragCoefficient + DragSpinSlope * S, with spin
	-- factor S = r*w/v. Nathan's trajectory calculator uses
	-- Cd = 0.3008 + 0.0292 * (rpm / 1000); at ~100 mph that spin term is
	-- 0.34 * S. A 2500 rpm fly ball then has Cd ~ 0.37.
	DragCoefficient = 0.30,
	DragSpinSlope = 0.34,
	-- Spin decays as exp(-t / tau). Nathan uses tau ~ 25 s. math.huge = no decay.
	SpinDecaySeconds = 25,
	-- gameplay: multiplies PitchConfig air density for the batted ball only
	-- ("thin air" upgrades). 1 = sea level.
	AirDensityScale = 1.0,
	-- Simulation budget. A flight ends at the first of these:
	MaxFlightSeconds = 12, -- at most 1440 RK4 steps at 120 Hz
	MaxHorizontalDistanceMeters = 1500,
	-- The free-flight solution keeps going until the ball is this far below
	-- home-plate level (so sunken fields / bowls still get a first impact).
	FloorBelowPlateMeters = 30,
}

-- First-impact detection (LandingDetector).
BattedBallConfig.Collision = {
	-- Long chords between stored samples are swept first (sphere radius
	-- inflated by the curve's deviation from the chord, so nothing is
	-- skipped), then the fixed steps inside a chord that hit are re-swept
	-- with the true ball radius.
	ChordSeconds = 1 / 20,
	-- A surface whose normal has at least this upward component counts as
	-- ground (cos 45 deg ~ 0.707). Steeper surfaces are walls; downward-facing
	-- ones are ceilings.
	GroundMinNormalUp = 0.7,
	-- Server raycast settings.
	RespectCanCollide = true, -- ignore non-collidable decorative / debug parts
	IgnoreTag = "BattedBallIgnore", -- CollectionService tag for extra parts to ignore
	-- Children of Workspace (by name) that are never hit.
	IgnoreWorkspaceChildren = { "GameplayMarkers", "PitchVisuals", "BattingVisuals", "PitchDebug", "BattedBallVisuals" },
	-- A regulation infield: bags 90 ft from home. Landings shorter than this
	-- may still roll foul/fair, so their fair/foul call is provisional.
	BaseDistanceMeters = 27.43,
}

-- Foul lines. Markers (PitchConfig.Markers.LeftFoulPole / RightFoulPole,
-- then FirstBase / ThirdBase) define them when present; otherwise the
-- rulebook geometry is used: each line 45 deg from the home -> mound line.
BattedBallConfig.FoulLines = {
	FallbackHalfAngleDegrees = 45,
	-- Marker-derived lines outside this opening angle are rejected as bad markers.
	MinOpeningDegrees = 70,
	MaxOpeningDegrees = 110,
}

-- Hit lifecycle (HitLifecycle / BattedBallServer).
BattedBallConfig.Lifecycle = {
	-- After the first impact the lane holds this long before the next pitch can start.
	ResultHoldSeconds = 1.5,
	-- A client-predicted flight the server never confirms is removed after this.
	PredictionTimeoutSeconds = 1.25,
}

BattedBallConfig.Display = {
	DistanceUnit = "Feet" :: "Feet" | "Meters",
	-- Visual spin: real spin (2000+ rpm) reads as a blur, so it is slowed down.
	VisualSpinScale = 0.05,
	TrailLifetime = 0.35,
	LandedHoldSeconds = 1.2,
	LandedFadeSeconds = 0.4,
	ResultLabelSeconds = 2.5, -- distance headline for the batter's own hits
	ShowLandingMarker = true,
	LandingMarkerSeconds = 4,
	LandingMarkerDiameterMeters = 1.2,
}

BattedBallConfig.Debug = {
	-- Studio-only; part of the F7 overlay (PitchConfig.Debug).
	ShowTrajectory = true,
	TrajectoryDotEverySteps = 6, -- 40 dots per second of flight
	KeepTrajectories = 2,
	ShowFoulLines = true,
	FoulLineLengthMeters = 130,
	LogHitsToOutput = true,
}

return BattedBallConfig
