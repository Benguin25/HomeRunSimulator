--!strict
-- Tunables for the procedural pitcher and catcher (presentation only: nothing
-- here changes a pitch's timing, trajectory or any batting outcome). Lengths
-- are meters, times seconds, angles degrees. Colors are RGB 0..255 arrays so
-- this module stays loadable by the pure-Luau test runner.

local AthleteConfig = {}

AthleteConfig.Pitcher = {
	-- 1 = ~1.88 m tall athlete (AthleteRig proportions); a tall pitcher reaches
	-- the default 1.75 m release height with a natural arm slot.
	Scale = 1.05,
	-- Blend from whatever was on screen into a new windup / back to the set
	-- position after an aborted pitch (no snapping).
	BlendSeconds = 0.3,
	AbortBlendSeconds = 0.45,
	-- The head tracks the catcher's target at this height above the plate.
	LookHeightMeters = 0.8,
	MaxHeadTurnDegrees = 85,
	-- The ball is hidden in the glove until the hands break (windup fraction).
	BallRevealStart = 0.5,
	BallRevealEnd = 0.56,
	-- Short streak behind the ball once the arm accelerates (the "here it comes" cue).
	TrailStart = 0.9,
	-- Release alignment: the authored pose is shifted by the small difference
	-- between its hand and the authoritative (jittered) release point. The
	-- body shift ramps in from the leg lift, the stride foot lands with it,
	-- and the shift fades out while the pitcher walks back to the rubber.
	Alignment = {
		StartFraction = 0.5,
		FootPlantFraction = 0.84,
		TrailDragFraction = 0.84,
		MaxBodyVerticalMeters = 0.08, -- the rest of a vertical difference is reached by the arm
		FadeStartSeconds = 1.0, -- after release
		FadeEndSeconds = 2.2,
	},
	-- Idle (set position) breathing.
	IdleBreathPeriodSeconds = 3.4,
	IdleBreathDegrees = 1.2,
	IdleBobMeters = 0.006,
	-- Seconds after release at which the recovery is complete (end of the keyframes).
	RecoverySeconds = 2.2,
}

AthleteConfig.Catcher = {
	Scale = 0.96,
	-- Placement behind the plate (toward the backstop).
	BehindPlateMeters = 1.45,
	-- The resting target (zone middle), never the pitch's own target, so the
	-- catcher cannot tip off a location before the release.
	TargetHeightMeters = 0.78,
	TargetForwardMeters = 0.45, -- mitt held this far in front of the pelvis
	SetupFraction = 0.55, -- of the windup: mitt raised to the target
	-- The mitt starts moving to the real ball this far into the flight.
	ReactFraction = 0.55,
	-- Catch "pop": a short recoil along the ball's path, then a hold.
	RecoilMeters = 0.05,
	RecoilSeconds = 0.08,
	HoldSeconds = 0.55,
	RelaxSeconds = 0.4,
	-- While the local player bats on this lane the catcher is in the camera's
	-- line to the low strike zone: draw it nearly transparent there.
	OwnLaneTransparency = 0.82,
	OwnLaneMittTransparency = 0.55,
}

AthleteConfig.Colors = {
	Skin = { 214, 170, 128 },
	Jersey = { 238, 241, 246 },
	JerseyTrim = { 32, 58, 112 },
	Pants = { 222, 226, 232 },
	Socks = { 32, 58, 112 },
	Cleats = { 28, 30, 36 },
	Cap = { 32, 58, 112 },
	Belt = { 24, 26, 32 },
	Glove = { 132, 78, 38 },
	GloveLace = { 84, 46, 20 },
	CatcherGear = { 46, 52, 64 },
	Mask = { 24, 26, 30 },
}

AthleteConfig.PitcherNumber = "27"

return AthleteConfig
