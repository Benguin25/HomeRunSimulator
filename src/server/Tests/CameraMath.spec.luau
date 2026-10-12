--!strict
-- Pure camera math (Stage 4): springs, orientation, profiles, heading,
-- occlusion easing and the contact impulse.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Presentation = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Presentation")
local CameraMath = require(Presentation.CameraMath)
local PresentationConfig = require(Presentation.PresentationConfig)

local TestUtil = require(script.Parent.TestUtil)

local function runSpring(fps: number, seconds: number, target: Vector3): CameraMath.Spring
	local spring: CameraMath.Spring = { value = Vector3.zero, velocity = Vector3.zero }
	local frames = math.floor(seconds * fps + 0.5)
	for _ = 1, frames do
		CameraMath.springStep(spring, target, 0.35, 1 / fps)
	end
	return spring
end

return function(t)
	t.test("spring result is identical at 30, 60, 120, 144 and 240 fps", function()
		local target = Vector3.new(10, -4, 7)
		local reference = runSpring(240, 1.5, target)
		for _, fps in { 30, 60, 120, 144 } do
			local s = runSpring(fps, 1.5, target)
			TestUtil.assertNear((s.value - reference.value).Magnitude, 0, 1e-4, `position at {fps} fps`)
			TestUtil.assertNear((s.velocity - reference.velocity).Magnitude, 0, 1e-3, `velocity at {fps} fps`)
		end
	end)

	t.test("spring approaches without overshoot and settles", function()
		local spring: CameraMath.Spring = { value = Vector3.zero, velocity = Vector3.zero }
		local target = Vector3.new(5, 0, 0)
		local last = 0
		for _ = 1, 600 do
			CameraMath.springStep(spring, target, 0.35, 1 / 60)
			TestUtil.assertTrue(spring.value.X <= 5 + 1e-6, "overshoot")
			TestUtil.assertTrue(spring.value.X >= last - 1e-9, "not monotonic")
			last = spring.value.X
		end
		TestUtil.assertNear(spring.value.X, 5, 1e-3, "settled")
		-- A huge dt (hitch) lands on the target instead of exploding.
		local s2: CameraMath.Spring = { value = Vector3.zero, velocity = Vector3.new(100, 0, 0) }
		CameraMath.springStep(s2, target, 0.35, 10)
		TestUtil.assertNear(s2.value.X, 5, 1e-3, "hitch")
	end)

	t.test("damp is frame-rate independent", function()
		local a, b = 0, 0
		for _ = 1, 30 do
			a = CameraMath.damp(a, 1, 0.2, 1 / 30)
		end
		for _ = 1, 144 do
			b = CameraMath.damp(b, 1, 0.2, 1 / 144)
		end
		TestUtil.assertNear(a, b, 1e-9, "damp 30 vs 144")
	end)

	t.test("yaw/pitch match CFrame.fromEulerAnglesYXZ and the pose has no roll", function()
		for _, d in { Vector3.new(1, 0.3, -2), Vector3.new(-3, -1, 0.5), Vector3.new(0.2, 0.1, 4) } do
			local yaw, pitch = CameraMath.yawPitch(d, 89)
			local dir = CameraMath.direction(yaw, pitch)
			TestUtil.assertNear((dir - d.Unit).Magnitude, 0, 1e-5, "direction round trip")
			local cf = CameraMath.toCFrame({ position = Vector3.new(1, 2, 3), yaw = yaw, pitch = pitch, fov = 60 })
			TestUtil.assertNear((cf.LookVector - d.Unit).Magnitude, 0, 1e-4, "CFrame look")
			TestUtil.assertNear(cf.RightVector.Y, 0, 1e-5, "roll (right vector stays horizontal)")
		end
	end)

	t.test("pitch is clamped: looking straight up or down never degenerates", function()
		local limit = math.rad(PresentationConfig.Camera.MaxPitchDegrees)
		local _, up = CameraMath.yawPitch(Vector3.new(0, 1, 0))
		local _, down = CameraMath.yawPitch(Vector3.new(0, -1, 1e-9))
		TestUtil.assertNear(up, limit, 1e-9, "straight up")
		TestUtil.assertNear(down, -limit, 1e-9, "straight down")
		local pose = CameraMath.lookPose(Vector3.zero, Vector3.new(0, 50, 0), 60)
		TestUtil.assertTrue(pose.yaw == pose.yaw and pose.pitch == pose.pitch, "NaN orientation")
	end)

	t.test("pose blending takes the short way round and never rolls", function()
		local a: CameraMath.Pose = { position = Vector3.zero, yaw = math.rad(170), pitch = 0, fov = 50 }
		local b: CameraMath.Pose = { position = Vector3.new(10, 0, 0), yaw = math.rad(-170), pitch = 0.2, fov = 70 }
		local mid = CameraMath.blendPoses(a, b, 0.5)
		TestUtil.assertNear(math.abs(CameraMath.wrapAngle(mid.yaw)), math.pi, 1e-6, "through 180, not 0")
		TestUtil.assertNear(mid.fov, 60, 1e-9, "fov")
		local arc = CameraMath.blendPoses(a, b, 0.5, 4)
		TestUtil.assertNear(arc.position.Y, 4, 1e-6, "arc peak")
		TestUtil.assertNear(CameraMath.blendPoses(a, b, 1, 4).position.Y, 0, 1e-6, "arc ends on the target")
	end)

	t.test("profiles: anchors by launch angle, continuous between them, clamped outside", function()
		TestUtil.assertEqual(CameraMath.profileFor(2).name, "Grounder")
		TestUtil.assertEqual(CameraMath.profileFor(16).name, "LineDrive")
		TestUtil.assertEqual(CameraMath.profileFor(30).name, "FlyBall")
		TestUtil.assertEqual(CameraMath.profileFor(70).name, "PopUp")
		TestUtil.assertEqual(CameraMath.profileFor(-30).Back, PresentationConfig.Profiles[1].Back, "below the first anchor")
		local prev = CameraMath.profileFor(-10)
		for deg = -9.9, 80, 0.1 do
			local p = CameraMath.profileFor(deg)
			TestUtil.assertTrue(math.abs(p.Back - prev.Back) < 0.1, `Back jumps at {deg}`)
			TestUtil.assertTrue(math.abs(p.FieldOfView - prev.FieldOfView) < 0.1, `FOV jumps at {deg}`)
			prev = p
		end
	end)

	t.test("power factor is clamped for weak and extreme exit velocities", function()
		TestUtil.assertEqual(CameraMath.powerFactor(10), 0)
		TestUtil.assertEqual(CameraMath.powerFactor(400), 1)
		local mid = CameraMath.powerFactor((PresentationConfig.Camera.PowerMinMph + PresentationConfig.Camera.PowerMaxMph) / 2)
		TestUtil.assertNear(mid, 0.5, 1e-9, "midpoint")
	end)

	t.test("heading turns at a bounded rate and holds when the ball has no horizontal speed", function()
		local heading = Vector3.new(0, 0, -1)
		local dt = 1 / 60
		-- Velocity reversed: a naive follow would flip 180 degrees in one frame.
		local turned = CameraMath.stepHeading(heading, Vector3.new(0, 0, 200), 0.28, dt)
		local angle = math.acos(math.clamp(turned:Dot(heading), -1, 1))
		TestUtil.assertTrue(angle <= math.rad(PresentationConfig.Camera.MaxHeadingDegreesPerSecond) * dt + 1e-6, "rate limit")
		local held = CameraMath.stepHeading(heading, Vector3.new(0.5, 80, 0.5), 0.28, dt)
		TestUtil.assertNear((held - heading).Magnitude, 0, 1e-9, "straight-up ball keeps heading")
		TestUtil.assertNear(turned.Y, 0, 1e-9, "heading stays horizontal")
	end)

	t.test("occlusion pulls in at once, eases out slowly and never exceeds the desired distance", function()
		local afterHit = CameraMath.stepOcclusion(20, 20, 8, 1 / 144)
		TestUtil.assertEqual(afterHit, 8, "in front of the wall on the first frame")
		local released = CameraMath.stepOcclusion(afterHit, 20, nil, 0.1)
		TestUtil.assertTrue(released > afterHit and released < 15, `eases out: {released}`)
		TestUtil.assertTrue(CameraMath.stepOcclusion(30, 20, nil, 0.1) <= 20, "clamped to desired")
	end)

	t.test("impulse: none for weak contact, bounded, deterministic and over in DurationSeconds", function()
		local cfg = PresentationConfig.Shake
		local p0, y0, f0 = CameraMath.impulse(cfg.MinIntensity - 0.01, 0.01)
		TestUtil.assertTrue(p0 == 0 and y0 == 0 and f0 == 0, "weak contact has no impulse")
		local maxRad = math.rad(cfg.MaxDegrees)
		for age = 0, cfg.DurationSeconds, 0.005 do
			local p, y, f = CameraMath.impulse(1, age)
			TestUtil.assertTrue(math.abs(p) <= maxRad + 1e-9 and math.abs(y) <= maxRad + 1e-9, "bounded")
			TestUtil.assertTrue(f >= -1e-9 and f <= cfg.FovPunchDegrees + 1e-9, "fov punch bounded")
			local p2, y2, f2 = CameraMath.impulse(1, age)
			TestUtil.assertTrue(p == p2 and y == y2 and f == f2, "deterministic")
		end
		local pe, ye, fe = CameraMath.impulse(1, cfg.DurationSeconds)
		TestUtil.assertTrue(pe == 0 and ye == 0 and fe == 0, "finished")
	end)
end
