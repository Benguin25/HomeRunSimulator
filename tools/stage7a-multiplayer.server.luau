--!nocheck
-- Opt-in temporary Studio integration fixture; NEVER Rojo mapped or shipped.
-- Uses three real clients and mock profiles. Synthetic engine contacts seed
-- world access / exercise lifecycle adapters, not earned gameplay or balance.
local Studio = game:GetService("StudioTestService")
if not game:GetService("RunService"):IsStudio() or Studio:GetTestArgs() ~= "Stage7ABatting" then
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
			"Stage7A fixture requires Mock/New; never seed DataStore profiles"
		)
		local loading = require(Shared.Presentation.LoadingConfig).Enabled
		if loading then
			local probe = Instance.new("RemoteEvent")
			probe.Name, probe.Parent = "Stage7ALoadingProbe", game.ReplicatedStorage
			probe.OnServerEvent:Connect(function(player, report)
				if type(report) == "table" and type(report.diagnostic) == "string" then
					player:SetAttribute("Stage7ALoadingDiagnostic", report.diagnostic)
				end
				if
					type(report) == "table"
					and report.entered
					and report.hidden
					and (not report.playVisible or report.world == "rookie")
				then
					player:SetAttribute("Stage7ALoadingWorld", report.world)
				end
			end)
		end
		local Batter = require(server.BatterService)
		local Pitch = require(server.PitchServer)
		local Gameplay = require(server.GameplayServer)
		local Progression = require(server.ProgressionServer)
		local Hits = require(server.BattedBallServer)
		local Geometry = require(Shared.Pitching.LaneGeometry)
		local Ball = require(Shared.BattedBall.BattedBall)
		local Field = require(Shared.BattedBall.FieldFrame)
		local Landing = require(Shared.BattedBall.LandingDetector)
		local Rules = require(Shared.Progression.ProgressionRules)
		local Helpers = require(server.Tests.BattedBallTestUtil)
		local Collision = require(server.Worlds.WorldCollision)
		local deadline = os.clock() + 220
		local function waitFor(predicate, label)
			repeat
				if predicate() then
					return
				end
				task.wait(0.05)
			until os.clock() > deadline
			local diagnostics = {}
			for _, p in Players:GetPlayers() do
				table.insert(diagnostics, { name = p.Name, attributes = p:GetAttributes() })
			end
			error("timeout: " .. label .. " " .. game:GetService("HttpService"):JSONEncode(diagnostics))
		end
		waitFor(function()
			if
				#Players:GetPlayers() ~= 3
				or not Shared.Gameplay:FindFirstChild("BattingModeRules")
				or not game.ReplicatedStorage:FindFirstChild("WorldRuntime")
			then
				return false
			end
			for _, p in Players:GetPlayers() do
				if
					not Progression.ready(p)
					or (loading and p:GetAttribute("Stage7ALoadingWorld") ~= "rookie")
					or not p.Character
					or not p.Character:FindFirstChild("HumanoidRootPart")
				then
					return false
				end
			end
			return true
		end, "three ready clients")
		local clients = Players:GetPlayers()
		table.sort(clients, function(a, b)
			return a.UserId < b.UserId
		end)
		local power, sky, home = clients[1], clients[2], clients[3]
		for _, p in clients do
			assert(p:GetAttribute("ProfileMock") == true, "fixture must use mock profiles")
			assert(
				p:GetAttribute("BattingMode") == "FreeRoam" and not p:GetAttribute("PitchLaneId"),
				"free roam initialization"
			)
			assert(not p.Character.HumanoidRootPart.Anchored and p.Character.Humanoid.WalkSpeed > 0, "free movement")
		end
		for _, id in Pitch.getLaneIds() do
			assert(Pitch.getLaneFolder(id):GetAttribute("State") == "Idle", "no automatic pitches")
		end
		local function seed(player, id, level, hitId)
			local geo = Pitch.getGeometry(id)
			local contact = assert(
				Helpers.swing(geo, Helpers.pitch(geo, 537), 0, Helpers.skillAim(-0.035), 0).contact,
				"seed contact"
			)
			local frame = Field.new(geo)
			local launch = Ball.computeLaunch(
				frame,
				contact,
				{ hitId = hitId, laneId = id, pitchId = 1, userId = player.UserId },
				Rules.impactConfig(level)
			)
			launch.powerLevel = level
			local params = Collision.params(id)
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
			assert(outcome.kind == "Landed" and outcome.territory == "Fair", "engine qualification")
			Progression.launch(player, hitId)
			Progression.resolve(player, hitId, outcome)
		end
		seed(power, "power/Lane1", 2, 1)
		seed(sky, "sky/Lane1", 24, 1)
		local powerBefore, skyBefore = Progression.snapshot(power), Progression.snapshot(sky)
		local _, a = Batter.travel(power, "power", 1, "rookie")
		assert(a.ok, a.reason)
		local _, b = Batter.travel(sky, "sky", 1, "rookie")
		assert(b.ok, b.reason)
		for _, p in clients do
			assert(not p:GetAttribute("PitchLaneId"), "travel keeps free roam")
		end
		local function approach(p, id, side)
			local geo = Pitch.getGeometry(id)
			p.Character:PivotTo(CFrame.new(Geometry.boxGround(geo, side) + Vector3.new(0, 3, 0)))
		end
		local function enter(p, id, side)
			if loading then
				waitFor(function()
					return p:GetAttribute("Stage7ALoadingWorld") == p:GetAttribute("CurrentWorld")
				end, "loading finished " .. id)
			end
			approach(p, id, side)
			local accepted, reason = Batter.enter(p, id, side)
			assert(accepted, reason)
			waitFor(function()
				return Gameplay.canPitch(id)
			end, "camera ready " .. id)
			assert(Pitch.getGeometry(id).inputs.batterSide == side, "authoritative hand")
		end
		enter(power, "power/Lane1", "Left")
		enter(sky, "sky/Lane1", "Right")
		enter(home, "Lane1", "Right")
		assert(
			Progression.snapshot(power).coins == powerBefore.coins
				and Progression.snapshot(sky).coins == skyBefore.coins,
			"entry/travel preserve profiles"
		)
		assert(Progression.snapshot(home).coins == 0, "profile isolation")
		-- Seeded progression used hit #1. Reserve the first real server hit on
		-- the unseeded Rookie client so later real hit IDs remain monotonic.
		waitFor(function()
			return Pitch.getActivePitch("Lane1") ~= nil
		end, "Rookie contact")
		local rookieActive = Pitch.getActivePitch("Lane1")
		local rookieContact = assert(
			Helpers.swing(Pitch.getGeometry("Lane1"), rookieActive.flight, 0, Helpers.skillAim(-0.035), 0).contact,
			"Rookie contact"
		)
		assert(Pitch.resolveContact("Lane1", rookieActive.data.id, rookieContact.contactTime, "BatContact"))
		assert(Hits.launch("Lane1", rookieActive.data.id, home, rookieContact), "prime authoritative hit ID")

		local exitSequence = {}
		local function leave(p)
			exitSequence[p] = (exitSequence[p] or 0) + 1
			local id = p:GetAttribute("PitchLaneId")
			local epoch = p:GetAttribute("BattingEpoch")
			local accepted, reason = Batter.exit(p, exitSequence[p], id, epoch)
			assert(accepted, reason)
			return id, epoch, reason
		end
		local oldLane, oldEpoch = leave(sky)
		assert(
			not sky:GetAttribute("PitchLaneId") and not sky.Character.HumanoidRootPart.Anchored,
			"incoming pitch exit"
		)
		local _, replay = Batter.exit(sky, 1, oldLane, oldEpoch)
		assert(replay == "DuplicateRequest", "exit replay")
		task.wait(0.4)
		local _, trip = Batter.travel(sky, "power", 2, "sky")
		assert(trip.ok, trip.reason)
		if loading then
			waitFor(function()
				return sky:GetAttribute("Stage7ALoadingWorld") == "power"
			end, "Power travel opening view")
		end
		approach(sky, "power/Lane1", "Right")
		local accepted, occupied = Batter.enter(sky, "power/Lane1", "Right")
		assert(not accepted and occupied == "LaneOccupied", "opposite box same lane")
		task.wait(0.4)
		approach(sky, "power/Lane2", "Right")
		sky.Character:PivotTo(sky.Character:GetPivot() + Vector3.new(0, 0, 200))
		local _, far = Batter.enter(sky, "power/Lane2", "Right")
		assert(far == "TooFarAway", "distance validation")
		task.wait(0.4)
		enter(sky, "power/Lane2", "Right")
		assert(power:GetAttribute("PitchLaneId") ~= sky:GetAttribute("PitchLaneId"), "same world lane isolation")
		-- Actual authoritative launch/contact adapter, followed by queued E exit.
		waitFor(function()
			return Pitch.getActivePitch("power/Lane1") ~= nil
		end, "pitch to contact")
		local active = Pitch.getActivePitch("power/Lane1")
		local geo = Pitch.getGeometry("power/Lane1")
		local contact =
			assert(Helpers.swing(geo, active.flight, 0, Helpers.skillAim(-0.035), 0).contact, "synthetic contact")
		assert(Pitch.resolveContact("power/Lane1", active.data.id, contact.contactTime, "BatContact"))
		assert(Hits.launch("power/Lane1", active.data.id, power, contact), "authoritative launch")
		local coinsBefore = Progression.snapshot(power).coins
		local _, _, pending = leave(power)
		assert(pending == "FinishingHit", "flight exit queued")
		assert(
			power:GetAttribute("PitchLaneId") == "power/Lane1" and not Gameplay.canSwing("power/Lane1", power),
			"pending lane held"
		)
		local _, busy = Batter.travel(power, "rookie", 2, "power")
		assert(busy.reason == "FinishHitFirst", "travel cannot cancel flight")
		waitFor(function()
			return not power:GetAttribute("PitchLaneId")
		end, "confirmed hit + camera return exit")
		assert(
			not Hits.getActiveHit("power/Lane1") and not power.Character.HumanoidRootPart.Anchored,
			"completed exit movement"
		)
		local after = Progression.snapshot(power)
		assert(after.coins > coinsBefore, "hit credited before exit")
		task.wait(0.5)
		assert(Progression.snapshot(power).coins == after.coins, "no duplicate reward")
		-- Reset clears batting immediately, retains selected world/profile.
		local beforeReset = Progression.snapshot(sky)
		sky:LoadCharacterAsync()
		waitFor(function()
			return sky.Character
				and sky.Character:FindFirstChild("HumanoidRootPart")
				and sky:GetAttribute("BattingMode") == "FreeRoam"
				and not sky:GetAttribute("PitchLaneId")
		end, "respawn free roam")
		assert(
			Progression.world(sky) == "power" and Progression.snapshot(sky).coins == beforeReset.coins,
			"reset profile integrity"
		)
		leave(home)
		-- Character reset during an active hit retains its authoritative result.
		task.wait(0.4)
		enter(power, "power/Lane1", "Right")
		waitFor(function()
			return Pitch.getActivePitch("power/Lane1") ~= nil
		end, "second contact")
		active = Pitch.getActivePitch("power/Lane1")
		geo = Pitch.getGeometry("power/Lane1")
		contact = assert(Helpers.swing(geo, active.flight, 0, Helpers.skillAim(-0.035), 0).contact, "second contact")
		assert(Pitch.resolveContact("power/Lane1", active.data.id, contact.contactTime, "BatContact"))
		assert(Hits.launch("power/Lane1", active.data.id, power, contact))
		power:LoadCharacterAsync()
		waitFor(function()
			return power.Character
				and power:GetAttribute("BattingMode") == "FreeRoam"
				and not power:GetAttribute("PitchLaneId")
		end, "reset flight result release")
		assert(Progression.snapshot(power).coins > after.coins, "reset flight awarded once")
		return {
			ok = true,
			clients = 3,
			checks = "free roam, both hands, three worlds, same-world isolation, proximity/occupancy, replay, flight exit, return gates, respawn during flight, profiles/rewards",
		}
	end)
	Studio:EndTest(if ok then result else { ok = false, error = tostring(result) })
end)
