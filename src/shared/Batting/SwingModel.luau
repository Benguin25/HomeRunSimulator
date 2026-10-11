--!strict
-- Swing kinematics shared by server (authoritative collision) and client
-- (rendered bat, prediction). Everything is a pure function of server time, so
-- the bat is in the same place at time t on every machine and at any frame rate.
--
-- State machine (by time since the click):
--   Ready -> Windup -> Active -> FollowThrough -> Recovery -> Ready
--
-- Bat model: a straight bat whose knob (hands) and barrel rotate about a pivot
-- on the batter's body axis. The swing plane is spanned by:
--   across  : from the batter toward/over the plate (bat direction when square)
--   tangent : direction the sweet spot moves at square (toward the pitcher,
--             tilted up by the attack angle)
--   axis    : across x tangent (rotation axis, roughly world up)
-- At angle theta the bat points along across*cos(theta) + tangent*sin(theta).
-- The pivot is placed so that at theta = 0 the sweet spot sits exactly on the
-- aim point. Aim therefore positions the whole swing path.
--
-- During Active the angle advances at a constant rate `omega`, which makes the
-- collision volume exact and gives an analytic speed bound for the sweep test.

local Pitching = script.Parent.Parent.Pitching
local LaneGeometry = require(Pitching.LaneGeometry)
local PitchConfig = require(Pitching.PitchConfig)
local PitchPhysics = require(Pitching.PitchPhysics)

local BattingConfig = require(script.Parent.BattingConfig)

local SwingModel = {}

export type Phase = "Ready" | "Windup" | "Active" | "FollowThrough" | "Recovery"

SwingModel.PHASES = { "Windup", "Active", "FollowThrough", "Recovery" } :: { Phase }

export type Timeline = {
	windup: number,
	active: number,
	followThrough: number,
	recovery: number,
	total: number,
}

export type BatDimensions = {
	length: number, -- studs
	sweetSpot: number, -- studs from knob
	barrelStart: number, -- studs from knob
	barrelRadius: number,
	handleRadius: number,
	pivotRadius: number, -- pivot -> knob
}

export type Swing = {
	startTime: number, -- server time of the click (windup begins)
	aimX: number, -- studs, lane-local (see BattingConfig.Aim)
	aimY: number,
	aimPoint: Vector3, -- sweet spot position when square
	pivot: Vector3,
	across: Vector3,
	tangent: Vector3,
	axis: Vector3,
	omega: number, -- rad/s during Active
	timeline: Timeline,
	activeStart: number, -- server time
	activeEnd: number,
	squareTime: number, -- server time the bat is square (sweet spot on the aim point)
	dims: BatDimensions,
	-- Angles (radians)
	startAngle: number,
	endAngle: number,
	restAngle: number,
	restRaise: number,
	followEndAngle: number,
	followRaise: number,
}

export type Pose = {
	knob: Vector3,
	tip: Vector3,
	direction: Vector3, -- unit, knob -> tip
	planeNormal: Vector3, -- swing-plane normal (the bat's "up")
	angle: number, -- radians in the swing plane
	collidable: boolean,
}

function SwingModel.timeline(): Timeline
	local cfg = BattingConfig.Swing
	return {
		windup = cfg.WindupSeconds,
		active = cfg.ActiveSeconds,
		followThrough = cfg.FollowThroughSeconds,
		recovery = cfg.RecoverySeconds,
		total = cfg.WindupSeconds + cfg.ActiveSeconds + cfg.FollowThroughSeconds + cfg.RecoverySeconds,
	}
end

function SwingModel.dimensions(geometry: LaneGeometry.Geometry): BatDimensions
	local units = geometry.units
	local bat = BattingConfig.Bat
	return {
		length = units.toStuds(bat.LengthMeters),
		sweetSpot = units.toStuds(bat.SweetSpotFromKnobMeters),
		barrelStart = units.toStuds(bat.BarrelStartFromKnobMeters),
		barrelRadius = units.toStuds(bat.BarrelRadiusMeters),
		handleRadius = units.toStuds(bat.HandleRadiusMeters),
		pivotRadius = units.toStuds(bat.PivotBehindKnobMeters),
	}
end

-- Batter side sign as used by LaneGeometry (+1 = batter on the catcher's right).
function SwingModel.batterSideSign(): number
	return if PitchConfig.Geometry.BatterSide == "Left" then 1 else -1
end

-- The vertical plane aim is projected onto (normal points toward the catcher,
-- like the zone plane).
function SwingModel.contactPlane(geometry: LaneGeometry.Geometry): PitchPhysics.Plane
	local offset = geometry.units.toStuds(BattingConfig.Aim.ContactPlaneOffsetMeters)
	return {
		point = geometry.zonePlane.point + geometry.toPitcher * offset,
		normal = geometry.zonePlane.normal,
	}
end

-- World position of an aim coordinate (on the contact plane).
function SwingModel.aimToWorld(geometry: LaneGeometry.Geometry, aimX: number, aimY: number): Vector3
	local plane = SwingModel.contactPlane(geometry)
	return plane.point + geometry.right * aimX + geometry.up * aimY
end

-- Aim region in studs: minX, maxX, minY, maxY.
function SwingModel.aimBounds(geometry: LaneGeometry.Geometry): (number, number, number, number)
	local units = geometry.units
	local aim = BattingConfig.Aim
	return units.toStuds(aim.MinXMeters), units.toStuds(aim.MaxXMeters), units.toStuds(aim.MinYMeters), units.toStuds(aim.MaxYMeters)
end

function SwingModel.clampAim(geometry: LaneGeometry.Geometry, aimX: number, aimY: number): (number, number)
	local minX, maxX, minY, maxY = SwingModel.aimBounds(geometry)
	return math.clamp(aimX, minX, maxX), math.clamp(aimY, minY, maxY)
end

-- Projects a camera ray onto the contact plane. Returns the unclamped aim
-- coordinates, or nil if the ray is parallel to / points away from the plane.
-- `sensitivity` scales the offset from the zone center (1 = exact).
function SwingModel.aimFromRay(
	geometry: LaneGeometry.Geometry,
	origin: Vector3,
	direction: Vector3,
	sensitivity: number?
): (number?, number?)
	local plane = SwingModel.contactPlane(geometry)
	local denom = direction:Dot(plane.normal)
	if math.abs(denom) < 1e-6 then
		return nil, nil
	end
	local distance = (plane.point - origin):Dot(plane.normal) / denom
	if distance <= 0 then
		return nil, nil
	end
	local hit = origin + direction * distance
	local offset = hit - plane.point
	local x, y = offset:Dot(geometry.right), offset:Dot(geometry.up)
	local gain = sensitivity or 1
	if gain ~= 1 then
		local centerY = (geometry.zoneBottom + geometry.zoneTop) / 2
		x *= gain
		y = centerY + (y - centerY) * gain
	end
	return x, y
end

-- The swing pivot for an aim, without building a whole swing.
function SwingModel.pivotFor(geometry: LaneGeometry.Geometry, aimX: number, aimY: number): Vector3
	local dims = SwingModel.dimensions(geometry)
	local across = geometry.right * -SwingModel.batterSideSign()
	return SwingModel.aimToWorld(geometry, aimX, aimY) - across * (dims.pivotRadius + dims.sweetSpot)
end

function SwingModel.new(geometry: LaneGeometry.Geometry, aimX: number, aimY: number, startTime: number): Swing
	local cfg = BattingConfig.Swing
	local dims = SwingModel.dimensions(geometry)
	local timeline = SwingModel.timeline()

	local across = geometry.right * -SwingModel.batterSideSign()
	local attack = math.rad(cfg.AttackAngleDegrees)
	local tangent = geometry.toPitcher * math.cos(attack) + geometry.up * math.sin(attack)
	local axis = across:Cross(tangent).Unit

	local aimPoint = SwingModel.aimToWorld(geometry, aimX, aimY)
	local pivot = aimPoint - across * (dims.pivotRadius + dims.sweetSpot)

	local startAngle = math.rad(cfg.ActiveStartAngleDegrees)
	local endAngle = math.rad(cfg.ActiveEndAngleDegrees)
	local omega = (endAngle - startAngle) / timeline.active
	local activeStart = startTime + timeline.windup

	return {
		startTime = startTime,
		aimX = aimX,
		aimY = aimY,
		aimPoint = aimPoint,
		pivot = pivot,
		across = across,
		tangent = tangent,
		axis = axis,
		omega = omega,
		timeline = timeline,
		activeStart = activeStart,
		activeEnd = activeStart + timeline.active,
		squareTime = activeStart - startAngle / omega,
		dims = dims,
		startAngle = startAngle,
		endAngle = endAngle,
		restAngle = math.rad(cfg.RestAngleDegrees),
		restRaise = math.rad(cfg.RestRaiseDegrees),
		followEndAngle = math.rad(cfg.FollowThroughEndAngleDegrees),
		followRaise = math.rad(cfg.FollowThroughRaiseDegrees),
	}
end

-- Click time that makes the bat square at `squareTime` (tests, tooling).
function SwingModel.startTimeForSquareAt(squareTime: number): number
	local cfg = BattingConfig.Swing
	local timeline = SwingModel.timeline()
	local startAngle = math.rad(cfg.ActiveStartAngleDegrees)
	local omega = (math.rad(cfg.ActiveEndAngleDegrees) - startAngle) / timeline.active
	return squareTime + startAngle / omega - timeline.windup
end

-- Phase at server time t, plus the phase's start and end times. Before the
-- click and after recovery the swing is Ready.
function SwingModel.phaseAt(swing: Swing, t: number): (Phase, number, number)
	local tl = swing.timeline
	local elapsed = t - swing.startTime
	if elapsed < 0 then
		return "Ready", -math.huge, swing.startTime
	end
	local boundary = swing.startTime
	local durations = { tl.windup, tl.active, tl.followThrough, tl.recovery }
	for index, duration in durations do
		local phaseEnd = boundary + duration
		if t < phaseEnd then
			return SwingModel.PHASES[index], boundary, phaseEnd
		end
		boundary = phaseEnd
	end
	return "Ready", boundary, math.huge
end

function SwingModel.isReadyAt(swing: Swing?, t: number): boolean
	if swing == nil then
		return true
	end
	return (SwingModel.phaseAt(swing, t)) == "Ready"
end

local function hermite1(p0: number, m0: number, p1: number, m1: number, u: number): number
	local u2 = u * u
	local u3 = u2 * u
	return (2 * u3 - 3 * u2 + 1) * p0 + (u3 - 2 * u2 + u) * m0 + (-2 * u3 + 3 * u2) * p1 + (u3 - u2) * m1
end

local function smoothstep(u: number): number
	return u * u * (3 - 2 * u)
end

-- Swing-plane angle and raise (both radians) at server time t.
function SwingModel.anglesAt(swing: Swing, t: number): (number, number)
	local phase, phaseStart, phaseEnd = SwingModel.phaseAt(swing, t)
	if phase == "Active" then
		return swing.startAngle + swing.omega * (t - swing.activeStart), 0
	elseif phase == "Ready" then
		return swing.restAngle, swing.restRaise
	end
	local duration = phaseEnd - phaseStart
	local u = math.clamp((t - phaseStart) / duration, 0, 1)
	if phase == "Windup" then
		-- Accelerate from rest into the active angular speed.
		local angle = hermite1(swing.restAngle, 0, swing.startAngle, swing.omega * duration, u)
		return angle, swing.restRaise * (1 - u) * (1 - u)
	elseif phase == "FollowThrough" then
		local angle = hermite1(swing.endAngle, swing.omega * duration, swing.followEndAngle, 0, u)
		return angle, swing.followRaise * smoothstep(u)
	else -- Recovery: keep turning forward all the way round to the rest pose.
		local s = smoothstep(u)
		local target = swing.restAngle + 2 * math.pi
		return swing.followEndAngle + (target - swing.followEndAngle) * s, swing.followRaise + (swing.restRaise - swing.followRaise) * s
	end
end

-- Unit bat direction in the swing plane at `angle` (no raise).
function SwingModel.directionAt(swing: Swing, angle: number): Vector3
	return swing.across * math.cos(angle) + swing.tangent * math.sin(angle)
end

function SwingModel.poseAt(swing: Swing, t: number): Pose
	local angle, raise = SwingModel.anglesAt(swing, t)
	local flat = SwingModel.directionAt(swing, angle)
	local direction = if raise == 0 then flat else (flat * math.cos(raise) + swing.axis * math.sin(raise)).Unit
	local knob = swing.pivot + flat * swing.dims.pivotRadius
	-- Bat "up": perpendicular to the bat, in the plane of the raise.
	local planeNormal = if raise == 0 then swing.axis else direction:Cross(swing.axis:Cross(direction)).Unit
	local phase = SwingModel.phaseAt(swing, t)
	return {
		knob = knob,
		tip = knob + direction * swing.dims.length,
		direction = direction,
		planeNormal = planeNormal,
		angle = angle,
		collidable = phase == "Active",
	}
end

-- Collision pose during Active, with t clamped to the Active window. Used by
-- the sweep test so window edges never depend on phase lookups.
function SwingModel.activePoseAt(swing: Swing, t: number): Pose
	local clamped = math.clamp(t, swing.activeStart, swing.activeEnd)
	return SwingModel.poseAtAngle(swing, swing.startAngle + swing.omega * (clamped - swing.activeStart))
end

-- Collision-shaped pose at a swing-plane angle (no timing, no clamping).
function SwingModel.poseAtAngle(swing: Swing, angle: number): Pose
	local direction = SwingModel.directionAt(swing, angle)
	local knob = swing.pivot + direction * swing.dims.pivotRadius
	return {
		knob = knob,
		tip = knob + direction * swing.dims.length,
		direction = direction,
		planeNormal = swing.axis,
		angle = angle,
		collidable = true,
	}
end

-- Pose while waiting (Ready) for an aim, without an actual swing.
function SwingModel.restPose(geometry: LaneGeometry.Geometry, aimX: number, aimY: number): Pose
	local swing = SwingModel.new(geometry, aimX, aimY, math.huge)
	return SwingModel.poseAt(swing, 0)
end

-- Velocity of a bat point during Active (rigid rotation about the pivot axis).
function SwingModel.pointVelocity(swing: Swing, point: Vector3): Vector3
	return (swing.axis * swing.omega):Cross(point - swing.pivot)
end

-- Upper bound on the speed of any bat point during Active (studs/s).
function SwingModel.maxPointSpeed(swing: Swing): number
	return math.abs(swing.omega) * (swing.dims.pivotRadius + swing.dims.length + swing.dims.barrelRadius)
end

-- Sweet-spot speed during Active (studs/s).
function SwingModel.sweetSpotSpeed(swing: Swing): number
	return math.abs(swing.omega) * (swing.dims.pivotRadius + swing.dims.sweetSpot)
end

return SwingModel
