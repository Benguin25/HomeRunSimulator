--!strict
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Worlds.WorldConfig)
local Selection = require(Shared.Worlds.LaneSelection)
local Test = require(script.Parent.TestUtil)
return function(t)
	t.test("simultaneous players reserve distinct lanes only in their selected worlds", function()
		local ids = { "rookie1", "power1", "power2", "sky1" }
		local worldIds = { rookie1 = "rookie", power1 = "power", power2 = "power", sky1 = "sky" }
		local occupied: { [string]: number } = {}
		local function worldFor(id: string): string?
			return worldIds[id]
		end
		local a = assert(Selection.free(ids, occupied, worldFor, "power"))
		occupied[a] = 1
		local b = assert(Selection.free(ids, occupied, worldFor, "power"))
		occupied[b] = 2
		Test.assertTrue(a ~= b)
		Test.assertEqual(Selection.free(ids, occupied, worldFor, "power"), nil)
		Test.assertEqual(Selection.free(ids, occupied, worldFor, "sky"), "sky1")
		occupied[a] = nil
		Test.assertEqual(Selection.free(ids, occupied, worldFor, "power"), a)
	end)
	t.robloxTest("world initialization is idempotent and preserves every original stadium part", function()
		local Registry = require(game:GetService("ServerScriptService").Server.Worlds.WorldRegistry)
		local stadium = workspace:FindFirstChild("Stadium")
		local originals: { [BasePart]: CFrame } = {}
		if stadium then
			for _, part in stadium:GetDescendants() do
				if part:IsA("BasePart") then
					originals[part] = part.CFrame
				end
			end
		end
		local first = Registry.initialize()
		local count = #first:GetDescendants()
		Test.assertEqual(Registry.initialize(), first)
		Test.assertEqual(#first:GetDescendants(), count)
		for part, cf in originals do
			Test.assertTrue(part.Parent ~= nil)
			Test.assertEqual(part.CFrame, cf)
		end
		for _, world in Config.Worlds do
			if world.id == "rookie" then
				continue
			end
			local model = assert(Registry.model(world.id))
			Test.assertTrue(#model:GetDescendants() < 650, "bounded stadium instance budget")
			Test.assertEqual(#assert(model:FindFirstChild("GameplayMarkers")):GetChildren(), 4)
			Test.assertEqual(model.ModelStreamingMode, Enum.ModelStreamingMode.PersistentPerPlayer)
		end
	end)
	t.robloxTest("engine collision queries isolate worlds and ignore cosmetic architecture", function()
		local server = game:GetService("ServerScriptService").Server.Worlds
		local Registry = require(server.WorldRegistry)
		local Collision = require(server.WorldCollision)
		Registry.initialize()
		for _, world in Config.Worlds do
			if world.id == "rookie" then
				continue
			end
			local lane = `__test_{world.id}`
			Registry.register(lane, world.id)
			local params = Collision.params(lane)
			local cf = Config.frame(world)
			local hit =
				workspace:Spherecast(cf.Position + Vector3.new(0, 20, -800), 0.15, Vector3.new(0, -40, 0), params)
			Test.assertTrue(hit ~= nil, "real collidable landing surface")
			local other = Config.get(if world.id == "sky" then "power" else "sky") :: Config.Definition
			Test.assertEqual(
				workspace:Spherecast(other.origin + Vector3.new(0, 20, 0), 0.15, Vector3.new(0, -40, 0), params),
				nil
			)
			local model = assert(Registry.model(world.id))
			for _, part in model:GetDescendants() do
				if
					part:IsA("BasePart")
					and (part.Name == "Cloud" or part.Name == "FieldStripe" or part.Transparency == 1)
				then
					Test.assertTrue(
						not part.CanQuery and not part.CanCollide,
						"no invisible or cosmetic flight blockers"
					)
				end
			end
		end
	end)
	t.robloxTest("outer lanes retain fair landing ground for extreme left and right sprays", function()
		local server = game:GetService("ServerScriptService").Server
		local Registry = require(server.Worlds.WorldRegistry)
		local Collision = require(server.Worlds.WorldCollision)
		local Geometry = require(Shared.Pitching.LaneGeometry)
		local Field = require(Shared.BattedBall.FieldFrame)
		local Ball = require(Shared.BattedBall.BattedBall)
		local Landing = require(Shared.BattedBall.LandingDetector)
		local Helpers = require(script.Parent.BattedBallTestUtil)
		Registry.initialize()
		for _, world in Config.Worlds do
			if world.id == "rookie" then
				continue
			end
			for _, index in { 1, 4 } do
				local cf = Config.frame(world) * CFrame.new((index - 2.5) * Config.LaneSpacingStuds, 0, 0)
				local geo = Geometry.new({
					plateGround = cf.Position,
					pitcherGround = cf:PointToWorldSpace(Vector3.new(0, 0, -65.8)),
				})
				local frame = Field.new(geo)
				local id = `__extreme_{world.id}_{index}`
				Registry.register(id, world.id)
				local params = Collision.params(id)
				for _, angle in { -42, 42 } do
					local launch =
						Helpers.launchData(frame, { speedMph = 9000, launchDegrees = 26, sprayDegrees = angle })
					launch.powerLevel = 40
					local flight = Ball.buildFlight(frame, launch)
					local result = Landing.evaluate(flight, function(o, d, r)
						local hit = workspace:Spherecast(o, r, d, params)
						return if hit
							then { distance = hit.Distance, point = hit.Position, normal = hit.Normal }
							else nil
					end)
					Test.assertEqual(result.kind, "Landed")
					Test.assertEqual(result.territory, "Fair")
					Test.assertTrue((result.carryMeters or 0) > 800)
				end
			end
		end
	end)
end
