--!strict
-- Pitch data: generation (server), replication encoding, and flight
-- reconstruction (server and clients).
--
-- A pitch is described by a small, replicable `PitchData` record. Both the
-- server and every client turn that record into an identical `Flight` by
-- running the shared integrator, so no positions are ever streamed.

local LaneGeometry = require(script.Parent.LaneGeometry)
local PitchConfig = require(script.Parent.PitchConfig)
local PitchPhysics = require(script.Parent.PitchPhysics)
local PitchSolver = require(script.Parent.PitchSolver)
local Units = require(script.Parent.Units)

local Pitch = {}

export type PitchData = {
	id: number,
	laneId: string,
	pitchType: string,
	windupTime: number, -- server time (workspace:GetServerTimeNow()) the windup starts
	releaseTime: number, -- server time the ball leaves the hand
	releasePosition: Vector3,
	releaseVelocity: Vector3,
	spin: Vector3, -- transverse angular velocity, rad/s
	target: Vector3, -- intended crossing point on the zone plane
}

export type Flight = {
	data: PitchData,
	params: PitchPhysics.PhysicsParams,
	trajectory: PitchPhysics.Trajectory,
	crossing: PitchPhysics.Crossing?,
	-- Seconds after release.
	crossTime: number?,
	endTime: number,
	releaseSpeedMph: number,
	plateSpeedMph: number?,
	targetError: number?, -- studs between intended target and actual crossing
	isStrike: boolean,
}

export type Rng = {
	NextNumber: (self: any, min: number, max: number) -> number,
}

local function jitter(rng: Rng, amount: number): number
	if amount <= 0 then
		return 0
	end
	return rng:NextNumber(-amount, amount)
end

function Pitch.getTypeConfig(pitchType: string): PitchConfig.PitchTypeConfig
	local typeConfig = PitchConfig.PitchTypes[pitchType]
	assert(typeConfig, `Unknown pitch type "{pitchType}"`)
	return typeConfig
end

-- Release speed range (mph) for a pitch type at a difficulty tier.
function Pitch.getSpeedRange(pitchType: string, tierName: string?): (number, number)
	local tier = PitchConfig.getTier(tierName)
	local offset = Pitch.getTypeConfig(pitchType).SpeedOffsetMph
	return tier.SpeedMphMin + offset, tier.SpeedMphMax + offset
end

-- Drag/Magnus/gravity parameters (in studs) for a pitch type and spin vector.
function Pitch.buildParams(units: Units.Converter, typeConfig: PitchConfig.PitchTypeConfig, spin: Vector3): PitchPhysics.PhysicsParams
	local ball = PitchConfig.Ball
	local area = math.pi * ball.RadiusMeters * ball.RadiusMeters
	local rho = PitchConfig.Environment.AirDensityKgPerCubicMeter
	-- Coefficients in 1/m; dividing by studsPerMeter expresses them per stud
	-- (a = k*|v|*v is quadratic in velocity, so one factor of scale remains).
	local dragPerMeter = 0.5 * rho * typeConfig.DragCoefficient * area / ball.MassKg
	local magnusPerMeter = 0.5 * rho * area / ball.MassKg
	return {
		gravity = Vector3.new(0, -units.accelToStuds(PitchConfig.Environment.GravityMetersPerSecondSq), 0),
		dragK = dragPerMeter / units.studsPerMeter,
		magnusK = magnusPerMeter / units.studsPerMeter,
		radius = units.toStuds(ball.RadiusMeters),
		spin = spin,
	}
end

-- Spin vector producing Magnus movement in direction `tiltDegrees` (0 = up,
-- +90 = arm side) for a ball travelling along the lane toward the plate.
function Pitch.buildSpin(geometry: LaneGeometry.Geometry, spinRpm: number, efficiency: number, tiltDegrees: number): Vector3
	local tilt = math.rad(tiltDegrees)
	local movement = geometry.up * math.cos(tilt) + geometry.armSide * math.sin(tilt)
	local travel = -geometry.toPitcher
	-- (travel x movement) x travel == movement, so this axis lifts toward `movement`.
	local axis = travel:Cross(movement).Unit
	return axis * (spinRpm * Units.RPM_TO_RAD_PER_SEC * efficiency)
end

function Pitch.simulateOptions(geometry: LaneGeometry.Geometry, stopDistancePast: number): PitchPhysics.SimulateOptions
	local sim = PitchConfig.Simulation
	return {
		dt = sim.FixedStepSeconds,
		maxTime = sim.MaxFlightSeconds,
		plane = geometry.zonePlane,
		stopDistancePast = stopDistancePast,
		floorY = geometry.floorY,
	}
end

function Pitch.choosePitchType(rng: Rng): string
	local total = 0
	for _, entry in PitchConfig.PitchMix do
		total += entry.Weight
	end
	local roll = rng:NextNumber(0, total)
	for _, entry in PitchConfig.PitchMix do
		roll -= entry.Weight
		if roll <= 0 then
			return entry.Type
		end
	end
	return PitchConfig.PitchMix[#PitchConfig.PitchMix].Type
end

-- Samples a target inside the configured target region of the strike zone.
function Pitch.sampleTarget(geometry: LaneGeometry.Geometry, rng: Rng): Vector3
	local zone = PitchConfig.StrikeZone
	local halfWidth = geometry.zoneWidth / 2 * zone.TargetRegionScaleX
	local halfHeight = (geometry.zoneTop - geometry.zoneBottom) / 2 * zone.TargetRegionScaleY
	local midHeight = (geometry.zoneTop + geometry.zoneBottom) / 2
	return LaneGeometry.zonePoint(geometry, jitter(rng, halfWidth), midHeight + jitter(rng, halfHeight))
end

export type GenerateOptions = {
	id: number,
	laneId: string,
	windupTime: number,
	releaseTime: number,
	pitchType: string?,
	target: Vector3?, -- override the sampled target (tests, future aiming)
	speedMph: number?, -- override the sampled speed
	tier: string?, -- difficulty tier (defaults to PitchConfig.Difficulty.Active)
}

-- Server-side: chooses speed/spin/target with natural variation and solves
-- the release velocity. Returns the replicable data and the solve result.
function Pitch.generate(geometry: LaneGeometry.Geometry, rng: Rng, options: GenerateOptions): (PitchData, PitchSolver.SolveResult)
	local units = geometry.units
	local pitchType = options.pitchType or Pitch.choosePitchType(rng)
	local typeConfig = Pitch.getTypeConfig(pitchType)

	local minMph, maxMph = Pitch.getSpeedRange(pitchType, options.tier)
	local speedMph = options.speedMph or rng:NextNumber(minMph, maxMph)
	local spinRpm = typeConfig.SpinRpm + jitter(rng, typeConfig.SpinRpmJitter)
	local tilt = typeConfig.MovementTiltDegrees + jitter(rng, typeConfig.MovementTiltJitterDegrees)
	local spin = Pitch.buildSpin(geometry, spinRpm, typeConfig.SpinEfficiency, tilt)
	local params = Pitch.buildParams(units, typeConfig, spin)

	local releaseJitter = units.toStuds(typeConfig.ReleaseJitterMeters)
	local releasePosition = geometry.releasePoint
		+ geometry.right * jitter(rng, releaseJitter)
		+ geometry.up * jitter(rng, releaseJitter)
	local target = options.target or Pitch.sampleTarget(geometry, rng)

	local sim = PitchConfig.Simulation
	local result = PitchSolver.solve({
		releasePosition = releasePosition,
		target = target,
		speed = units.mphToStudsPerSecond(speedMph),
		params = params,
		plane = geometry.zonePlane,
		dt = sim.FixedStepSeconds,
		maxTime = sim.MaxFlightSeconds,
		maxIterations = sim.SolverMaxIterations,
		tolerance = units.toStuds(sim.SolverToleranceMeters),
	})

	local data: PitchData = {
		id = options.id,
		laneId = options.laneId,
		pitchType = pitchType,
		windupTime = options.windupTime,
		releaseTime = options.releaseTime,
		releasePosition = releasePosition,
		releaseVelocity = result.velocity,
		spin = spin,
		target = target,
	}
	return data, result
end

-- Server and clients: rebuild the full flight from replicated data.
function Pitch.buildFlight(geometry: LaneGeometry.Geometry, data: PitchData): Flight
	local units = geometry.units
	local typeConfig = Pitch.getTypeConfig(data.pitchType)
	local params = Pitch.buildParams(units, typeConfig, data.spin)
	local catchDistance = units.toStuds(PitchConfig.Simulation.CatchDistanceMeters)
	local trajectory = PitchPhysics.simulate(
		data.releasePosition,
		data.releaseVelocity,
		params,
		Pitch.simulateOptions(geometry, catchDistance)
	)
	local crossing = trajectory.crossing
	return {
		data = data,
		params = params,
		trajectory = trajectory,
		crossing = crossing,
		crossTime = crossing and crossing.time,
		endTime = trajectory.duration,
		releaseSpeedMph = units.studsPerSecondToMph(data.releaseVelocity.Magnitude),
		plateSpeedMph = crossing and units.studsPerSecondToMph(crossing.velocity.Magnitude),
		targetError = crossing and (crossing.position - data.target).Magnitude,
		isStrike = crossing ~= nil and LaneGeometry.isStrike(geometry, crossing.position, params.radius),
	}
end

-- Compact wire format (array, no string keys). Sent once per pitch.
function Pitch.encode(data: PitchData): { any }
	return {
		data.id,
		data.laneId,
		data.pitchType,
		data.windupTime,
		data.releaseTime,
		data.releasePosition,
		data.releaseVelocity,
		data.spin,
		data.target,
	}
end

function Pitch.decode(packet: { any }): PitchData?
	if typeof(packet) ~= "table" or #packet < 9 then
		return nil
	end
	local data: PitchData = {
		id = packet[1],
		laneId = packet[2],
		pitchType = packet[3],
		windupTime = packet[4],
		releaseTime = packet[5],
		releasePosition = packet[6],
		releaseVelocity = packet[7],
		spin = packet[8],
		target = packet[9],
	}
	if PitchConfig.PitchTypes[data.pitchType] == nil then
		return nil
	end
	return data
end

return Pitch
