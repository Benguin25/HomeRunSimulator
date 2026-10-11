--!strict
-- Server entry point: authoritative pitching + batter placement.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local PitchConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Pitching"):WaitForChild("PitchConfig"))

local BatterService = require(script.BatterService)
local PitchServer = require(script.PitchServer)

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

PitchServer.start()
BatterService.start()
