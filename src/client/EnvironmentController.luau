--!strict
-- Client-side Rookie environment (Stage 2).
--
-- Realizes the shared EnvironmentPlan locally, a few milliseconds per frame,
-- into Workspace.RookieEnvironment. Nothing here replicates or touches server
-- state: the authored Stadium, Baseplate and RookieCatchment are only made
-- invisible LOCALLY (their collision and the authoritative landing set are
-- unchanged), and the hidden authored bleachers stop blocking the local
-- character. Detail chunks are parented in and out by camera distance; the
-- whole folder is detached while the player is in another world.

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
local tagged: { [string]: { BasePart } } = {}
local labels: { [string]: TextLabel } = {}
local flagBase: { [BasePart]: CFrame } = {}
local flagCount = 0
local built = false
local hiddenOriginals = false

local function color(c: Kit.Color): Color3
	return Color3.fromRGB(c[1], c[2], c[3])
end

local materialCache: { [string]: Enum.Material } = {}
local function material(name: string): Enum.Material
	local m = materialCache[name]
	if not m then
		local ok, value = pcall(function()
			return (Enum.Material :: any)[name]
		end)
		m = if ok and value then value else Enum.Material.SmoothPlastic
		materialCache[name] = m
	end
	return m :: Enum.Material
end

local function font(name: string?): Enum.Font
	local ok, value = pcall(function()
		return (Enum.Font :: any)[name or "GothamBlack"]
	end)
	return if ok and value then value else Enum.Font.GothamBlack
end

local function realize(spec: Kit.Spec, parent: Instance): BasePart
	local part: BasePart
	if spec.shape == "Wedge" then
		part = Instance.new("WedgePart")
	else
		local p = Instance.new("Part")
		if spec.shape == "Cylinder" then
			p.Shape = Enum.PartType.Cylinder
		elseif spec.shape == "Ball" then
			p.Shape = Enum.PartType.Ball
		end
		part = p
	end
	part.Anchored = true
	part.CanCollide = spec.collide
	part.CanQuery = spec.collide
	part.CanTouch = false
	part.CastShadow = spec.shadow
	-- Parts are capped at 2,048 studs; very large ellipsoids (hills, massifs)
	-- keep their shape by scaling the sphere mesh instead.
	local meshScale = 1
	if spec.shape == "Ellipsoid" then
		meshScale = math.max(1, math.ceil(math.max(spec.size.X, spec.size.Y, spec.size.Z) / 2048))
	end
	part.Size = spec.size / meshScale
	part.CFrame = spec.cf
	part.Color = color(spec.color)
	part.Material = material(spec.material)
	part.Transparency = spec.transparency
	part.Reflectance = spec.reflectance
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	if spec.shape == "Ellipsoid" then
		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = Enum.MeshType.Sphere
		mesh.Scale = Vector3.one * meshScale
		mesh.Parent = part
	end
	local sign = spec.sign
	if sign then
		local face = sign.face or "Front"
		local w = spec.size.X
		local h = if face == "Top" then spec.size.Z else spec.size.Y
		local gui = Instance.new("SurfaceGui")
		gui.Face = (Enum.NormalId :: any)[face] or Enum.NormalId.Front
		gui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
		gui.CanvasSize = Vector2.new(400, math.clamp(400 * h / math.max(w, 0.01), 40, 800))
		gui.LightInfluence = 1
		gui.Brightness = 1
		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(0.94, 0.86)
		label.Position = UDim2.fromScale(0.03, 0.07)
		label.BackgroundTransparency = 1
		label.TextScaled = true
		label.Font = font(sign.font)
		label.TextColor3 = color(sign.color)
		label.Text = sign.text
		label.Parent = gui
		gui.Parent = part
		if spec.tag then
			labels[spec.tag] = label
		end
	end
	if spec.tag then
		local list = tagged[spec.tag] or {}
		table.insert(list, part)
		tagged[spec.tag] = list
		if spec.tag == "Flag" and flagCount < Config.Motion.MaxAnimatedParts then
			flagCount += 1
			flagBase[part] = spec.cf
		end
	end
	part.Parent = parent
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
		`TOP EV  {if stats.highestExitMph and stats.highestExitMph > 0 then `{math.floor(stats.highestExitMph + 0.5)} MPH` else "---"}`
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
	if started or not Config.Enabled then
		return
	end
	started = true
	GameplayController.onSnapshot(onSnapshot)
	Players.LocalPlayer:GetAttributeChangedSignal("CurrentWorld"):Connect(function()
		local root = folder
		if root then
			root.Parent = if inRookie() then Workspace else nil
		end
	end)
	task.spawn(build)
	ambience()
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		if not built or not folder or folder.Parent == nil then
			return
		end
		acc += dt
		if acc >= Config.Build.LodCheckSeconds then
			acc = 0
			updateLod()
		end
		animate()
	end)
end

return Controller
