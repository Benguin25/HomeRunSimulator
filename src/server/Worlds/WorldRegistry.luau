--!strict
-- Owns ONLY Workspace.GeneratedWorlds. Original Stadium/GameplayMarkers stay untouched.
local Workspace = game:GetService("Workspace")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Worlds.WorldConfig)
local Geometry = require(Shared.Pitching.LaneGeometry)
local Builder = require(script.Parent.StadiumBuilder)
local Build = require(script.Parent.Construction)
local Registry = {}
local laneWorld: { [string]: string } = {}
local generated: Folder?
function Registry.initialize(): Folder
	if generated and generated.Parent then
		return generated
	end
	local existing = Workspace:FindFirstChild(Config.GeneratedFolder)
	if existing then
		assert(
			existing:IsA("Folder") and existing:GetAttribute("SourceOwner") == "Stage6B",
			"GeneratedWorlds name is occupied by unmanaged assets"
		)
		assert(
			existing:GetAttribute("GenerationVersion") == Config.GenerationVersion,
			"Generated world version changed; restart Play"
		)
		generated = existing
		return existing
	end
	local root = Instance.new("Folder")
	root.Name = Config.GeneratedFolder
	root:SetAttribute("SourceOwner", "Stage6B")
	root:SetAttribute("GenerationVersion", Config.GenerationVersion)
	root.Parent = Workspace
	for _, world in Config.Worlds do
		if world.id ~= Config.DefaultId then
			local model = Builder.create(world)
			model.Parent = root
			task.wait() -- one bounded stadium subtree at a time
		end
	end
	generated = root
	return root
end
function Registry.register(laneId: string, worldId: string)
	assert(Config.get(worldId), "unknown world")
	laneWorld[laneId] = worldId
end
function Registry.worldForLane(laneId: string): string?
	return laneWorld[laneId]
end
function Registry.model(worldId: string): Model?
	local root = generated
	local m = root and root:FindFirstChild(worldId)
	return if m and m:IsA("Model") then m else nil
end
-- Rookie catchment surrounds a projected bounding box of the actual Studio stadium.
-- No guessed bounds, overlays, replacement parts or changes to original collision.
function Registry.rookieCatchment(geometry: Geometry.Geometry)
	local root = Registry.initialize()
	if root:FindFirstChild("RookieCatchment") or not Config.Rookie.CatchmentEnabled then
		return
	end
	local model = Instance.new("Model")
	model.Name, model.ModelStreamingMode = "RookieCatchment", Enum.ModelStreamingMode.PersistentPerPlayer
	local frame = CFrame.lookAt(geometry.plateGround, geometry.plateGround + geometry.toPitcher)
	local minX, maxX, minZ, maxZ = -256, 256, -400, 180
	local stadium = Workspace:FindFirstChild("Stadium")
	if stadium and stadium:IsA("Model") then
		local cf, size = stadium:GetBoundingBox()
		minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
		for _, x in { -1, 1 } do
			for _, y in { -1, 1 } do
				for _, z in { -1, 1 } do
					local p = frame:PointToObjectSpace(cf:PointToWorldSpace(size * Vector3.new(x, y, z) / 2))
					minX, maxX, minZ, maxZ =
						math.min(minX, p.X), math.max(maxX, p.X), math.min(minZ, p.Z), math.max(maxZ, p.Z)
				end
			end
		end
	end
	local width, forward = Config.Rookie.WidthStuds / 2, Config.Rookie.ForwardStuds
	local y, color = -Config.Rookie.DropStuds, Color3.fromRGB(52, 104, 62)
	local tile = Config.Rookie.TileStuds
	Build.ground(model, frame, -width, width, -forward, minZ, y, color, tile)
	Build.ground(model, frame, -width, minX, minZ, maxZ, y, color, tile)
	Build.ground(model, frame, maxX, width, minZ, maxZ, y, color, tile)
	Build.ground(model, frame, -width, width, maxZ, math.max(maxZ + 50, Config.Rookie.BackStuds), y, color, tile)
	model.Parent = root
end
function Registry.collisionRoots(laneId: string): { Instance }
	local id = Registry.worldForLane(laneId)
	if id ~= Config.DefaultId then
		local m = id and Registry.model(id)
		return if m then { m } else {}
	end
	local roots: { Instance } = {}
	for _, name in { "Stadium", "Baseplate" } do
		local child = Workspace:FindFirstChild(name)
		if child then
			table.insert(roots, child)
		end
	end
	local catchment = generated and generated:FindFirstChild("RookieCatchment")
	if catchment then
		table.insert(roots, catchment)
	end
	return roots
end
function Registry.visibility(player: Player, previous: string?, current: string)
	local interaction = generated and generated:FindFirstChild("RookieBattingInteractions")
	if interaction and interaction:IsA("Model") then
		if previous == Config.DefaultId then
			interaction:RemovePersistentPlayer(player)
		end
		if current == Config.DefaultId then
			interaction:AddPersistentPlayer(player)
		end
	end
	if previous then
		local old = if previous == Config.DefaultId
			then generated and generated:FindFirstChild("RookieCatchment")
			else Registry.model(previous)
		if old and old:IsA("Model") then
			old:RemovePersistentPlayer(player)
		end
	end
	local nextModel = if current == Config.DefaultId
		then generated and generated:FindFirstChild("RookieCatchment")
		else Registry.model(current)
	if nextModel and nextModel:IsA("Model") then
		nextModel:AddPersistentPlayer(player)
	end
end
return Registry
