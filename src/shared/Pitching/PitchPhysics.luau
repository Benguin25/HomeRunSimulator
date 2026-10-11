--!strict
-- Deterministic baseball flight model (gravity + quadratic drag + Magnus lift).
--
-- Approach: a pitch is fully described by its release position, release
-- velocity, spin vector and physics parameters. `simulate` integrates that
-- state with fixed-step RK4 and stores every step. Rendering and gameplay then
-- call `sample(trajectory, t)` (cubic Hermite between steps), which is a pure
-- function of elapsed time. Consequences:
--   * Frame rate cannot change the path: a 30 fps and a 240 fps client sample
--     the exact same curve, and a long frame simply samples further along it.
--   * Server and clients run the same integrator on the same replicated
--     inputs, so all of them agree on the path without per-frame networking.
--   * Plane crossings are found by scanning the stored steps (with bisection
--     refinement), never by Touched events, so they can't be skipped.
--
-- Everything here is in studs and seconds. No Roblox services are used, so the
-- module runs unchanged in the pure-Luau test runner.

local PitchPhysics = {}

export type PhysicsParams = {
	gravity: Vector3, -- studs/s^2 (usually (0, -g, 0))
	dragK: number, -- 0.5*rho*Cd*A/m converted to 1/stud; a_drag = -dragK*|v|*v
	magnusK: number, -- 0.5*rho*A/m converted to 1/stud; a_magnus = magnusK*Cl*|v|^2*(w_hat x v_hat)
	radius: number, -- studs (physical radius, used for spin factor)
	spin: Vector3, -- transverse angular velocity, rad/s
}

export type Plane = {
	point: Vector3,
	normal: Vector3, -- unit, pointing in the direction the ball travels through it
}

export type Crossing = {
	time: number, -- seconds after release
	position: Vector3,
	velocity: Vector3,
}

export type Trajectory = {
	dt: number,
	count: number, -- number of stored samples (>= 2)
	duration: number, -- (count - 1) * dt
	positions: { Vector3 },
	velocities: { Vector3 },
	crossing: Crossing?,
	endReason: "Caught" | "Ground" | "Timeout",
}

export type SimulateOptions = {
	dt: number,
	maxTime: number,
	plane: Plane,
	-- Keep simulating until the ball is this far beyond the plane (studs).
	-- 0 stops at the first step past the plane.
	stopDistancePast: number,
	-- Optional floor height (studs); the flight ends if the ball's bottom drops below it.
	floorY: number?,
}

-- Lift coefficient from spin factor S = r*w/|v| (Sawicki, Hubbard & Stronge 2003).
function PitchPhysics.liftCoefficient(spinFactor: number): number
	if spinFactor <= 0 then
		return 0
	elseif spinFactor <= 0.1 then
		return 1.5 * spinFactor
	else
		return 0.09 + 0.6 * spinFactor
	end
end

function PitchPhysics.acceleration(velocity: Vector3, params: PhysicsParams): Vector3
	local accel = params.gravity
	local speed = velocity.Magnitude
	if speed < 1e-6 then
		return accel
	end

	accel -= velocity * (params.dragK * speed)

	local spinRate = params.spin.Magnitude
	if spinRate > 1e-6 and params.magnusK > 0 then
		local cl = PitchPhysics.liftCoefficient(params.radius * spinRate / speed)
		-- (w_hat x v_hat) scaled by |v|^2 == (w_hat x v) * |v|
		local spinAxis = params.spin / spinRate
		accel += spinAxis:Cross(velocity) * (params.magnusK * cl * speed)
	end

	return accel
end

-- One classic RK4 step. Acceleration depends only on velocity, which keeps
-- this cheap, but the full position/velocity form is kept for clarity.
function PitchPhysics.step(position: Vector3, velocity: Vector3, dt: number, params: PhysicsParams): (Vector3, Vector3)
	local accel = PitchPhysics.acceleration

	local k1v = accel(velocity, params)
	local k1p = velocity

	local v2 = velocity + k1v * (dt / 2)
	local k2v = accel(v2, params)
	local k2p = v2

	local v3 = velocity + k2v * (dt / 2)
	local k3v = accel(v3, params)
	local k3p = v3

	local v4 = velocity + k3v * dt
	local k4v = accel(v4, params)
	local k4p = v4

	local newPosition = position + (k1p + k2p * 2 + k3p * 2 + k4p) * (dt / 6)
	local newVelocity = velocity + (k1v + k2v * 2 + k3v * 2 + k4v) * (dt / 6)
	return newPosition, newVelocity
end

function PitchPhysics.signedDistance(plane: Plane, position: Vector3): number
	return (position - plane.point):Dot(plane.normal)
end

local function hermite(p0: Vector3, v0: Vector3, p1: Vector3, v1: Vector3, dt: number, u: number): Vector3
	local u2 = u * u
	local u3 = u2 * u
	local h00 = 2 * u3 - 3 * u2 + 1
	local h10 = u3 - 2 * u2 + u
	local h01 = -2 * u3 + 3 * u2
	local h11 = u3 - u2
	return p0 * h00 + v0 * (h10 * dt) + p1 * h01 + v1 * (h11 * dt)
end

-- Finds where segment [i, i+1] crosses the plane by bisecting on the Hermite curve.
local function refineCrossing(traj: Trajectory, i: number, plane: Plane): Crossing
	local dt = traj.dt
	local p0, v0 = traj.positions[i], traj.velocities[i]
	local p1, v1 = traj.positions[i + 1], traj.velocities[i + 1]
	local lo, hi = 0, 1
	for _ = 1, 32 do
		local mid = (lo + hi) / 2
		if PitchPhysics.signedDistance(plane, hermite(p0, v0, p1, v1, dt, mid)) < 0 then
			lo = mid
		else
			hi = mid
		end
	end
	local u = hi
	return {
		time = ((i - 1) + u) * dt,
		position = hermite(p0, v0, p1, v1, dt, u),
		velocity = v0:Lerp(v1, u),
	}
end

-- Integrates a pitch from release until it is caught, hits the floor, or times out.
function PitchPhysics.simulate(
	releasePosition: Vector3,
	releaseVelocity: Vector3,
	params: PhysicsParams,
	options: SimulateOptions
): Trajectory
	local dt = options.dt
	assert(dt > 0, "dt must be positive")
	local plane = options.plane
	local maxSteps = math.max(1, math.ceil(options.maxTime / dt))
	local floorY = options.floorY

	local positions = { releasePosition }
	local velocities = { releaseVelocity }
	local traj: Trajectory = {
		dt = dt,
		count = 1,
		duration = 0,
		positions = positions,
		velocities = velocities,
		crossing = nil,
		endReason = "Timeout",
	}

	local position, velocity = releasePosition, releaseVelocity
	local previousDistance = PitchPhysics.signedDistance(plane, position)

	for stepIndex = 1, maxSteps do
		position, velocity = PitchPhysics.step(position, velocity, dt, params)
		local count = stepIndex + 1
		positions[count] = position
		velocities[count] = velocity
		traj.count = count

		local distance = PitchPhysics.signedDistance(plane, position)
		if traj.crossing == nil and previousDistance < 0 and distance >= 0 then
			traj.crossing = refineCrossing(traj, stepIndex, plane)
		end
		previousDistance = distance

		if traj.crossing ~= nil and distance >= options.stopDistancePast then
			traj.endReason = "Caught"
			break
		end
		if floorY ~= nil and position.Y - params.radius <= floorY then
			traj.endReason = "Ground"
			break
		end
	end

	traj.duration = (traj.count - 1) * dt
	return traj
end

-- Position at time t (seconds after release). Clamped to the trajectory.
function PitchPhysics.sample(traj: Trajectory, t: number): Vector3
	if t <= 0 then
		return traj.positions[1]
	elseif t >= traj.duration then
		return traj.positions[traj.count]
	end
	local scaled = t / traj.dt
	local index = math.floor(scaled)
	local u = scaled - index
	local i = index + 1
	if i >= traj.count then
		return traj.positions[traj.count]
	end
	return hermite(traj.positions[i], traj.velocities[i], traj.positions[i + 1], traj.velocities[i + 1], traj.dt, u)
end

-- Velocity at time t (linear between steps; plenty for orientation and HUD).
function PitchPhysics.sampleVelocity(traj: Trajectory, t: number): Vector3
	if t <= 0 then
		return traj.velocities[1]
	elseif t >= traj.duration then
		return traj.velocities[traj.count]
	end
	local scaled = t / traj.dt
	local index = math.floor(scaled)
	local i = index + 1
	if i >= traj.count then
		return traj.velocities[traj.count]
	end
	return traj.velocities[i]:Lerp(traj.velocities[i + 1], scaled - index)
end

return PitchPhysics
