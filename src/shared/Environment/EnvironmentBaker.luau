--!strict
-- Edit-only authoring tool. Never called by production server/client startup.
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ServerStorage = game:GetService("ServerStorage")
local Lighting = game:GetService("Lighting")
local History = game:GetService("ChangeHistoryService")
local Config = require(script.Parent.EnvironmentConfig)
local Plan = require(script.Parent.EnvironmentPlan)
local Layout = require(script.Parent.BakeLayout)
local Realizer = require(script.Parent.EnvironmentRealizer)
local RegionMap = require(script.Parent.RegionMap)
local Baker = {}
local busy = false

local function editOnly()
	assert(RunService:IsStudio() and not RunService:IsRunning(), "Bake/rollback require Studio Edit mode")
	assert(not busy, "An environment bake is already running")
end

local function folder(parent: Instance, name: string): Folder
	local found = parent:FindFirstChild(name)
	if found then
		assert(found:IsA("Folder"))
		return found
	end
	local f = Instance.new("Folder")
	f.Name, f.Parent = name, parent
	return f
end

local function snapshotProperty(inst: Instance, key: string, value: any)
	local attr = `BakeOriginal_{key}`
	if inst:GetAttribute(attr) == nil then
		inst:SetAttribute(attr, (inst :: any)[key])
	end
	(inst :: any)[key] = value
end

-- Move existing baked assets in bounded leaf models as well as during creation.
local function transfer(source: Instance, target: Instance)
	for key, value in source:GetAttributes() do
		target:SetAttribute(key, value)
	end
	for _, child in source:GetChildren() do
		if child:IsA("Folder") then
			local nextFolder = folder(target, child.Name)
			for key, value in child:GetAttributes() do
				nextFolder:SetAttribute(key, value)
			end
			transfer(child, nextFolder)
			child:Destroy()
		else
			child.Parent = target
			task.wait()
		end
	end
end

local function originals(backup: Folder)
	local archived = folder(backup, "AuthoredAssets")
	for _, name in { "Stadium", "Baseplate" } do
		local source = Workspace:FindFirstChild(name)
		if source and not archived:FindFirstChild(name) then
			source:Clone().Parent = archived
		end
	end
	local stadium = Workspace:FindFirstChild("Stadium")
	if stadium then
		for _, inst in stadium:GetDescendants() do
			local hide = table.find(Config.HideStadium.Parts, inst.Name) ~= nil or inst.Name == "StadiumSpawn"
			local p = inst.Parent
			while p and p ~= stadium do
				if table.find(Config.HideStadium.Folders, p.Name) then
					hide = true
				end
				p = p.Parent
			end
			if hide then
				if inst:IsA("BasePart") then
					snapshotProperty(inst, "Transparency", 1)
					snapshotProperty(inst, "CastShadow", false)
					-- Server collision stays authored; the client removes invisible bench blockers.
				elseif inst:IsA("Decal") or inst:IsA("Texture") then
					snapshotProperty(inst, "Transparency", 1)
				end
			end
		end
	end
	local base = Workspace:FindFirstChild("Baseplate")
	if base and Config.HideStadium.HideBaseplate then
		snapshotProperty(base, "Transparency", 1)
		snapshotProperty(base, "CastShadow", false)
		for _, d in base:GetDescendants() do
			if d:IsA("Decal") or d:IsA("Texture") then
				snapshotProperty(d, "Transparency", 1)
			end
		end
	end
end

local function previewLighting(backup: Folder)
	local saved = folder(backup, "Lighting")
	local cfg = Config.Lighting
	local function rgb(c: { number }): Color3
		return Color3.fromRGB(c[1], c[2], c[3])
	end
	local values: { [string]: any } = {
		Brightness = cfg.Brightness,
		Ambient = rgb(cfg.Ambient),
		OutdoorAmbient = rgb(cfg.OutdoorAmbient),
		ExposureCompensation = cfg.ExposureCompensation,
		EnvironmentDiffuseScale = cfg.EnvironmentDiffuseScale,
		EnvironmentSpecularScale = cfg.EnvironmentSpecularScale,
		ShadowSoftness = cfg.ShadowSoftness,
		FogStart = cfg.FogStart,
		FogEnd = cfg.FogEnd,
	}
	for key, value in values do
		snapshotProperty(Lighting, key, value)
	end
	local best, clock, latitude = -math.huge, Lighting.ClockTime, Lighting.GeographicLatitude
	-- Save the sun before probing engine directions.
	snapshotProperty(Lighting, "ClockTime", Lighting.ClockTime)
	snapshotProperty(Lighting, "GeographicLatitude", Lighting.GeographicLatitude)
	for _, candidate in cfg.SunCandidates do
		Lighting.ClockTime, Lighting.GeographicLatitude = candidate.ClockTime, candidate.GeographicLatitude
		local sun = Lighting:GetSunDirection()
		local score = sun:Dot(-Config.Site.Forward.Unit)
			- math.abs(math.deg(math.asin(math.clamp(sun.Y, -1, 1))) - cfg.TargetElevationDegrees) / 60
		if score > best then
			best, clock, latitude = score, candidate.ClockTime, candidate.GeographicLatitude
		end
	end
	Lighting.ClockTime, Lighting.GeographicLatitude = clock, latitude
	local effects: { [string]: { [string]: any } } = {
		Atmosphere = {
			Density = cfg.Atmosphere.Density,
			Offset = cfg.Atmosphere.Offset,
			Color = rgb(cfg.Atmosphere.Color),
			Decay = rgb(cfg.Atmosphere.Decay),
			Glare = cfg.Atmosphere.Glare,
			Haze = cfg.Atmosphere.Haze,
		},
		BloomEffect = cfg.Bloom,
		SunRaysEffect = cfg.SunRays,
		DepthOfFieldEffect = cfg.DepthOfField,
		ColorCorrectionEffect = {
			TintColor = rgb(cfg.Grade.Tint),
			Contrast = cfg.Grade.Contrast,
			Saturation = cfg.Grade.Saturation,
			Brightness = cfg.Grade.Brightness,
		},
	}
	for class, properties in effects do
		local effect = if class == "ColorCorrectionEffect"
			then Lighting:FindFirstChild("RookieBakeColorCorrectionEffect")
			else Lighting:FindFirstChildOfClass(class)
		if not effect then
			effect = Instance.new(class)
			effect.Name = `RookieBake{class}`
			effect:SetAttribute("BakeCreated", true)
			effect.Parent = Lighting
		elseif not saved:FindFirstChild(effect.Name) then
			effect:Clone().Parent = saved
		end
		for key, value in properties do
			snapshotProperty(effect :: Instance, key, value)
		end
	end
end

-- Full bake, or rebuild only one stable RegionMap id. Build in a staging root;
-- keep previous assets live until the full replacement is counted and checked.
function Baker.bake(regionId: string?): { parts: number, groups: number, seconds: number }
	editOnly()
	if regionId then
		assert(RegionMap.region(regionId), "Unknown region id")
	end
	local previous = Workspace:FindFirstChild(Config.FolderName)
	assert(not previous or Layout.isVerified(previous), "Environment name occupied by unverified/unmanaged assets")
	assert(not regionId or previous, "Bake the full world before rebuilding a region")
	busy = true
	local started = os.clock()
	local staging = Instance.new("Folder")
	staging.Name = "RookieEnvironment_Baking"
	staging:SetAttribute("SourceOwner", Config.Baked.Owner)
	staging.Parent = ServerStorage
	local ok, result = pcall(function()
		local marker = Workspace:FindFirstChild("GameplayMarkers")
		local home = marker and marker:FindFirstChild("HomePlateOrigin", true)
		local pitcher = marker and marker:FindFirstChild("PitcherRubber", true)
		assert(home and home:IsA("BasePart") and pitcher and pitcher:IsA("BasePart"), "Rookie markers unavailable")
		local forward = Vector3.new(pitcher.Position.X - home.Position.X, 0, pitcher.Position.Z - home.Position.Z)
		assert(forward.Magnitude > 1, "Invalid Rookie marker frame")
		local plan = Plan.build(home.Position, forward.Unit, function()
			task.wait()
		end)
		assert(plan.count <= Config.Build.PartBudget, "Environment exceeds part budget")
		for _, region in RegionMap.Regions do
			if not regionId or region.id == regionId then
				folder(staging, region.id):SetAttribute("RegionId", region.id)
			end
		end
		local count, groups = 0, 0
		for _, group in Layout.groups(plan) do
			if not regionId or group.region == regionId then
				local parent = folder(folder(staging, group.region), group.chunk)
				local model = Instance.new("Model")
				model.Name = group.id
				model.ModelStreamingMode = if group.keep
					then Enum.ModelStreamingMode.PersistentPerPlayer
					else Enum.ModelStreamingMode.Atomic
				model:SetAttribute("KeepForRookie", group.keep)
				model:SetAttribute("ChunkId", group.chunk)
				for i, spec in group.parts do
					local part = Realizer.create(spec, model)
					part.Name = `{spec.tag or spec.shape}_{i}`
					assert(
						(part.Position - spec.cf.Position).Magnitude < 0.01 and part.CanCollide == spec.collide,
						"Instance adapter changed placement/collision"
					)
					count += 1
				end
				model.Parent = parent -- <=100 parts per insertion
				groups += 1
				task.wait()
			end
		end
		assert(regionId or count == plan.count, "Incomplete environment bake")
		staging:SetAttribute("BakeVersion", Config.Baked.Version)
		staging:SetAttribute("Seed", Config.Seed)
		staging:SetAttribute("PartCount", count)
		staging:SetAttribute("Verified", true)
		local backup = folder(ServerStorage, Config.Baked.BackupName)
		backup:SetAttribute("SourceOwner", Config.Baked.Owner)
		History:SetWaypoint("Before Rookie environment bake")
		originals(backup)
		previewLighting(backup)
		local archive = folder(backup, `Bake_{DateTime.now().UnixTimestampMillis}`)
		if regionId then
			local old = (previous :: Instance):FindFirstChild(regionId)
			if old then
				transfer(old, folder(archive, old.Name))
				old:Destroy()
			end
			local region = staging:FindFirstChild(regionId) :: Folder
			-- Transfer small leaf models, never one large unyielding region subtree.
			local destination = folder(previous :: Instance, regionId)
			destination:SetAttribute("RegionId", regionId)
			for _, chunk in region:GetChildren() do
				local target = folder(destination, chunk.Name)
				for _, model in chunk:GetChildren() do
					model.Parent = target
					task.wait()
				end
			end
			local total = 0
			for _, inst in (previous :: Instance):GetDescendants() do
				if inst:IsA("BasePart") then
					total += 1
				end
			end
			(previous :: Instance):SetAttribute("PartCount", total)
			staging:Destroy()
		else
			if previous then
				transfer(previous, folder(archive, previous.Name))
				previous:Destroy()
			end
			local root = Instance.new("Folder")
			root.Name = Config.FolderName
			for key, value in staging:GetAttributes() do
				root:SetAttribute(key, value)
			end
			root:SetAttribute("Verified", false)
			root.Parent = Workspace
			for _, region in staging:GetChildren() do
				local destination = folder(root, region.Name)
				destination:SetAttribute("RegionId", region.Name)
				for _, chunk in region:GetChildren() do
					local target = folder(destination, chunk.Name)
					for _, model in chunk:GetChildren() do
						model.Parent = target
						task.wait()
					end
				end
			end
			root:SetAttribute("Verified", true)
			staging:Destroy()
		end
		History:SetWaypoint("Baked Rookie environment")
		return { parts = count, groups = groups, seconds = os.clock() - started }
	end)
	busy = false
	if not ok then
		staging:Destroy()
		error(result)
	end
	return result
end

function Baker.rollback()
	editOnly()
	local root = Workspace:FindFirstChild(Config.FolderName)
	assert(not root or root:GetAttribute("SourceOwner") == Config.Baked.Owner, "Refusing to archive unmanaged assets")
	local backup = folder(ServerStorage, Config.Baked.BackupName)
	if root then
		transfer(root, folder(backup, `Rollback_{DateTime.now().UnixTimestampMillis}`))
		root:Destroy()
	end
	local function restore(inst: Instance)
		for attr, value in inst:GetAttributes() do
			if string.sub(attr, 1, 13) == "BakeOriginal_" then
				(inst :: any)[string.sub(attr, 14)] = value
				inst:SetAttribute(attr, nil)
			end
		end
	end
	for _, name in { "Stadium", "Baseplate" } do
		local source = Workspace:FindFirstChild(name)
		if source then
			restore(source)
			for _, d in source:GetDescendants() do
				restore(d)
			end
		end
	end
	restore(Lighting)
	for _, effect in Lighting:GetChildren() do
		if effect:GetAttribute("BakeCreated") then
			effect:Destroy()
		else
			restore(effect)
		end
	end
	History:SetWaypoint("Restored authored Rookie visuals")
end

return Baker
