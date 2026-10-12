--!strict
-- Batted-ball flight tests (pure Luau). Wherever possible the integrator is
-- checked against closed-form solutions:
--   * vacuum projectile (range, time of flight, apex),
--   * drag only:   v(t) = v0 / (1 + k v0 t),  x(t) = ln(1 + k v0 t) / k,
--   * Magnus only: uniform circular motion of radius 1 / (k_M * C_L(S)),
-- plus convergence against a much finer step, physical ordering
-- (drag < vacuum, backspin > no spin > topspin) and one published reference.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PitchPhysics = require(Shared.Pitching.PitchPhysics)
local Units = require(Shared.Pitching.Units)
local BattedBall = require(Shared.BattedBall.BattedBall)
local BattedBallConfig = require(Shared.BattedBall.BattedBallConfig)
local FieldFrame = require(Shared.BattedBall.FieldFrame)
local FlightPhysics = require(Shared.BattedBall.FlightPhysics)

local BBTU = require(script.Parent.BattedBallTestUtil)
local TestUtil = require(script.Parent.TestUtil)

local G = 9.80665
local R = 0.0366

local function params(overrides: { [string]: number }?): FlightPhysics.Params
	local p: FlightPhysics.Params = {
		gravity = G,
		dragK = 0,
		dragSpinK = 0,
		magnusK = 0,
		radius = R,
		spinX = 0,
		spinY = 0,
		spinZ = 0,
		spinDecaySeconds = math.huge,
	}
	for key, value in (overrides or {}) :: { [string]: number } do
		(p :: any)[key] = value
	end
	return p
end

local function options(dt: number?): FlightPhysics.Options
	local o = BattedBall.simulateOptions()
	if dt then
		o.dt = dt
	end
	return o
end

local function launchAt(speedMph: number, degrees: number): (number, number)
	local v = speedMph * Units.MPH_TO_MPS
	local a = math.rad(degrees)
	return v * math.cos(a), v * math.sin(a)
end

local function carry(p: FlightPhysics.Params, speedMph: number, degrees: number, dt: number?): (number, FlightPhysics.Trajectory)
	local vx, vy = launchAt(speedMph, degrees)
	local traj = FlightPhysics.simulate(p, 0, 0.9, 0, vx, vy, 0, options(dt))
	local landing = traj.fieldLanding
	assert(landing, "no landing")
	return landing.distance, traj
end

local function realParams(backspinRpm: number, sidespinRpm: number?): FlightPhysics.Params
	return BattedBall.buildParams(Vector3.new(0, -(sidespinRpm or 0) * Units.RPM_TO_RAD_PER_SEC, backspinRpm * Units.RPM_TO_RAD_PER_SEC))
end

return function(t)
	t.test("gravity-only flight matches the vacuum projectile solution", function()
		for _, dt in { 1 / 120, 1 / 37, 1 / 1000 } do
			for _, case in { { 40, 35 }, { 25, 60 }, { 60, 10 } } do
				local v, a = case[1], math.rad(case[2])
				local y0 = R -- start at landing height so the closed form applies directly
				local traj = FlightPhysics.simulate(params(), 0, y0, 0, v * math.cos(a), v * math.sin(a), 0, options(dt))
				local landing = traj.fieldLanding
				assert(landing, "no landing")
				TestUtil.assertNear(landing.time, 2 * v * math.sin(a) / G, 1e-7, `time of flight (dt {dt})`)
				TestUtil.assertNear(landing.distance, v * v * math.sin(2 * a) / G, 1e-6, `range (dt {dt})`)
				TestUtil.assertNear(traj.apexHeight, y0 + (v * math.sin(a)) ^ 2 / (2 * G), 1e-6, `apex (dt {dt})`)
				TestUtil.assertNear(traj.apexTime, v * math.sin(a) / G, 1e-6, `apex time (dt {dt})`)
			end
		end
	end)

	t.test("drag-only flight matches v0 / (1 + k v0 t)", function()
		local k = BattedBall.buildParams(Vector3.zero).dragK
		local v0 = 45
		local traj = FlightPhysics.simulate(params({ gravity = 0, dragK = k }), 0, 10, 0, v0, 0, 0, options())
		for _, time in { 0.5, 1, 2.5, 4 } do
			local x = FlightPhysics.sample(traj, time)
			local vx = FlightPhysics.sampleVelocity(traj, time)
			TestUtil.assertNear(x, math.log(1 + k * v0 * time) / k, 1e-6, `x({time})`)
			TestUtil.assertNear(vx, v0 / (1 + k * v0 * time), 1e-6, `v({time})`)
		end
	end)

	t.test("Magnus-only flight is uniform circular motion of radius 1 / (k_M C_L)", function()
		local base = BattedBall.buildParams(Vector3.zero)
		local spin = 250 -- rad/s about +Z, perpendicular to the velocity
		local v0 = 40
		local p = params({ gravity = 0, magnusK = base.magnusK, spinZ = spin })
		local traj = FlightPhysics.simulate(p, 0, 10, 0, v0, 0, 0, options())
		local radius = 1 / (base.magnusK * PitchPhysics.liftCoefficient(R * spin / v0))
		-- w x v for w = +Z, v = +X is +Y: the circle's center is straight above the start.
		local cx, cy = 0, 10 + radius
		for _, time in { 0.5, 1.5, 3 } do
			local x, y, z = FlightPhysics.sample(traj, time)
			local vx, vy, vz = FlightPhysics.sampleVelocity(traj, time)
			TestUtil.assertNear(math.sqrt((x - cx) ^ 2 + (y - cy) ^ 2), radius, radius * 1e-6, `radius at {time}`)
			TestUtil.assertNear(math.sqrt(vx * vx + vy * vy + vz * vz), v0, 1e-6, `speed at {time} (Magnus does no work)`)
			TestUtil.assertNear(z, 0, 1e-12, "stays in the plane")
		end
	end)

	t.test("spin decays as exp(-t / tau)", function()
		local decaying = params({ magnusK = 0.003, spinZ = 200, spinDecaySeconds = 25 })
		local scaled = params({ magnusK = 0.003, spinZ = 200 * math.exp(-1) })
		local ax1, ay1 = FlightPhysics.acceleration(decaying, 25, 30, 5, 0)
		local ax2, ay2 = FlightPhysics.acceleration(scaled, 0, 30, 5, 0)
		TestUtil.assertNear(ax1, ax2, 1e-12, "ax")
		TestUtil.assertNear(ay1, ay2, 1e-12, "ay")
	end)

	t.test("drag shortens carry compared with vacuum flight", function()
		local vacuum = carry(params(), 100, 28)
		local dragged = carry(realParams(0), 100, 28)
		TestUtil.assertTrue(dragged < 0.75 * vacuum, string.format("drag %.1f m vs vacuum %.1f m", dragged, vacuum))
	end)

	t.test("backspin lifts and carries farther; topspin drops and carries shorter", function()
		local back, backTraj = carry(realParams(2500), 95, 25)
		local none, noneTraj = carry(realParams(0), 95, 25)
		local top, topTraj = carry(realParams(-2000), 95, 25)
		TestUtil.assertTrue(back > none + 10, string.format("backspin %.1f m vs none %.1f m", back, none))
		TestUtil.assertTrue(top < none - 10, string.format("topspin %.1f m vs none %.1f m", top, none))
		TestUtil.assertTrue(backTraj.apexHeight > noneTraj.apexHeight and topTraj.apexHeight < noneTraj.apexHeight, "apex ordering")
		-- Instantaneous lift: backspin pushes up (less than g down), topspin pushes down.
		local vx, vy = launchAt(95, 0)
		local _, ayBack = FlightPhysics.acceleration(realParams(2500), 0, vx, vy, 0)
		local _, ayTop = FlightPhysics.acceleration(realParams(-2500), 0, vx, vy, 0)
		local _, ayNone = FlightPhysics.acceleration(realParams(0), 0, vx, vy, 0)
		TestUtil.assertTrue(ayBack > -G + 3 and ayTop < -G - 3, string.format("lift %.2f / %.2f m/s^2", ayBack, ayTop))
		TestUtil.assertNear(ayNone, -G, 1e-9, "no lift without spin")
	end)

	t.test("sidespin breaks the ball sideways", function()
		local _, right = carry(realParams(1500, 1500), 90, 25)
		local _, left = carry(realParams(1500, -1500), 90, 25)
		local _, straight = carry(realParams(1500, 0), 90, 25)
		local function endZ(traj: FlightPhysics.Trajectory): number
			return (traj.fieldLanding :: FlightPhysics.Landing).z
		end
		TestUtil.assertTrue(endZ(right) > 3 and endZ(left) < -3, "sidespin direction")
		TestUtil.assertNear(endZ(straight), 0, 1e-9, "no sidespin, no break")
	end)

	t.test("fixed step converges: 120 Hz agrees with 960 Hz to a millimeter", function()
		for _, case in { { 100, 28, 2500 }, { 75, 12, 600 }, { 300, 30, 3000 }, { 60, 70, 4500 } } do
			local p = realParams(case[3])
			local coarse = carry(p, case[1], case[2], 1 / 120)
			local fine = carry(p, case[1], case[2], 1 / 960)
			TestUtil.assertNear(coarse, fine, 0.001, `{case[1]} mph at {case[2]} deg`)
		end
	end)

	t.test("rendering is frame-rate independent: position is a pure function of time", function()
		local frame = FieldFrame.new(TestUtil.geometries().rotated)
		local flight = BBTU.flight(frame, { speedMph = 85, launchDegrees = 26, sprayDegrees = -12, backspinRpm = 2100, sidespinRpm = 300 })
		local rng = TestUtil.rng(5)
		local duration = flight.trajectory.duration
		local endPositions = {}
		for _, fps in { 24, 30, 60, 144, 240, 0 } do
			local now, last = 0, BattedBall.positionAt(flight, 0)
			while now < duration do
				local dt = if fps == 0 then rng:NextNumber(0.001, 0.1) else 1 / fps
				now = math.min(duration, now + dt)
				local p = BattedBall.positionAt(flight, now)
				-- Never jumps farther than the ball can travel in one frame.
				local maxStep = flight.exitSpeedMps * frame.studsPerMeter * dt * 1.05 + 1e-3
				TestUtil.assertTrue((p - last).Magnitude <= maxStep, `{fps} fps: jump`)
				last = p
			end
			table.insert(endPositions, last)
		end
		for i = 2, #endPositions do
			TestUtil.assertTrue((endPositions[i] - endPositions[1]).Magnitude < 1e-4, "end position depends on frame rate")
		end
		-- Query order doesn't matter.
		for _, time in { 2.1, 0.3, 1.7, 0.3, 2.1 } do
			local a = BattedBall.positionAt(flight, time)
			local b = BattedBall.positionAt(flight, time)
			TestUtil.assertTrue(a == b, "sampling has hidden state")
		end
	end)

	t.test("identical launch records reconstruct bit-identical flights (encode/decode too)", function()
		local frame = FieldFrame.new(TestUtil.geometries().rotated)
		local launch = BBTU.launchData(frame, { speedMph = 92.3, launchDegrees = 31.7, sprayDegrees = 17.2, backspinRpm = 2333, sidespinRpm = -411 })
		local decoded, endTime = BattedBall.decode(BattedBall.encode(launch, 4.25))
		assert(decoded and endTime, "decode failed")
		TestUtil.assertEqual(endTime, 4.25, "end time")
		local a = BattedBall.buildFlight(frame, launch)
		local b = BattedBall.buildFlight(FieldFrame.new(TestUtil.geometries().rotated), decoded)
		TestUtil.assertEqual(a.trajectory.count, b.trajectory.count, "sample count")
		for i = 1, a.trajectory.count do
			local ta, tb = a.trajectory, b.trajectory
			if ta.px[i] ~= tb.px[i] or ta.py[i] ~= tb.py[i] or ta.pz[i] ~= tb.pz[i] or ta.vx[i] ~= tb.vx[i] then
				error(`sample {i} differs`)
			end
		end
		TestUtil.assertTrue(BattedBall.decode({ 1, 2, 3 }) == nil, "short packet rejected")
		TestUtil.assertTrue(BattedBall.decode("junk") == nil, "non-table rejected")
	end)

	t.test("a 100 mph, 28 degree fly ball carries like published Statcast data", function()
		-- Reference: Statcast batted balls at ~100 mph / 28 deg average ~390-400 ft
		-- with ~5.3-5.5 s hang time (A. Nathan's trajectory calculator gives
		-- ~400 ft with similar inputs). This is a plausibility band, not a fit target.
		local meters, traj = carry(realParams(2500), 100, 28)
		local feet = meters / Units.METERS_PER_FOOT
		TestUtil.assertTrue(feet > 370 and feet < 420, string.format("carry %.0f ft", feet))
		local hang = (traj.fieldLanding :: FlightPhysics.Landing).time
		TestUtil.assertTrue(hang > 5.0 and hang < 5.9, string.format("hang time %.2f s", hang))
	end)

	t.test("extreme launches stay finite and inside the step budget", function()
		local cfg = BattedBallConfig.Flight
		local maxSteps = math.ceil(cfg.MaxFlightSeconds / cfg.FixedStepSeconds)
		for _, case in { { 1000, 45, 3000 }, { 3000, 5, 0 }, { 400, 89, 6000 }, { 0.5, -10, 0 }, { 0, 0, 0 }, { 60, 90, 0 } } do
			local vx, vy = launchAt(case[1], case[2])
			local start = os.clock()
			local traj = FlightPhysics.simulate(realParams(case[3]), 0, 0.9, 0, vx, vy, 0, options())
			local elapsed = os.clock() - start
			TestUtil.assertTrue(traj.count - 1 <= maxSteps, `{case[1]} mph: {traj.count - 1} steps over budget`)
			TestUtil.assertTrue(elapsed < 0.25, string.format("%d mph took %.1f ms", case[1], elapsed * 1000))
			for i = 1, traj.count do
				local x, y, z = traj.px[i], traj.py[i], traj.pz[i]
				if x ~= x or y ~= y or z ~= z or math.abs(x) == math.huge then
					error(`{case[1]} mph: non-finite sample {i}`)
				end
			end
		end
		-- The distance budget ends absurd flat drives.
		local vx = launchAt(5000, 0)
		local flat = FlightPhysics.simulate(params({ gravity = 0 }), 0, 1, 0, vx, 0, 0, options())
		TestUtil.assertEqual(flat.endReason, "MaxDistance", "distance budget")
		-- Straight up: launch angle 90, no backspin axis, nothing NaN.
		local frame = FieldFrame.new(TestUtil.geometries().straight)
		local up = BBTU.flight(frame, { speedMph = 60, launchDegrees = 90 })
		TestUtil.assertNear(up.launchAngleDegrees, 90, 1e-3, "vertical launch angle")
		TestUtil.assertTrue(up.backspinRpm == up.backspinRpm, "backspin NaN")
	end)
end
