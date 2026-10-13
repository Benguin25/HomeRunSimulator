--!nocheck
-- Temporary Studio fixture, NOT Rojo mapped. Install as a Script in ServerScriptService,
-- then call StudioTestService:ExecuteMultiplayerTestAsync(3, "Stage6BWorlds") in Edit.
-- Remove the fixture after the test. Qualification is seeded from real engine sweeps;
-- this checks world adapters, not the player's ability to earn those seeded distances.
local StudioTest = game:GetService("StudioTestService")
if not game:GetService("RunService"):IsStudio() or StudioTest:GetTestArgs() ~= "Stage6BWorlds" then
	return
end
task.spawn(function()
	local ok, result = pcall(function()
		local Players = game:GetService("Players")
		local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
		local server = game:GetService("ServerScriptService"):WaitForChild("Server")
		local persistence = require(server.Persistence.PersistenceConfig)
		assert(
			persistence.StudioMode == "Mock" and persistence.StudioMockScenario == "New",
			"Stage6B fixture requires Mock/New; never seed DataStore profiles"
		)
		local Ball = require(Shared.BattedBall.BattedBall)
		local Field = require(Shared.BattedBall.FieldFrame)
		local Landing = require(Shared.BattedBall.LandingDetector)
		local Rules = require(Shared.Progression.ProgressionRules)
		local Helpers = require(server.Tests.BattedBallTestUtil)
		local Pitch = require(server.PitchServer)
		local Progression = require(server.ProgressionServer)
		local Batter = require(server.BatterService)
		local Gameplay = require(server.GameplayServer)
		local Collision = require(server.Worlds.WorldCollision)
		local deadline = os.clock() + 120
		repeat
			task.wait(0.1)
		until #Players:GetPlayers() == 3 and game.ReplicatedStorage:FindFirstChild("WorldRuntime")
			or os.clock() > deadline
		assert(#Players:GetPlayers() == 3, "three clients connected")
		local rookie, others = nil, {}
		for _, p in Players:GetPlayers() do
			assert(p:GetAttribute("ProfileMock") == true, "fixture must use mock profiles")
			if p:GetAttribute("PitchLaneId") then
				rookie = p
			else
				table.insert(others, p)
			end
		end
		assert(rookie and #others == 2, "starting lane and waiting players")
		local power, sky = rookie, others[1]
		local home = others[2]
		local function seed(player, laneId, level)
			local geo = assert(Pitch.getGeometry(laneId))
			local incoming = Helpers.pitch(geo, 537)
			local contact = assert(Helpers.swing(geo, incoming, 0, -0.035, 0).contact, "fixture connects")
			local frame = Field.new(geo)
			local launch = Ball.computeLaunch(
				frame,
				contact,
				{ hitId = 1, laneId = laneId, pitchId = 1, userId = player.UserId },
				Rules.impactConfig(level)
			)
			launch.powerLevel = level
			local params = Collision.params(laneId)
			local outcome = Landing.toPayload(Landing.evaluate(Ball.buildFlight(frame, launch), function(o, d, r)
				local hit = workspace:Spherecast(o, r, d, params)
				return hit
					and {
						distance = hit.Distance,
						point = hit.Position,
						normal = hit.Normal,
						name = hit.Instance:GetFullName(),
					}
			end))
			assert(outcome.kind == "Landed" and outcome.territory == "Fair", "measured engine fixture")
			Progression.launch(player, 1)
			Progression.resolve(player, 1, outcome)
		end
		seed(power, "power/Lane1", 2)
		seed(sky, "sky/Lane1", 21)
		local beforePower, beforeSky = Progression.snapshot(power), Progression.snapshot(sky)
		repeat
			task.wait(0.1)
		until Gameplay.canPitch(power:GetAttribute("PitchLaneId")) or os.clock() > deadline
		local _, a = Batter.travel(power, "power", 1, "rookie")
		assert(a.ok, a.reason)
		-- FIFO gives this waiting player the freed Rookie lane; wait for its fresh camera gate.
		repeat
			task.wait(0.1)
		until not sky:GetAttribute("PitchLaneId")
			or Gameplay.canPitch(sky:GetAttribute("PitchLaneId"))
			or os.clock() > deadline
		local _, b = Batter.travel(sky, "sky", 1, "rookie")
		assert(b.ok, b.reason)
		repeat
			task.wait(0.1)
		until home:GetAttribute("PitchLaneId")
				and Gameplay.canPitch(power:GetAttribute("PitchLaneId"))
				and Gameplay.canPitch(sky:GetAttribute("PitchLaneId"))
				and Gameplay.canPitch(home:GetAttribute("PitchLaneId"))
			or os.clock() > deadline
		local ids = {}
		for _, p in { power, sky, home } do
			local laneId = assert(p:GetAttribute("PitchLaneId"))
			assert(not ids[laneId], "unique ownership")
			ids[laneId] = true
			assert(Gameplay.canPitch(laneId), "independent camera/character readiness")
			local geo = Pitch.getGeometry(laneId)
			assert(
				(p.Character:GetPivot().Position - geo.batterCFrame.Position).Magnitude < 6,
				"world-relative placement"
			)
		end
		assert(
			Progression.world(power) == "power"
				and Progression.world(sky) == "sky"
				and Progression.world(home) == "rookie",
			"three simultaneous worlds"
		)
		assert(
			Progression.snapshot(power).coins == beforePower.coins
				and Progression.snapshot(sky).coins == beforeSky.coins,
			"no travel debits or duplicate rewards"
		)
		assert(
			Progression.snapshot(home).coins == 0 and not Progression.snapshot(home).worlds.unlockedWorlds.power,
			"player isolation"
		)
		power:LoadCharacterAsync()
		repeat
			task.wait(0.1)
		until Gameplay.canPitch(power:GetAttribute("PitchLaneId")) or os.clock() > deadline
		assert(
			Progression.world(power) == "power" and Gameplay.canPitch(power:GetAttribute("PitchLaneId")),
			"respawn in current world"
		)
		assert(Progression.snapshot(power).coins == beforePower.coins, "respawn preserves progression")
		local _, locked = Batter.travel(home, "sky", 1, "rookie")
		assert(locked.reason == "LockedWorld", "locked travel rejection")
		local _, full = Batter.travel(power, "rookie", 2, "power")
		assert(full.reason == "WorldFull", "occupied destination leaves source assigned")
		return {
			ok = true,
			clients = 3,
			worlds = { "rookie", "power", "sky" },
			checks = "placement, distinct lanes, ready gates, waiting queue, progression isolation, respawn, locked/full rejection",
		}
	end)
	StudioTest:EndTest(if ok then result else { ok = false, error = tostring(result) })
end)
