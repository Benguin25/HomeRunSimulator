--!strict
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Environment.EnvironmentConfig)
local Plan = require(Shared.Environment.EnvironmentPlan)
local Layout = require(Shared.Environment.BakeLayout)
local RegionMap = require(Shared.Environment.RegionMap)
local Test = require(script.Parent.TestUtil)

return function(t: any)
	t.robloxTest("authoring bake and rollback refuse Play without touching shared assets", function()
		local Baker = require(Shared.Environment.EnvironmentBaker)
		local existing = workspace:FindFirstChild(Config.FolderName)
		Test.assertTrue(not pcall(Baker.bake), "Play unexpectedly permitted a bake")
		Test.assertTrue(not pcall(Baker.rollback), "Play unexpectedly permitted rollback")
		Test.assertTrue(workspace:FindFirstChild(Config.FolderName) == existing)
	end)
	t.test("bake partitions retain all specs, regions and bounded stable groups", function()
		local plan = Plan.build()
		local first, second = Layout.groups(plan), Layout.groups(plan)
		local seen: { [any]: boolean } = {}
		local ids: { [string]: boolean } = {}
		local regions: { [string]: boolean } = {}
		local total = 0
		Test.assertEqual(#first, #second)
		for i, group in first do
			local id = `{group.region}/{group.chunk}/{group.id}`
			Test.assertTrue(not ids[id], "duplicate bake identity")
			ids[id], regions[group.region] = true, true
			Test.assertTrue(#group.parts <= Config.Baked.BatchParts)
			Test.assertEqual(id, `{second[i].region}/{second[i].chunk}/{second[i].id}`)
			for j, spec in group.parts do
				Test.assertTrue(not seen[spec], "duplicated spec")
				Test.assertTrue(spec == second[i].parts[j], "partition mutated or copied spec")
				seen[spec] = true
				total += 1
			end
		end
		Test.assertEqual(total, plan.count)
		for _, region in RegionMap.Regions do
			Test.assertTrue(regions[region.id], region.id)
		end
		for _, chunk in plan.chunks do
			for _, spec in chunk.parts do
				Test.assertTrue(seen[spec])
			end
		end
	end)
	t.test("town streams spatially while park and horizon stay available", function()
		local retained, streamed = 0, 0
		for _, group in Layout.groups(Plan.build()) do
			if group.keep then
				retained += #group.parts
			else
				streamed += #group.parts
			end
			if string.sub(group.chunk, 1, 4) == "Town" then
				Test.assertTrue(not group.keep)
			end
			if group.chunk == "Field" or group.chunk == "Mountains" then
				Test.assertTrue(group.keep)
			end
		end
		Test.assertTrue(retained > 0 and streamed > retained, "whole town must not become persistent")
	end)
	t.robloxTest("bake adapter preserves signs, geometry and collision without landing roots", function()
		local Realizer = require(Shared.Environment.EnvironmentRealizer)
		local plan = Plan.build()
		local root = Instance.new("Folder")
		root.Name = "EnvironmentAdapterTest"
		local count = 0
		for _, chunk in plan.chunks do
			for _, spec in chunk.parts do
				if spec.sign or spec.tag or spec.shape == "Ellipsoid" then
					local part = Realizer.create(spec, root)
					Test.assertTrue(part.Anchored and not part.CanTouch)
					Test.assertEqual(part.CanCollide, spec.collide)
					Test.assertTrue((part.Position - spec.cf.Position).Magnitude < 0.01)
					Test.assertTrue(part.Size.X <= 2048 and part.Size.Y <= 2048 and part.Size.Z <= 2048)
					if spec.sign then
						local label = part:FindFirstChildWhichIsA("TextLabel", true) :: TextLabel
						Test.assertEqual(label.Text, spec.sign.text)
					end
					part:Destroy()
					count += 1
					if count % 100 == 0 then
						task.wait()
					end
				end
			end
		end
		Test.assertTrue(root.Parent == nil, "test visuals entered gameplay collision")
		root:Destroy()
	end)
end
