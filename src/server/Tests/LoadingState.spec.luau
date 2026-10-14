--!strict
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local State = require(Shared.Presentation.LoadingState)
local Input = require(Shared.Presentation.InputMode)
local Test = require(script.Parent.TestUtil)
local function ready(): State.Readiness
	return {
		boot = true,
		profile = true,
		character = true,
		world = true,
		loaded = 100,
		total = 100,
		assets = true,
		scene = true,
	}
end
return function(t: any)
	t.test("the visual deadline admits unfinished scenery but never missing core readiness", function()
		local s, r = State.new(), ready()
		r.scene, r.assets, r.loaded = false, false, 0
		Test.assertTrue(not State.cap(s, 0, 29, 30, r))
		Test.assertTrue(State.cap(s, 0, 30, 30, r))
		Test.assertTrue(s.capped and State.leave(s, 0) and State.finish(s, 0))
		for _, key in { "boot", "profile", "character", "world" } do
			local missing, flags = ready(), ready() :: any
			flags[key] = false
			missing = flags
			Test.assertTrue(not State.cap(State.new(), 0, 31, 30, missing), key)
		end
	end)
	t.test("capped joining keeps Play ready through late visual polls and waits for explicit entry", function()
		local s, r = State.new(), ready()
		r.scene, r.assets, r.loaded = false, false, 0
		Test.assertTrue(State.cap(s, 0, 30, 30, r))
		for _ = 1, 10 do
			Test.assertTrue(State.update(s, 0, r))
			Test.assertEqual(s.phase, "Ready")
			Test.assertEqual(s.percent, 100)
			Test.assertTrue(not s.entered)
		end
		Test.assertTrue(State.leave(s, 0) and State.finish(s, 0))
		Test.assertTrue(s.entered)
	end)
	t.test("capped readiness still rejects a lost profile or living character", function()
		for _, key in { "profile", "character" } do
			local s, r = State.new(), ready()
			r.scene = false
			Test.assertTrue(State.cap(s, 0, 30, 30, r))
			local flags = r :: any
			flags[key] = false
			Test.assertTrue(not State.update(s, 0, r))
			Test.assertTrue(not State.leave(s, 0) and not s.entered)
		end
	end)
	t.test("visual caps reject profile failure, stale requests and an already ready Play menu", function()
		local s, r = State.new(), ready()
		r.failure = "LoadFailed"
		Test.assertTrue(not State.cap(s, 0, 31, 30, r))
		r.failure = nil
		Test.assertTrue(not State.cap(s, 1, 31, 30, r))
		State.update(s, 0, r)
		Test.assertTrue(not State.cap(s, 0, 31, 30, r))
		Test.assertTrue(not s.capped and not s.entered)
	end)
	t.test("displayed progress spreads the wait with only modest slowing at the end", function()
		local first = State.displayProgress(10, 30, 1.15)
		local middle = State.displayProgress(20, 30, 1.15)
		local last = State.displayProgress(29, 30, 1.15)
		Test.assertTrue(first >= 30 and first <= 40)
		Test.assertTrue(middle >= 65 and middle <= 75)
		Test.assertTrue(last >= 95 and last < 100)
		Test.assertTrue(State.displayProgress(30, 30, 1.15) < 100)
	end)
	t.test("Play requires every real readiness gate and nonempty scene coverage", function()
		for _, key in { "boot", "profile", "character", "world", "assets", "scene" } do
			local s, r = State.new(), ready()
			local flags = r :: any
			flags[key] = false
			Test.assertTrue(not State.update(s, 0, r), key)
			Test.assertTrue(not State.leave(s, 0), key)
			Test.assertTrue(s.percent < 100)
		end
		local s, r = State.new(), ready()
		r.total, r.loaded = 0, 0
		Test.assertTrue(not State.update(s, 0, r))
	end)
	t.test("incomplete model replication cannot enable Play", function()
		local s, r = State.new(), ready()
		r.loaded = 99
		Test.assertTrue(not State.update(s, 0, r))
		Test.assertTrue(s.percent < 100)
		r.loaded = 100
		Test.assertTrue(State.update(s, 0, r))
		Test.assertEqual(s.percent, 100)
	end)
	t.test("join readiness waits for explicit Play and rejects duplicate clicks", function()
		local s = State.new()
		Test.assertTrue(State.update(s, 0, ready()))
		Test.assertTrue(not s.entered and s.phase == "Ready")
		Test.assertTrue(State.leave(s, 0))
		Test.assertTrue(not State.leave(s, 0))
		Test.assertTrue(State.finish(s, 0))
		Test.assertTrue(not State.finish(s, 0))
		Test.assertTrue(s.entered and s.phase == "Hidden")
	end)
	t.test("delayed polls cannot change an active reveal or restart finished loading", function()
		local s = State.new()
		State.update(s, 0, ready())
		State.leave(s, 0)
		local r = ready()
		r.failure = "late failure"
		Test.assertTrue(not State.update(s, 0, r))
		Test.assertEqual(s.phase, "Leaving")
		State.finish(s, 0)
		Test.assertTrue(not State.update(s, 0, ready()))
		Test.assertEqual(s.phase, "Hidden")
	end)
	t.test("travel readiness uses a new epoch and preserves initial entry", function()
		local s = State.new()
		State.update(s, 0, ready())
		State.leave(s, 0)
		State.finish(s, 0)
		local token = State.begin(s, "Travel", "power")
		Test.assertTrue(s.entered and token > 0 and s.world == "power")
		Test.assertTrue(not State.update(s, 0, ready()))
		Test.assertTrue(State.update(s, token, ready()))
		Test.assertTrue(State.leave(s, token) and State.finish(s, token))
	end)
	t.test("profile failure cannot release the screen or claim completion", function()
		local s, r = State.new(), ready()
		r.failure = "LoadFailed"
		Test.assertTrue(not State.update(s, 0, r))
		Test.assertEqual(s.phase, "Error")
		Test.assertTrue(not State.leave(s, 0))
		Test.assertTrue(not s.entered)
	end)
	t.test("retry replaces the old token and clears previous progress", function()
		local s = State.new()
		State.update(s, 0, ready())
		local token = State.begin(s, "Join", "rookie")
		Test.assertEqual(s.percent, 0)
		Test.assertTrue(not State.leave(s, 0))
		Test.assertTrue(not State.finish(s, 0))
		Test.assertTrue(State.update(s, token, ready()))
	end)
	t.test("loading shares menu suppression and the existing closing-click guard", function()
		local s = Input.new()
		s.batting = true
		Input.menu(s, "Loading", true, 0)
		Test.assertTrue(Input.cursor(s) and not Input.canSwing(s, 1, false))
		Input.menu(s, "Loading", false, 1)
		Test.assertTrue(not Input.canSwing(s, 1, false))
		Test.assertTrue(Input.canSwing(s, 2, false))
	end)
end
