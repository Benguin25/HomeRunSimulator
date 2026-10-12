--!strict
-- Server entry point: authoritative pitching, batting, batted balls and batter placement.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local PitchConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Pitching"):WaitForChild("PitchConfig"))

local BattedBallServer = require(script.BattedBallServer)
local BatterService = require(script.BatterService)
local BattingServer = require(script.BattingServer)
local PitchServer = require(script.PitchServer)
local GameplayServer = require(script.GameplayServer)
local ProgressionServer = require(script.ProgressionServer)

if RunService:IsStudio() and PitchConfig.Debug.Enabled and PitchConfig.Debug.RunTestsOnStart then
	local ok, err = pcall(function()
		local summary = require(script.Tests).run(true)
		if summary.failed > 0 then
			warn(`[Pitching] {summary.failed} pitching test(s) FAILED; see output above.`)
		end
	end)
	if not ok then
		warn(`[Pitching] Test run errored: {err}`)
	end
end

ProgressionServer.start()
GameplayServer.start()
PitchServer.start()
BattedBallServer.start()
BattingServer.start()
BatterService.start()
