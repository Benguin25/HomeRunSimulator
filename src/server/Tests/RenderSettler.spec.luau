--!strict
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Settler = require(Shared.Presentation.RenderSettler)
local Test = require(script.Parent.TestUtil)
return function(t: any)
	t.test("a short render plateau cannot bypass the measured warmup", function()
		local s = Settler.new()
		for _ = 1, 100 do
			Test.assertTrue(not Settler.update(s, 0.1, 100000, 35, 8, 0.0015))
		end
		local ready = false
		for _ = 1, 260 do
			ready = Settler.update(s, 0.1, 100000, 35, 8, 0.0015)
		end
		Test.assertTrue(ready)
	end)
	t.test("late skyline drawing requires a fresh stable render window", function()
		local s = Settler.new()
		for _ = 1, 400 do
			Settler.update(s, 0.1, 100000, 35, 8, 0.0015)
		end
		Test.assertTrue(not Settler.update(s, 0.1, 180000, 35, 8, 0.0015))
		for _ = 1, 75 do
			Test.assertTrue(not Settler.update(s, 0.1, 180000, 35, 8, 0.0015))
		end
		local ready = false
		for _ = 1, 10 do
			ready = Settler.update(s, 0.1, 180000, 35, 8, 0.0015)
		end
		Test.assertTrue(ready)
	end)
	t.test("frozen frames and an empty render cannot claim visual completion", function()
		local s = Settler.new()
		Test.assertTrue(not Settler.update(s, 60, 100000, 35, 8, 0.0015))
		Test.assertNear(s.elapsed, 0.1, 1e-6)
		for _ = 1, 400 do
			Test.assertTrue(not Settler.update(s, 0.1, 0, 35, 8, 0.0015))
		end
	end)
	t.test("minor animated triangle variations do not prevent a settled view", function()
		local s = Settler.new()
		local ready = false
		for i = 1, 400 do
			ready = Settler.update(s, 0.1, 100000 + i % 2 * 20, 35, 8, 0.0015)
		end
		Test.assertTrue(ready)
	end)
end
