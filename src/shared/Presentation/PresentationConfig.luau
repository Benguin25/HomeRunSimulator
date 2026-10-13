--!strict
-- Stage 4 presentation tunables: the cinematic hit camera, impact feedback,
-- ball-flight visuals, the distance counter / result card and sounds.
--
-- Presentation only: nothing here changes a pitch, a swing, a launch, a
-- flight or an outcome. Distances are meters, times seconds, angles degrees
-- unless the name says otherwise. Must stay free of Roblox services so the
-- pure-Luau test runner can load it.

local PresentationConfig = {}
local GameplayConfig = require(script.Parent.Parent.Gameplay.GameplayConfig)

-- Camera state timing (seconds). The landing hold + return must fit inside the
-- server's post-landing hold (BattedBallConfig.Lifecycle.ResultHoldSeconds) so
-- the next windup never starts while the camera is away; a test enforces it.
PresentationConfig.Timing = {
	-- After contact the camera holds on the batter this long (the "hit" beat),
	-- then blends into ball-follow. Cosmetic only (camera, not the ball). 0 = off.
	ContactHoldSeconds = 0.06,
	-- Blend from the batting framing into the follow camera.
	ContactTransitionSeconds = 0.4,
	-- Camera holds on the first impact this long before returning.
	LandingHoldSeconds = GameplayConfig.Pacing.LandingHoldSeconds,
	-- Blend back to the batting framing.
	ReturnSeconds = GameplayConfig.Pacing.ReturnSeconds,
	-- The return path arcs up by this much per 100 m of travel (keeps it off the field / fences).
	ReturnArcMetersPer100 = 6,
	ReturnArcMaxMeters = 12,
	-- If the landing time comes and the server has not answered yet, hold at
	-- most this much longer for the result before returning anyway.
	OutcomeGraceSeconds = 0.75,
	-- Safety net: no hit presentation may last longer than this (s after contact).
	MaxHitSeconds = 20,
}

-- Follow-camera profiles keyed by launch angle (degrees). The camera blends
-- linearly between neighbouring anchors, so there is no cliff at a category
-- boundary. Offsets are relative to the ball and its horizontal heading:
--   Back     : behind the ball along the heading
--   Height   : above the (lagged) ball
--   Side     : sideways, on the batter's side of the heading (as the batting camera), for a 3/4 view
--   LagSeconds : the camera anchors to where the ball was this long ago, so
--                the ball visibly pulls away (bounded, frame-rate independent)
--   VerticalFollow : 1 = rides with the ball; <1 = stays lower while the ball climbs
--   LookAheadSeconds / LookDown : framing of the look point
--   FieldOfView : base vertical FOV
PresentationConfig.Profiles = {
	{
		name = "Grounder",
		launchDegrees = 0,
		Back = 6.5,
		Height = 2.2,
		Side = 1.2,
		LagSeconds = 0.08,
		VerticalFollow = 0.6,
		LookAheadSeconds = 0.35,
		LookDown = 0.6,
		FieldOfView = 60,
	},
	{
		name = "LineDrive",
		launchDegrees = 16,
		Back = 7.5,
		Height = 2.6,
		Side = 1.4,
		LagSeconds = 0.14,
		VerticalFollow = 0.85,
		LookAheadSeconds = 0.3,
		LookDown = 0.5,
		FieldOfView = 62,
	},
	{
		name = "FlyBall",
		launchDegrees = 32,
		Back = 10,
		Height = 3.4,
		Side = 2,
		LagSeconds = 0.16,
		VerticalFollow = 0.8,
		LookAheadSeconds = 0.25,
		LookDown = 2.6,
		FieldOfView = 64,
	},
	{
		name = "PopUp",
		launchDegrees = 55,
		Back = 11,
		Height = 2.5,
		Side = 2.2,
		LagSeconds = 0.12,
		VerticalFollow = 0.65,
		LookAheadSeconds = 0.15,
		LookDown = 1.5,
		FieldOfView = 66,
	},
}

PresentationConfig.Camera = {
	-- Power (exit velocity) widens the shot: extra pullback and FOV, capped.
	PowerMinMph = 55,
	PowerMaxMph = 110, -- full extra pullback / FOV at and above this
	PowerPullbackScale = 0.35, -- Back/Height multiplied by up to 1 + this
	PowerFovBonus = 6, -- degrees at full power
	-- The lagged anchor never trails the ball by more than this (very fast hits).
	MaxLagMeters = 5,
	-- Smoothing time constants (critically damped springs; larger = softer).
	OffsetSmoothSeconds = 0.35, -- camera offset from the ball
	LookSmoothSeconds = 0.18, -- look point offset from the ball
	FovSmoothSeconds = 0.4,
	-- Heading (direction "behind" the ball): follows the horizontal velocity,
	-- never turns faster than this, and ignores slower horizontal speeds.
	HeadingSmoothSeconds = 0.5,
	MaxHeadingDegreesPerSecond = 90,
	MinHeadingSpeedMps = 2,
	-- Vertical look-ahead is scaled down to keep the horizon calm near the apex.
	LookAheadVerticalScale = 0.35,
	-- Never look steeper than this up or down (no flips, no banking; roll is always 0).
	MaxPitchDegrees = 65,
	-- The camera stays at least this far above home-plate level.
	MinHeightAboveField = 1.2,
	-- Landing: the camera eases to a slightly wider view of the impact area.
	LandingExtraBack = 2.5,
	LandingExtraHeight = 2,
	LandingLookDown = 0,
	-- Occlusion (client raycast from the ball to the camera): the camera is
	-- pulled in front of blocking geometry at once, and eases back out.
	AvoidOcclusion = true,
	OcclusionPaddingMeters = 0.6,
	OcclusionOutSeconds = 0.5,
	-- The batting framing's FOV comes from PitchConfig.Camera.FieldOfView.
}

-- Camera impulse on strong contact: a deterministic decaying oscillation
-- (no randomness), small and short to avoid motion sickness.
PresentationConfig.Shake = {
	Enabled = true,
	MinIntensity = 0.45, -- impulse only for contact at least this strong (0..1)
	MaxDegrees = 0.9, -- at intensity 1
	FrequencyHz = 14,
	DecaySeconds = 0.09,
	DurationSeconds = 0.35,
	FovPunchDegrees = 3, -- brief FOV widening at intensity 1
	FovPunchSeconds = 0.25,
}

-- Contact intensity (0..1) from measured contact properties. Weights sum to 1.
PresentationConfig.Intensity = {
	ExitVelocityLowMph = 35, -- intensity contribution 0 at/below
	ExitVelocityHighMph = 85, -- full contribution at/above
	RelativeSpeedLowMps = 25, -- bat-ball closing speed (|bat - ball| velocity)
	RelativeSpeedHighMps = 50,
	SweetSpotToleranceMeters = 0.12, -- full credit at the sweet spot, none beyond this
	IdealLaunchDegrees = 25, -- launch-angle factor peaks here...
	LaunchSpreadDegrees = 30, -- ...and falls off (Gaussian) with this spread
	LaunchMinFactor = 0.6, -- a topped/popped ball keeps at least this much
	Weights = {
		ExitVelocity = 0.45,
		Quality = 0.25,
		RelativeSpeed = 0.15,
		SweetSpot = 0.15,
	},
	-- Tiers pick the sound and effect scale.
	SolidAt = 0.4,
	CrushedAt = 0.72,
}

-- Impact burst at the real contact point.
PresentationConfig.Impact = {
	FlashSeconds = 0.12,
	FlashMinMeters = 0.12,
	FlashMaxMeters = 0.35,
	RingEnabled = true, -- expanding shockwave ring, Solid and Crushed only
	RingSeconds = 0.22,
	RingMaxMeters = 1.6,
	SparksWeak = 6,
	SparksSolid = 12,
	SparksCrushed = 22,
	LandingPuffEnabled = true,
	LandingPuffParticles = 14,
}

-- Batted-ball flight visuals (cosmetic; the ball path is the physics flight).
PresentationConfig.Flight = {
	-- Trail lifetime / opacity grow with ball speed between these speeds.
	TrailSlowMps = 15,
	TrailFastMps = 45,
	TrailLifetimeSlow = 0.18,
	TrailLifetimeFast = 0.45,
	TrailTransparencySlow = 0.75,
	TrailTransparencyFast = 0.35,
	TrailSteps = 8, -- trail properties change only when the speed crosses one of these levels
	-- Screen-space halo so the ball stays visible far away. Fades in with camera distance.
	HaloEnabled = true,
	HaloPixels = 9,
	HaloFadeStartMeters = 8,
	HaloFadeEndMeters = 22,
	HaloMaxOpacity = 0.85,
}

-- Distance counter and result card.
PresentationConfig.Hud = {
	CounterDelaySeconds = 0.15, -- after contact
	CounterFadeSeconds = 0.18,
	-- Hits that never get farther than this from home plate do not show a live counter.
	CounterMinMeters = 3,
	FinalPunchSeconds = 0.18,
	FinalPunchScale = 1.18,
	CardInSeconds = 0.22,
	CardOutSeconds = 0.2,
	-- The card appears this long after the result is known (lets the landing read first).
	CardDelaySeconds = 0.12,
	-- Reference resolution for UI scale (UIScale = min(w/RefW, h/RefH), clamped).
	ReferenceWidth = 1280,
	ReferenceHeight = 720,
	MinScale = 0.6,
	MaxScale = 1.25,
	-- Batting HUD (reticle, zone) fades back in over the last part of the return.
	AimHudReturnFraction = 0.6,
}

-- Sounds. Ids are Roblox built-in placeholders verified to ship with the client
-- (content/sounds). Replace them with real assets: a wood bat crack (3 tiers),
-- a ball whoosh loop, a grass thud, a wall knock and a UI tick. Empty id = off.
PresentationConfig.Sounds = {
	MasterVolume = 0.65,
	MaxConcurrent = 3,
	MinGapSeconds = 0.08, -- the same sound never restarts faster than this
	Weak = { Id = "rbxasset://sounds/action_jump_land.mp3", Volume = 0.45, Speed = 1.55 },
	Solid = { Id = "rbxasset://sounds/action_jump_land.mp3", Volume = 0.8, Speed = 1.9 },
	Crushed = { Id = "rbxasset://sounds/action_jump_land.mp3", Volume = 1, Speed = 2.1 },
	-- Layered under Crushed for weight.
	CrushedLayer = { Id = "", Volume = 0.15, Speed = 1.6 },
	Whoosh = { Id = "", Volume = 0.3, Speed = 1 }, -- looped on the ball while it flies (no placeholder)
	Landing = { Id = "rbxasset://sounds/action_jump_land.mp3", Volume = 0.35, Speed = 0.8 },
	Wall = { Id = "rbxasset://sounds/action_jump_land.mp3", Volume = 0.55, Speed = 0.6 },
	Result = { Id = "rbxasset://sounds/volume_slider.ogg", Volume = 0.35, Speed = 1.15 },
	Pitch = { Id = "rbxasset://sounds/action_jump.mp3", Volume = 0.12, Speed = 1.65 },
	Swing = { Id = "rbxasset://sounds/action_jump.mp3", Volume = 0.25, Speed = 0.85 },
	Miss = { Id = "", Volume = 0.12, Speed = 1 },
	Best = { Id = "rbxasset://sounds/volume_slider.ogg", Volume = 0.4, Speed = 1.35 },
	Upgrade = { Id = "rbxasset://sounds/volume_slider.ogg", Volume = 0.3, Speed = 1.55 },
	Rebirth = { Id = "rbxasset://sounds/volume_slider.ogg", Volume = 0.45, Speed = 0.9 },
}

-- Post-swing analysis panel (timing, contact placement, coaching tip). Every
-- number shown comes from the server's swing result / batted-ball records.
PresentationConfig.SwingAnalysis = {
	-- Timing classes as fractions of BattingConfig.Quality.TimingToleranceSeconds
	-- (the error at which the contact-quality timing factor reaches zero).
	PerfectFraction = 0.18, -- |error| <= ~13 ms: PERFECT
	GoodFraction = 0.45, -- <= ~32 ms: GOOD (just early / just late)
	-- Up to 1x tolerance: EARLY / LATE; beyond it: VERY EARLY / VERY LATE.
	MeterRangeFraction = 2, -- the timing meter spans +/- this many tolerances
	-- Placement calls (aimed high/low, inside/outside) only beyond this distance.
	PlacementCallMeters = 0.03,
	-- A contact factor below this is worth a coaching tip.
	TipFactorBelow = 0.9,
	-- Height tips use the confirmed launch angle: at/above PopUp the bat was
	-- under the ball, at/below GroundBall it topped it; in between the flight
	-- was fine and no height correction is suggested.
	PopUpDegrees = 40,
	GroundBallDegrees = 5,
	-- Panel lifecycle (seconds).
	MissDelaySeconds = 0, -- after the server answer / the moment of the miss
	ContactDelaySeconds = 0.35, -- lets the contact beat read first
	InSeconds = 0.25,
	OutSeconds = 0.25,
	HideBeforeReleaseSeconds = 0.35, -- fades out late in the next windup
	MaxMissSeconds = 9,
	MaxContactSeconds = 25,
	CompactKey = "H", -- toggles the compact (one-line) layout
}

return PresentationConfig
