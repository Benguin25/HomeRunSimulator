--!strict
-- Pure camera math for the hit presentation (no Roblox services, no
-- Instances): springs, framing profiles, the follow-camera pose, yaw/pitch
-- orientation, occlusion easing and the contact impulse.
--
-- Orientation is always yaw + pitch with zero roll, so the horizon stays
-- level and there is nothing to bank. Pitch is clamped, so the camera never
-- looks straight up or down (no lookAt degeneracy, no 180-degree flips).
-- Every smoother is an exact closed-form critically damped spring: for a
-- fixed target it gives the same result whatever the frame rate.

local PresentationConfig = require(script.Parent.PresentationConfig)

local CameraMath = {}

export type Pose = {
	position: Vector3,
	yaw: number, -- radians, world: 0 looks along -Z
	pitch: number, -- radians, + looks up
	fov: number, -- degrees (vertical)
}

export type Profile = {
	name: string,
	Back: number,
	Height: number,
	Side: number,
	LagSeconds: number,
	VerticalFollow: number,
	LookAheadSeconds: number,
	LookDown: number,
	FieldOfView: number,
}

export type Spring = { value: Vector3, velocity: Vector3 }
export type ScalarSpring = { value: number, velocity: number }

local UP = Vector3.new(0, 1, 0)

---------------------------------------------------------------------------
-- Springs
---------------------------------------------------------------------------

-- Exact critically damped step toward a fixed `target` over `dt`.
-- `tau` is the time constant (omega = 2 / tau): from rest, ~60% of the gap
-- closes in tau and ~99% in 4 tau, with no overshoot.
function CameraMath.springStep(spring: Spring, target: Vector3, tau: number, dt: number)
	if tau <= 0 or dt <= 0 then
		if tau <= 0 then
			spring.value = target
			spring.velocity = Vector3.zero
		end
		return
	end
	local w = 2 / tau
	local x0 = spring.value - target
	local v0 = spring.velocity
	local decay = math.exp(-w * dt)
	local c = v0 + x0 * w
	spring.value = target + (x0 + c * dt) * decay
	spring.velocity = (v0 - c * (w * dt)) * decay
end

function CameraMath.scalarSpringStep(spring: ScalarSpring, target: number, tau: number, dt: number)
	if tau <= 0 or dt <= 0 then
		if tau <= 0 then
			spring.value = target
			spring.velocity = 0
		end
		return
	end
	local w = 2 / tau
	local x0 = spring.value - target
	local v0 = spring.velocity
	local decay = math.exp(-w * dt)
	local c = v0 + x0 * w
	spring.value = target + (x0 + c * dt) * decay
	spring.velocity = (v0 - c * (w * dt)) * decay
end

-- First-order exponential approach, frame-rate independent.
function CameraMath.damp(current: number, target: number, tau: number, dt: number): number
	if tau <= 0 then
		return target
	end
	return target + (current - target) * math.exp(-dt / tau)
end

---------------------------------------------------------------------------
-- Easing
---------------------------------------------------------------------------

function CameraMath.easeOutCubic(a: number): number
	local x = 1 - math.clamp(a, 0, 1)
	return 1 - x * x * x
end

-- Gentler than cubic: peak speed is pi/2 x the average (cubic: 3x). Used for
-- long camera moves (the return) to keep the peak velocity comfortable.
function CameraMath.easeInOutSine(a: number): number
	return 0.5 - 0.5 * math.cos(math.pi * math.clamp(a, 0, 1))
end

function CameraMath.easeInOutCubic(a: number): number
	local x = math.clamp(a, 0, 1)
	if x < 0.5 then
		return 4 * x * x * x
	end
	local y = -2 * x + 2
	return 1 - y * y * y / 2
end

---------------------------------------------------------------------------
-- Orientation
---------------------------------------------------------------------------

-- Wraps an angle to (-pi, pi].
function CameraMath.wrapAngle(a: number): number
	local wrapped = (a + math.pi) % (2 * math.pi) - math.pi
	if wrapped <= -math.pi then
		wrapped += 2 * math.pi
	end
	return wrapped
end

-- Yaw/pitch (radians) of a direction; pitch clamped to +-maxPitch.
function CameraMath.yawPitch(direction: Vector3, maxPitchDegrees: number?): (number, number)
	local horizontal = math.sqrt(direction.X * direction.X + direction.Z * direction.Z)
	local yaw = if horizontal > 1e-9 then math.atan2(-direction.X, -direction.Z) else 0
	local pitch = math.atan2(direction.Y, horizontal)
	local limit = math.rad(maxPitchDegrees or PresentationConfig.Camera.MaxPitchDegrees)
	return yaw, math.clamp(pitch, -limit, limit)
end

-- Unit look direction for yaw/pitch (matches CFrame.fromEulerAnglesYXZ(pitch, yaw, 0).LookVector).
function CameraMath.direction(yaw: number, pitch: number): Vector3
	local cp = math.cos(pitch)
	return Vector3.new(-math.sin(yaw) * cp, math.sin(pitch), -math.cos(yaw) * cp)
end

-- Pose looking from `position` at `target` (stable: clamped pitch, zero roll).
function CameraMath.lookPose(position: Vector3, target: Vector3, fov: number, maxPitchDegrees: number?): Pose
	local yaw, pitch = CameraMath.yawPitch(target - position, maxPitchDegrees)
	return { position = position, yaw = yaw, pitch = pitch, fov = fov }
end

-- Pose from a camera CFrame (its roll is discarded).
function CameraMath.poseFromCFrame(cframe: CFrame, fov: number): Pose
	local yaw, pitch = CameraMath.yawPitch(cframe.LookVector, 89)
	return { position = cframe.Position, yaw = yaw, pitch = pitch, fov = fov }
end

function CameraMath.toCFrame(pose: Pose): CFrame
	return CFrame.new(pose.position) * CFrame.fromEulerAnglesYXZ(pose.pitch, pose.yaw, 0)
end

-- Interpolates two poses: position along a straight line (plus an optional
-- upward arc), yaw along the shortest way round, pitch and FOV linearly.
function CameraMath.blendPoses(a: Pose, b: Pose, alpha: number, arcHeight: number?): Pose
	local t = math.clamp(alpha, 0, 1)
	local position = a.position:Lerp(b.position, t)
	if arcHeight and arcHeight > 0 then
		position += UP * (arcHeight * math.sin(math.pi * t))
	end
	return {
		position = position,
		yaw = a.yaw + CameraMath.wrapAngle(b.yaw - a.yaw) * t,
		pitch = a.pitch + (b.pitch - a.pitch) * t,
		fov = a.fov + (b.fov - a.fov) * t,
	}
end

---------------------------------------------------------------------------
-- Profiles
---------------------------------------------------------------------------

local PROFILE_KEYS = { "Back", "Height", "Side", "LagSeconds", "VerticalFollow", "LookAheadSeconds", "LookDown", "FieldOfView" }

-- Framing for a launch angle: linear blend between the neighbouring anchors.
-- `name` is the nearest anchor's (debug / tests).
function CameraMath.profileFor(launchDegrees: number, profiles: { any }?): Profile
	local list = profiles or PresentationConfig.Profiles
	local first, last = list[1], list[#list]
	local lo, hi, a = first, first, 0
	if launchDegrees <= first.launchDegrees then
		lo, hi, a = first, first, 0
	elseif launchDegrees >= last.launchDegrees then
		lo, hi, a = last, last, 0
	else
		for i = 1, #list - 1 do
			local p, q = list[i], list[i + 1]
			if launchDegrees >= p.launchDegrees and launchDegrees <= q.launchDegrees then
				lo, hi = p, q
				a = (launchDegrees - p.launchDegrees) / (q.launchDegrees - p.launchDegrees)
				break
			end
		end
	end
	local result: any = { name = if a < 0.5 then lo.name else hi.name }
	for _, key in PROFILE_KEYS do
		result[key] = lo[key] + (hi[key] - lo[key]) * a
	end
	return result :: Profile
end

-- 0..1 power factor from exit velocity (mph).
function CameraMath.powerFactor(exitSpeedMph: number): number
	local cfg = PresentationConfig.Camera
	return math.clamp((exitSpeedMph - cfg.PowerMinMph) / (cfg.PowerMaxMph - cfg.PowerMinMph), 0, 1)
end

---------------------------------------------------------------------------
-- Heading
---------------------------------------------------------------------------

-- Horizontal unit heading (world). Turns toward the horizontal velocity,
-- exponentially smoothed and rate limited; keeps the current heading when
-- the ball moves too slowly sideways to define one (straight-up pop-ups).
function CameraMath.stepHeading(current: Vector3, velocityStuds: Vector3, metersPerStud: number, dt: number): Vector3
	local cfg = PresentationConfig.Camera
	local horizontal = Vector3.new(velocityStuds.X, 0, velocityStuds.Z)
	if horizontal.Magnitude * metersPerStud < cfg.MinHeadingSpeedMps then
		return current
	end
	local target = horizontal.Unit
	local currentYaw = math.atan2(-current.X, -current.Z)
	local targetYaw = math.atan2(-target.X, -target.Z)
	local delta = CameraMath.wrapAngle(targetYaw - currentYaw)
	local smoothed = delta * (1 - math.exp(-dt / math.max(cfg.HeadingSmoothSeconds, 1e-6)))
	local maxStep = math.rad(cfg.MaxHeadingDegreesPerSecond) * dt
	local yaw = currentYaw + math.clamp(smoothed, -maxStep, maxStep)
	return Vector3.new(-math.sin(yaw), 0, -math.cos(yaw))
end

---------------------------------------------------------------------------
-- Follow pose
---------------------------------------------------------------------------

export type FollowInput = {
	ball: Vector3, -- world studs: where the ball is drawn now
	lagged: Vector3, -- world studs: where it was LagSeconds ago (the camera anchor)
	velocity: Vector3, -- world studs/s at `ball`
	heading: Vector3, -- horizontal unit (world)
	launchHeight: number, -- world Y (studs) of the contact point
	fieldHeight: number, -- world Y (studs) of home-plate level
	studsPerMeter: number,
	sideSign: number, -- +1 / -1: which side of the heading the 3/4 view sits on
	profile: Profile,
	power: number, -- 0..1
	landing: boolean, -- the ball is at rest at its first impact
}

export type FollowTarget = {
	offset: Vector3, -- camera position - ball (studs)
	lookOffset: Vector3, -- look point - ball (studs)
	fov: number,
}

-- Desired (unsmoothed) camera offset, look offset and FOV.
function CameraMath.followTarget(input: FollowInput): FollowTarget
	local cfg = PresentationConfig.Camera
	local profile = input.profile
	local s = input.studsPerMeter
	local heading = input.heading
	local sideAxis = heading:Cross(UP) -- right of the heading
	local scale = 1 + cfg.PowerPullbackScale * input.power

	local back = profile.Back * scale
	local height = profile.Height * scale
	local lookDown = profile.LookDown
	local lookAhead = profile.LookAheadSeconds
	if input.landing then
		back += cfg.LandingExtraBack
		height += cfg.LandingExtraHeight
		lookDown = cfg.LandingLookDown
		lookAhead = 0
	end

	-- Anchor: the lagged ball, lowered while it climbs (VerticalFollow < 1).
	local anchor = input.lagged
	local rise = anchor.Y - input.launchHeight
	if rise > 0 then
		anchor -= UP * (rise * (1 - profile.VerticalFollow))
	end
	local position = anchor - heading * (back * s) + UP * (height * s) + sideAxis * (input.sideSign * profile.Side * s)
	local minY = input.fieldHeight + cfg.MinHeightAboveField * s
	if position.Y < minY then
		position = Vector3.new(position.X, minY, position.Z)
	end

	local v = input.velocity
	local ahead = Vector3.new(v.X, v.Y * cfg.LookAheadVerticalScale, v.Z) * lookAhead
	local look = input.ball + ahead - UP * (lookDown * s)

	return {
		offset = position - input.ball,
		lookOffset = look - input.ball,
		fov = profile.FieldOfView + cfg.PowerFovBonus * input.power,
	}
end

---------------------------------------------------------------------------
-- Occlusion
---------------------------------------------------------------------------

-- The allowed camera distance from the ball: clamped in at once when
-- something blocks the view (never renders from inside a wall), eased back
-- out once clear (no popping). `blockedDistance` = nil when clear.
function CameraMath.stepOcclusion(current: number, desired: number, blockedDistance: number?, dt: number): number
	local target = if blockedDistance then math.min(desired, blockedDistance) else desired
	local eased = CameraMath.damp(current, target, PresentationConfig.Camera.OcclusionOutSeconds, dt)
	return math.min(eased, target)
end

---------------------------------------------------------------------------
-- Contact impulse
---------------------------------------------------------------------------

-- Pitch/yaw offsets (radians) and FOV offset `age` seconds after an impulse
-- of `intensity` (0..1). Deterministic, decays to exactly 0 at DurationSeconds.
function CameraMath.impulse(intensity: number, age: number): (number, number, number)
	local cfg = PresentationConfig.Shake
	if not cfg.Enabled or intensity < cfg.MinIntensity or age < 0 or age >= cfg.DurationSeconds then
		return 0, 0, 0
	end
	local strength = math.clamp((intensity - cfg.MinIntensity) / math.max(1 - cfg.MinIntensity, 1e-6), 0, 1)
	local envelope = math.exp(-age / cfg.DecaySeconds) * (1 - age / cfg.DurationSeconds)
	local amplitude = math.rad(cfg.MaxDegrees) * strength * envelope
	local phase = 2 * math.pi * cfg.FrequencyHz * age
	local fovAge = age / cfg.FovPunchSeconds
	local fov = if fovAge < 1 then cfg.FovPunchDegrees * strength * math.sin(math.pi * math.min(fovAge * 2, 1)) * (1 - fovAge) else 0
	return amplitude * math.cos(phase), amplitude * 0.5 * math.sin(phase * 0.7), fov
end

return CameraMath
