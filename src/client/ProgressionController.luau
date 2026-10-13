--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Data = require(Shared.Progression.PlayerProgression)
local Replica = require(Shared.Progression.ProgressionReplica)
local Controller = {}
local Input = require(script.Parent.InputCoordinator)
local state = Replica.new()
local callbacks: { (Data.Snapshot) -> () } = {}
local purchase: RemoteFunction
local rebirthRemote: RemoteFunction
local rebirthSequence = 0
local panel = "Power"
local sequence = 0
local pending = false
local shopOpen = false
local function apply(value: Data.Snapshot?)
	if value and Replica.apply(state, value) then
		for _, callback in callbacks do
			callback(value)
		end
	end
end
function Controller.accept(value: Data.Snapshot?)
	apply(value)
end
function Controller.onSnapshot(callback: (Data.Snapshot) -> ())
	table.insert(callbacks, callback)
	if state.value then
		callback(state.value)
	end
end
function Controller.power(): (number, number, number)
	local value = state.value
	return if value then value.powerLevel else 0,
		if value then value.version else 0,
		if value then value.rebirths else 0
end
function Controller.openPanel(name: string)
	panel, shopOpen = name, true
	Input.menu("Progression", true)
end
function Controller.panel(): string
	return panel
end
function Controller.setOpen(value: boolean)
	shopOpen = value
	Input.menu("Progression", value)
end
function Controller.isOpen(): boolean
	return shopOpen
end
function Controller.isPending(): boolean
	return pending
end
function Controller.buy(callback: (Data.PurchaseResult) -> ())
	local value = state.value
	if pending or not value or not value.nextCost then
		return
	end
	pending = true
	sequence += 1
	local requestedSequence, expectedLevel = sequence, value.powerLevel
	task.spawn(function()
		local ok, snapshot, result = pcall(function()
			return purchase:InvokeServer("Power", requestedSequence, expectedLevel, value.rebirths)
		end)
		pending = false
		if ok and snapshot and result then
			apply(snapshot)
			callback(result)
		else
			callback({ ok = false, reason = "ConnectionError" })
		end
	end)
end
function Controller.rebirth(callback: (Data.PurchaseResult) -> ())
	local value = state.value
	if pending or not value then
		return
	end
	pending = true
	rebirthSequence += 1
	local requested = rebirthSequence
	task.spawn(function()
		local ok, snapshot, result = pcall(function()
			return rebirthRemote:InvokeServer(requested, value.rebirths, value.version)
		end)
		pending = false
		if ok and snapshot and result then
			apply(snapshot)
			callback(result)
		else
			callback({ ok = false, reason = "ConnectionError" })
		end
	end)
end
function Controller.start()
	local runtime = ReplicatedStorage:WaitForChild("ProgressionRuntime")
	purchase = runtime:WaitForChild("Purchase") :: RemoteFunction
	rebirthRemote = runtime:WaitForChild("Rebirth") :: RemoteFunction
	(runtime:WaitForChild("Update") :: RemoteEvent).OnClientEvent:Connect(apply)
	local getSnapshot = runtime:WaitForChild("GetSnapshot") :: RemoteFunction
	task.spawn(function()
		-- Subscribe first; late initialization cannot roll back a newer award/purchase.
		local ok, value = pcall(function()
			return getSnapshot:InvokeServer()
		end)
		if ok then
			apply(value)
		end
	end)
end
return Controller
