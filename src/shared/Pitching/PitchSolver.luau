--!strict
-- Finds a release velocity of a given speed that makes the simulated pitch
-- cross the strike-zone plane at a target point.
--
-- Method: shooting with fixed-point aim correction. We aim straight at an
-- "aim point" on the plane, simulate the full model (gravity, drag, Magnus),
-- measure where the ball actually crossed, and shift the aim point by the
-- miss. Because a small change of aim moves the crossing point by almost the
-- same amount, this converges in a handful of iterations to sub-millimeter
-- error for any combination of forces, so new pitch types need no new math.

local PitchPhysics = require(script.Parent.PitchPhysics)

local PitchSolver = {}

export type SolveRequest = {
	releasePosition: Vector3,
	target: Vector3, -- point on the plane
	speed: number, -- release speed, studs/s
	params: PitchPhysics.PhysicsParams,
	plane: PitchPhysics.Plane,
	dt: number,
	maxTime: number,
	maxIterations: number,
	tolerance: number, -- studs
}

export type SolveResult = {
	ok: boolean,
	velocity: Vector3,
	iterations: number,
	error: number, -- studs between target and simulated crossing (math.huge if it never crossed)
	crossing: PitchPhysics.Crossing?,
}

function PitchSolver.solve(request: SolveRequest): SolveResult
	local options: PitchPhysics.SimulateOptions = {
		dt = request.dt,
		maxTime = request.maxTime,
		plane = request.plane,
		stopDistancePast = 0,
	}

	local aimPoint = request.target
	local best: SolveResult = {
		ok = false,
		velocity = (request.target - request.releasePosition).Unit * request.speed,
		iterations = 0,
		error = math.huge,
		crossing = nil,
	}

	for iteration = 1, request.maxIterations do
		local velocity = (aimPoint - request.releasePosition).Unit * request.speed
		local traj = PitchPhysics.simulate(request.releasePosition, velocity, request.params, options)
		local crossing = traj.crossing
		if crossing == nil then
			-- Never reached the plate (too slow for the drag/gravity). Aim higher
			-- by the vertical gap and retry; give up if that doesn't help.
			local last = traj.positions[traj.count]
			local remaining = -PitchPhysics.signedDistance(request.plane, last)
			aimPoint += Vector3.new(0, math.max(remaining, 1), 0)
			best.iterations = iteration
			continue
		end

		local miss = crossing.position - request.target
		local missDistance = miss.Magnitude
		if missDistance < best.error then
			best = {
				ok = missDistance <= request.tolerance,
				velocity = velocity,
				iterations = iteration,
				error = missDistance,
				crossing = crossing,
			}
		end
		if missDistance <= request.tolerance then
			break
		end
		aimPoint -= miss
	end

	return best
end

return PitchSolver
