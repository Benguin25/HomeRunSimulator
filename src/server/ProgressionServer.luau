--!strict
-- Runtime adapter around one progression profile, never a second economy.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Data = require(Shared.Progression.PlayerProgression)
local Schema = require(Shared.Progression.PlayerData)
local Landing = require(Shared.BattedBall.LandingDetector)
local Worlds = require(Shared.Worlds.WorldRules)
local Profiles = require(script.Parent.Persistence.ProfileStore)
local Adapter = require(script.Parent.Persistence.DataStoreAdapter)
local Config = require(script.Parent.Persistence.PersistenceConfig)
local Server = {}
local profiles: { [Player]: Profiles.Profile } = {}

local manager: Profiles.Manager
local mockMode = false
local closing = false
local update: RemoteEvent
local function publish(player: Player)
	local p = profiles[player]
	if not p or player.Parent == nil then
		return
	end
	player:SetAttribute("ProfileState", if Profiles.writable(manager, p) then "Ready" else p.status)
	player:SetAttribute("ProfileMock", mockMode)
	player:SetAttribute(
		"ProfileLoadMessage",
		if p.status ~= "LoadFailed"
			then ""
			elseif
				p.lastError == "Locked"
			then "Your progression is open in another session. Wait a moment, then rejoin."
			elseif
				p.lastError == "StorageUnavailable"
			then "Temporary connection issue loading progression. Please rejoin to retry. Your saved data is protected."
			else "Saved progression couldn't be read safely. Please rejoin or contact support. Your saved data is protected."
	)
	if RunService:IsStudio() then
		player:SetAttribute("ProfileSchema", Schema.Version)
		player:SetAttribute(
			"ProfileOwnsLease",
			p.state ~= nil and p.expires > manager.clock.now() and p.status ~= "Lost"
		)
		player:SetAttribute("ProfileLastSave", p.lastSave)
		player:SetAttribute("ProfileRetry", p.retry)
		player:SetAttribute("ProfileError", p.lastError)
		player:SetAttribute("ProfileUnsaved", p.state ~= nil and (p.state :: Data.State).version > p.savedVersion)
		player:SetAttribute("ProfileSaving", p.busy)
	end
	if p.state then
		update:FireClient(player, Data.snapshot(p.state))
	end
end
local function mutate(player: Player, reducer: (Data.State) -> any): (boolean, any)
	local p = profiles[player]
	if not p or closing then
		return false, nil
	end
	return Profiles.mutate(manager, p, reducer)
end
function Server.ready(player: Player): boolean
	local p = profiles[player]
	return not closing and p ~= nil and Profiles.writable(manager, p)
end
function Server.records(player: Player): Schema.Data?
	local p = profiles[player]
	return if p and p.state then Data.export(p.state) else nil
end
function Server.world(player: Player): string
	local p = profiles[player]
	return if p and p.state then p.state.worlds.currentWorld else "rookie"
end
function Server.travel(
	player: Player,
	target: any,
	sequence: any,
	expectedWorld: any,
	context: Worlds.Context
): Worlds.Result
	local allowed, result = mutate(player, function(state)
		return Data.travel(state, target, sequence, expectedWorld, Workspace:GetServerTimeNow(), context)
	end)
	return if allowed then result else { ok = false, reason = "DataUnavailable" }
end
function Server.publish(player: Player)
	publish(player)
end
function Server.snapshot(player: Player): Data.Snapshot?
	local p = profiles[player]
	return if p and p.state then Data.snapshot(p.state) else nil
end
function Server.power(player: Player): (number, number, number)
	local p = profiles[player]
	local state = p and p.state
	return if state then state.powerLevel else 0,
		if state then state.version else 0,
		if state then state.rebirths else 0
end
function Server.launch(player: Player, hitId: number)
	mutate(player, function(state)
		return Data.launch(state, hitId)
	end)
end
function Server.resolve(player: Player, hitId: number, outcome: Landing.OutcomePayload)
	local p = profiles[player]
	if p and not closing and Profiles.resolve(manager, p, hitId, outcome) then
		publish(player)
	end
end
function Server.cancel(player: Player, hitId: number)
	local p = profiles[player]
	if p and p.state and not p.queued[hitId] then
		Data.cancel(p.state, hitId)
	end
end
function Server.start()
	local adapter
	adapter, mockMode = Adapter.new()
	manager = Profiles.new(adapter, {
		now = function()
			return DateTime.now().UnixTimestampMillis / 1000
		end,
		wait = function(seconds)
			task.wait(seconds)
		end,
		random = math.random,
	})
	local runtime = Instance.new("Folder")
	runtime.Name = "ProgressionRuntime"
	update = Instance.new("RemoteEvent")
	update.Name, update.Parent = "Update", runtime
	local getSnapshot = Instance.new("RemoteFunction")
	getSnapshot.Name, getSnapshot.Parent = "GetSnapshot", runtime
	getSnapshot.OnServerInvoke = Server.snapshot
	local purchase = Instance.new("RemoteFunction")
	purchase.Name, purchase.Parent = "Purchase", runtime
	purchase.OnServerInvoke = function(
		player: Player,
		category: any,
		sequence: any,
		expectedLevel: any,
		expectedRebirths: any
	)
		local allowed, result = mutate(player, function(state)
			if expectedRebirths == nil then
				return { ok = false, reason = "InvalidRequest" }
			end
			return Data.purchase(
				state,
				category,
				sequence,
				expectedLevel,
				Workspace:GetServerTimeNow(),
				expectedRebirths
			)
		end)
		if allowed and result.ok then
			publish(player)
		end
		return Server.snapshot(player), if allowed then result else { ok = false, reason = "DataUnavailable" }
	end
	local rebirth = Instance.new("RemoteFunction")
	rebirth.Name, rebirth.Parent = "Rebirth", runtime
	rebirth.OnServerInvoke = function(player: Player, sequence: any, count: any, version: any)
		local allowed, result = mutate(player, function(state)
			return Data.rebirth(state, sequence, count, version, Workspace:GetServerTimeNow())
		end)
		if allowed and result.ok then
			publish(player)
		end
		return Server.snapshot(player), if allowed then result else { ok = false, reason = "DataUnavailable" }
	end
	local function added(player: Player)
		if profiles[player] or closing then
			return
		end
		local p = Profiles.profile(`Player_{player.UserId}`, HttpService:GenerateGUID(false))
		profiles[player] = p
		publish(player)
		task.spawn(function()
			Profiles.load(manager, p)
			if player.Parent == nil or closing then
				Profiles.close(manager, p, manager.clock.now() + Config.CloseTimeoutSeconds)
				return
			end
			publish(player)
			-- Per-profile stagger: no global burst and one operation per profile.
			while Players:GetPlayerByUserId(player.UserId) == player and not closing and not p.closing do
				task.wait(Config.AutosaveSeconds * (0.9 + math.random() * 0.2))
				if Players:GetPlayerByUserId(player.UserId) ~= player or closing or p.closing then
					break
				end
				if p.state then
					Profiles.save(manager, p)
					publish(player)
				end
			end
		end)
	end
	Players.PlayerAdded:Connect(added)
	Players.PlayerRemoving:Connect(function(player)
		local p = profiles[player]
		if p then
			Profiles.close(manager, p, manager.clock.now() + Config.CloseTimeoutSeconds)
			-- Retain failed closes for the bounded shutdown retry; no mutations.
			if p.status == "Closed" or not p.state then
				profiles[player] = nil
			end
		end
	end)
	game:BindToClose(function()
		closing = true
		local deadline = manager.clock.now() + Config.CloseTimeoutSeconds
		local remaining = 0
		for _, p in profiles do
			p.closing = true
			remaining += 1
			task.spawn(function()
				Profiles.close(manager, p, deadline)
				remaining -= 1
			end)
		end
		while remaining > 0 and manager.clock.now() < deadline do
			task.wait(0.05)
		end
	end)
	-- Freeze gameplay before lease expiry even if a transport call is hung.
	local elapsed = 0
	RunService.Heartbeat:Connect(function(dt)
		elapsed += dt
		if elapsed < 1 then
			return
		end
		elapsed = 0
		for player, p in profiles do
			if
				p.closing
				and not p.busy
				and manager.clock.now() >= p.expires
				and Players:GetPlayerByUserId(player.UserId) ~= player
			then
				profiles[player] = nil
				continue
			end
			if player.Parent and p.status == "Ready" and not Profiles.writable(manager, p) then
				p.status = "SaveDelayed"
				publish(player)
			elseif RunService:IsStudio() and player.Parent then
				publish(player)
			end
		end
	end)
	for _, player in Players:GetPlayers() do
		added(player)
	end
	runtime.Parent = ReplicatedStorage
end
return Server
