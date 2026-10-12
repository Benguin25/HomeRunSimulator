--!strict
-- The field coordinate system for batted balls, derived from lane markers.
--
--   origin  : home plate marker at ground level
--   forward : horizontal, home plate -> pitcher marker (toward center field)
--   up      : Roblox world up
--   right   : horizontal, toward the first-base side (catcher's right)
--
-- Field coordinates are meters: x = forward, y = up, z = right. The frame is
-- right-handed (forward x up = right), so cross products agree with world
-- space. Nothing here assumes a world axis: a stadium rotated or moved
-- anywhere gives the same field-frame numbers.
--
-- Angles: spray angle 0 = straightaway center field, + = toward right field
-- (first-base line), - = toward left field (third-base line). The pull side
-- depends on the batter: left field for a right-handed batter.
--
-- Foul lines come from markers when present (foul poles first, then the
-- bases), otherwise from the rulebook layout: 45 degrees either side of the
-- home -> mound line (still marker-relative, never a fixed world angle).

local Pitching = script.Parent.Parent.Pitching
local LaneGeometry = require(Pitching.LaneGeometry)
local PitchConfig = require(Pitching.PitchConfig)

local BattedBallConfig = require(script.Parent.BattedBallConfig)

local FieldFrame = {}

export type Territory = "Fair" | "Foul"

export type Frame = {
	origin: Vector3,
	forward: Vector3,
	up: Vector3,
	right: Vector3,
	metersPerStud: number,
	studsPerMeter: number,
	-- Spray angles (radians) of the foul lines: left < 0 < right.
	leftLineAngle: number,
	rightLineAngle: number,
	foulLineSource: string, -- which markers defined the lines (for logs / debug)
	batterSide: "Right" | "Left",
}

local function angleOf(frame: Frame, world: Vector3): number?
	local offset = world - frame.origin
	local x, z = offset:Dot(frame.forward), offset:Dot(frame.right)
	if x * x + z * z < 1e-6 then
		return nil
	end
	return math.atan2(z, x)
end

-- Picks a foul-line angle for one side from the first usable marker.
local function lineFrom(frame: Frame, candidates: { { name: string, point: Vector3? } }, sign: number): (number?, string?)
	for _, candidate in candidates do
		local point = candidate.point
		if point then
			local angle = angleOf(frame, point)
			if angle and angle * sign > 0 and math.abs(angle) < math.pi / 2 then
				return angle, candidate.name
			end
		end
	end
	return nil, nil
end

function FieldFrame.new(geometry: LaneGeometry.Geometry, batterSide: ("Right" | "Left")?): Frame
	local units = geometry.units
	local forward = geometry.toPitcher
	local up = geometry.up
	local right = geometry.right
	local inputs = geometry.inputs
	local cfg = BattedBallConfig.FoulLines

	local frame: Frame = {
		origin = geometry.plateGround,
		forward = forward,
		up = up,
		right = right,
		metersPerStud = units.metersPerStud,
		studsPerMeter = units.studsPerMeter,
		leftLineAngle = -math.rad(cfg.FallbackHalfAngleDegrees),
		rightLineAngle = math.rad(cfg.FallbackHalfAngleDegrees),
		foulLineSource = "rulebook (45 deg from home -> mound)",
		batterSide = batterSide or PitchConfig.Geometry.BatterSide,
	}

	local left, leftSource = lineFrom(frame, {
		{ name = "LeftFoulPole", point = inputs.leftFoulPole },
		{ name = "ThirdBase", point = inputs.thirdBase },
	}, -1)
	local rightAngle, rightSource = lineFrom(frame, {
		{ name = "RightFoulPole", point = inputs.rightFoulPole },
		{ name = "FirstBase", point = inputs.firstBase },
	}, 1)

	if left or rightAngle then
		local l = left or frame.leftLineAngle
		local r = rightAngle or frame.rightLineAngle
		local opening = math.deg(r - l)
		if opening >= cfg.MinOpeningDegrees and opening <= cfg.MaxOpeningDegrees then
			frame.leftLineAngle = l
			frame.rightLineAngle = r
			frame.foulLineSource = string.format(
				"left: %s, right: %s (opening %.1f deg)",
				leftSource or "rulebook",
				rightSource or "rulebook",
				opening
			)
		else
			frame.foulLineSource = string.format(
				"rulebook (marker foul lines rejected: opening %.1f deg outside %d-%d)",
				opening,
				cfg.MinOpeningDegrees,
				cfg.MaxOpeningDegrees
			)
		end
	end
	return frame
end

-- World position (studs) -> field coordinates (meters).
function FieldFrame.toField(frame: Frame, world: Vector3): (number, number, number)
	local offset = world - frame.origin
	local s = frame.metersPerStud
	return offset:Dot(frame.forward) * s, offset:Dot(frame.up) * s, offset:Dot(frame.right) * s
end

-- Field coordinates (meters) -> world position (studs).
function FieldFrame.toWorld(frame: Frame, x: number, y: number, z: number): Vector3
	local s = frame.studsPerMeter
	return frame.origin + (frame.forward * x + frame.up * y + frame.right * z) * s
end

-- World direction/angular velocity -> field components (no unit change).
function FieldFrame.vectorToField(frame: Frame, v: Vector3): (number, number, number)
	return v:Dot(frame.forward), v:Dot(frame.up), v:Dot(frame.right)
end

-- Field components -> world vector (no unit change).
function FieldFrame.vectorToWorld(frame: Frame, x: number, y: number, z: number): Vector3
	return frame.forward * x + frame.up * y + frame.right * z
end

-- World velocity (studs/s) -> field velocity (m/s).
function FieldFrame.velocityToField(frame: Frame, v: Vector3): (number, number, number)
	local s = frame.metersPerStud
	return v:Dot(frame.forward) * s, v:Dot(frame.up) * s, v:Dot(frame.right) * s
end

-- Spray angle (degrees) of a horizontal field direction / position.
function FieldFrame.sprayAngleDegrees(x: number, z: number): number
	if x * x + z * z < 1e-12 then
		return 0
	end
	return math.deg(math.atan2(z, x))
end

-- + = toward the batter's pull side (left field for a right-handed batter).
function FieldFrame.pullAngleDegrees(frame: Frame, sprayDegrees: number): number
	return if frame.batterSide == "Left" then sprayDegrees else -sprayDegrees
end

-- Fair if the point lies between the foul lines (the lines themselves are fair).
function FieldFrame.territory(frame: Frame, x: number, z: number): Territory
	if x * x + z * z < 1e-6 then
		return "Foul"
	end
	local angle = math.atan2(z, x)
	if angle >= frame.leftLineAngle - 1e-9 and angle <= frame.rightLineAngle + 1e-9 then
		return "Fair"
	end
	return "Foul"
end

function FieldFrame.horizontalDistance(x: number, z: number): number
	return math.sqrt(x * x + z * z)
end

-- Horizontal unit direction (world) of a foul line, for drawing.
function FieldFrame.foulLineDirection(frame: Frame, side: "Left" | "Right"): Vector3
	local angle = if side == "Left" then frame.leftLineAngle else frame.rightLineAngle
	return frame.forward * math.cos(angle) + frame.right * math.sin(angle)
end

return FieldFrame
