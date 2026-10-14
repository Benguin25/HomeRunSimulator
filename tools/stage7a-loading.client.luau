--!nocheck
-- TEMPORARY Studio-only companion to the Stage 7A three-client fixture.
-- Install in StarterPlayerScripts for the test, remove before saving/publishing.
if not game:GetService("RunService"):IsStudio() then
	return
end
local player = game.Players.LocalPlayer
local remote = game.ReplicatedStorage:WaitForChild("Stage7ALoadingProbe", 30)
if not remote then
	return
end
local screen = require(game.ReplicatedFirst:WaitForChild("Loading"):WaitForChild("Screen"))
local deadline = os.clock() + 75
local function ready()
	local gui = player.PlayerGui:FindFirstChild("HRSLoadingScreen")
	local play = gui and gui:FindFirstChild("Play", true)
	return player:GetAttribute("LoadingPhase") == "Ready" and play and play.Active
end
while not ready() and os.clock() < deadline do
	remote:FireServer({
		diagnostic = tostring(player:GetAttribute("LoadingPhase")) .. ":" .. tostring(
			player:GetAttribute("LoadingProgress")
		),
	})
	task.wait(0.1)
end
assert(player:GetAttribute("ProfileMock") == true, "loading fixture requires mock profiles")
local gui = player.PlayerGui.HRSLoadingScreen
assert(not gui:FindFirstChild("Tutorial", true).Active, "tutorial must remain disabled")
assert(ready(), "joining must enable Play rather than enter automatically")
assert(gui.Enabled and player:GetAttribute("LoadingScreenEntered") ~= true, "join entered before Play")
if not player:GetAttribute("LoadingVisualCapUsed") then
	assert(player:GetAttribute("LoadingScenePreloaded") == true, "ready menu without visual preload")
	assert(player:GetAttribute("LoadingRenderReady") == true, "ready menu before rendering settled")
	assert(
		player:GetAttribute("LoadingSceneParts") == player:GetAttribute("LoadingSceneTotal"),
		"opening geometry incomplete"
	)
end
task.wait(2)
assert(ready() and gui.Enabled and player:GetAttribute("LoadingScreenEntered") ~= true, "join did not wait for Play")
screen.activate() -- same production UI command as Play.Activated

local lastWorld
while task.wait(0.15) do
	local world = player:GetAttribute("CurrentWorld")
	if world ~= lastWorld and player:GetAttribute("LoadingPhase") == "Hidden" then
		assert(player:GetAttribute("LoadingScreenEntered") == true and not gui.Enabled, "gameplay reveal completed")
		local playVisible = gui:FindFirstChild("Play", true).Visible
		assert(world == "rookie" or not playVisible, "travel incorrectly offered Play")
		if not player:GetAttribute("LoadingVisualCapUsed") then
			assert(player:GetAttribute("LoadingScenePreloaded") == true, "entry without visual preload or cap")
			assert(player:GetAttribute("LoadingRenderReady") == true, "entry without render settling or cap")
		end
		remote:FireServer({ world = world, entered = true, hidden = true, playVisible = playVisible })
		lastWorld = world
	end
end
