--!strict
-- Batted-ball data: launch computation (from a validated contact), the
-- replicated launch record, and flight reconstruction.
--
-- A hit is fully described by a small `LaunchData` record: where the ball
-- was at contact (world studs), its outgoing velocity and spin (field frame,
-- SI) and the server time of contact. The server and every client turn it
-- into the identical flight with `buildFlight`. The record holds Vector3s
-- (float32) and the server simulates from that same record, so a client
-- that receives it rebuilds bit-for-bit the same trajectory.

local Shared = script.Parent.Parent
local Pitching = Shared.Pitching
local PitchConfig = require(Pitching.PitchConfig)
local Units = require(Pitching.Units)
local BattingConfig = require(Shared.Batting.BattingConfig)
local ContactQuality = require(Shared.Batting.ContactQuality)

local BattedBallConfig = require(script.Parent.BattedBallConfig)
local FieldFrame = require(script.Parent.FieldFrame)
local FlightPhysics = require(script.Parent.FlightPhysics)
local ImpactModel = require(script.Parent.ImpactModel)
local ProgressionConfig = require(Shared.Progression.ProgressionConfig)

local BattedBall = {}

export type LaunchData = {
	hitId: number,
	laneId: string,
	pitchId: number,
	userId: number,
	launchTime: number, -- server time of bat contact (flight t = 0)
	position: Vector3, -- world studs: ball center at contact
	velocity: Vector3, -- field frame, m/s (x forward, y up, z right)
	spin: Vector3, -- field frame, rad/s
	powerLevel: number?, -- captured at accepted server contact; prediction metadata only
	powerVersion: number?,
}

export type Flight = {
	launch: LaunchData,
	frame: FieldFrame.Frame,
	params: FlightPhysics.Params,
	trajectory: FlightPhysics.Trajectory,
	exitSpeedMps: number,
	exitSpeedMph: number,
	launchAngleDegrees: number,
	sprayAngleDegrees: number, -- + = right-field side
	pullAngleDegrees: number, -- + = batter's pull side
	spinRpm: number,
	backspinRpm: number, -- + = backspin, - = topspin
	sidespinRpm: number, -- + = breaks toward the right-field side
	apexHeightMeters: number, -- ball center above home-plate level
	apexTime: number,
	-- Where the ball would land on a flat field at plate level, ignoring
	-- obstacles (projection only; the measured first impact is LandingDetector's).
	fieldLanding: FlightPhysics.Landing?,
}

export type FlightConfig = typeof(BattedBallConfig.Flight)

local RAD_TO_RPM = 1 / Units.RPM_TO_RAD_PER_SEC

-- Physical parameters (SI) for a spin vector given in field components.
function BattedBall.buildParams(spin: Vector3, flightConfig: FlightConfig?): FlightPhysics.Params
	local flight = flightConfig or BattedBallConfig.Flight
	local ball = PitchConfig.Ball
	local area = math.pi * ball.RadiusMeters * ball.RadiusMeters
	local rho = PitchConfig.Environment.AirDensityKgPerCubicMeter * flight.AirDensityScale
	local k = 0.5 * rho * area / ball.MassKg
	return {
		gravity = PitchConfig.Environment.GravityMetersPerSecondSq,
		dragK = k * flight.DragCoefficient,
		dragSpinK = k * flight.DragSpinSlope,
		magnusK = k,
		radius = ball.RadiusMeters,
		spinX = spin.X,
		spinY = spin.Y,
		spinZ = spin.Z,
		spinDecaySeconds = flight.SpinDecaySeconds,
	}
end

export type LaunchIds = {
	hitId: number,
	laneId: string,
	pitchId: number,
	userId: number,
}

-- Turns a validated contact into launch data. `ballSpin` is the pitch's spin
-- (rad/s, world) at contact. Also returns the impact model's details.
function BattedBall.computeLaunch(
	frame: FieldFrame.Frame,
	contact: ContactQuality.ContactResult,
	ids: LaunchIds,
	impactConfig: ImpactModel.Config?
): (LaunchData, ImpactModel.Result)
	local s = frame.metersPerStud
	local surfaceUp = contact.batDirection:Cross(contact.swingDirection).Unit
	if surfaceUp:Dot(frame.up) < 0 then
		surfaceUp = -surfaceUp
	end
	local impact = ImpactModel.resolve({
		normal = contact.impactNormal,
		up = surfaceUp,
		ballVelocity = contact.ballVelocity * s,
		ballSpin = contact.ballSpin,
		batVelocity = contact.batVelocity * s,
		distanceFromKnob = contact.distanceFromKnob * s,
		sweetSpotFromKnob = BattingConfig.Bat.SweetSpotFromKnobMeters,
	}, impactConfig)
	local vx, vy, vz = FieldFrame.vectorToField(frame, impact.velocity)
	local wx, wy, wz = FieldFrame.vectorToField(frame, impact.spin)
	local launch: LaunchData = {
		hitId = ids.hitId,
		laneId = ids.laneId,
		pitchId = ids.pitchId,
		userId = ids.userId,
		launchTime = contact.contactTime,
		position = contact.ballCenter,
		velocity = Vector3.new(vx, vy, vz),
		spin = Vector3.new(wx, wy, wz),
	}
	return launch, impact
end

-- Descriptive contact type (squared / under / topped / inside / outside /
-- glancing / weak) from the measured contact and the impact result. Debug
-- and logs only; the physics never reads it.
function BattedBall.describeContact(
	frame: FieldFrame.Frame,
	contact: ContactQuality.ContactResult,
	impact: ImpactModel.Result
): ImpactModel.ContactType
	local bat = BattingConfig.Bat
	local segmentRadius = if contact.segment == "Barrel" then bat.BarrelRadiusMeters else bat.HandleRadiusMeters
	local reach = segmentRadius + PitchConfig.Ball.RadiusMeters
	local vertical = math.clamp(contact.verticalOffset * frame.metersPerStud / reach, -1, 1)
	return ImpactModel.describe({
		verticalAngleDegrees = math.deg(math.asin(vertical)),
		sweetSpotOffsetMeters = contact.sweetSpotOffset * frame.metersPerStud,
		closingFraction = contact.factors.efficiency,
		exitSpeedRatio = if impact.idealExitSpeed > 1e-6 then impact.velocity.Magnitude / impact.idealExitSpeed else 0,
	})
end

-- Simulation options for a frame (plate-level landing, floor, budgets).
function BattedBall.simulateOptions(flightConfig: FlightConfig?): FlightPhysics.Options
	local flight = flightConfig or BattedBallConfig.Flight
	return {
		dt = flight.FixedStepSeconds,
		maxTime = flight.MaxFlightSeconds,
		maxHorizontalDistance = flight.MaxHorizontalDistanceMeters,
		floorY = -flight.FloorBelowPlateMeters,
		landingY = PitchConfig.Ball.RadiusMeters,
	}
end

-- Server and clients: rebuild the full flight from launch data.
function BattedBall.buildFlight(frame: FieldFrame.Frame, launch: LaunchData, flightConfig: FlightConfig?): Flight
	if not flightConfig and launch.powerLevel and launch.powerLevel > 0 then
		local expanded = table.clone(BattedBallConfig.Flight)
		expanded.MaxFlightSeconds = ProgressionConfig.Limits.MaxFlightSeconds
		expanded.MaxHorizontalDistanceMeters = ProgressionConfig.Limits.MaxDistanceMeters
		flightConfig = expanded
	end
	local params = BattedBall.buildParams(launch.spin, flightConfig)
	local x0, y0, z0 = FieldFrame.toField(frame, launch.position)
	local v = launch.velocity
	local trajectory = FlightPhysics.simulate(params, x0, y0, z0, v.X, v.Y, v.Z, BattedBall.simulateOptions(flightConfig))

	local speed = v.Magnitude
	local horizontal = math.sqrt(v.X * v.X + v.Z * v.Z)
	local spray = FieldFrame.sprayAngleDegrees(v.X, v.Z)

	-- Spin components relative to the launch direction: backspin about
	-- (v x up), sidespin about up.
	local w = launch.spin
	local backspin = 0
	if horizontal > 1e-6 then
		backspin = (w.X * -v.Z + w.Z * v.X) / horizontal
	end

	local landing = trajectory.fieldLanding
	return {
		launch = launch,
		frame = frame,
		params = params,
		trajectory = trajectory,
		exitSpeedMps = speed,
		exitSpeedMph = speed / Units.MPH_TO_MPS,
		launchAngleDegrees = math.deg(math.atan2(v.Y, horizontal)),
		sprayAngleDegrees = spray,
		pullAngleDegrees = FieldFrame.pullAngleDegrees(frame, spray),
		spinRpm = w.Magnitude * RAD_TO_RPM,
		backspinRpm = backspin * RAD_TO_RPM,
		sidespinRpm = -w.Y * RAD_TO_RPM,
		apexHeightMeters = trajectory.apexHeight,
		apexTime = trajectory.apexTime,
		fieldLanding = landing,
	}
end

-- World position (studs) at t seconds after launch.
function BattedBall.positionAt(flight: Flight, t: number): Vector3
	local x, y, z = FlightPhysics.sample(flight.trajectory, t)
	return FieldFrame.toWorld(flight.frame, x, y, z)
end

-- Horizontal distance from home plate (m) at t seconds after launch.
function BattedBall.distanceAt(flight: Flight, t: number): number
	local x, _, z = FlightPhysics.sample(flight.trajectory, t)
	return math.sqrt(x * x + z * z)
end

-- Player-facing distance text in the configured unit.
function BattedBall.formatDistance(meters: number, unit: ("Feet" | "Meters")?): string
	local chosen = unit or BattedBallConfig.Display.DistanceUnit
	if chosen == "Meters" then
		return string.format("%.1f m", meters)
	end
	return string.format("%d ft", math.floor(meters / Units.METERS_PER_FOOT + 0.5))
end

-- Compact wire format (array). `endTime` = seconds after launch at which the
-- server's flight ends (first impact, or the end of the simulated flight).
function BattedBall.encode(launch: LaunchData, endTime: number): { any }
	return {
		launch.hitId,
		launch.laneId,
		launch.pitchId,
		launch.userId,
		launch.launchTime,
		launch.position,
		launch.velocity,
		launch.spin,
		endTime,
		launch.powerLevel or 0,
		launch.powerVersion or 0,
	}
end

function BattedBall.decode(packet: any): (LaunchData?, number?)
	if typeof(packet) ~= "table" or #packet < 9 then
		return nil, nil
	end
	local launch: LaunchData = {
		hitId = packet[1],
		laneId = packet[2],
		pitchId = packet[3],
		userId = packet[4],
		launchTime = packet[5],
		position = packet[6],
		velocity = packet[7],
		spin = packet[8],
		powerLevel = packet[10] or 0,
		powerVersion = packet[11] or 0,
	}
	if
		typeof(launch.hitId) ~= "number"
		or typeof(launch.laneId) ~= "string"
		or typeof(launch.launchTime) ~= "number"
		or typeof(launch.position) ~= "Vector3"
		or typeof(launch.velocity) ~= "Vector3"
		or typeof(launch.spin) ~= "Vector3"
		or typeof(packet[9]) ~= "number"
	then
		return nil, nil
	end
	return launch, packet[9]
end

-- Launch records equal to float32 precision (prediction vs. server).
function BattedBall.sameLaunch(a: LaunchData, b: LaunchData, tolerance: number?): boolean
	local tol = tolerance or 1e-4
	return math.abs(a.launchTime - b.launchTime) < 1e-6
		and (a.powerLevel or 0) == (b.powerLevel or 0)
		and (a.position - b.position).Magnitude < tol
		and (a.velocity - b.velocity).Magnitude < tol
		and (a.spin - b.spin).Magnitude < tol * 100
end

return BattedBall
