--!strict
-- Physics, solver and targeting tests (pure Luau; run in Studio and the CLI).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Pitching = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Pitching")
local LaneGeometry = require(Pitching.LaneGeometry)
local Pitch = require(Pitching.Pitch)
local PitchConfig = require(Pitching.PitchConfig)
local PitchPhysics = require(Pitching.PitchPhysics)

local TestUtil = require(script.Parent.TestUtil)

local units = TestUtil.units
local MM = units.toStuds(0.001)
-- Solver tolerance plus float32 headroom (Vector3 is single precision).
local TARGET_TOLERANCE = units.toStuds(PitchConfig.Simulation.SolverToleranceMeters) + 2 * MM

local function generate(geometry, seed: number, overrides: { [string]: any }?)
	local options = {
		id = 1,
		laneId = "Test",
		windupTime = 0,
		releaseTime = 1,
	}
	if overrides then
		for key, value in overrides do
			(options :: any)[key] = value
		end
	end
	local data, result = Pitch.generate(geometry, TestUtil.rng(seed), options :: any)
	return data, result, Pitch.buildFlight(geometry, data)
end

return function(t)
	t.test("fastballs reach random targets within tolerance", function()
		for laneName, geometry in TestUtil.geometries() do
			for seed = 1, 60 do
				local _, result, flight = generate(geometry, seed * 7919)
				TestUtil.assertTrue(result.ok, `{laneName} seed {seed}: solver did not converge ({result.error})`)
				TestUtil.assertTrue(flight.crossing ~= nil, `{laneName} seed {seed}: no crossing`)
				TestUtil.assertTrue(
					(flight.targetError :: number) <= TARGET_TOLERANCE,
					`{laneName} seed {seed}: error {units.toMeters(flight.targetError :: number) * 1000} mm`
				)
				TestUtil.assertTrue(flight.isStrike, `{laneName} seed {seed}: in-zone target was called a ball`)
			end
		end
	end)

	t.test("targets at the strike zone edges and corners work", function()
		for laneName, geometry in TestUtil.geometries() do
			local halfWidth = geometry.zoneWidth / 2
			local points = {
				{ -halfWidth, geometry.zoneBottom },
				{ halfWidth, geometry.zoneBottom },
				{ -halfWidth, geometry.zoneTop },
				{ halfWidth, geometry.zoneTop },
				{ 0, geometry.zoneBottom },
				{ 0, geometry.zoneTop },
				{ -halfWidth, (geometry.zoneBottom + geometry.zoneTop) / 2 },
				{ halfWidth, (geometry.zoneBottom + geometry.zoneTop) / 2 },
			}
			for i, point in points do
				local target = LaneGeometry.zonePoint(geometry, point[1], point[2])
				local _, result, flight = generate(geometry, 1000 + i, { target = target })
				TestUtil.assertTrue(result.ok, `{laneName} edge {i}: solver did not converge`)
				TestUtil.assertTrue((flight.targetError :: number) <= TARGET_TOLERANCE, `{laneName} edge {i}: missed`)
				local x, y = LaneGeometry.zoneCoords(geometry, (flight.crossing :: any).position)
				TestUtil.assertNear(x, point[1], TARGET_TOLERANCE, `{laneName} edge {i} x`)
				TestUtil.assertNear(y, point[2], TARGET_TOLERANCE, `{laneName} edge {i} y`)
				TestUtil.assertTrue(flight.isStrike, `{laneName} edge {i}: edge pitch should be a strike`)
			end
		end
	end)

	t.test("strike calls include the ball radius and reject clear balls", function()
		local geometry = TestUtil.geometries().straight
		local radius = units.toStuds(PitchConfig.Ball.RadiusMeters)
		local halfWidth = geometry.zoneWidth / 2
		local midY = (geometry.zoneBottom + geometry.zoneTop) / 2
		TestUtil.assertTrue(LaneGeometry.isStrike(geometry, LaneGeometry.zonePoint(geometry, halfWidth + radius * 0.9, midY), radius))
		TestUtil.assertTrue(not LaneGeometry.isStrike(geometry, LaneGeometry.zonePoint(geometry, halfWidth + radius * 1.1, midY), radius))
		TestUtil.assertTrue(not LaneGeometry.isStrike(geometry, LaneGeometry.zonePoint(geometry, 0, geometry.zoneTop + radius * 1.1), radius))
		TestUtil.assertTrue(not LaneGeometry.isStrike(geometry, LaneGeometry.zonePoint(geometry, 0, geometry.zoneBottom - radius * 1.1), radius))
	end)

	t.test("flight time decreases as pitch speed increases", function()
		local geometry = TestUtil.geometries().straight
		local target = geometry.zoneCenter
		local previous = math.huge
		for _, mph in { 60, 70, 80, 90, 100 } do
			local _, _, flight = generate(geometry, 42, { target = target, speedMph = mph })
			local crossTime = flight.crossTime :: number
			TestUtil.assertTrue(crossTime < previous, `flight time at {mph} mph ({crossTime}) not below {previous}`)
			previous = crossTime
		end
	end)

	t.test("flight time and speed loss are physically plausible", function()
		-- An ~94 mph four-seamer takes ~0.40-0.45 s to the plate and loses ~8-10% speed.
		local geometry = TestUtil.geometries().straight
		local _, _, flight = generate(geometry, 7, { target = geometry.zoneCenter, speedMph = 94 })
		local crossTime = flight.crossTime :: number
		TestUtil.assertTrue(crossTime > 0.37 and crossTime < 0.47, `unexpected flight time {crossTime}`)
		local loss = 1 - (flight.plateSpeedMph :: number) / flight.releaseSpeedMph
		TestUtil.assertTrue(loss > 0.05 and loss < 0.13, `unexpected speed loss {loss}`)
	end)

	t.test("backspin makes a fastball drop less than a spinless ball", function()
		local geometry = TestUtil.geometries().straight
		local data = generate(geometry, 3, { target = geometry.zoneCenter })
		local spinless = table.clone(data)
		spinless.spin = Vector3.zero
		local withSpin = Pitch.buildFlight(geometry, data)
		local without = Pitch.buildFlight(geometry, spinless)
		local _, ySpin = LaneGeometry.zoneCoords(geometry, (withSpin.crossing :: any).position)
		local _, yNone = LaneGeometry.zoneCoords(geometry, (without.crossing :: any).position)
		TestUtil.assertTrue(ySpin > yNone + units.toStuds(0.1), `expected >10 cm of ride, got {units.toMeters(ySpin - yNone)} m`)
	end)

	t.test("rendering at any frame rate stays on the true flight path", function()
		-- The renderer samples the 240 Hz trajectory at whatever time a frame
		-- lands on. Compare those samples against a 4000 Hz reference
		-- integration for several frame schedules, including erratic frames.
		local geometry = TestUtil.geometries().rotated
		local data, _, flight = generate(geometry, 99)
		local traj = flight.trajectory
		local reference = PitchPhysics.simulate(data.releasePosition, data.releaseVelocity, flight.params, {
			dt = 1 / 4000,
			maxTime = traj.duration + 0.01,
			plane = geometry.zonePlane,
			stopDistancePast = math.huge,
		})

		local jitterRng = TestUtil.rng(5)
		local frameSchedules: { [string]: () -> number } = {
			["30fps"] = function()
				return 1 / 30
			end,
			["60fps"] = function()
				return 1 / 60
			end,
			["144fps"] = function()
				return 1 / 144
			end,
			["variable 2-120ms"] = function()
				return jitterRng:NextNumber(0.002, 0.12)
			end,
		}

		for label, nextDt in frameSchedules do
			local frameTime = 0
			local frames = 0
			while frameTime < traj.duration do
				local rendered = PitchPhysics.sample(traj, frameTime)
				local truth = PitchPhysics.sample(reference, frameTime)
				local deviation = (rendered - truth).Magnitude
				TestUtil.assertTrue(
					deviation < 0.5 * MM,
					string.format("%s: frame at t=%.4f deviates %.3f mm", label, frameTime, units.toMeters(deviation) * 1000)
				)
				frameTime += nextDt()
				frames += 1
			end
			TestUtil.assertTrue(frames >= 2, `{label}: no frames rendered`)
		end

		-- The crossing is a property of the trajectory, not of the frames.
		TestUtil.assertNear(flight.crossTime :: number, (reference.crossing :: any).time, 1e-4, "crossing time")
	end)

	t.test("integration step size barely changes the path (convergence)", function()
		local geometry = TestUtil.geometries().straight
		local data = generate(geometry, 11)
		local params = Pitch.buildParams(units, Pitch.getTypeConfig(data.pitchType), data.spin)
		local crossings = {}
		for _, dt in { 1 / 60, 1 / 240, 1 / 1000 } do
			local traj = PitchPhysics.simulate(data.releasePosition, data.releaseVelocity, params, {
				dt = dt,
				maxTime = 3,
				plane = geometry.zonePlane,
				stopDistancePast = 0,
			})
			table.insert(crossings, (traj.crossing :: any).position)
		end
		-- 60 Hz vs 1000 Hz differ by well under a millimeter with RK4.
		TestUtil.assertTrue((crossings[1] - crossings[3]).Magnitude < MM, "60 Hz vs 1000 Hz mismatch")
		TestUtil.assertTrue((crossings[2] - crossings[3]).Magnitude < MM, "240 Hz vs 1000 Hz mismatch")
	end)

	t.test("a ball cannot pass the zone plane without a crossing being registered", function()
		local geometry = TestUtil.geometries().rotated
		local params = Pitch.buildParams(units, Pitch.getTypeConfig("Fastball"), Vector3.zero)
		local rng = TestUtil.rng(77)
		for _ = 1, 50 do
			local speed = units.mphToStudsPerSecond(rng:NextNumber(40, 160))
			local target = LaneGeometry.zonePoint(geometry, rng:NextNumber(-3, 3), rng:NextNumber(1, 6))
			local velocity = (target - geometry.releasePoint).Unit * speed
			-- Deliberately huge steps: the ball jumps several feet per step.
			for _, dt in { 1 / 240, 1 / 30, 0.1 } do
				local traj = PitchPhysics.simulate(geometry.releasePoint, velocity, params, {
					dt = dt,
					maxTime = 4,
					plane = geometry.zonePlane,
					stopDistancePast = units.toStuds(1),
				})
				local last = traj.positions[traj.count]
				if PitchPhysics.signedDistance(geometry.zonePlane, last) >= 0 then
					local crossing = traj.crossing
					TestUtil.assertTrue(crossing ~= nil, "ball passed the plane without a crossing")
					assert(crossing, "crossing missing")
					TestUtil.assertNear(PitchPhysics.signedDistance(geometry.zonePlane, crossing.position), 0, 1e-3, "crossing off-plane")
					TestUtil.assertTrue(crossing.time >= 0 and crossing.time <= traj.duration, "crossing time out of range")
				end
			end
		end
	end)

	t.test("pitches vary in speed, target and spin", function()
		local geometry = TestUtil.geometries().straight
		local rng = TestUtil.rng(2024)
		local speeds, targets = {}, {}
		for i = 1, 10 do
			local data = Pitch.generate(geometry, rng, { id = i, laneId = "Test", windupTime = 0, releaseTime = 0 })
			speeds[math.floor(data.releaseVelocity.Magnitude * 1000)] = true
			targets[tostring(data.target)] = true
		end
		local distinctSpeeds, distinctTargets = 0, 0
		for _ in speeds do
			distinctSpeeds += 1
		end
		for _ in targets do
			distinctTargets += 1
		end
		TestUtil.assertTrue(distinctSpeeds >= 8 and distinctTargets >= 8, "pitches are not varied")
	end)

	t.test("speeds stay inside the configured range", function()
		local geometry = TestUtil.geometries().straight
		local minMph, maxMph = Pitch.getSpeedRange("Fastball")
		for seed = 1, 40 do
			local _, _, flight = generate(geometry, seed)
			TestUtil.assertTrue(
				flight.releaseSpeedMph >= minMph - 0.01 and flight.releaseSpeedMph <= maxMph + 0.01,
				`speed {flight.releaseSpeedMph} outside range`
			)
		end
	end)

	t.test("default tier is Beginner at 50-55 mph", function()
		TestUtil.assertEqual(PitchConfig.Difficulty.Active, "Beginner", "active tier")
		local minMph, maxMph = Pitch.getSpeedRange("Fastball")
		TestUtil.assertTrue(minMph >= 50 and maxMph <= 55, `default range {minMph}-{maxMph} mph`)
	end)

	t.test("beginner pitches give a readable flight time and stay accurate", function()
		-- 50-55 mph over 60.5 ft takes ~0.7-0.8 s (the old 78-85 mph took ~0.46-0.50 s).
		for laneName, geometry in TestUtil.geometries() do
			for seed = 1, 60 do
				local data, result, flight = generate(geometry, seed * 104729, { tier = "Beginner" })
				local crossTime = flight.crossTime :: number
				TestUtil.assertTrue(
					crossTime >= 0.65 and crossTime <= 0.85,
					`{laneName} seed {seed}: flight {crossTime} s at {flight.releaseSpeedMph} mph`
				)
				TestUtil.assertTrue(result.ok, `{laneName} seed {seed}: solver did not converge`)
				TestUtil.assertTrue((flight.targetError :: number) <= TARGET_TOLERANCE, `{laneName} seed {seed}: missed target`)
				TestUtil.assertTrue(flight.isStrike, `{laneName} seed {seed}: in-zone target called a ball`)
				-- Rebuilding the flight from the same data is bit-for-bit repeatable.
				local again = Pitch.buildFlight(geometry, data)
				TestUtil.assertEqual(again.trajectory.count, flight.trajectory.count, "step count")
				TestUtil.assertTrue(
					(again.crossing :: any).position == (flight.crossing :: any).position,
					"rebuilt crossing differs"
				)
			end
		end
	end)

	t.test("slower tiers always have longer flights and windups", function()
		local geometry = TestUtil.geometries().straight
		local previousFlight, previousWindup = 0, 0
		for _, tier in { "Advanced", "Intermediate", "Beginner" } do
			local _, _, flight = generate(geometry, 5, { tier = tier, target = geometry.zoneCenter })
			local crossTime = flight.crossTime :: number
			local windup = PitchConfig.getTiming(tier).WindupSeconds
			TestUtil.assertTrue(crossTime > previousFlight, `{tier} flight {crossTime} not above {previousFlight}`)
			TestUtil.assertTrue(windup > previousWindup, `{tier} windup {windup} not above {previousWindup}`)
			previousFlight, previousWindup = crossTime, windup
		end
		TestUtil.assertEqual(PitchConfig.Timing.WindupSeconds, PitchConfig.getTiming().WindupSeconds, "default timing follows tier")
	end)

	t.test("every tier hits the zone edges and registers the crossing", function()
		for _, tier in { "Beginner", "Intermediate", "Advanced" } do
			for laneName, geometry in TestUtil.geometries() do
				local halfWidth = geometry.zoneWidth / 2
				for i, point in { { -halfWidth, geometry.zoneBottom }, { halfWidth, geometry.zoneTop } } do
					local target = LaneGeometry.zonePoint(geometry, point[1], point[2])
					local _, result, flight = generate(geometry, 77 + i, { tier = tier, target = target })
					TestUtil.assertTrue(result.ok and flight.crossing ~= nil, `{tier} {laneName} corner {i}: no hit`)
					TestUtil.assertTrue((flight.targetError :: number) <= TARGET_TOLERANCE, `{tier} {laneName} corner {i}: missed`)
					-- The sampled path passes through the crossing at the crossing time.
					local sampled = PitchPhysics.sample(flight.trajectory, flight.crossTime :: number)
					TestUtil.assertTrue((sampled - (flight.crossing :: any).position).Magnitude < MM, `{tier}: sample vs crossing`)
				end
			end
		end
	end)

	t.test("encode/decode round-trips and server/client flights agree", function()
		local geometry = TestUtil.geometries().rotated
		local data = generate(geometry, 314)
		local decoded = Pitch.decode(Pitch.encode(data))
		assert(decoded, "decode failed")
		-- A client rebuilds geometry from the four replicated inputs.
		local clientGeometry = LaneGeometry.new(geometry.inputs)
		local server = Pitch.buildFlight(geometry, data)
		local client = Pitch.buildFlight(clientGeometry, decoded)
		TestUtil.assertEqual(client.trajectory.count, server.trajectory.count, "step count")
		TestUtil.assertTrue(((client.crossing :: any).position - (server.crossing :: any).position).Magnitude < 1e-6, "crossing mismatch")
		TestUtil.assertEqual(client.isStrike, server.isStrike, "strike call")
		TestUtil.assertTrue(Pitch.decode({ 1, 2, 3 }) == nil, "short packet should be rejected")
	end)
end
