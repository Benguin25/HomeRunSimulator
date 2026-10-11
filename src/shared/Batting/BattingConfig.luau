--!strict
-- Shared, data-only configuration for batting (Phase 2).
--
-- Real-world quantities are in meters / seconds / degrees and converted to
-- studs through the lane's Units converter. Values marked "readability"
-- intentionally deviate from reality to make hitting learnable; the realistic
-- baseline is noted beside them.
--
-- Must stay free of Roblox services so the pure-Luau test runner can load it.

local BattingConfig = {}

-- Aiming happens on the "contact plane": a vertical plane parallel to the
-- strike-zone plane, slightly in front of it (good contact is made out front).
-- Aim coordinates are lane-local: x = lateral offset from plate center
-- (+ = catcher's right), y = height above plate ground.
BattingConfig.Aim = {
	ContactPlaneOffsetMeters = 0.15, -- in front of the zone plane, toward the pitcher
	-- Where the bat's sweet spot may be aimed. The strike zone is
	-- x in [-0.216, 0.216], y in [0.48, 1.07]; the region extends past it so
	-- balls just off the zone are still hittable.
	MinXMeters = -0.5,
	MaxXMeters = 0.5,
	MinYMeters = 0.3,
	MaxYMeters = 1.3,
	-- Gain applied to the cursor's offset from the zone center. 1 = the reticle
	-- sits exactly under the cursor (recommended).
	Sensitivity = 1.0,
	-- Exponential smoothing time constant (seconds). 0 = none. Keep tiny: any
	-- smoothing adds aim latency.
	SmoothingSeconds = 0,
	-- Server-side slack when checking that a received aim is inside the region.
	ValidationToleranceMeters = 0.005,
}

-- Bat collision geometry. The rendered bat uses exactly these numbers.
BattingConfig.Bat = {
	LengthMeters = 0.86, -- 34 in
	SweetSpotFromKnobMeters = 0.68, -- ~6.5 in from the tip
	BarrelStartFromKnobMeters = 0.42, -- handle/barrel split
	BarrelRadiusMeters = 0.055, -- readability: real barrel ~0.033 m
	HandleRadiusMeters = 0.022, -- readability: real handle ~0.013 m
	-- The bat rotates about the batter's body axis, this far behind the hands.
	PivotBehindKnobMeters = 0.3,
}

-- Swing timing and arc. Angles are measured in the swing plane from "square"
-- (bat perpendicular to the pitch, pointing across the plate): negative =
-- barrel still behind (catcher side), positive = barrel out front.
--
-- Only the Active window can make contact, and during it the bat turns at a
-- constant angular speed, so the collision volume is an exact function of time.
-- Windup / follow-through / recovery are presentation only.
BattingConfig.Swing = {
	WindupSeconds = 0.05, -- click -> bat enters the hitting zone (kept short for responsiveness)
	ActiveSeconds = 0.11,
	FollowThroughSeconds = 0.18,
	RecoverySeconds = 0.3,
	ActiveStartAngleDegrees = -75,
	ActiveEndAngleDegrees = 60,
	-- Swing plane tilt: the sweet spot moves upward at this angle through
	-- contact (slight uppercut). 0 = perfectly level swing.
	AttackAngleDegrees = 6,
	-- Presentation-only pose angles.
	RestAngleDegrees = -100,
	RestRaiseDegrees = 55, -- bat tilted up "on the shoulder" while waiting
	FollowThroughEndAngleDegrees = 150,
	FollowThroughRaiseDegrees = 35,
}

-- Contact quality. Each factor is in [0, 1]; the score is their weighted
-- product, so one bad factor is enough to make weak contact.
BattingConfig.Quality = {
	-- Timing error = (bat square time) - (ball reaches the aim point's plane).
	TimingToleranceSeconds = 0.07,
	-- Distance along the bat from the sweet spot.
	SweetSpotToleranceMeters = 0.3,
	-- Vertical offset between ball center and bat axis, relative to the
	-- combined radius (ball + barrel). 1 = falls to zero at the very edge of
	-- the bat; >1 is more forgiving (contact itself is still pure geometry).
	VerticalToleranceScale = 1.25,
	Weights = {
		Timing = 1,
		SweetSpot = 1,
		Vertical = 1,
		Efficiency = 0.5, -- how head-on the collision is (closing speed / relative speed)
	},
	Thresholds = {
		Perfect = 0.85,
		Great = 0.65,
		Good = 0.4,
		-- Anything with contact below Good is Weak.
	},
}

-- Where the visible bat rests and how it reaches the authoritative swing
-- (presentation only: none of this touches the collision geometry or timing).
-- During the Active window the rendered bat IS the collision pose; before it
-- the bat is carried from the character's hands into that pose, and after the
-- follow-through it returns to the hands.
BattingConfig.Stance = {
	-- How far the resting bat drifts from the hands toward the aimed swing
	-- (0 = stays at the hands, 1 = sits on the aimed swing's pivot circle).
	-- Lets the hands visibly track the aim so the short windup is a small move.
	PreloadFraction = 0.35,
	ReadyFollowSeconds = 0.05, -- smoothing of the resting bat as the mouse moves
	WindupEasePower = 2, -- >1 = accelerates into the swing
	-- Hands anchor relative to the shoulders, in units of arm length (R15 rig).
	AnchorDownFraction = 0.3,
	AnchorForwardFraction = 0.4, -- toward the plate (the way the chest faces)
	AnchorRearFraction = 0.25, -- toward the catcher (rear shoulder side)
	-- Used when the character has no R15 rig yet (meters from the batter marker).
	FallbackHeightMeters = 0.85,
	FallbackForwardMeters = 0.25,
	FallbackRearMeters = 0.12,
	-- Where the hands grip, measured from the knob along the handle.
	GripBottomMeters = 0.04,
	GripTopMeters = 0.17,
	-- Procedural arms: two-bone IK so both hands follow the bat (R15 only).
	ArmIK = true,
	ElbowOutward = 0.6, -- elbow hint: down, plus this much away from the chest
	-- Silence the default character animations while batting. Roblox's
	-- Animator rewrites every Motor6D.Transform each frame, which would undo
	-- the procedural pose.
	SuppressAnimations = true,
	-- Waist rotation follows the bat's swing angle (0 at the resting angle).
	TorsoYawGain = 0.3,
	MaxTorsoYawDegrees = 55,
	-- Body fit: the swing is a rotation about a pivot on the batter's body
	-- axis, so the visible body is moved (client-side only) to put its shoulders
	-- over that pivot, and crouches when the pivot is far below the shoulders.
	BodyFit = true,
	BodyDeadZoneMeters = 0.1, -- horizontal slack before the body moves
	BodyMaxShiftMeters = 1.2,
	BodyMaxCrouchMeters = 0.3,
	BodyReachMargin = 0.92, -- fraction of arm length the grips may use
	BodyFollowSeconds = 0.09, -- smoothing of the body position
	Legs = true, -- bend the legs with feet planted while crouching
}

-- Collision search settings (see BatCollision).
BattingConfig.Collision = {
	ToleranceMeters = 0.0005, -- surfaces closer than this count as touching
	MaxIterations = 20000,
	SpeedBoundMargin = 1.1, -- safety factor on the max relative speed bound
}

-- Server validation / latency compensation (see SwingValidator).
BattingConfig.Network = {
	-- The client stamps its click with its synchronized server-clock estimate.
	-- The server accepts stamps up to this far in the past (rewind) ...
	MaxRewindSeconds = 0.25,
	-- ... but never more than (measured round-trip ping * factor + slack).
	PingRewindFactor = 1.0,
	RewindSlackSeconds = 0.06,
	-- Clocks are synchronized, so stamps from the future are only clock noise.
	FutureToleranceSeconds = 0.05,
	-- Stamps older than this are rejected outright instead of clamped.
	StaleRejectSeconds = 1.0,
	MinRequestIntervalSeconds = 0.08, -- flood guard, independent of the swing cooldown
	CooldownToleranceSeconds = 0.02,
	MaxSwingsPerPitch = 1,
}

BattingConfig.Presentation = {
	BatBarrelColor = { 0.78, 0.6, 0.38 },
	BatHandleColor = { 0.2, 0.15, 0.12 },
	ReticleColor = { 1, 1, 1 },
	ReticleScale = 1.0, -- multiplies the physically sized reticle (combined contact radius)
	ReticleMinPixels = 18,
	ReticleThicknessPixels = 2,
	ShowBarrelLine = true, -- thin line showing the barrel's reach at the aim height
	ShowZoneOutline = true,
	ZoneOutlineTransparency = 0.75,
	HideSystemCursor = true,
	LabelSeconds = 0.9,
	-- Placeholder sounds from Studio's built-in content. Swap for real assets.
	SwingSoundId = "rbxasset://sounds/action_jump.mp3",
	SwingSoundSpeed = 1.5,
	ContactSoundId = "rbxasset://sounds/action_jump_land.mp3",
	ContactSoundSpeed = 1.9,
	MissSoundId = "rbxasset://sounds/action_jump.mp3",
	MissSoundSpeed = 0.75,
	CameraKickDegrees = 0.35, -- Great/Perfect only; decays in CameraKickSeconds
	CameraKickSeconds = 0.12,
	ContactMarkerSeconds = 1.5,
	-- Temporary Phase 2 stand-in for batted-ball flight: a short, fading
	-- deflection along the impact normal. NOT a distance or outcome.
	TemporaryDeflection = {
		Enabled = true,
		Seconds = 0.6,
		SpeedScale = 0.5, -- fraction of the closing speed
	},
}

BattingConfig.Debug = {
	-- Studio-only; shares PitchConfig.Debug's toggle key and visibility.
	ShowBatAtContact = true,
	ShowSweptPath = true,
	SweptPathSamples = 12,
	ShowContactPoint = true,
	LogSwingsToOutput = true,
}

return BattingConfig
