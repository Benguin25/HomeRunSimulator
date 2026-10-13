--!strict
-- Geometry of one batting lane (pitcher -> plate), derived from marker
-- positions plus PitchConfig. Pure: the server builds it from markers, then
-- replicates only the four input points; each client rebuilds the identical
-- geometry with the same code.
--
-- Lane axes (all horizontal unless noted):
--   toPitcher : from the plate toward the pitcher
--   right     : the catcher's right when facing the pitcher
--   up        : world up
-- The strike-zone plane is vertical, faces the pitcher, and its normal points
-- toward the catcher (the direction the ball travels through it).

local PitchConfig = require(script.Parent.PitchConfig)
local PitchPhysics = require(script.Parent.PitchPhysics)
local Units = require(script.Parent.Units)

local LaneGeometry = {}

export type Inputs = {
	plateGround: Vector3, -- plate marker at ground level
	pitcherGround: Vector3, -- pitcher marker at ground level
	releasePoint: Vector3?, -- explicit release marker, if one exists
	batterGround: Vector3?, -- batter marker at ground level, if one exists
	batterSide: ("Right" | "Left")?, -- explicit server-selected hand; absent in legacy benchmarks
	rightBatterGround: Vector3?,
	leftBatterGround: Vector3?,
	-- Optional field markers (Phase 3A, see BattedBall/FieldFrame): foul poles
	-- and bases define the foul lines. Unused by pitching.
	leftFoulPole: Vector3?,
	rightFoulPole: Vector3?,
	firstBase: Vector3?,
	thirdBase: Vector3?,
}

export type Geometry = {
	inputs: Inputs,
	units: Units.Converter,
	up: Vector3,
	toPitcher: Vector3,
	right: Vector3,
	armSide: Vector3, -- pitcher's throwing-arm side
	plateGround: Vector3,
	pitcherGround: Vector3,
	moundToPlate: number, -- studs, horizontal
	releasePoint: Vector3,
	zonePlane: PitchPhysics.Plane,
	zoneWidth: number, -- studs
	zoneBottom: number, -- studs above plate ground
	zoneTop: number, -- studs above plate ground
	zoneCenter: Vector3,
	floorY: number,
	batterCFrame: CFrame, -- at ground level, facing across the plate
}

local UP = Vector3.new(0, 1, 0)

local function horizontal(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

function LaneGeometry.new(inputs: Inputs, config: typeof(PitchConfig)?): Geometry
	local cfg = config or PitchConfig
	local units = Units.new(cfg.Units.MetersPerStud)
	local geo = cfg.Geometry
	local zone = cfg.StrikeZone

	local flat = horizontal(inputs.pitcherGround - inputs.plateGround)
	assert(flat.Magnitude > 1e-3, "Pitcher and plate markers are at the same horizontal position")
	local toPitcher = flat.Unit
	local right = toPitcher:Cross(UP).Unit
	local armSide = if geo.PitcherHand == "Left" then right else -right

	local releasePoint = inputs.releasePoint
		or (
			inputs.pitcherGround
			- toPitcher * units.toStuds(geo.ReleaseExtensionMeters)
			+ UP * units.toStuds(geo.ReleaseHeightMeters)
			+ armSide * units.toStuds(geo.ReleaseSideMeters)
		)

	local planePoint = inputs.plateGround + toPitcher * units.toStuds(geo.ZonePlaneOffsetMeters)
	local zoneBottom = units.toStuds(zone.BottomMeters)
	local zoneTop = units.toStuds(zone.TopMeters)

	-- Right-handed batters stand on the catcher's left.
	local batterSideSign = if (inputs.batterSide or geo.BatterSide) == "Left" then 1 else -1
	local batterGround = inputs.batterGround
		or (inputs.plateGround + right * (batterSideSign * units.toStuds(geo.BatterOffsetFromPlateMeters)))
	local facePlate = horizontal(inputs.plateGround - batterGround)
	if facePlate.Magnitude < 1e-3 then
		facePlate = right * -batterSideSign
	end

	return {
		inputs = inputs,
		units = units,
		up = UP,
		toPitcher = toPitcher,
		right = right,
		armSide = armSide,
		plateGround = inputs.plateGround,
		pitcherGround = inputs.pitcherGround,
		moundToPlate = flat.Magnitude,
		releasePoint = releasePoint,
		zonePlane = { point = planePoint, normal = -toPitcher },
		zoneWidth = units.toStuds(zone.WidthMeters),
		zoneBottom = zoneBottom,
		zoneTop = zoneTop,
		zoneCenter = planePoint + UP * ((zoneBottom + zoneTop) / 2),
		floorY = math.min(inputs.plateGround.Y, inputs.pitcherGround.Y),
		batterCFrame = CFrame.lookAt(batterGround, batterGround + facePlate.Unit),
	}
end

function LaneGeometry.boxGround(geometry: Geometry, side: "Right" | "Left"): Vector3
	local point = if side == "Right" then geometry.inputs.rightBatterGround else geometry.inputs.leftBatterGround
	return point
		or (
			geometry.plateGround
			+ geometry.right
				* geometry.units.toStuds(PitchConfig.Geometry.BatterOffsetFromPlateMeters)
				* (if side == "Left" then 1 else -1)
		)
end

function LaneGeometry.forBatter(geometry: Geometry, side: "Right" | "Left"): Geometry
	local inputs = table.clone(geometry.inputs)
	inputs.batterSide, inputs.batterGround = side, LaneGeometry.boxGround(geometry, side)
	return LaneGeometry.new(inputs)
end

-- World point on the zone plane: x = lateral offset from plate center (studs,
-- + = catcher's right), y = height above plate ground (studs).
function LaneGeometry.zonePoint(geometry: Geometry, x: number, y: number): Vector3
	return geometry.zonePlane.point + geometry.right * x + geometry.up * y
end

-- Inverse of zonePoint (ignores the depth component).
function LaneGeometry.zoneCoords(geometry: Geometry, world: Vector3): (number, number)
	local offset = world - geometry.zonePlane.point
	return offset:Dot(geometry.right), offset:Dot(geometry.up)
end

-- A pitch is a strike if any part of the ball passes through the zone.
function LaneGeometry.isStrike(geometry: Geometry, crossingPosition: Vector3, ballRadius: number): boolean
	local x, y = LaneGeometry.zoneCoords(geometry, crossingPosition)
	return math.abs(x) <= geometry.zoneWidth / 2 + ballRadius
		and y >= geometry.zoneBottom - ballRadius
		and y <= geometry.zoneTop + ballRadius
end

return LaneGeometry
