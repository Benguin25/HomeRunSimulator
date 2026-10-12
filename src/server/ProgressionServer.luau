--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Data = require(Shared.Progression.PlayerProgression)
local Landing = require(Shared.BattedBall.LandingDetector)
local Server = {}
local states: { [Player]: Data.State } = {}
local update: RemoteEvent
local function publish(player: Player)
	local state = states[player]
	if state then
		update:FireClient(player, Data.snapshot(state))
	end
end
function Server.power(player: Player): (number, number)
	local state = states[player]
	return if state then state.powerLevel else 0, if state then state.version else 0
end
function Server.launch(player: Player, hitId: number)
	local state = states[player]
	if state then
		Data.launch(state, hitId)
	end
end
function Server.resolve(player: Player, hitId: number, outcome: Landing.OutcomePayload)
	local state = states[player]
	if state and Data.resolve(state, hitId, outcome) then
		publish(player)
	end
end
function Server.cancel(player: Player, hitId: number)
	local state = states[player]
	if state then
		Data.cancel(state, hitId)
	end
end
function Server.start()
	local runtime = Instance.new("Folder")
	runtime.Name = "ProgressionRuntime"
	update = Instance.new("RemoteEvent")
	update.Name, update.Parent = "Update", runtime
	local getSnapshot = Instance.new("RemoteFunction")
	getSnapshot.Name, getSnapshot.Parent = "GetSnapshot", runtime
	getSnapshot.OnServerInvoke = function(player: Player)
		local state = states[player]
		return if state then Data.snapshot(state) else nil
	end
	local purchase = Instance.new("RemoteFunction")
	purchase.Name, purchase.Parent = "Purchase", runtime
	purchase.OnServerInvoke = function(player: Player, category: any, sequence: any, expectedLevel: any)
		local state = states[player]
		if not state then
			return nil, { ok = false, reason = "PlayerUnavailable" }
		end
		-- No yields: cost calculation, subtraction and increment form one transaction.
		local result = Data.purchase(state, category, sequence, expectedLevel, Workspace:GetServerTimeNow())
		if result.ok then
			publish(player)
		end
		return Data.snapshot(state), result
	end
	local function added(player: Player)
		states[player] = Data.new()
	end
	Players.PlayerAdded:Connect(added)
	Players.PlayerRemoving:Connect(function(player)
		states[player] = nil
	end)
	for _, player in Players:GetPlayers() do
		added(player)
	end
	runtime.Parent = ReplicatedStorage
end
return Server
