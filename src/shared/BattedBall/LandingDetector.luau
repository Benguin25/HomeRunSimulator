--!strict
-- First-impact detection and distance measurement for a batted-ball flight.
--
-- The environment is queried through a `Caster` (sphere sweep): the server
-- wraps Workspace:Spherecast, tests supply analytic geometry. So this module
-- is pure and the outcome rules are testable without Roblox.
--
-- Swept detection (no tunneling at any speed):
--   1. Coarse: sweep a sphere along chords spanning ChordSeconds of stored
--      fixed-step samples. The sphere radius is the ball radius plus the largest
--      distance of any sample inside the chord from the chord line, so the
--      swept volume contains the curved path (to within the microscopic
--      deviation of one fixed step from its own straight segment).
--   2. Fine: in a chord that hits, sweep the true ball radius along each
--      fixed-step segment in order. The first hit is the first impact; a coarse
--      hit with no fine hit (from the inflated radius) is ignored.
--
-- Outcome rules:
--   * The first impact is classified by its surface normal: Ground (normal
--     mostly up), Wall (steep), Ceiling (facing down).
--   * Ground first   -> "Landed": carry = horizontal distance from home plate
--                       to the touch point. Rolling is never added.
--   * Wall / ceiling -> "Obstacle": carry is NOT reported (we do not simulate
--                       the bounce). The impact's horizontal distance and
--                       height are reported instead, explicitly labelled.
--   * No impact      -> "NoImpact": the flight left the simulated volume
--                       (time / distance budget, or fell below the floor).
--   In every case `projectedCarryMeters` is the plate-level landing of the
--   free flight, ignoring obstacles: a projection, never the measurement.
--   Fair/foul is the territory of the touch point (or projection). A landing
--   short of the bases is marked provisional because it could still roll.

local FieldFrame = require(script.Parent.FieldFrame)
local BattedBall = require(script.Parent.BattedBall)
local BattedBallConfig = require(script.Parent.BattedBallConfig)

local LandingDetector = {}

export type CastHit = {
	distance: number, -- studs travelled along the displacement before touching
	point: Vector3, -- world contact point on the surface
	normal: Vector3, -- world unit surface normal
	name: string?, -- what was hit (debug)
}

-- Sweeps a sphere of `radius` (studs) from `origin` along `displacement`.
export type Caster = (origin: Vector3, displacement: Vector3, radius: number) -> CastHit?

export type SurfaceKind = "Ground" | "Wall" | "Ceiling"

export type Impact = {
	time: number, -- seconds after launch
	center: Vector3, -- world ball center at impact
	point: Vector3, -- world surface point
	normal: Vector3,
	surface: SurfaceKind,
	name: string?,
	-- Field coordinates (m) of the surface point.
	x: number,
	y: number,
	z: number,
}

export type OutcomeKind = "Landed" | "Obstacle" | "NoImpact"

export type Outcome = {
	kind: OutcomeKind,
	impact: Impact?,
	endTime: number, -- seconds after launch when the flight stops
	carryMeters: number?, -- only for Landed
	impactDistanceMeters: number?, -- horizontal distance of the first impact (any surface)
	impactHeightMeters: number?, -- height of the first impact's surface point above plate level
	projectedCarryMeters: number?, -- free flight to plate level, ignoring obstacles
	territory: FieldFrame.Territory,
	territoryProvisional: boolean,
	sprayAngleDegrees: number, -- of the point that decided the territory
	casts: number, -- coarse + fine sweeps used
}

export type Options = {
	chordSeconds: number?,
	groundMinNormalUp: number?,
	-- Ignore impacts before this time (s): lets a ball that starts touching
	-- something (e.g. a resting surface) leave it.
	minTime: number?,
}

local function classify(normal: Vector3, up: Vector3, minUp: number): SurfaceKind
	local dot = normal:Dot(up)
	if dot >= minUp then
		return "Ground"
	elseif dot <= -minUp then
		return "Ceiling"
	end
	return "Wall"
end

local function worldAt(flight: BattedBall.Flight, i: number): Vector3
	local traj = flight.trajectory
	return FieldFrame.toWorld(flight.frame, traj.px[i], traj.py[i], traj.pz[i])
end

-- Distance (studs) from p to the segment [a, b].
local function distanceToSegment(p: Vector3, a: Vector3, b: Vector3): number
	local ab = b - a
	local lengthSq = ab:Dot(ab)
	if lengthSq < 1e-12 then
		return (p - a).Magnitude
	end
	local u = math.clamp((p - a):Dot(ab) / lengthSq, 0, 1)
	return (p - (a + ab * u)).Magnitude
end

-- First impact along the stored trajectory, or nil. Returns the cast count too.
function LandingDetector.findFirstImpact(flight: BattedBall.Flight, caster: Caster, options: Options?): (Impact?, number)
	local opts: Options = options or {}
	local cfg = BattedBallConfig.Collision
	local traj = flight.trajectory
	local frame = flight.frame
	local dt = traj.dt
	local ballRadius = flight.params.radius * frame.studsPerMeter
	local chordSteps = math.max(1, math.floor((opts.chordSeconds or cfg.ChordSeconds) / dt + 0.5))
	local minUp = opts.groundMinNormalUp or cfg.GroundMinNormalUp
	local minTime = opts.minTime or 0
	local casts = 0

	local i = 1
	while i < traj.count do
		local j = math.min(i + chordSteps, traj.count)
		local a, b = worldAt(flight, i), worldAt(flight, j)
		local deviation = 0
		for k = i + 1, j - 1 do
			deviation = math.max(deviation, distanceToSegment(worldAt(flight, k), a, b))
		end
		casts += 1
		local coarse = if (b - a).Magnitude > 1e-6 or deviation > 0
			then caster(a, b - a, ballRadius + deviation * 1.01 + 1e-4)
			else nil
		if coarse then
			for k = i, j - 1 do
				local p0, p1 = worldAt(flight, k), worldAt(flight, k + 1)
				local segment = p1 - p0
				local length = segment.Magnitude
				if length > 1e-6 then
					casts += 1
					local hit = caster(p0, segment, ballRadius)
					if hit then
						local fraction = math.clamp(hit.distance / length, 0, 1)
						local time = ((k - 1) + fraction) * dt
						if time >= minTime then
							local x, y, z = FieldFrame.toField(frame, hit.point)
							return {
								time = time,
								center = p0 + segment.Unit * hit.distance,
								point = hit.point,
								normal = hit.normal,
								surface = classify(hit.normal, frame.up, minUp),
								name = hit.name,
								x = x,
								y = y,
								z = z,
							},
								casts
						end
					end
				end
			end
		end
		i = j
	end
	return nil, casts
end

-- Full outcome: first impact + measured / alternate distances + territory.
function LandingDetector.evaluate(flight: BattedBall.Flight, caster: Caster, options: Options?): Outcome
	local impact, casts = LandingDetector.findFirstImpact(flight, caster, options)
	local frame = flight.frame
	local landing = flight.fieldLanding
	local projected = landing and landing.distance
	local baseDistance = BattedBallConfig.Collision.BaseDistanceMeters

	local outcome: Outcome = {
		kind = "NoImpact",
		impact = impact,
		endTime = flight.trajectory.duration,
		carryMeters = nil,
		impactDistanceMeters = nil,
		impactHeightMeters = nil,
		projectedCarryMeters = projected,
		territory = "Foul",
		territoryProvisional = false,
		sprayAngleDegrees = 0,
		casts = casts,
	}

	local tx: number, tz: number
	if impact then
		outcome.endTime = impact.time
		local horizontal = FieldFrame.horizontalDistance(impact.x, impact.z)
		outcome.impactDistanceMeters = horizontal
		outcome.impactHeightMeters = impact.y
		if impact.surface == "Ground" then
			outcome.kind = "Landed"
			outcome.carryMeters = horizontal
			outcome.territoryProvisional = horizontal < baseDistance
		else
			outcome.kind = "Obstacle"
		end
		tx, tz = impact.x, impact.z
	elseif landing then
		tx, tz = landing.x, landing.z
	else
		local traj = flight.trajectory
		tx, tz = traj.px[traj.count], traj.pz[traj.count]
	end
	outcome.territory = FieldFrame.territory(frame, tx, tz)
	outcome.sprayAngleDegrees = FieldFrame.sprayAngleDegrees(tx, tz)
	return outcome
end

-- Plain-data form of an outcome for replication (no Instances, no nested Vector3 math).
export type OutcomePayload = {
	kind: OutcomeKind,
	endTime: number,
	surface: SurfaceKind?,
	impactPoint: Vector3?,
	impactCenter: Vector3?,
	impactName: string?,
	carryMeters: number?,
	impactDistanceMeters: number?,
	impactHeightMeters: number?,
	projectedCarryMeters: number?,
	territory: FieldFrame.Territory,
	territoryProvisional: boolean,
	sprayAngleDegrees: number,
}

function LandingDetector.toPayload(outcome: Outcome): OutcomePayload
	local impact = outcome.impact
	return {
		kind = outcome.kind,
		endTime = outcome.endTime,
		surface = impact and impact.surface,
		impactPoint = impact and impact.point,
		impactCenter = impact and impact.center,
		impactName = impact and impact.name,
		carryMeters = outcome.carryMeters,
		impactDistanceMeters = outcome.impactDistanceMeters,
		impactHeightMeters = outcome.impactHeightMeters,
		projectedCarryMeters = outcome.projectedCarryMeters,
		territory = outcome.territory,
		territoryProvisional = outcome.territoryProvisional,
		sprayAngleDegrees = outcome.sprayAngleDegrees,
	}
end

-- Short human-readable summary (logs, debug HUD).
function LandingDetector.describe(payload: OutcomePayload): string
	local territory = payload.territory .. (if payload.territoryProvisional then " (provisional)" else "")
	if payload.kind == "Landed" then
		return string.format("LANDED %s, %s", BattedBall.formatDistance(payload.carryMeters or 0), territory)
	elseif payload.kind == "Obstacle" then
		return string.format(
			"HIT %s at %s, %.1f m up (carry undetermined), %s",
			string.upper(payload.surface or "obstacle"),
			BattedBall.formatDistance(payload.impactDistanceMeters or 0),
			payload.impactHeightMeters or 0,
			territory
		)
	end
	return string.format(
		"NO IMPACT (left the simulated area; projected %s), %s",
		if payload.projectedCarryMeters then BattedBall.formatDistance(payload.projectedCarryMeters) else "n/a",
		territory
	)
end

return LandingDetector
