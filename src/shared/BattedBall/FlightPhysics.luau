--!strict
-- Deterministic batted-ball flight in SI units (gravity + drag + Magnus lift
-- + spin decay), integrated with fixed-step RK4.
--
-- Coordinates are the field frame (see FieldFrame), in meters:
--   x = forward (home plate -> mound -> center field)
--   y = up (Roblox world up)
--   z = right (toward the first-base side)
-- (x, y, z) is right-handed, so cross products (Magnus) are the same as in
-- world space. The origin is home plate at ground level.
--
-- Unlike PitchPhysics (Vector3 = float32, studs), this integrates plain Luau
-- numbers (float64). Long, fast flights therefore keep millimeter accuracy at
-- any distance, and the results don't depend on where in the world the
-- stadium is (no float32 world coordinates inside the solver).
--
-- Equations (per unit mass):
--   a = g + a_drag + a_magnus
--   g        = (0, -g, 0)
--   a_drag   = -kD (Cd0 + Cd1 * S) |v| v            kD = rho A / (2 m)
--   a_magnus = kD * CL(S) |v| (w_hat x v)            (same rho A / 2m prefactor)
--   S        = R |w(t)| / |v|                        spin factor
--   w(t)     = w0 exp(-t / tau)                      spin decay, fixed axis
--   CL(S)    = Sawicki-Hubbard-Stronge (PitchPhysics.liftCoefficient)
-- No Roblox services are used.

local PitchPhysics = require(script.Parent.Parent.Pitching.PitchPhysics)

local FlightPhysics = {}

export type Params = {
	gravity: number, -- m/s^2, acts along -y
	dragK: number, -- 1/m: rho * Cd0 * A / (2m)
	dragSpinK: number, -- 1/m: rho * Cd1 * A / (2m) (spin-dependent part)
	magnusK: number, -- 1/m: rho * A / (2m)
	radius: number, -- m
	spinX: number, -- initial angular velocity, rad/s (field frame)
	spinY: number,
	spinZ: number,
	spinDecaySeconds: number, -- tau; math.huge = no decay
}

export type Options = {
	dt: number,
	maxTime: number,
	maxHorizontalDistance: number, -- m from the origin
	floorY: number, -- m; the flight ends once the ball center drops below this
	landingY: number, -- m; height of the ball center when resting on the plate-level field
}

export type Landing = {
	time: number,
	x: number,
	y: number,
	z: number,
	vx: number,
	vy: number,
	vz: number,
	distance: number, -- horizontal distance from the origin (m)
}

export type Trajectory = {
	dt: number,
	count: number,
	duration: number,
	px: { number },
	py: { number },
	pz: { number },
	vx: { number },
	vy: { number },
	vz: { number },
	endReason: "Floor" | "Timeout" | "MaxDistance",
	apexTime: number,
	apexHeight: number, -- m (ball center, field frame)
	-- First descending crossing of landingY: where the ball would land on a
	-- flat field at plate level, ignoring every obstacle. A projection only;
	-- LandingDetector finds the real first impact.
	fieldLanding: Landing?,
}

local sqrt = math.sqrt
local exp = math.exp
local liftCoefficient = PitchPhysics.liftCoefficient

-- Acceleration at time t (since launch) for velocity (vx, vy, vz).
function FlightPhysics.acceleration(params: Params, t: number, vx: number, vy: number, vz: number): (number, number, number)
	local ax, ay, az = 0, -params.gravity, 0
	local speed = sqrt(vx * vx + vy * vy + vz * vz)
	if speed < 1e-9 then
		return ax, ay, az
	end

	local decay = if params.spinDecaySeconds == math.huge then 1 else exp(-t / params.spinDecaySeconds)
	local wx, wy, wz = params.spinX * decay, params.spinY * decay, params.spinZ * decay
	local w = sqrt(wx * wx + wy * wy + wz * wz)
	local spinFactor = params.radius * w / speed

	local kd = (params.dragK + params.dragSpinK * spinFactor) * speed
	ax -= kd * vx
	ay -= kd * vy
	az -= kd * vz

	if w > 1e-9 and params.magnusK > 0 then
		-- (w_hat x v) |v| = (w x v) |v| / |w|
		local f = params.magnusK * liftCoefficient(spinFactor) * speed / w
		ax += f * (wy * vz - wz * vy)
		ay += f * (wz * vx - wx * vz)
		az += f * (wx * vy - wy * vx)
	end
	return ax, ay, az
end

-- One classic RK4 step from time t. Returns the new position and velocity.
function FlightPhysics.step(
	params: Params,
	t: number,
	dt: number,
	px: number,
	py: number,
	pz: number,
	vx: number,
	vy: number,
	vz: number
): (number, number, number, number, number, number)
	local accel = FlightPhysics.acceleration
	local h = dt / 2

	local a1x, a1y, a1z = accel(params, t, vx, vy, vz)
	local v2x, v2y, v2z = vx + a1x * h, vy + a1y * h, vz + a1z * h
	local a2x, a2y, a2z = accel(params, t + h, v2x, v2y, v2z)
	local v3x, v3y, v3z = vx + a2x * h, vy + a2y * h, vz + a2z * h
	local a3x, a3y, a3z = accel(params, t + h, v3x, v3y, v3z)
	local v4x, v4y, v4z = vx + a3x * dt, vy + a3y * dt, vz + a3z * dt
	local a4x, a4y, a4z = accel(params, t + dt, v4x, v4y, v4z)

	local s = dt / 6
	return px + (vx + 2 * v2x + 2 * v3x + v4x) * s,
		py + (vy + 2 * v2y + 2 * v3y + v4y) * s,
		pz + (vz + 2 * v2z + 2 * v3z + v4z) * s,
		vx + (a1x + 2 * a2x + 2 * a3x + a4x) * s,
		vy + (a1y + 2 * a2y + 2 * a3y + a4y) * s,
		vz + (a1z + 2 * a2z + 2 * a3z + a4z) * s
end

local function hermite(p0: number, v0: number, p1: number, v1: number, dt: number, u: number): number
	local u2 = u * u
	local u3 = u2 * u
	return p0 * (2 * u3 - 3 * u2 + 1) + v0 * dt * (u3 - 2 * u2 + u) + p1 * (-2 * u3 + 3 * u2) + v1 * dt * (u3 - u2)
end

-- Segment index (1-based) and fraction for time t, clamped to the trajectory.
local function locate(traj: Trajectory, t: number): (number, number)
	if t <= 0 then
		return 1, 0
	elseif t >= traj.duration then
		return math.max(1, traj.count - 1), 1
	end
	local scaled = t / traj.dt
	local index = math.floor(scaled)
	local i = index + 1
	if i >= traj.count then
		return traj.count - 1, 1
	end
	return i, scaled - index
end

-- Position at time t (seconds after launch), cubic Hermite between steps.
function FlightPhysics.sample(traj: Trajectory, t: number): (number, number, number)
	if traj.count < 2 then
		return traj.px[1], traj.py[1], traj.pz[1]
	end
	local i, u = locate(traj, t)
	local j, dt = i + 1, traj.dt
	return hermite(traj.px[i], traj.vx[i], traj.px[j], traj.vx[j], dt, u),
		hermite(traj.py[i], traj.vy[i], traj.py[j], traj.vy[j], dt, u),
		hermite(traj.pz[i], traj.vz[i], traj.pz[j], traj.vz[j], dt, u)
end

-- Velocity at time t (linear between steps).
function FlightPhysics.sampleVelocity(traj: Trajectory, t: number): (number, number, number)
	if traj.count < 2 then
		return traj.vx[1], traj.vy[1], traj.vz[1]
	end
	local i, u = locate(traj, t)
	local j = i + 1
	return traj.vx[i] + (traj.vx[j] - traj.vx[i]) * u,
		traj.vy[i] + (traj.vy[j] - traj.vy[i]) * u,
		traj.vz[i] + (traj.vz[j] - traj.vz[i]) * u
end

-- Refines a descending crossing of height y in segment [i, i+1] by bisection on the Hermite curve.
local function refineLanding(traj: Trajectory, i: number, y: number): Landing
	local dt = traj.dt
	local lo, hi = 0, 1
	for _ = 1, 40 do
		local mid = (lo + hi) / 2
		if hermite(traj.py[i], traj.vy[i], traj.py[i + 1], traj.vy[i + 1], dt, mid) > y then
			lo = mid
		else
			hi = mid
		end
	end
	local t = ((i - 1) + hi) * dt
	local x, py, z = FlightPhysics.sample(traj, t)
	local vx, vy, vz = FlightPhysics.sampleVelocity(traj, t)
	return { time = t, x = x, y = py, z = z, vx = vx, vy = vy, vz = vz, distance = sqrt(x * x + z * z) }
end

-- Integrates from launch until the ball falls below the floor, flies past
-- the distance budget, or runs out of time.
function FlightPhysics.simulate(
	params: Params,
	x0: number,
	y0: number,
	z0: number,
	vx0: number,
	vy0: number,
	vz0: number,
	options: Options
): Trajectory
	local dt = options.dt
	assert(dt > 0, "dt must be positive")
	local maxSteps = math.max(1, math.ceil(options.maxTime / dt - 1e-9))
	local maxDistanceSq = options.maxHorizontalDistance * options.maxHorizontalDistance

	local px, py, pz = { x0 }, { y0 }, { z0 }
	local vxs, vys, vzs = { vx0 }, { vy0 }, { vz0 }
	local traj: Trajectory = {
		dt = dt,
		count = 1,
		duration = 0,
		px = px,
		py = py,
		pz = pz,
		vx = vxs,
		vy = vys,
		vz = vzs,
		endReason = "Timeout",
		apexTime = 0,
		apexHeight = y0,
		fieldLanding = nil,
	}

	local x, y, z, vx, vy, vz = x0, y0, z0, vx0, vy0, vz0
	local step = FlightPhysics.step
	local landingY = options.landingY
	for stepIndex = 1, maxSteps do
		local previousY, previousVy = y, vy
		x, y, z, vx, vy, vz = step(params, (stepIndex - 1) * dt, dt, x, y, z, vx, vy, vz)
		local count = stepIndex + 1
		px[count], py[count], pz[count] = x, y, z
		vxs[count], vys[count], vzs[count] = vx, vy, vz
		traj.count = count
		-- Kept current so the refinements below can sample the newest segment.
		traj.duration = stepIndex * dt

		-- Apex: vertical velocity changes sign inside this step (linear in vy).
		if previousVy > 0 and vy <= 0 then
			local u = previousVy / (previousVy - vy)
			traj.apexTime = (stepIndex - 1 + u) * dt
			local _, apexY = FlightPhysics.sample(traj, traj.apexTime)
			traj.apexHeight = apexY
		end
		if traj.fieldLanding == nil and previousY > landingY and y <= landingY then
			traj.fieldLanding = refineLanding(traj, stepIndex, landingY)
		end

		if y < options.floorY then
			traj.endReason = "Floor"
			break
		end
		if x * x + z * z >= maxDistanceSq then
			traj.endReason = "MaxDistance"
			break
		end
	end
	traj.duration = (traj.count - 1) * dt
	if traj.apexTime == 0 and traj.apexHeight == y0 and vy0 > 0 then
		-- Still rising at the end of the budget: report the highest sample.
		for i = 1, traj.count do
			if py[i] > traj.apexHeight then
				traj.apexHeight = py[i]
				traj.apexTime = (i - 1) * dt
			end
		end
	end
	return traj
end

return FlightPhysics
