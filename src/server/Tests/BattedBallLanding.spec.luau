--!strict
-- First-impact detection, distance measurement and fair/foul tests (pure
-- Luau). The environment is analytic geometry swept exactly (planes and
-- boxes), so the expected impacts are known independently of the detector.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local LaneGeometry = require(Shared.Pitching.LaneGeometry)
local FieldFrame = require(Shared.BattedBall.FieldFrame)
local FlightPhysics = require(Shared.BattedBall.FlightPhysics)
local LandingDetector = require(Shared.BattedBall.LandingDetector)

local BBTU = require(script.Parent.BattedBallTestUtil)
local TestUtil = require(script.Parent.TestUtil)

local G = 9.80665
local R = 0.0366
local VACUUM = BBTU.flightConfig({ AirDensityScale = 0 })

local function frames(): { [string]: FieldFrame.Frame }
	local result = {}
	for name, geometry in TestUtil.geometries() do
		result[name] = FieldFrame.new(geometry)
	end
	return result
end

local function wall(x: number, height: number, thickness: number?): BBTU.Shape
	return BBTU.box("Wall", Vector3.new(x, -1, -500), Vector3.new(x + (thickness or 1), height, 500))
end

return function(t)
	t.test("first ground contact matches the analytic vacuum landing", function()
		for laneName, frame in frames() do
			for _, case in { { 30, 35, 10 }, { 45, 20, -25 }, { 15, 60, 0 } } do
				local v, a, spray = case[1], math.rad(case[2]), math.rad(case[3])
				local mph = v / 0.44704
				local flight = BBTU.flight(frame, { speedMph = mph, launchDegrees = case[2], sprayDegrees = case[3], x = 0.5, y = 0.9 }, VACUUM)
				local outcome = LandingDetector.evaluate(flight, BBTU.scene(frame, { BBTU.ground() }).caster)
				-- Ball center reaches y = R (bottom touches y = 0) at the positive root.
				local vy = v * math.sin(a)
				local time = (vy + math.sqrt(vy * vy + 2 * G * (0.9 - R))) / G
				local horizontal = v * math.cos(a) * time
				local x, z = 0.5 + horizontal * math.cos(spray), horizontal * math.sin(spray)
				TestUtil.assertEqual(outcome.kind, "Landed", `{laneName}: kind`)
				TestUtil.assertNear(outcome.endTime, time, 1e-4, `{laneName} {case[1]} m/s: impact time`)
				TestUtil.assertNear(outcome.carryMeters :: number, math.sqrt(x * x + z * z), 2e-3, `{laneName} {case[1]} m/s: carry`)
				TestUtil.assertNear((outcome.impact :: LandingDetector.Impact).y, 0, 1e-3, `{laneName}: touch point on the ground`)
			end
		end
	end)

	t.test("on flat ground the measured carry equals the free-flight landing", function()
		local frame = frames().rotated
		for _, spec in {
			{ speedMph = 100, launchDegrees = 28, backspinRpm = 2500 },
			{ speedMph = 80, launchDegrees = 12, sprayDegrees = 30, backspinRpm = 900, sidespinRpm = 400 },
			{ speedMph = 70, launchDegrees = -8, backspinRpm = -1500 },
		} :: { BBTU.LaunchSpec } do
			local flight = BBTU.flight(frame, spec)
			local outcome = LandingDetector.evaluate(flight, BBTU.scene(frame, { BBTU.ground() }).caster)
			local landing = flight.fieldLanding :: FlightPhysics.Landing
			TestUtil.assertEqual(outcome.kind, "Landed", "kind")
			TestUtil.assertNear(outcome.carryMeters :: number, landing.distance, 3e-3, `{spec.speedMph} mph carry`)
			TestUtil.assertNear(outcome.endTime, landing.time, 1e-3, `{spec.speedMph} mph time`)
			TestUtil.assertNear(outcome.projectedCarryMeters :: number, landing.distance, 1e-9, "projection")
		end
	end)

	t.test("a very fast ball cannot tunnel through a thin wall", function()
		local frame = frames().straight
		local flight = BBTU.flight(frame, { speedMph = 300, launchDegrees = 5, backspinRpm = 1000 })
		local thin = wall(60, 30, 0.05)
		local outcome = LandingDetector.evaluate(flight, BBTU.scene(frame, { thin, BBTU.ground() }).caster)
		TestUtil.assertEqual(outcome.kind, "Obstacle", "kind")
		TestUtil.assertNear((outcome.impact :: LandingDetector.Impact).x, 60, 1e-3, "impact on the wall face")
		-- Sanity: point-sampling the same flight at 60 Hz never finds the ball inside the wall.
		local traj = flight.trajectory
		local found = false
		for time = 0, traj.duration, 1 / 60 do
			local x = FlightPhysics.sample(traj, time)
			if x > 60 - R and x < 60.05 + R then
				found = true
			end
		end
		TestUtil.assertTrue(not found, "the scenario should defeat naive sampling")
	end)

	t.test("hitting a wall is an obstacle outcome with no carry distance", function()
		local frame = frames().straight
		local flight = BBTU.flight(frame, { speedMph = 100, launchDegrees = 28, backspinRpm = 2500 })
		local outcome = LandingDetector.evaluate(flight, BBTU.scene(frame, { wall(60, 60), BBTU.ground() }).caster)
		TestUtil.assertEqual(outcome.kind, "Obstacle", "kind")
		TestUtil.assertTrue(outcome.carryMeters == nil, "no carry after hitting a wall")
		local impact = outcome.impact :: LandingDetector.Impact
		TestUtil.assertEqual(impact.surface, "Wall", "surface")
		TestUtil.assertNear(outcome.impactDistanceMeters :: number, 60, 0.01, "impact distance")
		TestUtil.assertTrue((outcome.impactHeightMeters :: number) > 5, "impact height")
		TestUtil.assertTrue((outcome.projectedCarryMeters :: number) > 100, "projection ignores the wall")
		TestUtil.assertEqual(outcome.territory, "Fair", "territory")
	end)

	t.test("a ball that clears the fence lands beyond it", function()
		local frame = frames().straight
		local flight = BBTU.flight(frame, { speedMph = 100, launchDegrees = 28, backspinRpm = 2500 })
		local outcome = LandingDetector.evaluate(flight, BBTU.scene(frame, { wall(95, 3), BBTU.ground() }).caster)
		TestUtil.assertEqual(outcome.kind, "Landed", "kind")
		TestUtil.assertTrue((outcome.carryMeters :: number) > 96, "landed past the fence")
		TestUtil.assertNear(outcome.carryMeters :: number, outcome.projectedCarryMeters :: number, 3e-3, "same as the flat-field landing")
	end)

	t.test("raised stands count as ground: carry is measured where the ball comes down", function()
		local frame = frames().rotated
		local flight = BBTU.flight(frame, { speedMph = 100, launchDegrees = 28, backspinRpm = 2500 })
		local stands = BBTU.box("Stands", Vector3.new(100, -1, -500), Vector3.new(300, 8, 500))
		local outcome = LandingDetector.evaluate(flight, BBTU.scene(frame, { stands, BBTU.ground() }).caster)
		TestUtil.assertEqual(outcome.kind, "Landed", "kind")
		TestUtil.assertNear(outcome.impactHeightMeters :: number, 8, 1e-3, "landed on top of the stands")
		local carry = outcome.carryMeters :: number
		TestUtil.assertTrue(carry > 100 and carry < (outcome.projectedCarryMeters :: number) - 1, "comes down early on the raised surface")
	end)

	t.test("a pop-up into a roof is a ceiling obstacle", function()
		local frame = frames().straight
		local flight = BBTU.flight(frame, { speedMph = 75, launchDegrees = 70, backspinRpm = 4000 })
		local roof = BBTU.box("Roof", Vector3.new(-50, 15, -100), Vector3.new(200, 16, 100))
		local outcome = LandingDetector.evaluate(flight, BBTU.scene(frame, { roof, BBTU.ground() }).caster)
		TestUtil.assertEqual(outcome.kind, "Obstacle", "kind")
		TestUtil.assertEqual((outcome.impact :: LandingDetector.Impact).surface, "Ceiling", "surface")
		TestUtil.assertNear(outcome.impactHeightMeters :: number, 15, 1e-3, "underside height")
	end)

	t.test("fair and foul follow the foul lines (rulebook layout)", function()
		for laneName, frame in frames() do
			local function call(spray: number, launch: number?): LandingDetector.Outcome
				local flight = BBTU.flight(frame, { speedMph = 80, launchDegrees = launch or 25, sprayDegrees = spray, backspinRpm = 2000 }, VACUUM)
				return LandingDetector.evaluate(flight, BBTU.scene(frame, { BBTU.ground() }).caster)
			end
			TestUtil.assertEqual(call(0).territory, "Fair", `{laneName} center`)
			TestUtil.assertEqual(call(30).territory, "Fair", `{laneName} right-center`)
			TestUtil.assertEqual(call(-44).territory, "Fair", `{laneName} inside the left line`)
			TestUtil.assertEqual(call(46).territory, "Foul", `{laneName} past the right line`)
			TestUtil.assertEqual(call(-50).territory, "Foul", `{laneName} past the left line`)
			TestUtil.assertEqual(call(150, 60).territory, "Foul", `{laneName} behind the plate`)
			TestUtil.assertTrue(math.abs(call(30).sprayAngleDegrees - 30) < 0.5, "spray at landing")
		end
		local frame = frames().straight
		TestUtil.assertEqual(FieldFrame.territory(frame, 10, 10), "Fair", "on the right line is fair")
		TestUtil.assertEqual(FieldFrame.territory(frame, 10, -10), "Fair", "on the left line is fair")
		TestUtil.assertEqual(FieldFrame.territory(frame, 0, 0), "Foul", "home plate itself")
	end)

	t.test("foul poles and bases define the foul lines; bad markers fall back to the rulebook", function()
		local base = TestUtil.geometries().rotated
		local function geometryWith(extra: { [string]: Vector3 }): LaneGeometry.Geometry
			local inputs = table.clone(base.inputs) :: any
			for key, value in extra do
				inputs[key] = value
			end
			return LaneGeometry.new(inputs)
		end
		local function at(spray: number, distanceMeters: number): Vector3
			local s = 1 / base.units.metersPerStud
			local a = math.rad(spray)
			return base.plateGround + (base.toPitcher * math.cos(a) + base.right * math.sin(a)) * distanceMeters * s
		end
		-- Asymmetric poles: right line at +40, left at -50 (opening 90).
		local poles = FieldFrame.new(geometryWith({ rightFoulPole = at(40, 100), leftFoulPole = at(-50, 100) }))
		TestUtil.assertNear(math.deg(poles.rightLineAngle), 40, 1e-3, "right line from pole")
		TestUtil.assertNear(math.deg(poles.leftLineAngle), -50, 1e-3, "left line from pole")
		TestUtil.assertEqual(FieldFrame.territory(poles, 50 * math.cos(math.rad(42)), 50 * math.sin(math.rad(42))), "Foul", "42 deg is foul with these poles")
		TestUtil.assertEqual(FieldFrame.territory(poles, 50 * math.cos(math.rad(-48)), 50 * math.sin(math.rad(-48))), "Fair", "-48 deg is fair with these poles")
		-- Bases only (poles win when both exist).
		local bases = FieldFrame.new(geometryWith({ firstBase = at(44, 27.4), thirdBase = at(-44, 27.4) }))
		TestUtil.assertNear(math.deg(bases.rightLineAngle), 44, 1e-3, "right line from first base")
		local both = FieldFrame.new(geometryWith({ firstBase = at(44, 27.4), rightFoulPole = at(46, 100) }))
		TestUtil.assertNear(math.deg(both.rightLineAngle), 46, 1e-3, "pole preferred over base")
		-- Nonsense markers (opening 150 deg) are rejected.
		local bad = FieldFrame.new(geometryWith({ rightFoulPole = at(75, 100), leftFoulPole = at(-75, 100) }))
		TestUtil.assertNear(math.deg(bad.rightLineAngle), 45, 1e-9, "fallback right")
		TestUtil.assertTrue(string.find(bad.foulLineSource, "rejected", 1, true) ~= nil, "fallback reason")
		local none = FieldFrame.new(base)
		TestUtil.assertTrue(string.find(none.foulLineSource, "rulebook", 1, true) ~= nil, "rulebook source")
	end)

	t.test("landings short of the bases are provisional fair/foul calls", function()
		local frame = frames().straight
		local scene = BBTU.scene(frame, { BBTU.ground() })
		local dribbler = LandingDetector.evaluate(BBTU.flight(frame, { speedMph = 40, launchDegrees = 5 }), scene.caster)
		local fly = LandingDetector.evaluate(BBTU.flight(frame, { speedMph = 90, launchDegrees = 28, backspinRpm = 2200 }), scene.caster)
		TestUtil.assertTrue(dribbler.territoryProvisional and (dribbler.carryMeters :: number) < 27.43, "dribbler is provisional")
		TestUtil.assertTrue(not fly.territoryProvisional, "outfield fly is final")
	end)

	t.test("with nothing to hit the outcome is NoImpact plus a labelled projection", function()
		local frame = frames().straight
		local flight = BBTU.flight(frame, { speedMph = 95, launchDegrees = 30, backspinRpm = 2400 })
		local outcome = LandingDetector.evaluate(flight, BBTU.scene(frame, {}).caster)
		TestUtil.assertEqual(outcome.kind, "NoImpact", "kind")
		TestUtil.assertTrue(outcome.carryMeters == nil, "no measured carry")
		TestUtil.assertNear(outcome.projectedCarryMeters :: number, (flight.fieldLanding :: FlightPhysics.Landing).distance, 1e-9, "projection")
		TestUtil.assertNear(outcome.endTime, flight.trajectory.duration, 1e-9, "flight runs to its end")
		local payload = LandingDetector.toPayload(outcome)
		TestUtil.assertTrue(string.find(LandingDetector.describe(payload), "NO IMPACT", 1, true) ~= nil, "description")
	end)

	t.test("chord sweeps find exactly the first impact a brute-force sweep finds", function()
		local rng = TestUtil.rng(77)
		local frame = frames().rotated
		for case = 1, 40 do
			local shapes = { BBTU.ground() }
			for _ = 1, 4 do
				local x, z = rng:NextNumber(5, 110), rng:NextNumber(-60, 60)
				local size = Vector3.new(rng:NextNumber(0.05, 6), rng:NextNumber(0.5, 25), rng:NextNumber(0.5, 30))
				local bottom = rng:NextNumber(-1, 12)
				table.insert(shapes, BBTU.box("Box", Vector3.new(x, bottom, z), Vector3.new(x, bottom, z) + size))
			end
			local flight = BBTU.flight(frame, {
				speedMph = rng:NextNumber(30, 140),
				launchDegrees = rng:NextNumber(-10, 60),
				sprayDegrees = rng:NextNumber(-50, 50),
				backspinRpm = rng:NextNumber(-1500, 3500),
				sidespinRpm = rng:NextNumber(-800, 800),
			})
			local scene = BBTU.scene(frame, shapes)
			local impact = LandingDetector.findFirstImpact(flight, scene.caster)
			-- Brute force: the true ball radius along every stored segment.
			local traj = flight.trajectory
			local radius = R * frame.studsPerMeter
			local expected: number? = nil
			for i = 1, traj.count - 1 do
				local p0 = FieldFrame.toWorld(frame, traj.px[i], traj.py[i], traj.pz[i])
				local p1 = FieldFrame.toWorld(frame, traj.px[i + 1], traj.py[i + 1], traj.pz[i + 1])
				local hit = scene.caster(p0, p1 - p0, radius)
				if hit then
					expected = (i - 1 + hit.distance / (p1 - p0).Magnitude) * traj.dt
					break
				end
			end
			if expected == nil then
				TestUtil.assertTrue(impact == nil, `case {case}: phantom impact`)
			else
				assert(impact, `case {case}: missed the impact at {expected}`)
				TestUtil.assertNear(impact.time, expected, 1e-6, `case {case}: impact time`)
			end
		end
	end)

	t.test("measurements don't depend on where the lane is in the world", function()
		local results = {}
		for name, frame in frames() do
			local flight = BBTU.flight(frame, { speedMph = 88, launchDegrees = 24, sprayDegrees = -20, backspinRpm = 2000 })
			local outcome = LandingDetector.evaluate(flight, BBTU.scene(frame, { wall(90, 3), BBTU.ground() }).caster)
			results[name] = outcome
		end
		TestUtil.assertEqual(results.straight.kind, results.rotated.kind, "kind")
		TestUtil.assertNear(results.straight.endTime, results.rotated.endTime, 1e-4, "time")
		local a = results.straight.carryMeters or results.straight.impactDistanceMeters :: number
		local b = results.rotated.carryMeters or results.rotated.impactDistanceMeters :: number
		TestUtil.assertNear(a, b, 2e-3, "distance")
	end)

	t.test("sweep cost stays small: one cast per chord plus one per step in a hit chord", function()
		local frame = frames().straight
		local flight = BBTU.flight(frame, { speedMph = 100, launchDegrees = 28, backspinRpm = 2500 })
		local scene = BBTU.scene(frame, { wall(95, 3), BBTU.ground() })
		local outcome = LandingDetector.evaluate(flight, scene.caster)
		local chordSteps = math.floor((1 / 20) / flight.trajectory.dt + 0.5)
		local chords = math.ceil((flight.trajectory.count - 1) / chordSteps)
		TestUtil.assertTrue(outcome.casts <= chords + 3 * chordSteps, `{outcome.casts} casts for {chords} chords`)
		TestUtil.assertEqual(outcome.casts, scene.casts, "cast accounting")
	end)
end
