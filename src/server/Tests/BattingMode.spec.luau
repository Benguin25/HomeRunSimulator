--!strict
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Rules = require(Shared.Gameplay.BattingModeRules)
local Config = require(Shared.Gameplay.BattingModeConfig)
local Movement = require(Shared.Gameplay.BattingMovement)
local Input = require(Shared.Presentation.InputMode)
local Motion = require(Shared.Presentation.PitcherMotion)
local Geometry = require(Shared.Pitching.LaneGeometry)
local Pitch = require(Shared.Pitching.Pitch)
local PitchLane = require(Shared.Pitching.PitchLane)
local Swing = require(Shared.Batting.SwingModel)
local Field = require(Shared.BattedBall.FieldFrame)
local Gate = require(Shared.Gameplay.ReturnGate)
local Lifecycle = require(Shared.BattedBall.HitLifecycle)
local Landing = require(Shared.BattedBall.LandingDetector)
local Ball = require(Shared.BattedBall.BattedBall)
local Progression = require(Shared.Progression.PlayerProgression)
local WorldRules = require(Shared.Worlds.WorldRules)
local Helpers = require(script.Parent.BattedBallTestUtil)
local Test = require(script.Parent.TestUtil)
local function entry(): Rules.Entry
	return {
		profileReady = true,
		characterReady = true,
		assigned = false,
		sameWorld = true,
		laneAvailable = true,
		distance = 4,
		side = "Right",
	}
end
return function(t)
	t.test("free roam starts with standard cursor, no swings and no pitching", function()
		local input = Input.new()
		Test.assertTrue(Input.cursor(input))
		Test.assertTrue(not Input.canSwing(input, 10, false))
		local started = 0
		local lane = PitchLane.new("test", {
			createPitch = function()
				started += 1
				return nil
			end,
		})
		lane:update(100)
		Test.assertEqual(started, 0)
		Test.assertEqual(lane.state, "Idle")
	end)
	t.test("both boxes admit only ready nearby players in the correct world", function()
		for _, side in { "Right", "Left" } do
			local context = entry()
			context.side = side
			Test.assertEqual(Rules.entry(context), nil)
			context.distance = Config.EntryDistanceStuds
			Test.assertEqual(Rules.entry(context), nil)
			context.distance += 0.01
			Test.assertEqual(Rules.entry(context), "TooFarAway")
		end
		for _, key in { "profileReady", "characterReady", "sameWorld", "laneAvailable" } do
			local context = entry()
			local mutable = context :: any
			mutable[key] = false
			Test.assertTrue(Rules.entry(context) ~= nil, key)
		end
		for _, distance in { math.huge, 0 / 0, -1, 1000 } do
			local context = entry()
			context.distance = distance
			Test.assertEqual(Rules.entry(context), "TooFarAway")
		end
	end)
	t.test("occupied lanes reject either hand and duplicate entry cannot replace a batter", function()
		local context = entry()
		context.laneAvailable = false
		Test.assertEqual(Rules.entry(context), "LaneOccupied")
		context.side = "Left"
		Test.assertEqual(Rules.entry(context), "LaneOccupied")
		context.assigned = true
		Test.assertEqual(Rules.entry(context), "AlreadyBatting")
		context = entry()
		context.side = "Forged"
		Test.assertEqual(Rules.entry(context), "UnknownBox")
	end)
	t.test("exit rejects replay, stale assignment, non-owner and spam across entries", function()
		local guard = Rules.new()
		Test.assertEqual(Rules.request(guard, 1, 1), nil)
		Test.assertEqual(Rules.request(guard, 2, 1), "DuplicateRequest")
		Test.assertEqual(Rules.request(guard, 1.1, 2), "RateLimited")
		Test.assertEqual(Rules.request(guard, 3, 3), nil)
		Test.assertEqual(Rules.exit(false, 1, 1, false), "NotBatting")
		Test.assertEqual(Rules.exit(true, 1, 2, false), "StaleAssignment")
		Test.assertEqual(Rules.exit(true, 2, 2, true), "AlreadyLeaving")
		Test.assertEqual(Rules.exit(true, 2, 2, false), nil)
		for _, seq in { 0, -1, 1.5, math.huge, 0 / 0 } do
			Test.assertEqual(Rules.request(guard, 10, seq), "InvalidRequest")
		end
	end)
	t.test("simultaneous explicit handedness mirrors poses without mutating global settings", function()
		for _, base in Test.geometries() do
			local right, left = Geometry.forBatter(base, "Right"), Geometry.forBatter(base, "Left")
			Test.assertTrue((right.batterCFrame.Position - base.plateGround):Dot(base.right) < 0, "third base")
			Test.assertTrue((left.batterCFrame.Position - base.plateGround):Dot(base.right) > 0, "first base")
			local r = Swing.new(right, 0.2, 2.5, 10)
			local l = Swing.new(left, -0.2, 2.5, 10)
			Test.assertEqual(Field.new(right).batterSide, "Right")
			Test.assertEqual(Field.new(left).batterSide, "Left")
			Test.assertEqual(Swing.batterSideSign(right), -1)
			Test.assertEqual(Swing.batterSideSign(left), 1)
			Test.assertTrue(Swing.restPose(left, 0, 2.5).direction.Y > 0, "left bat raised")
			Test.assertTrue(Swing.restPose(right, 0, 2.5).direction.Y > 0, "right bat raised")
			for _, f in { 0, 0.25, 0.5, 0.75, 1 } do
				local rp = Swing.activePoseAt(r, r.activeStart + r.timeline.active * f)
				local lp = Swing.activePoseAt(l, l.activeStart + l.timeline.active * f)
				local off = rp.tip - base.plateGround
				local mirrored = rp.tip - base.right * (2 * off:Dot(base.right))
				Test.assertNear((lp.tip - mirrored).Magnitude, 0, 0.001)
			end
			Test.assertNear((left.releasePoint - right.releasePoint).Magnitude, 0, 0.0001, "pitch release unchanged")
		end
	end)
	t.test("explicit hands retain correct early pull and late opposite-field spray", function()
		for _, base in Test.geometries() do
			for _, side in { "Right", "Left" } do
				local geo = Geometry.forBatter(base, side :: "Right" | "Left")
				local pitch = Helpers.pitch(geo, 8)
				local early = Helpers.hit(geo, pitch, 0, -0.02, -0.012)
				local late = Helpers.hit(geo, pitch, 0, -0.02, 0.012)
				Test.assertTrue(early.pullAngleDegrees > 0 and late.pullAngleDegrees < 0, side)
			end
		end
	end)
	t.test("menu cursor and input suppression cover all panels and closing clicks", function()
		local input = Input.new()
		input.batting = true
		Test.assertTrue(Input.canSwing(input, 1, false) and not Input.cursor(input))
		for _, name in { "Progression", "Worlds", "Stats", "Roblox", "TextBox" } do
			Input.menu(input, name, true, 2)
			Test.assertTrue(Input.cursor(input) and not Input.canSwing(input, 3, false), name)
			Input.menu(input, name, false, 4)
			Test.assertTrue(not Input.canSwing(input, 4, false), "menu-closing click")
			Test.assertTrue(Input.canSwing(input, 4.2, false) and not Input.cursor(input))
		end
		Input.menu(input, "Stats", true, 5)
		Input.menu(input, "Worlds", true, 5)
		Input.menu(input, "Stats", false, 6)
		Test.assertTrue(Input.cursor(input) and not Input.canSwing(input, 7, false), "second panel still open")
	end)
	t.test("leaving and text focus suppress swings and free roam restores the cursor", function()
		local input = Input.new()
		input.batting = true
		Test.assertTrue(not Input.canSwing(input, 1, true))
		input.leaving = true
		Test.assertTrue(Input.cursor(input) and not Input.canSwing(input, 1, false))
		input.batting, input.leaving = false, false
		Test.assertTrue(Input.cursor(input) and not Input.canSwing(input, 2, false))
	end)
	t.test("pitcher hand meets jittered release exactly for every difficulty windup", function()
		for _, geo in Test.geometries() do
			for _, tier in { "Beginner", "Intermediate", "Advanced" } do
				local windup = 10
				local data = Pitch.generate(
					geo,
					Test.rng(74),
					{ id = 1, laneId = "Test", windupTime = windup, releaseTime = 12, tier = tier }
				)
				for _, duration in { 0.4, 1, 1.6, 2.5 } do
					local release = windup + duration
					local pose = Motion.sample(geo, windup, release, data.releasePosition, release)
					Test.assertNear((pose.hand - data.releasePosition).Magnitude, 0, 0.0001)
					Test.assertTrue(pose.released)
					local before = Motion.sample(geo, windup, release, data.releasePosition, release - 0.00001)
					Test.assertTrue(not before.released and (before.hand - pose.hand).Magnitude < 0.003)
				end
			end
		end
	end)
	t.test("exiting any incoming pitch phase stops the lane without restarting it", function()
		local geo = Test.geometries().straight
		for _, time in { 0, 0.5, 1.01, 1.3, 2, 4 } do
			local lane = PitchLane.new("Test", {
				createPitch = function(_, id, windup, release)
					local data = Pitch.generate(
						geo,
						Test.rng(5),
						{ id = id, laneId = "Test", windupTime = windup, releaseTime = release }
					)
					return { data = data, flight = Pitch.buildFlight(geo, data) }
				end,
			}, { WindupSeconds = 1, ReadySeconds = 1, ResetSeconds = 1, FirstPitchDelaySeconds = 0 })
			lane:start(0, 0)
			lane:update(0)
			lane:update(time)
			lane:stop(time, "ExitRequested")
			lane:resumeAfterHit(time + 1)
			lane:update(time + 100)
			Test.assertEqual(lane.state, "Idle")
			Test.assertEqual(lane.pitch, nil)
			Test.assertTrue(Rules.canRelease(false))
		end
	end)
	t.test("flight and landing exits credit once and retain the lane until validated return", function()
		local frame = Field.new(Test.geometries().straight)
		local launch = Helpers.launchData(frame, { speedMph = 85, launchDegrees = 25, backspinRpm = 2000 })
		launch.hitId, launch.launchTime = 987, 10
		local flight = Ball.buildFlight(frame, launch)
		local outcome = Landing.evaluate(flight, Helpers.scene(frame, { Helpers.ground() }).caster)
		local landAt = launch.launchTime + outcome.endTime
		for _, requestAt in { 10, landAt - 0.01, landAt, landAt + 0.1 } do
			local profile = Progression.new()
			local gate = Gate.new(1, 1, 0)
			Gate.character(gate, true, 2)
			Gate.request(gate, 1, 2, 0, "Ready", 1)
			Gate.begin(gate, 987, 1)
			Progression.launch(profile, 987)
			local credited = 0
			local life = Lifecycle.new("Test", {
				onResolved = function()
					if Gate.resolve(gate, 987, landAt) then
						Progression.resolve(profile, 987, Landing.toPayload(outcome))
						credited += 1
					end
				end,
				canFinish = function()
					return Gate.canPitch(gate)
				end,
			}, 0)
			life:launch(10, { launch = launch, flight = flight, outcome = outcome })
			life:update(requestAt)
			Test.assertTrue(not Rules.canRelease(life:isBusy()), "keep reservation")
			life:update(landAt)
			local ok = Gate.request(gate, 1, 2, 987, "Ready", landAt + 0.01)
			Test.assertTrue(not ok, "minimum return interval")
			Gate.request(gate, 1, 2, 987, "Ready", landAt + 5)
			life:update(landAt + 5)
			life:update(landAt + 6)
			Test.assertTrue(Rules.canRelease(life:isBusy()))
			Test.assertEqual(credited, 1)
			local coins = Progression.snapshot(profile).coins
			Progression.resolve(profile, 987, Landing.toPayload(outcome))
			Test.assertEqual(Progression.snapshot(profile).coins, coins)
		end
	end)
	t.test("free roam travels with all destination batting lanes occupied", function()
		local state = WorldRules.new()
		state.unlockedWorlds.power = true
		local result = WorldRules.travel(
			state,
			"power",
			1,
			"rookie",
			1,
			{ characterReady = true, hitBusy = false, returnReady = true, laneAvailable = true }
		)
		Test.assertTrue(result.ok)
		Test.assertEqual(state.currentWorld, "power")
	end)
	t.robloxTest("movement restore preserves custom speed and both jump modes", function()
		for _, usePower in { true, false } do
			local model = Instance.new("Model")
			local humanoid, root = Instance.new("Humanoid"), Instance.new("Part")
			humanoid.Parent, root.Parent = model, model
			humanoid.WalkSpeed, humanoid.JumpPower, humanoid.JumpHeight, humanoid.UseJumpPower = 22, 65, 9, usePower
			local saved = Movement.capture(humanoid, root)
			Movement.lock(saved)
			Test.assertTrue(root.Anchored and humanoid.WalkSpeed == 0)
			Movement.restore(saved)
			Test.assertTrue(not root.Anchored and humanoid.AutoRotate)
			Test.assertEqual(humanoid.WalkSpeed, 22)
			Test.assertEqual(humanoid.JumpPower, 65)
			Test.assertEqual(humanoid.JumpHeight, 9)
			Test.assertEqual(humanoid.UseJumpPower, usePower)
			model:Destroy()
		end
	end)
end
