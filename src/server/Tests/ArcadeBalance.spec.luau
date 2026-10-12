--!strict
-- Geometry invariants and real-swing regressions; --balance covers distributions.
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.BattedBall.BattedBallConfig)
local ImpactModel = require(Shared.BattedBall.ImpactModel)
local BattedBall = require(Shared.BattedBall.BattedBall)
local BBTU = require(script.Parent.BattedBallTestUtil)
local TestUtil = require(script.Parent.TestUtil)

return function(t)
	t.test("original tuning reproduces the measured Stage 4 benchmark", function()
		local geometry = TestUtil.geometries().straight
		local flight = BBTU.hit(geometry, BBTU.pitch(geometry, 537), 0, -0.03, 0, Config.OriginalBalance)
		TestUtil.assertNear(flight.exitSpeedMph, 75.6, 0.5, "original exit speed")
		TestUtil.assertNear(flight.launchAngleDegrees, 27.4, 0.5, "original launch angle")
		assert(flight.fieldLanding, "original benchmark must land on the flat field")
		TestUtil.assertNear(flight.fieldLanding.distance / 0.3048, 265.45, 0.5, "original carry")
	end)

	t.test("normal map is monotonic, unit length, symmetric and preserves spray", function()
		local up, horizontal = Vector3.yAxis, Vector3.new(0.8, 0, 0.6)
		local previous = -1
		for i = -1000, 1000 do
			local u = i / 1000
			local normal = horizontal * math.sqrt(1 - u * u) + up * u
			local mapped = ImpactModel.contactNormal(normal, up, Config.ArcadeContact)
			TestUtil.assertNear(mapped.Magnitude, 1, 2e-6, "unit normal")
			TestUtil.assertTrue(mapped.Y >= previous - 1e-6, "monotonic tilt")
			previous = mapped.Y
			if math.abs(u) < 0.999 then
				TestUtil.assertNear(mapped.X / mapped.Z, horizontal.X / horizontal.Z, 2e-6, "spray preserved")
			end
			local reflected = ImpactModel.contactNormal(horizontal * math.sqrt(1 - u * u) - up * u, up, Config.ArcadeContact)
			TestUtil.assertNear(reflected.Y, -mapped.Y, 2e-6, "topped/under symmetry")
		end
		TestUtil.assertEqual(ImpactModel.contactNormal(up, up, Config.ArcadeContact), up, "edge")
		TestUtil.assertEqual(ImpactModel.contactNormal(horizontal, up, Config.ArcadeContact), horizontal, "center")
	end)

	t.test("shoulder is smooth and the adjustment rotates with the swing plane", function()
		local cfg = Config.ArcadeContact
		local function value(u: number): number
			return ImpactModel.contactNormal(Vector3.new(math.sqrt(1 - u * u), u, 0), Vector3.yAxis, cfg).Y
		end
		local h = 0.001
		for _, s in {-cfg.ShoulderStart, 0, cfg.ShoulderStart} do
			local left, right = (value(s) - value(s - h)) / h, (value(s + h) - value(s)) / h
			TestUtil.assertNear(left, right, 0.002, "continuous derivative")
			TestUtil.assertNear(left, cfg.CenterSlope, 0.002, "center/shoulder slope")
		end
		local rotation = CFrame.fromEulerAnglesXYZ(0.4, -0.7, 0.2)
		local normal = Vector3.new(0.8, 0.6, 0)
		local actual = ImpactModel.contactNormal(rotation:VectorToWorldSpace(normal), rotation:VectorToWorldSpace(Vector3.yAxis), cfg)
		local expected = rotation:VectorToWorldSpace(ImpactModel.contactNormal(normal, Vector3.yAxis, cfg))
		TestUtil.assertTrue((actual - expected).Magnitude < 2e-6, "rotation invariant")
		local disabled = table.clone(cfg)
		disabled.Enabled = false
		TestUtil.assertEqual(ImpactModel.contactNormal(normal, Vector3.yAxis, disabled), normal, "exact bypass")
	end)

	t.test("separating contact remains separating with forgiveness", function()
		local normal, velocity = Vector3.new(0.5, math.sqrt(0.75), 0), Vector3.new(-5, 10, 0)
		local result = ImpactModel.resolve({normal = normal, up = Vector3.yAxis, ballVelocity = velocity,
			ballSpin = Vector3.zero, batVelocity = Vector3.zero, distanceFromKnob = 0.68, sweetSpotFromKnob = 0.68})
		TestUtil.assertTrue(result.separated, "real contact separates")
		TestUtil.assertEqual(result.velocity, velocity, "no fabricated impulse")
	end)

	t.test("real swings have a broader elevated window and lower vertical sensitivity", function()
		for _, geometry in TestUtil.geometries() do
			local pitch = BBTU.pitch(geometry, 537)
			local originalWindow, arcadeWindow = 0, 0
			for offset = -70, -10 do
				local original = BBTU.hit(geometry, pitch, 0, offset / 1000, 0, Config.OriginalBalance)
				local arcade = BBTU.hit(geometry, pitch, 0, offset / 1000, 0)
				if original.launchAngleDegrees >= 20 and original.launchAngleDegrees <= 40 then
					originalWindow += 1
				end
				if arcade.launchAngleDegrees >= 20 and arcade.launchAngleDegrees <= 40 then
					arcadeWindow += 1
				end
			end
			TestUtil.assertTrue(arcadeWindow >= originalWindow * 1.25, `window {arcadeWindow} vs {originalWindow} mm`)
			local function slope(config: ImpactModel.Config?): number
				local a = BBTU.hit(geometry, pitch, 0, -0.035, 0, config)
				local b = BBTU.hit(geometry, pitch, 0, -0.025, 0, config)
				return a.launchAngleDegrees - b.launchAngleDegrees
			end
			TestUtil.assertTrue(slope(nil) < 0.7 * slope(Config.OriginalBalance), "1 cm sensitivity reduced")
		end
	end)

	t.test("labels never drive launch and inaccurate swings still lose power or miss", function()
		local geometry = TestUtil.geometries().straight
		local pitch = BBTU.pitch(geometry, 537)
		local ideal, contact, _, frame = BBTU.hit(geometry, pitch, 0, -0.04, 0)
		local changed = table.clone(contact)
		changed.label, changed.score = "Weak", 0
		changed.factors = {timing = 0, sweetSpot = 0, vertical = 0, efficiency = 0}
		local ids = {hitId = 1, laneId = "Test", pitchId = 1, userId = 1}
		local a = BattedBall.computeLaunch(frame, contact, ids)
		local b = BattedBall.computeLaunch(frame, changed, ids)
		TestUtil.assertEqual(a.velocity, b.velocity, "label-independent velocity")
		TestUtil.assertEqual(a.spin, b.spin, "label-independent spin")
		local mistimed = BBTU.hit(geometry, pitch, 0, -0.04, -0.045)
		local jammed = BBTU.hit(geometry, pitch, 0.3, -0.04, 0)
		TestUtil.assertTrue(mistimed.exitSpeedMph < ideal.exitSpeedMph - 15, "timing penalty")
		TestUtil.assertTrue(jammed.exitSpeedMph < ideal.exitSpeedMph - 25, "sweet spot penalty")
		TestUtil.assertTrue(BBTU.swing(geometry, pitch, 0, -0.15, 0).contact == nil, "aim miss")
		TestUtil.assertTrue(BBTU.swing(geometry, pitch, 0, -0.04, 0.12).contact == nil, "timing miss")
	end)
end
