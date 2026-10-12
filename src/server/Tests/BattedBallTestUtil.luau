--!strict
-- Helpers for the batted-ball specs:
--   * analytic environments: exact sphere sweeps against planes and boxes,
--     defined in field coordinates (meters) so the same scene works on any lane;
--   * flights from explicit launch values (speed, angles, spin);
--   * contacts from real swings against real pitches.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local LaneGeometry = require(Shared.Pitching.LaneGeometry)
local Pitch = require(Shared.Pitching.Pitch)
local PitchPhysics = require(Shared.Pitching.PitchPhysics)
local Units = require(Shared.Pitching.Units)
local ContactQuality = require(Shared.Batting.ContactQuality)
local SwingModel = require(Shared.Batting.SwingModel)
local SwingResolver = require(Shared.Batting.SwingResolver)
local BattedBall = require(Shared.BattedBall.BattedBall)
local BattedBallConfig = require(Shared.BattedBall.BattedBallConfig)
local FieldFrame = require(Shared.BattedBall.FieldFrame)
local ImpactModel = require(Shared.BattedBall.ImpactModel)
local LandingDetector = require(Shared.BattedBall.LandingDetector)

local TestUtil = require(script.Parent.TestUtil)

local BattedBallTestUtil = {}

BattedBallTestUtil.EPOCH = 1.7e9

-- A sweep result in field meters: parameter s in [0, 1] along the displacement, outward normal.
type SweepHit = { s: number, normal: Vector3, name: string }

export type Shape = {
	name: string,
	sweep: (origin: Vector3, displacement: Vector3, radius: number) -> SweepHit?,
}

-- Infinite (or bounded) plane through `point` with unit `normal` facing the
-- side the ball comes from. `accept(contactPoint)` can bound it (e.g. a wall's height).
function BattedBallTestUtil.plane(name: string, point: Vector3, normal: Vector3, accept: ((Vector3) -> boolean)?): Shape
	local n = normal.Unit
	return {
		name = name,
		sweep = function(origin, displacement, radius)
			local start = (origin - point):Dot(n) - radius
			local approach = displacement:Dot(n)
			if start < -1e-7 or approach >= 0 then
				return nil
			end
			local s = start / -approach
			if s > 1 then
				return nil
			end
			local contact = origin + displacement * s - n * radius
			if accept and not accept(contact) then
				return nil
			end
			return { s = math.max(0, s), normal = n, name = name }
		end,
	}
end

-- Axis-aligned (field axes) box, swept as the box grown by the radius (exact
-- on faces, slightly conservative at edges and corners).
function BattedBallTestUtil.box(name: string, minCorner: Vector3, maxCorner: Vector3): Shape
	return {
		name = name,
		sweep = function(origin, displacement, radius)
			local o = { origin.X, origin.Y, origin.Z }
			local d = { displacement.X, displacement.Y, displacement.Z }
			local lo = { minCorner.X - radius, minCorner.Y - radius, minCorner.Z - radius }
			local hi = { maxCorner.X + radius, maxCorner.Y + radius, maxCorner.Z + radius }
			local tEnter, tExit = -math.huge, math.huge
			local enterAxis, enterSign = 0, 0
			for axis = 1, 3 do
				if math.abs(d[axis]) < 1e-12 then
					if o[axis] < lo[axis] or o[axis] > hi[axis] then
						return nil
					end
				else
					local t1 = (lo[axis] - o[axis]) / d[axis]
					local t2 = (hi[axis] - o[axis]) / d[axis]
					local sign = -1
					if t1 > t2 then
						t1, t2 = t2, t1
						sign = 1
					end
					if t1 > tEnter then
						tEnter, enterAxis, enterSign = t1, axis, sign
					end
					tExit = math.min(tExit, t2)
				end
			end
			if enterAxis == 0 or tEnter > tExit or tEnter < 0 or tEnter > 1 then
				return nil -- no hit, or the sweep starts inside (Spherecast ignores those too)
			end
			local normal = Vector3.new(
				if enterAxis == 1 then enterSign else 0,
				if enterAxis == 2 then enterSign else 0,
				if enterAxis == 3 then enterSign else 0
			)
			return { s = tEnter, normal = normal, name = name }
		end,
	}
end

export type Scene = {
	caster: LandingDetector.Caster,
	casts: number,
}

-- A Caster over field-frame shapes, converting to and from world studs like Workspace would.
function BattedBallTestUtil.scene(frame: FieldFrame.Frame, shapes: { Shape }): Scene
	local scene: Scene = { caster = nil :: any, casts = 0 }
	scene.caster = function(origin: Vector3, displacement: Vector3, radius: number): LandingDetector.CastHit?
		scene.casts += 1
		local ox, oy, oz = FieldFrame.toField(frame, origin)
		local ex, ey, ez = FieldFrame.toField(frame, origin + displacement)
		local o = Vector3.new(ox, oy, oz)
		local d = Vector3.new(ex - ox, ey - oy, ez - oz)
		local r = radius * frame.metersPerStud
		local best: SweepHit? = nil
		for _, shape in shapes do
			local hit = shape.sweep(o, d, r)
			if hit and (best == nil or hit.s < best.s) then
				best = hit
			end
		end
		if best == nil then
			return nil
		end
		local center = o + d * best.s
		local point = center - best.normal * r
		return {
			distance = best.s * displacement.Magnitude,
			point = FieldFrame.toWorld(frame, point.X, point.Y, point.Z),
			normal = FieldFrame.vectorToWorld(frame, best.normal.X, best.normal.Y, best.normal.Z),
			name = best.name,
		}
	end
	return scene
end

-- Flat ground at plate level.
function BattedBallTestUtil.ground(height: number?): Shape
	return BattedBallTestUtil.plane("Ground", Vector3.new(0, height or 0, 0), Vector3.new(0, 1, 0))
end

export type LaunchSpec = {
	speedMph: number,
	launchDegrees: number,
	sprayDegrees: number?,
	backspinRpm: number?,
	sidespinRpm: number?, -- + = breaks toward the right-field side
	x: number?, -- launch point in field meters
	y: number?,
	z: number?,
}

function BattedBallTestUtil.launchData(frame: FieldFrame.Frame, spec: LaunchSpec): BattedBall.LaunchData
	local speed = spec.speedMph * Units.MPH_TO_MPS
	local la = math.rad(spec.launchDegrees)
	local spray = math.rad(spec.sprayDegrees or 0)
	local horizontal = speed * math.cos(la)
	local vx, vy, vz = horizontal * math.cos(spray), speed * math.sin(la), horizontal * math.sin(spray)
	-- Backspin axis = (v x up) / |v x up| = (-vz, 0, vx) / |h|; sidespin = -w_y.
	local back = (spec.backspinRpm or 0) * Units.RPM_TO_RAD_PER_SEC
	local side = (spec.sidespinRpm or 0) * Units.RPM_TO_RAD_PER_SEC
	local hx, hz = math.cos(spray), math.sin(spray)
	return {
		hitId = 1,
		laneId = "Test",
		pitchId = 1,
		userId = 1,
		launchTime = BattedBallTestUtil.EPOCH,
		position = FieldFrame.toWorld(frame, spec.x or 0.5, spec.y or 0.9, spec.z or 0),
		velocity = Vector3.new(vx, vy, vz),
		spin = Vector3.new(-hz * back, -side, hx * back),
	}
end

function BattedBallTestUtil.flight(frame: FieldFrame.Frame, spec: LaunchSpec, flightConfig: BattedBall.FlightConfig?): BattedBall.Flight
	return BattedBall.buildFlight(frame, BattedBallTestUtil.launchData(frame, spec), flightConfig)
end

-- Copy of the flight config with overrides (e.g. AirDensityScale = 0 for a vacuum).
function BattedBallTestUtil.flightConfig(overrides: { [string]: any }): BattedBall.FlightConfig
	local copy = table.clone(BattedBallConfig.Flight) :: any
	for key, value in overrides do
		copy[key] = value
	end
	return copy
end

-- Impact config with Power / Impact overrides (Bat may be overridden as a whole table).
function BattedBallTestUtil.impactConfig(power: { [string]: any }?, impact: { [string]: any }?): ImpactModel.Config
	local p = table.clone(BattedBallConfig.Power) :: any
	for key, value in (power or {}) :: { [string]: any } do
		p[key] = value
	end
	local i = table.clone(BattedBallConfig.Impact) :: any
	for key, value in (impact or {}) :: { [string]: any } do
		i[key] = value
	end
	return { Impact = i, Power = p }
end

-- Neutral power (BatSpeedMultiplier = 1 etc.) for analytic impact tests.
function BattedBallTestUtil.physicalConfig(impact: { [string]: any }?): ImpactModel.Config
	return BattedBallTestUtil.impactConfig({
		BatSpeedMultiplier = 1,
		RestitutionScale = 1,
		SpinEffectiveness = 1,
		ArcadePowerMultiplier = 1,
		MaxLaunchEnergyJoules = math.huge,
	}, impact)
end

-- Real pitch on a lane.
function BattedBallTestUtil.pitch(geometry: LaneGeometry.Geometry, seed: number): Pitch.Flight
	local release = BattedBallTestUtil.EPOCH + 1
	local data = Pitch.generate(geometry, TestUtil.rng(seed), {
		id = seed,
		laneId = "Test",
		windupTime = release - 1,
		releaseTime = release,
	})
	return Pitch.buildFlight(geometry, data)
end

-- Resolves a real swing. Aim offsets are in meters relative to where the ball
-- crosses the contact plane: dy > 0 puts the bat above the ball's center
-- (topping it), dy < 0 under it (lifting it). dx moves the aim along
-- `right`. dt > 0 = late, < 0 = early.
function BattedBallTestUtil.swing(
	geometry: LaneGeometry.Geometry,
	pitch: Pitch.Flight,
	dxMeters: number,
	dyMeters: number,
	dtSeconds: number
): SwingResolver.Resolution
	local units = geometry.units
	local ideal = SwingResolver.idealContactTime(geometry, pitch)
	assert(ideal, "ball never reaches the contact plane")
	local ball = PitchPhysics.sample(pitch.trajectory, ideal - pitch.data.releaseTime)
	local offset = ball - SwingModel.contactPlane(geometry).point
	local x = offset:Dot(geometry.right) + units.toStuds(dxMeters)
	local y = offset:Dot(geometry.up) + units.toStuds(dyMeters)
	local swing = SwingModel.new(geometry, x, y, SwingModel.startTimeForSquareAt(ideal + dtSeconds))
	return SwingResolver.resolve(geometry, pitch, swing)
end

-- Contact + launch + flight for a real swing (asserts that it connects).
function BattedBallTestUtil.hit(
	geometry: LaneGeometry.Geometry,
	pitch: Pitch.Flight,
	dxMeters: number,
	dyMeters: number,
	dtSeconds: number,
	impactConfig: ImpactModel.Config?,
	flightConfig: BattedBall.FlightConfig?
): (BattedBall.Flight, ContactQuality.ContactResult, ImpactModel.Result, FieldFrame.Frame)
	local resolution = BattedBallTestUtil.swing(geometry, pitch, dxMeters, dyMeters, dtSeconds)
	local contact = resolution.contact
	assert(contact, `swing (dx {dxMeters}, dy {dyMeters}, dt {dtSeconds}) missed: {resolution.missReason}`)
	local frame = FieldFrame.new(geometry)
	local launch, impact = BattedBall.computeLaunch(frame, contact, { hitId = 1, laneId = "Test", pitchId = pitch.data.id, userId = 1 }, impactConfig)
	return BattedBall.buildFlight(frame, launch, flightConfig), contact, impact, frame
end

-- Runs `fn` with PitchConfig.Geometry.BatterSide temporarily set.
function BattedBallTestUtil.withBatterSide(side: string, fn: () -> ())
	local geometryConfig = require(Shared.Pitching.PitchConfig).Geometry :: any
	local saved = geometryConfig.BatterSide
	geometryConfig.BatterSide = side
	local ok, err = pcall(fn :: any)
	geometryConfig.BatterSide = saved
	if not ok then
		error(err, 0)
	end
end

return BattedBallTestUtil
