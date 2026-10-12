--!strict
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Progression.ProgressionConfig)
local Rules = require(Shared.Progression.ProgressionRules)
local Data = require(Shared.Progression.PlayerProgression)
local Replica = require(Shared.Progression.ProgressionReplica)
local Ball = require(Shared.BattedBall.BattedBall)
local Landing = require(Shared.BattedBall.LandingDetector)
local Field = require(Shared.BattedBall.FieldFrame)
local BallConfig = require(Shared.BattedBall.BattedBallConfig)
local Gate = require(Shared.Gameplay.ReturnGate)
local Stats = require(Shared.Gameplay.SessionStats)
local Lifecycle = require(Shared.BattedBall.HitLifecycle)
local Camera = require(Shared.Presentation.CameraDirector)
local CameraMath = require(Shared.Presentation.CameraMath)
local BBTU = require(script.Parent.BattedBallTestUtil)
local Test = require(script.Parent.TestUtil)
local function outcome(feet: number): Landing.OutcomePayload
	return {
		kind = "Landed",
		surface = "Ground",
		territory = "Fair",
		territoryProvisional = false,
		carryMeters = feet * 0.3048,
		endTime = 4,
		sprayAngleDegrees = 0,
	}
end
local function fund(state: Data.State)
	for id = 1, 5 do
		Data.launch(state, id)
		Data.resolve(state, id, outcome(400))
	end
end
local function launchFor(level: number, id: number?): (Ball.LaunchData, Field.Frame)
	local geometry = Test.geometries().straight
	local pitch = BBTU.pitch(geometry, 537)
	local contact = assert(BBTU.swing(geometry, pitch, 0, -0.035, 0).contact, "benchmark connects")
	local frame = Field.new(geometry)
	local launch = Ball.computeLaunch(
		frame,
		contact,
		{ hitId = id or 1, laneId = "Test", pitchId = 537, userId = 1 },
		Rules.impactConfig(level)
	)
	launch.powerLevel, launch.powerVersion = level, level
	return launch, frame
end
return function(t)
	t.test("linear fair-carry rewards are predictable, modest at zero and monotonic", function()
		Test.assertEqual(Rules.reward(outcome(0)), Config.Reward.ContactCoins)
		Test.assertEqual(Rules.reward(outcome(200)), Config.Reward.ContactCoins + 90)
		Test.assertEqual(Rules.reward(outcome(400)), Config.Reward.ContactCoins + 180)
		local previous = 0
		for feet = 0, 2000, 10 do
			local coins = Rules.reward(outcome(feet))
			Test.assertTrue(coins >= previous, "distance monotonicity")
			previous = coins
		end
	end)
	t.test("fouls, walls, ceilings and provisional landings receive flat rewards only", function()
		local p = outcome(400)
		p.territory = "Foul"
		Test.assertEqual(Rules.reward(p), Config.Reward.ContactCoins)
		p.territory, p.territoryProvisional = "Fair", true
		Test.assertEqual(Rules.reward(p), Config.Reward.ContactCoins)
		p.territoryProvisional, p.kind, p.surface, p.impactDistanceMeters = false, "Obstacle", "Wall", 100
		p.projectedCarryMeters = 999999
		Test.assertEqual(Rules.reward(p), Config.Reward.ContactCoins)
		p.surface = "Ceiling"
		Test.assertEqual(Rules.reward(p), Config.Reward.ContactCoins)
		p.kind = "NoImpact"
		Test.assertEqual(Rules.reward(p), 0)
	end)
	t.test("invalid outcomes cannot mint currency", function()
		for _, distance in { -1, math.huge, 0 / 0, Config.Reward.MaxDistanceMeters + 1 } do
			local p = outcome(400)
			p.carryMeters = distance
			Test.assertEqual(Rules.reward(p), 0)
		end
		local p = outcome(400)
		p.surface = "Wall"
		Test.assertEqual(Rules.reward(p), 0)
		p.surface, p.endTime = "Ground", -1
		Test.assertEqual(Rules.reward(p), 0)
		p.endTime, p.carryMeters = 1, nil
		Test.assertEqual(Rules.reward(p), 0)
	end)
	t.test("only registered contacts resolve and canceled, duplicate or late results cannot pay", function()
		local state = Data.new()
		Test.assertTrue(not Data.resolve(state, 1, outcome(400)))
		Test.assertTrue(Data.launch(state, 1))
		Test.assertTrue(not Data.launch(state, 1))
		Test.assertTrue(Data.resolve(state, 1, outcome(400)))
		local coins = state.coins
		Test.assertTrue(not Data.resolve(state, 1, outcome(1000)))
		Test.assertEqual(state.coins, coins)
		Data.launch(state, 2)
		Data.cancel(state, 2)
		Test.assertTrue(not Data.resolve(state, 2, outcome(400)))
		Data.launch(state, 3)
		local invalid = outcome(400)
		invalid.carryMeters = -1
		Data.resolve(state, 3, invalid)
		Test.assertTrue(not Data.resolve(state, 3, outcome(400)), "invalid terminal outcome stays terminal")
		Test.assertEqual(state.coins, coins)
	end)
	t.test("configurable costs and power grow strictly through the tested range", function()
		Test.assertEqual(Rules.multiplier(0), 1)
		Test.assertEqual(Rules.cost(0), Config.Power.BaseCost)
		for level = 0, Config.Power.MaxLevel - 1 do
			Test.assertTrue(Rules.multiplier(level + 1) > Rules.multiplier(level))
			Test.assertNear(Rules.multiplier(level + 1) / Rules.multiplier(level), Config.Power.Growth, 1e-10)
			Test.assertNear(
				Rules.nextBenefit(level) :: number,
				Rules.multiplier(level + 1) - Rules.multiplier(level),
				1e-10
			)
			if level < Config.Power.MaxLevel - 1 then
				Test.assertTrue((Rules.cost(level + 1) :: number) > (Rules.cost(level) :: number))
			end
		end
		Test.assertEqual(Rules.cost(Config.Power.MaxLevel), nil)
		Test.assertEqual(Rules.nextBenefit(Config.Power.MaxLevel), nil)
	end)
	t.test("purchase deducts once and rejects replay, stale level, insufficiency and spam", function()
		local state = Data.new()
		Test.assertEqual(Data.purchase(state, "Power", 1, 0, 1).reason, "InsufficientCoins")
		fund(state)
		local before = state.coins
		local cost = Rules.cost(0) :: number
		Test.assertTrue(Data.purchase(state, "Power", 2, 0, 2).ok)
		Test.assertEqual(state.coins, before - cost)
		Test.assertEqual(state.powerLevel, 1)
		Test.assertEqual(Data.purchase(state, "Power", 2, 1, 3).reason, "DuplicateRequest")
		Test.assertEqual(Data.purchase(state, "Power", 3, 0, 3).reason, "StaleLevel")
		Test.assertEqual(Data.purchase(state, "Power", 4, 1, 3.1).reason, "RateLimited")
		Test.assertEqual(state.powerLevel, 1)
		Test.assertEqual(state.coins, before - cost)
		Test.assertTrue(Data.purchase(state, "Power", 5, 1, 4).ok)
	end)
	t.test("malformed intent and unsafe states reject without changing coins or level", function()
		local state = Data.new()
		fund(state)
		local before = state.coins
		for _, seq in { 0, -1, 1.5, math.huge, 0 / 0, Config.Limits.MaxSequence + 1 } do
			Test.assertEqual(Data.purchase(state, "Power", seq, 0, 1).reason, "InvalidRequest")
		end
		Test.assertEqual(Data.purchase(state, "Coins", 1, 0, 1).reason, "InvalidUpgrade")
		Test.assertEqual(Data.purchase(state, "Power", 2, 0.5, 2).reason, "InvalidUpgrade")
		Test.assertEqual(Data.purchase(state, "Power", 3, 0, math.huge).reason, "InvalidTime")
		Test.assertEqual(state.powerLevel, 0)
		Test.assertEqual(state.coins, before)
		state.coins = 0 / 0
		Test.assertEqual(Data.purchase(state, "Power", 4, 0, 4).reason, "InvalidState")
		state.coins, state.powerLevel = before, Config.Power.MaxLevel
		Test.assertEqual(Data.purchase(state, "Power", 5, Config.Power.MaxLevel, 5).reason, "MaxLevel")
	end)
	t.test("player balances, pending hits, purchases and snapshots are isolated", function()
		local a, b = Data.new(), Data.new()
		fund(a)
		Test.assertTrue(Data.purchase(a, "Power", 1, 0, 1).ok)
		Test.assertEqual(b.coins, 0)
		Test.assertEqual(b.powerLevel, 0)
		Test.assertTrue(not Data.resolve(b, 5, outcome(400)))
		local snapshot = Data.snapshot(a)
		snapshot.coins = 0
		assert(snapshot.award).coins = 9999
		Test.assertTrue(a.coins > 0)
		Test.assertEqual(assert(a.award).coins, Rules.reward(outcome(400)))
		local fresh = Data.new()
		Test.assertEqual(fresh.coins, 0, "new session resets")
	end)
	t.test("currency saturates safely without overflow or fractional balances", function()
		local state = Data.new()
		state.coins, state.earnedCoins = Config.Limits.MaxCoins - 1, Config.Limits.MaxCoins - 1
		Data.launch(state, 1)
		Data.resolve(state, 1, outcome(400))
		Test.assertEqual(state.coins, Config.Limits.MaxCoins)
		Test.assertEqual(state.earnedCoins, Config.Limits.MaxCoins)
		Test.assertEqual(assert(state.award).coins, 1)
	end)
	t.test("late initialization, duplicate snapshots and repeated awards cannot roll back state", function()
		local state, replica = Data.new(), Replica.new()
		local initial = Data.snapshot(state)
		fund(state)
		local awarded = Data.snapshot(state)
		Test.assertTrue(Replica.apply(replica, awarded))
		Test.assertTrue(Replica.award(replica) ~= nil)
		Test.assertTrue(Replica.award(replica) == nil)
		Test.assertTrue(not Replica.apply(replica, initial))
		Data.purchase(state, "Power", 1, 0, 1)
		Test.assertTrue(Replica.apply(replica, Data.snapshot(state)))
		Test.assertTrue(not Replica.apply(replica, awarded))
		Test.assertEqual(assert(replica.value).powerLevel, 1)
		Test.assertEqual(Replica.award(replica), nil)
	end)
	t.test("level zero exactly preserves baseline and purchases apply only to subsequent launches", function()
		local before, frame = launchFor(0)
		local state = Data.new()
		fund(state)
		Test.assertTrue(Data.purchase(state, "Power", 1, 0, 1).ok)
		local after = launchFor(state.powerLevel)
		local baseline = Rules.impactConfig(0)
		Test.assertEqual(baseline.Power.ArcadePowerMultiplier, BallConfig.Power.ArcadePowerMultiplier)
		Test.assertEqual(baseline.Power.MaxLaunchEnergyJoules, BallConfig.Power.MaxLaunchEnergyJoules)
		Test.assertNear(after.velocity.Magnitude / before.velocity.Magnitude, Config.Power.Growth, 2e-6)
		Test.assertTrue(after.velocity.Unit:Dot(before.velocity.Unit) > 0.999999)
		Test.assertEqual(after.spin, before.spin)
		Test.assertEqual(before.powerLevel, 0, "active launch remains immutable")
		local lower = Ball.buildFlight(frame, before)
		local higher = Ball.buildFlight(frame, after)
		Test.assertTrue(
			assert(higher.fieldLanding).distance > assert(lower.fieldLanding).distance * 1.1,
			"noticeable first purchase"
		)
	end)
	t.test("wire launch reconstructs power-specific flight exactly and stale predictions reconcile", function()
		local stale, frame = launchFor(0)
		local authority = launchFor(10)
		local received, finish = Ball.decode(Ball.encode(authority, 9))
		assert(received, "wire launch decodes")
		Test.assertEqual(received.powerLevel, 10)
		Test.assertEqual(finish, 9)
		Test.assertTrue(not Ball.sameLaunch(stale, received))
		Test.assertTrue(Ball.sameLaunch(authority, received))
		local server, client = Ball.buildFlight(frame, authority), Ball.buildFlight(frame, received)
		Test.assertEqual(server.trajectory.count, client.trajectory.count)
		for i = 1, server.trajectory.count do
			Test.assertEqual(server.trajectory.px[i], client.trajectory.px[i])
		end
	end)
	t.test("maximum-power flights stay finite, deterministic, bounded and convergent", function()
		for _, level in { 1, 10, 20, 30, 40 } do
			local launch, frame = launchFor(level)
			local flight = Ball.buildFlight(frame, launch)
			Test.assertTrue(launch.velocity.Magnitude <= Config.Limits.MaxExitSpeedMps + 0.001)
			Test.assertTrue(flight.trajectory.count <= 3601)
			for i = 1, flight.trajectory.count do
				for _, column in
					{
						flight.trajectory.px,
						flight.trajectory.py,
						flight.trajectory.pz,
						flight.trajectory.vx,
						flight.trajectory.vy,
						flight.trajectory.vz,
					}
				do
					Test.assertTrue(Rules.finite(column[i]), "finite sample")
				end
			end
			local reference = BBTU.flightConfig({
				FixedStepSeconds = 1 / 960,
				MaxFlightSeconds = 30,
				MaxHorizontalDistanceMeters = 10000,
			})
			local fine = Ball.buildFlight(frame, launch, reference)
			if flight.fieldLanding and fine.fieldLanding then
				Test.assertNear(flight.fieldLanding.distance, fine.fieldLanding.distance, 0.02, "960 Hz reference")
			end
		end
	end)
	t.test("long swept chords split at engine-safe lengths and cannot tunnel through thin walls", function()
		local calls = 0
		local caster = Landing.boundedCaster(function(origin, displacement)
			calls += 1
			Test.assertTrue(displacement.Magnitude <= Config.Limits.MaxCastStuds + 0.001)
			local distance = 1700 - origin.X
			if distance >= 0 and distance <= displacement.X then
				return { distance = distance, point = Vector3.new(1700, 0, 0), normal = -Vector3.xAxis }
			end
			return nil
		end)
		local hit = assert(caster(Vector3.zero, Vector3.new(3000, 0, 0), 0.1))
		Test.assertNear(hit.distance, 1700, 0.001)
		Test.assertEqual(calls, 3)
		local launch, frame = launchFor(40)
		local flight = Ball.buildFlight(frame, launch)
		local scene =
			BBTU.scene(frame, { BBTU.box("ThinWall", Vector3.new(100, -100, -100), Vector3.new(100.01, 1000, 100)) })
		local outcomeWall = Landing.evaluate(flight, scene.caster)
		Test.assertEqual(outcomeWall.kind, "Obstacle")
		Test.assertNear(assert(outcomeWall.impact).x, 100, 0.001)
	end)
	t.test("ten-thousand-foot flights use actual fixed-step simulation and accurate swept measurement", function()
		local frame = Field.new(Test.geometries().straight)
		local config =
			BBTU.flightConfig({ AirDensityScale = 0, MaxFlightSeconds = 30, MaxHorizontalDistanceMeters = 10000 })
		local flight = BBTU.flight(frame, { speedMph = 1000, launchDegrees = 5, y = 1 }, config)
		local impact = Landing.evaluate(flight, BBTU.scene(frame, { BBTU.ground() }).caster)
		Test.assertEqual(impact.kind, "Landed")
		Test.assertTrue((impact.carryMeters :: number) / 0.3048 > 10000)
		Test.assertNear(impact.carryMeters :: number, assert(flight.fieldLanding).distance, 0.02)
	end)
	t.test("upgraded camera follows past the legacy watchdog until authoritative resolution", function()
		local frame = Field.new(Test.geometries().straight)
		local config =
			BBTU.flightConfig({ AirDensityScale = 0, MaxFlightSeconds = 30, MaxHorizontalDistanceMeters = 10000 })
		local flight = BBTU.flight(frame, { speedMph = 500, launchDegrees = 75, y = 1 }, config)
		flight.launch.powerLevel, flight.launch.launchTime = 20, 0
		local camera = Camera.new()
		camera:setLane("Test")
		camera:begin(0, { pitchId = 1, flight = flight, confirmed = true, endTime = flight.trajectory.duration })
		local batting = CameraMath.poseFromCFrame(CFrame.new(0, 10, 12), 70)
		for tick = 0, 29 * 30 do
			local pose = camera:update(tick / 30, 1 / 30, batting)
			Test.assertTrue(Rules.finite(pose.position.X) and Rules.finite(pose.position.Y), "finite camera")
		end
		Test.assertEqual(camera:getState(), "BallFollow", "no early watchdog return at 20 seconds")
		local result = Landing.toPayload(Landing.evaluate(flight, function()
			return nil
		end))
		camera:resolve("Test", 1, result)
		for tick = 29 * 30 + 1, 33 * 30 do
			camera:update(tick / 30, 1 / 30, batting)
		end
		Test.assertTrue(camera:isBattingView(), "normal bounded return after terminal resolution")
	end)
	t.test("repeated powered camera/result/return cycles award once and preserve readiness gating", function()
		local data, stats, replica = Data.new(), Stats.new(), Replica.new()
		local gate = Gate.new(1, 1, 0)
		gate.characterReady, gate.cameraReady, gate.phase = true, true, "Ready"
		local director = Camera.new()
		director:setLane("Test")
		local batting = CameraMath.poseFromCFrame(CFrame.new(0, 10, 12), 70)
		local now = 0
		local resolved = 0
		for id = 1, 25 do
			Test.assertTrue(Gate.canPitch(gate))
			local launch, frame = launchFor(data.powerLevel, id)
			launch.launchTime, launch.powerVersion = now, data.version
			local flight = Ball.buildFlight(frame, launch)
			local result = Landing.evaluate(flight, BBTU.scene(frame, { BBTU.ground() }).caster)
			Data.launch(data, id)
			Stats.contact(stats, id, flight.exitSpeedMph)
			Gate.begin(gate, id, 537)
			local lifecycle = Lifecycle.new("Test", {
				onResolved = function(_, hit)
					resolved += 1
					local p = Landing.toPayload(hit.outcome)
					Gate.resolve(gate, id, now)
					Data.resolve(data, id, p)
					Stats.resolve(stats, id, p)
					director:resolve("Test", 537, p)
				end,
				canFinish = function()
					return Gate.canPitch(gate)
				end,
			}, 0)
			lifecycle:launch(now, { launch = launch, flight = flight, outcome = result })
			director:begin(now, { pitchId = 537, flight = flight, confirmed = true, endTime = result.endTime })
			local landing = now + result.endTime
			while now < landing + 0.02 do
				now += 1 / 30
				lifecycle:update(now)
				director:update(now, 1 / 30, batting)
				Test.assertTrue(not Gate.canPitch(gate), "no early pitch")
			end
			local earned = data.earnedCoins
			Test.assertTrue(not Data.resolve(data, id, Landing.toPayload(result)))
			Test.assertEqual(data.earnedCoins, earned)
			Replica.apply(replica, Data.snapshot(data))
			Test.assertTrue(Replica.award(replica) ~= nil)
			Test.assertTrue(Replica.award(replica) == nil)
			local cost = Rules.cost(data.powerLevel)
			if cost and data.coins >= cost then
				local oldLevel = launch.powerLevel
				Test.assertTrue(Data.purchase(data, "Power", id, data.powerLevel, now).ok)
				Test.assertEqual(launch.powerLevel, oldLevel)
			end
			while not director:isBattingView() do
				now += 1 / 30
				director:update(now, 1 / 30, batting)
				lifecycle:update(now)
				Test.assertTrue(not Gate.canPitch(gate), "no pitch during camera return")
			end
			Test.assertTrue(Gate.request(gate, 1, 1, id, "Ready", now))
			lifecycle:update(now)
			Test.assertEqual(lifecycle.finished, 1)
		end
		Test.assertEqual(resolved, 25)
		Test.assertEqual(stats.value.contacts, 25)
		Test.assertTrue(data.powerLevel >= 5)
	end)
end
