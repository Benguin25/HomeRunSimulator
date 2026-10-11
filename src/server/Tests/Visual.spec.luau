--!strict
-- Ball visual / playback cleanup tests. These create Instances, so they only
-- run inside Roblox (Studio test run); the CLI harness reports them as skipped.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Pitching = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Pitching")
local Pitch = require(Pitching.Pitch)
local PitchPlayback = require(Pitching.PitchPlayback)

local TestUtil = require(script.Parent.TestUtil)

return function(t)
	t.robloxTest("repeated playbacks leave no orphaned instances", function()
		local geometry = TestUtil.geometries().straight
		local rng = TestUtil.rng(123)
		local folder = Instance.new("Folder")
		folder.Name = "PitchingVisualTest"
		folder.Parent = workspace

		local ok, err = pcall(function()
			local releaseTime = 1
			for id = 1, 25 do
				local data = Pitch.generate(geometry, rng, {
					id = id,
					laneId = "Test",
					windupTime = releaseTime - 1,
					releaseTime = releaseTime,
				})
				local flight = Pitch.buildFlight(geometry, data)
				local playback = PitchPlayback.new(geometry, flight, folder)
				local now = data.windupTime
				local alive = true
				local maxChildren = 0
				while alive do
					now += 1 / 60
					alive = playback:update(now)
					maxChildren = math.max(maxChildren, #folder:GetChildren())
					TestUtil.assertTrue(now < releaseTime + 10, "playback never finished")
				end
				-- Ball model + release flash at most.
				TestUtil.assertTrue(maxChildren <= 2, `too many visual instances: {maxChildren}`)
				TestUtil.assertEqual(#folder:GetChildren(), 0, `instances left after pitch {id}`)
				releaseTime = now + 1
			end

			-- Aborting mid-flight also cleans up.
			local data = Pitch.generate(geometry, rng, { id = 99, laneId = "Test", windupTime = 0, releaseTime = 1 })
			local playback = PitchPlayback.new(geometry, Pitch.buildFlight(geometry, data), folder)
			playback:update(1.05)
			playback:destroy()
			TestUtil.assertEqual(#folder:GetChildren(), 0, "instances left after abort")
			TestUtil.assertTrue(not playback:update(1.1), "destroyed playback should report finished")
		end)
		folder:Destroy()
		if not ok then
			error(err, 0)
		end
	end)
end
