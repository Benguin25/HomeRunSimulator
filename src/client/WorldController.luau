--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Data = require(ReplicatedStorage:WaitForChild("Shared").Progression.PlayerProgression)
local Progression = require(script.Parent.ProgressionController)
local Controller = {}
local Input = require(script.Parent.InputCoordinator)
local opened, pending, started = false, false, false
local travel: RemoteFunction
local sequence = 0
local snapshot: Data.Snapshot?
function Controller.isOpen(): boolean
	return opened
end
function Controller.setOpen(value: boolean)
	opened = value
	Input.menu("Worlds", value)
	if value then
		Progression.setOpen(false)
	end
end
function Controller.isPending(): boolean
	return pending
end
function Controller.go(worldId: string, callback: (boolean, string) -> ())
	local value = snapshot
	if pending or not value then
		return
	end
	pending = true
	sequence += 1
	local seq, current = sequence, value.worlds.currentWorld
	task.spawn(function()
		local ok, response, result = pcall(function()
			return travel:InvokeServer(worldId, seq, current)
		end)
		pending = false
		if ok and response and result then
			Progression.accept(response)
			if result.ok then
				Controller.setOpen(false)
			end
			callback(result.ok, result.reason)
		else
			callback(false, "ConnectionError")
		end
	end)
end
function Controller.start()
	if started then
		return
	end
	started = true
	travel = ReplicatedStorage:WaitForChild("WorldRuntime"):WaitForChild("Travel") :: RemoteFunction
	Progression.onSnapshot(function(value)
		snapshot = value
		sequence = math.max(sequence, value.worlds.lastTravelSequence)
	end)
end
return Controller
