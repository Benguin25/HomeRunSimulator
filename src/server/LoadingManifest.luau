--!strict
-- Cosmetic stream-in manifests. No client event changes gameplay authority.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local HttpService = game:GetService("HttpService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Presentation.LoadingConfig)
local OpeningView = require(Shared.Presentation.OpeningView)
local EnvConfig = require(Shared.Environment.EnvironmentConfig)
local BakeLayout = require(Shared.Environment.BakeLayout)
local Worlds = require(script.Parent.Worlds.WorldRegistry)
local Boxes = require(script.Parent.BatterBoxes)
local Manifest = {}
type Record = { path: { string }, parts: number, descendants: number }
local extra: { [string]: { Model } } = {}
local retained: { [Player]: { world: string, models: { Model } } } = {}

local function path(inst: Instance): { string }
	local names = {}
	local current: Instance? = inst
	while current and current ~= Workspace do
		table.insert(names, 1, current.Name)
		current = current.Parent
	end
	assert(current == Workspace, "Loading target is outside Workspace")
	return names
end
local function partCount(inst: Instance): number
	local count = if inst:IsA("BasePart") then 1 else 0
	for _, d in inst:GetDescendants() do
		if d:IsA("BasePart") then
			count += 1
		end
	end
	return count
end
local function release(player: Player)
	local old = retained[player]
	if old and player.Parent == Players then
		for _, model in old.models do
			if model.Parent then
				model:RemovePersistentPlayer(player)
			end
		end
	end
	retained[player] = nil
end
local function visibility(player: Player, _previous: string?, current: string)
	local old = retained[player]
	if old and old.world == current then
		return
	end
	release(player)
	local models: { Model } = extra[current] or {}
	for _, model in models do
		model:AddPersistentPlayer(player)
	end
	retained[player] = { world = current, models = models }
end
function Manifest.start()
	if not Config.Enabled then
		return
	end
	local runtime = Instance.new("Folder")
	runtime.Name = Config.RuntimeName
	local generated = Workspace:FindFirstChild("GeneratedWorlds")
	for _, id in { "rookie", "power", "sky" } do
		local records: { Record } = {}
		local additional: { Model } = {}
		local spawn = Boxes.spawn(id)
		assert(spawn, `No spawn for loading manifest {id}`)
		local function add(inst: Instance?)
			if inst then
				local count = partCount(inst)
				if count > 0 then
					table.insert(records, { path = path(inst), parts = count, descendants = #inst:GetDescendants() })
				end
			end
		end
		if id == "rookie" then
			add(Workspace:FindFirstChild("Stadium"))
			add(Workspace:FindFirstChild("Baseplate"))
			add(generated and generated:FindFirstChild("RookieCatchment"))
			add(generated and generated:FindFirstChild("RookieBattingInteractions"))
			local environment = Workspace:FindFirstChild(EnvConfig.FolderName)
			if EnvConfig.Enabled and BakeLayout.isVerified(environment) then
				for i, model in (environment :: Instance):GetDescendants() do
					if model:IsA("Model") then
						local cf, size = model:GetBoundingBox()
						local visible = OpeningView.includes(
							spawn,
							cf,
							size,
							Config.OpeningRadiusStuds,
							Config.OpeningHalfAngleDegrees
						)
						if model:GetAttribute("KeepForRookie") or visible then
							add(model)
							if not model:GetAttribute("KeepForRookie") then
								model.ModelStreamingMode = Enum.ModelStreamingMode.PersistentPerPlayer
								table.insert(additional, model)
							end
						end
					end
					if i % 500 == 0 then
						task.wait()
					end
				end
			end
		else
			add(Worlds.model(id))
		end
		extra[id] = additional
		local folder = Instance.new("Folder")
		folder.Name = id
		folder:SetAttribute("Manifest", HttpService:JSONEncode(records))
		folder:SetAttribute("Spawn", spawn.Position)
		local total = 0
		for _, record in records do
			total += record.parts
		end
		folder:SetAttribute("Parts", total)
		folder.Parent = runtime
	end
	local loaded = Instance.new("RemoteEvent")
	loaded.Name, loaded.Parent = Config.LoadedEvent, runtime
	loaded.OnServerEvent:Connect(function(player, world)
		local old = retained[player]
		if
			typeof(world) ~= "string"
			or not old
			or old.world ~= world
			or player:GetAttribute("CurrentWorld") ~= world
		then
			return
		end
		-- The opening view must remain present after Play, including distant town
		-- silhouettes outside normal streaming range. Release only on world departure.
		player:SetAttribute("OpeningViewLoadedWorld", world)
	end)
	Players.PlayerRemoving:Connect(release)
	Worlds.onVisibility(visibility)
	for _, player in Players:GetPlayers() do
		local world = player:GetAttribute("CurrentWorld")
		visibility(player, nil, if typeof(world) == "string" then world else "rookie")
	end
	runtime.Parent = ReplicatedStorage -- complete manifests before exposing readiness
end
return Manifest
