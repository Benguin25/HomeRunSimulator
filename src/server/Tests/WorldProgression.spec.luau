--!strict
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Worlds.WorldConfig)
local Worlds = require(Shared.Worlds.WorldRules)
local Data = require(Shared.Progression.PlayerProgression)
local Replica = require(Shared.Progression.ProgressionReplica)
local Geometry = require(Shared.Pitching.LaneGeometry)
local PitchConfig = require(Shared.Pitching.PitchConfig)
local Ball = require(Shared.BattedBall.BattedBall)
local Field = require(Shared.BattedBall.FieldFrame)
local Landing = require(Shared.BattedBall.LandingDetector)
local Gate = require(Shared.Gameplay.ReturnGate)
local Camera = require(Shared.Presentation.CameraDirector)
local Preview = require(Shared.Presentation.PitchPreview)
local Test = require(script.Parent.TestUtil)
local BBTU = require(script.Parent.BattedBallTestUtil)
local function outcome(feet: number): Landing.OutcomePayload
	return {
		kind = "Landed",
		surface = "Ground",
		territory = "Fair",
		territoryProvisional = false,
		carryMeters = feet * 0.3048,
		endTime = 5,
		sprayAngleDegrees = 0,
	}
end
local function context(): Worlds.Context
	return { characterReady = true, hitBusy = false, returnReady = true, laneAvailable = true }
end
local function unlocked(): Data.State
	local state = Data.new()
	Data.launch(state, 1)
	Data.resolve(state, 1, outcome(2000))
	return state
end
return function(t)
	t.test("Rookie is the permanent default with no paid or fabricated unlocks", function()
		local state = Data.new()
		Test.assertEqual(state.worlds.currentWorld, "rookie")
		Test.assertTrue(state.worlds.unlockedWorlds.rookie)
		Test.assertEqual(state.worlds.unlockedWorlds.power, nil)
		Test.assertEqual(state.worlds.qualifyingBestMeters, 0)
	end)
	t.test("confirmed distances unlock exactly at thresholds and only once", function()
		local state = Worlds.new()
		Test.assertEqual(#Worlds.resolve(state, outcome(474.99)), 0)
		Test.assertEqual(#Worlds.resolve(state, outcome(475)), 1)
		Test.assertTrue(state.unlockedWorlds.power)
		Test.assertEqual(#Worlds.resolve(state, outcome(475)), 0)
		Test.assertEqual(#Worlds.resolve(state, outcome(1749.99)), 0)
		Test.assertEqual(#Worlds.resolve(state, outcome(1750)), 1)
		Test.assertEqual(#Worlds.resolve(state, outcome(1900)), 0)
	end)
	t.test("one exceptional confirmed hit unlocks preceding worlds in order", function()
		local state = Worlds.new()
		local ids = Worlds.resolve(state, outcome(2000))
		Test.assertEqual(ids[1], "power")
		Test.assertEqual(ids[2], "sky")
		Test.assertTrue(state.unlockedWorlds.rookie)
	end)
	t.test("foul, provisional, obstacle, projections and invalid outcomes cannot unlock", function()
		for _, change in { "Foul", "Provisional", "Wall", "NoImpact", "Invalid", "Excessive", "FakeSurface" } do
			local state, p = Worlds.new(), outcome(3000)
			if change == "Foul" then
				p.territory = "Foul"
			elseif change == "Provisional" then
				p.territoryProvisional = true
			elseif change == "Wall" then
				p.kind, p.surface = "Obstacle", "Wall"
			elseif change == "NoImpact" then
				p.kind, p.carryMeters, p.projectedCarryMeters = "NoImpact", nil, 9999
			elseif change == "Invalid" then
				p.carryMeters = 0 / 0
			elseif change == "Excessive" then
				p.carryMeters = 10001
			else
				p.surface = "Wall"
			end
			Test.assertEqual(#Worlds.resolve(state, p), 0)
			Test.assertEqual(state.qualifyingBestMeters, 0)
		end
	end)
	t.test("resolution deduplication protects rewards, records and unlock notices", function()
		local state = Data.new()
		Test.assertTrue(not Data.resolve(state, 1, outcome(2000)))
		Data.launch(state, 1)
		Data.resolve(state, 1, outcome(475))
		local coins, version = state.coins, state.version
		Test.assertTrue(not Data.resolve(state, 1, outcome(2000)))
		Test.assertEqual(state.coins, coins)
		Test.assertEqual(state.version, version)
		Test.assertEqual(state.worlds.unlockedWorlds.sky, nil)
		Test.assertEqual((state.worldUnlock :: any).ids[1], "power")
	end)
	t.test("locked and nonexistent travel is rejected without changing progression", function()
		local state = Data.new()
		Test.assertEqual(Data.travel(state, "sky", 1, "rookie", 10, context()).reason, "LockedWorld")
		Test.assertEqual(Data.travel(state, "missing", 2, "rookie", 12, context()).reason, "UnknownWorld")
		Test.assertEqual(state.worlds.currentWorld, "rookie")
		Test.assertEqual(state.version, 0)
	end)
	t.test("successful round trips keep coins, upgrades, best and unlocked worlds", function()
		local state = unlocked()
		Data.purchase(state, "Power", 1, 0, 8)
		local coins, best, level = state.coins, state.worlds.qualifyingBestMeters, state.powerLevel
		Test.assertTrue(Data.travel(state, "power", 1, "rookie", 10, context()).ok)
		Test.assertTrue(Data.travel(state, "sky", 2, "power", 12, context()).ok)
		Test.assertTrue(Data.travel(state, "rookie", 3, "sky", 14, context()).ok)
		Test.assertEqual(state.coins, coins)
		Test.assertEqual(state.powerLevel, level)
		Test.assertEqual(state.worlds.qualifyingBestMeters, best)
		Test.assertTrue(state.worlds.unlockedWorlds.sky)
	end)
	t.test("duplicate, spam and stale travel cannot perform a second transaction", function()
		local state = unlocked()
		Test.assertTrue(Data.travel(state, "power", 1, "rookie", 10, context()).ok)
		Test.assertEqual(Data.travel(state, "sky", 1, "power", 12, context()).reason, "DuplicateRequest")
		Test.assertEqual(Data.travel(state, "sky", 2, "power", 10.1, context()).reason, "RateLimited")
		Test.assertEqual(Data.travel(state, "sky", 3, "rookie", 14, context()).reason, "StaleWorld")
		Test.assertEqual(state.worlds.currentWorld, "power")
	end)
	t.test("full destinations and character reset preserve the current assignment", function()
		local state, ctx = unlocked(), context()
		ctx.laneAvailable = false
		Test.assertEqual(Data.travel(state, "power", 1, "rookie", 10, ctx).reason, "WorldFull")
		ctx.laneAvailable, ctx.characterReady = true, false
		Test.assertEqual(Data.travel(state, "power", 2, "rookie", 12, ctx).reason, "CharacterNotReady")
		Test.assertEqual(state.worlds.currentWorld, "rookie")
	end)
	t.test("travel during unresolved flight or incomplete camera return cannot cancel authority", function()
		local state, ctx = unlocked(), context()
		Data.launch(state, 2)
		ctx.hitBusy = true
		Test.assertEqual(Data.travel(state, "power", 1, "rookie", 10, ctx).reason, "FinishHitFirst")
		Test.assertTrue(state.pending[2])
		Data.resolve(state, 2, outcome(800))
		local coins = state.coins
		ctx.hitBusy, ctx.returnReady = false, false
		Test.assertEqual(Data.travel(state, "power", 2, "rookie", 12, ctx).reason, "FinishHitFirst")
		ctx.returnReady = true
		Test.assertTrue(Data.travel(state, "power", 3, "rookie", 14, ctx).ok)
		Test.assertTrue(not Data.resolve(state, 2, outcome(800)))
		Test.assertEqual(state.coins, coins)
	end)
	t.test("fresh destination gate requires new camera readiness and rejects old epochs", function()
		local gate = Gate.new(1, 100, 12)
		Gate.character(gate, true, 101)
		Test.assertTrue(not Gate.canPitch(gate))
		Test.assertTrue(not Gate.request(gate, 1, 50, 0, "Ready", 13))
		Test.assertTrue(Gate.request(gate, 1, 101, 0, "Ready", 14))
		Test.assertTrue(Gate.canPitch(gate))
	end)
	t.test("players and detached snapshots cannot change another player's worlds", function()
		local a, b = unlocked(), Data.new()
		Data.travel(a, "sky", 1, "rookie", 10, context())
		Test.assertEqual(b.worlds.currentWorld, "rookie")
		Test.assertEqual(b.worlds.unlockedWorlds.sky, nil)
		local snapshot = Data.snapshot(a)
		snapshot.worlds.unlockedWorlds.sky = false
		snapshot.worlds.currentWorld = "rookie"
		Test.assertTrue(a.worlds.unlockedWorlds.sky)
		Test.assertEqual(a.worlds.currentWorld, "sky")
	end)
	t.test("late progression snapshots cannot roll back current world", function()
		local state, replica = unlocked(), Replica.new()
		local old = Data.snapshot(state)
		Data.travel(state, "power", 1, "rookie", 10, context())
		Test.assertTrue(Replica.apply(replica, Data.snapshot(state)))
		Test.assertTrue(not Replica.apply(replica, old))
		Test.assertEqual((replica.value :: Data.Snapshot).worlds.currentWorld, "power")
	end)
	t.test("translated and rotated pitches retain targeting and marker-relative fair distances", function()
		for _, world in Config.Worlds do
			local cf = Config.frame(world)
			local distance = PitchConfig.Geometry.MoundToPlateMeters / PitchConfig.Units.MetersPerStud
			local geo = Geometry.new({
				plateGround = cf.Position,
				pitcherGround = cf:PointToWorldSpace(Vector3.new(0, 0, -distance)),
				leftFoulPole = cf:PointToWorldSpace(Vector3.new(-380, 0, -380)),
				rightFoulPole = cf:PointToWorldSpace(Vector3.new(380, 0, -380)),
			})
			local pitch = BBTU.pitch(geo, 537)
			Test.assertTrue((pitch.targetError or 0) < 0.02)
			local frame = Field.new(geo)
			local launch = BBTU.launchData(frame, { speedMph = 250, launchDegrees = 28, sprayDegrees = 10 })
			local flight = Ball.buildFlight(frame, launch)
			local result = Landing.evaluate(flight, BBTU.scene(frame, { BBTU.ground() }).caster)
			Test.assertEqual(result.territory, "Fair")
			Test.assertNear(result.carryMeters :: number, (flight.fieldLanding :: any).distance, 0.005)
		end
	end)
	t.test("extreme flights land on bounded world ground or explicitly remain unresolved", function()
		local world = Config.get("sky") :: Config.Definition
		local cf = Config.frame(world)
		local geo =
			Geometry.new({ plateGround = cf.Position, pitcherGround = cf:PointToWorldSpace(Vector3.new(0, 0, -65.8)) })
		local frame = Field.new(geo)
		local launch = BBTU.launchData(frame, { speedMph = 9000, launchDegrees = 26 })
		launch.powerLevel = 40
		local flight = Ball.buildFlight(frame, launch)
		local ground = BBTU.plane("BoundedGround", Vector3.zero, Vector3.yAxis, function(point)
			return point.X <= Config.GroundForwardStuds * frame.metersPerStud and math.abs(point.Z) < 1700
		end)
		local result = Landing.evaluate(flight, BBTU.scene(frame, { ground }).caster)
		Test.assertEqual(result.kind, "Landed")
		Test.assertTrue((result.carryMeters :: number) > 800)
		Test.assertTrue(flight.trajectory.count <= 3601)
		local absent = Landing.evaluate(flight, function()
			return nil
		end)
		Test.assertEqual(absent.kind, "NoImpact")
		Test.assertEqual(absent.carryMeters, nil)
	end)
	t.test("lane changes clear the hit director and development preview", function()
		local geo = Test.geometries().straight
		local frame = Field.new(geo)
		local launch = BBTU.launchData(frame, { speedMph = 100, launchDegrees = 28 })
		local director = Camera.new()
		director:setLane(launch.laneId)
		director:begin(
			launch.launchTime,
			{ pitchId = launch.pitchId, flight = Ball.buildFlight(frame, launch), confirmed = true }
		)
		director:reset("world travel")
		director:setLane("power/Lane1")
		Test.assertEqual(director:getHit(), nil)
		Test.assertTrue(director:isBattingView())
		local preview = Preview.new(true)
		local pitch = BBTU.pitch(geo, 537)
		Preview.setLane(preview, pitch.data.laneId)
		Preview.begin(preview, geo, pitch)
		Test.assertTrue(preview.target ~= nil)
		Preview.setLane(preview, "power/Lane1")
		Test.assertEqual(preview.target, nil)
	end)
end
