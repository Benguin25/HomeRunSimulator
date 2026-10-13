--!strict
-- Rookie environment adapter: prefer verified Studio assets; runtime fallback remains available.
--
-- Baked mode binds replicated parts, local scoreboard/flags and streaming hooks.
-- The legacy frame-budgeted generator is used only when no bake exists.
-- Scenery stays outside server baseball collision roots in either mode.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Environment.EnvironmentConfig)
local Plan = require(Shared.Environment.EnvironmentPlan)
local Kit = require(Shared.Environment.EnvKit)
local RegionMap = require(Shared.Environment.RegionMap)
local PitchNet = require(Shared.Pitching.PitchNet)
local WorldConfig = require(Shared.Worlds.WorldConfig)
local GameplayController = require(script.Parent.GameplayController)

local Controller = {}

type ChunkState = { chunk: Kit.Chunk, model: Model, visible: boolean }

local started = false
local folder: Folder? = nil
local chunks: { ChunkState } = {}
local labels: { [string]: TextLabel } = {}
local flagBase: { [BasePart]: CFrame } = {}
local flagCount = 0
local built = false
local hiddenOriginals = false

local Realizer = require(Shared.Environment.EnvironmentRealizer)
local BakeLayout = require(Shared.Environment.BakeLayout)
local baked = false
local bakedSolids: { [BasePart]: boolean } = {}

local function bindPart(part: BasePart)
	local tag = part:GetAttribute("EnvironmentTag")
	if typeof(tag) ~= "string" then
		return
	end
	local label = part:FindFirstChildWhichIsA("TextLabel", true)
	if label then
		labels[tag] = label
	end
	if tag == "Flag" and not flagBase[part] and flagCount < Config.Motion.MaxAnimatedParts then
		flagCount += 1
		flagBase[part] = part.CFrame
	end
end

local function realize(spec: Kit.Spec, parent: Instance): BasePart
	local part = Realizer.create(spec, parent)
	bindPart(part)
	return part
end

-- Authored visuals hidden locally; collision/landing untouched ----------------

local hideConfig = Config.HideStadium
local hiddenFolders: { [string]: boolean } = {}
for _, name in hideConfig.Folders do
	hiddenFolders[name] = true
end
local hiddenParts: { [string]: boolean } = { StadiumSpawn = true }
for _, name in hideConfig.Parts do
	hiddenParts[name] = true
end

local function hideOriginal(inst: Instance, stadium: Instance)
	if not inst:IsA("BasePart") and not inst:IsA("Decal") and not inst:IsA("Texture") then
		return
	end
	local hide = hiddenParts[inst.Name] == true
	local parent = inst.Parent
	while not hide and parent and parent ~= stadium do
		if hiddenFolders[parent.Name] then
			hide = true
		end
		parent = parent.Parent
	end
	if inst:IsA("Decal") or inst:IsA("Texture") then
		local owner = inst.Parent
		if owner and hiddenParts[owner.Name] then
			(inst :: Decal).Transparency = 1
		end
		return
	end
	if hide and inst:IsA("BasePart") then
		inst.Transparency = 1
		inst.CastShadow = false
		-- Invisible authored benches must not block walking (local physics only).
		local ancestor = inst:FindFirstAncestor("Bleachers")
		if ancestor and ancestor.Parent == stadium then
			inst.CanCollide = false
		end
	end
end

local function hideOriginals()
	if hiddenOriginals then
		return
	end
	hiddenOriginals = true
	local stadium = Workspace:FindFirstChild("Stadium")
	if stadium then
		for _, d in stadium:GetDescendants() do
			hideOriginal(d, stadium)
		end
		stadium.DescendantAdded:Connect(function(d)
			hideOriginal(d, stadium)
		end)
	end
	local function hideAll(root: Instance)
		local function apply(d: Instance)
			if d:IsA("BasePart") then
				d.Transparency = 1
				d.CastShadow = false
			elseif d:IsA("Texture") or d:IsA("Decal") then
				(d :: Decal).Transparency = 1
			end
		end
		apply(root)
		for _, d in root:GetDescendants() do
			apply(d)
		end
		root.DescendantAdded:Connect(apply)
	end
	if hideConfig.HideBaseplate then
		local baseplate = Workspace:FindFirstChild("Baseplate")
		if baseplate then
			hideAll(baseplate)
		end
	end
	if hideConfig.HideCatchment then
		task.spawn(function()
			local generated = Workspace:WaitForChild(WorldConfig.GeneratedFolder, 30)
			local catchment = generated and generated:WaitForChild("RookieCatchment", 30)
			if catchment then
				hideAll(catchment)
			end
		end)
	end
end

-- Site frame from the replicated Rookie lane (marker-relative, never guessed).
local function siteFrame(): (Vector3?, Vector3?)
	local runtime = ReplicatedStorage:WaitForChild(PitchNet.RuntimeFolderName, 20)
	local lanes = runtime and runtime:WaitForChild(PitchNet.LanesFolderName, 20)
	if not lanes then
		return nil, nil
	end
	local deadline = os.clock() + 20
	while os.clock() < deadline do
		for _, lane in lanes:GetChildren() do
			if not string.find(lane.Name, "/", 1, true) then
				local plate = lane:GetAttribute(PitchNet.LaneAttributes.PlateGround)
				local pitcher = lane:GetAttribute(PitchNet.LaneAttributes.PitcherGround)
				if typeof(plate) == "Vector3" and typeof(pitcher) == "Vector3" then
					local forward = Vector3.new(pitcher.X - plate.X, 0, pitcher.Z - plate.Z)
					if forward.Magnitude > 1 then
						return plate, forward.Unit
					end
				end
			end
		end
		task.wait(0.5)
	end
	return nil, nil
end

local function inRookie(): boolean
	local id = Players.LocalPlayer:GetAttribute("CurrentWorld")
	return id == nil or id == WorldConfig.DefaultId
end

local function bakedVisibility(inst: Instance)
	if inst:IsA("BasePart") then
		if bakedSolids[inst] == nil then
			bakedSolids[inst] = inst.CanCollide
		end
		inst.LocalTransparencyModifier = if inRookie() then 0 else 1
		inst.CanCollide = inRookie() and bakedSolids[inst]
	elseif inst:IsA("SurfaceGui") then
		inst.Enabled = inRookie()
	end
end

local function useBake(root: Folder)
	baked, folder = true, root
	for _, inst in root:GetDescendants() do
		if inst:IsA("BasePart") then
			bindPart(inst)
		end
		bakedVisibility(inst)
	end
	root.DescendantAdded:Connect(function(inst)
		if inst:IsA("BasePart") then
			bindPart(inst)
		end
		bakedVisibility(inst)
		if inst:IsA("TextLabel") and inst.Parent and inst.Parent.Parent and inst.Parent.Parent:IsA("BasePart") then
			bindPart(inst.Parent.Parent)
			local snapshot = GameplayController.getSnapshot()
			if snapshot then
				task.defer(function()
					Controller.refreshSnapshot(snapshot)
				end)
			end
		end
	end)
	root.DescendantRemoving:Connect(function(inst)
		if inst:IsA("BasePart") then
			bakedSolids[inst] = nil
			if flagBase[inst] then
				flagBase[inst] = nil
				flagCount -= 1
			end
		elseif inst:IsA("TextLabel") then
			for tag, label in labels do
				if label == inst then
					labels[tag] = nil
				end
			end
		end
	end)
	Players.LocalPlayer:SetAttribute("EnvironmentSource", "Baked")
	hideOriginals()
	built = true
end

local function chunkVisible(state: ChunkState, cameraPos: Vector3): boolean
	local lod = state.chunk.lod
	if lod <= 0 then
		return true
	end
	return (cameraPos - state.chunk.center).Magnitude - state.chunk.radius < lod
end

local function updateLod()
	local root = folder
	if not root then
		return
	end
	local camera = Workspace.CurrentCamera
	local pos = if camera then camera.CFrame.Position else Vector3.zero
	for _, state in chunks do
		local visible = chunkVisible(state, pos)
		if visible ~= state.visible then
			state.visible = visible
			state.model.Parent = if visible then root else nil
		end
	end
end

-- Scoreboard: server-confirmed session data for the local player only ----------

local flashUntil = 0
local function setLabel(tag: string, text: string)
	local label = labels[tag]
	if label then
		label.Text = text
	end
end

local lastSeenHit = 0
local function onSnapshot(snapshot: any)
	local stats = snapshot and snapshot.stats
	if not stats then
		return
	end
	local function feet(m: number?): string
		return if m and m > 0 then `{math.floor(m / 0.3048 + 0.5)} FT` else "---"
	end
	local result = stats.lastResult
	setLabel("ScoreboardLast", `LAST  {if result then feet(result.distanceMeters) else "---"}`)
	setLabel("ScoreboardLongest", `LONGEST  {feet(stats.longestMeters)}`)
	setLabel(
		"ScoreboardExit",
		`TOP EV  {if stats.highestExitMph and stats.highestExitMph > 0
			then `{math.floor(stats.highestExitMph + 0.5)} MPH`
			else "---"}`
	)
	if result and result.hitId ~= lastSeenHit then
		lastSeenHit = result.hitId
		local message = "NICE HIT!"
		if result.territory == "Foul" then
			message = "FOUL BALL"
		elseif result.kind == "Obstacle" then
			message = "OFF THE WALL!"
		elseif result.kind == "Landed" and result.distanceMeters then
			local ft = result.distanceMeters / 0.3048
			-- Beyond the deepest fence point (294 ft) is a home run anywhere.
			if ft >= 300 then
				local region = RegionMap.regionForFeet(ft)
				message = if ft >= 1000 then `MOONSHOT!\nINTO {string.upper(region.name)}` else "HOME RUN!"
				flashUntil = os.clock() + Config.Scoreboard.HomeRunFlashSeconds
			end
		end
		setLabel("ScoreboardMessage", message)
	end
end

Controller.refreshSnapshot = onSnapshot

local function animate()
	local t = os.clock()
	local amp = math.rad(Config.Motion.FlagSwayDegrees)
	local period = Config.Motion.FlagSwaySeconds
	local i = 0
	for part, base in flagBase do
		i += 1
		part.CFrame = base * CFrame.Angles(0, math.sin(t * 2 * math.pi / period + i * 0.7) * amp, 0)
	end
	local message = labels.ScoreboardMessage
	if message then
		if t < flashUntil then
			local on = math.floor(t * 6) % 2 == 0
			message.TextColor3 = if on then Color3.fromRGB(255, 220, 60) else Color3.fromRGB(255, 255, 255)
		else
			message.TextColor3 = Color3.fromRGB(255, 196, 46)
		end
	end
end

local function ambience()
	local amb = Config.Ambience
	for _, key in { "Crowd", "Wind", "City", "Nature" } do
		local entry = (amb :: any)[key]
		if entry and entry.Id ~= "" then
			local sound = Instance.new("Sound")
			sound.Name = `RookieAmbience{key}`
			sound.SoundId = entry.Id
			sound.Looped = true
			sound.Volume = math.min(entry.Volume, amb.MaxVolume)
			sound.Parent = SoundService
			sound:Play()
		end
	end
end

local function build()
	local existing = Workspace:FindFirstChild(Config.FolderName)
	if Config.Baked.Prefer and BakeLayout.isVerified(existing) then
		useBake(existing :: Folder)
		local snapshot = GameplayController.getSnapshot()
		if snapshot then
			onSnapshot(snapshot)
		end
		return
	end
	if existing then
		warn(
			"[Environment] Unverified environment occupies Workspace; refusing duplicate generation. Re-bake or rollback in Edit."
		)
		return
	end
	Players.LocalPlayer:SetAttribute("EnvironmentSource", "RuntimeFallback")
	local plate, forward = siteFrame()
	if not plate then
		warn("[Environment] Rookie lane geometry unavailable; using measured site defaults.")
	end
	local deadline = os.clock() + Config.Build.FrameBudgetSeconds
	local function yield()
		if os.clock() > deadline then
			task.wait()
			deadline = os.clock() + Config.Build.FrameBudgetSeconds
		end
	end
	local ok, plan = pcall(Plan.build, plate, forward, yield)
	if not ok then
		warn(`[Environment] Plan failed; keeping the authored stadium: {plan}`)
		return
	end
	local root = Instance.new("Folder")
	root.Name = Config.FolderName
	root.Parent = if inRookie() then Workspace else nil
	folder = root
	local camera = Workspace.CurrentCamera
	local first = true
	for _, chunk in (plan :: Plan.Plan).chunks do
		local model = Instance.new("Model")
		model.Name = chunk.name
		for _, spec in chunk.parts do
			realize(spec, model)
			yield()
		end
		local state: ChunkState = { chunk = chunk, model = model, visible = false }
		state.visible = chunkVisible(state, if camera then camera.CFrame.Position else Vector3.zero)
		model.Parent = if state.visible then root else nil
		table.insert(chunks, state)
		if first and chunk.name == "Field" then
			first = false
			-- Swap visuals only once the new field exists (no empty frame).
			hideOriginals()
		end
	end
	hideOriginals()
	built = true
	local snapshot = GameplayController.getSnapshot()
	if snapshot then
		onSnapshot(snapshot)
	end
end

function Controller.isBuilt(): boolean
	return built
end

function Controller.start()
	if started then
		return
	end
	started = true
	if not Config.Enabled then
		local root = Workspace:FindFirstChild(Config.FolderName)
		if BakeLayout.isVerified(root) then
			local function hide(inst: Instance)
				if inst:IsA("BasePart") then
					inst.LocalTransparencyModifier, inst.CanCollide = 1, false
				elseif inst:IsA("SurfaceGui") then
					inst.Enabled = false
				end
			end
			for _, inst in (root :: Instance):GetDescendants() do
				hide(inst)
			end
			(root :: Instance).DescendantAdded:Connect(hide)
			for _, name in { "Stadium", "Baseplate" } do
				local authored = Workspace:FindFirstChild(name)
				if authored then
					local all = authored:GetDescendants()
					table.insert(all, authored)
					for _, inst in all do
						for attr, value in inst:GetAttributes() do
							if string.sub(attr, 1, 13) == "BakeOriginal_" then
								(inst :: any)[string.sub(attr, 14)] = value
							end
						end
					end
				end
			end
		end
		Players.LocalPlayer:SetAttribute("EnvironmentSource", "AuthoredDisabled")
		return
	end
	GameplayController.onSnapshot(onSnapshot)
	Players.LocalPlayer:GetAttributeChangedSignal("CurrentWorld"):Connect(function()
		local root = folder
		if root then
			if baked then
				for _, inst in root:GetDescendants() do
					bakedVisibility(inst)
				end
			else
				root.Parent = if inRookie() then Workspace else nil
			end
		end
	end)
	task.spawn(build)
	ambience()
	local acc = 0
	local streamBusy = false
	local lastStream = Vector3.new(math.huge, 0, 0)
	RunService.Heartbeat:Connect(function(dt)
		if not built or not folder or folder.Parent == nil or (baked and not inRookie()) then
			return
		end
		acc += dt
		if acc >= Config.Build.LodCheckSeconds then
			acc = 0
			if not baked then
				updateLod()
			end
		end
		if baked and inRookie() and Workspace.StreamingEnabled and not streamBusy then
			local camera = Workspace.CurrentCamera
			if camera and (camera.CFrame.Position - lastStream).Magnitude >= Config.Baked.StreamMoveStuds then
				streamBusy = true
				lastStream = camera.CFrame.Position
				task.spawn(function()
					pcall(function()
						Players.LocalPlayer:RequestStreamAroundAsync(lastStream, Config.Baked.StreamTimeoutSeconds)
					end)
					task.wait(Config.Baked.StreamIntervalSeconds)
					streamBusy = false
				end)
			end
		end
		animate()
	end)
end

return Controller
