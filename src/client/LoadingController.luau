--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local HttpService = game:GetService("HttpService")
local Workspace = game:GetService("Workspace")
local ContentProvider = game:GetService("ContentProvider")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Presentation.LoadingConfig)
local State = require(Shared.Presentation.LoadingState)
local RenderSettler = require(Shared.Presentation.RenderSettler)
local Worlds = require(Shared.Worlds.WorldConfig)
local Screen = require(ReplicatedFirst:WaitForChild("Loading"):WaitForChild("Screen"))
local Environment = require(script.Parent.EnvironmentController)
local Controller = {}
local player = Players.LocalPlayer
local state = State.new()
type Record = { path: { string }, parts: number, descendants: number }
local records: { Record } = {}
type Cached = {
	root: Instance,
	complete: boolean,
	dirty: boolean,
	added: RBXScriptConnection,
	removing: RBXScriptConnection,
}
local cache: { [number]: Cached? } = {}
local manifest: Instance? = nil
local started = false
local current = "rookie"
local lastReadiness: State.Readiness?
local waitingRequest = false
local sceneReady = false
local scenePending = false
local renderedFrames = 0
local renderState = RenderSettler.new()
local renderReady = false
local renderCamera: CFrame? = nil
local renderFov: number? = nil

local function clearCache()
	for _, item in cache do
		if item then
			item.added:Disconnect()
			item.removing:Disconnect()
		end
	end
	cache = {}
end

local function preloadScene(token: number, roots: { Instance })
	scenePending = true
	task.spawn(function()
		local batch: { Instance } = {}
		local failed: string? = nil
		local function flush(): boolean
			if token ~= state.token then
				return false
			end
			local ok, err = pcall(function()
				ContentProvider:PreloadAsync(batch, function(id, status)
					if status ~= Enum.AssetFetchStatus.Success then
						failed = `{id}: {status.Name}`
					end
				end)
			end)
			if not ok then
				failed = tostring(err)
			end
			batch = {}
			if failed and token == state.token then
				player:SetAttribute("LoadingSceneError", failed)
			end
			RunService.RenderStepped:Wait()
			return token == state.token and failed == nil
		end
		for _, root in roots do
			local instances = root:GetDescendants()
			table.insert(instances, root)
			local budget = os.clock() + Config.ScanBudgetSeconds
			for _, inst in instances do
				if
					inst:IsA("BasePart")
					or inst:IsA("SpecialMesh")
					or inst:IsA("Decal")
					or inst:IsA("ImageLabel")
					or inst:IsA("ImageButton")
					or inst:IsA("TextLabel")
				then
					table.insert(batch, inst)
				end
				if #batch >= Config.VisualBatchInstances and not flush() then
					return
				end
				if os.clock() >= budget then
					RunService.RenderStepped:Wait()
					if token ~= state.token then
						return
					end
					budget = os.clock() + Config.ScanBudgetSeconds
				end
			end
		end
		if not flush() then
			return
		end
		sceneReady = true
		player:SetAttribute("LoadingScenePreloaded", true)
	end)
end

local function worldName(id: string): string
	local world = Worlds.get(id)
	return if world then world.name else "Stadium"
end
local function find(names: { string }): Instance?
	local root: Instance? = Workspace
	for _, name in names do
		root = root and root:FindFirstChild(name)
	end
	return root
end
local function complete(root: Instance, record: Record): boolean
	local descendants = root:GetDescendants()
	if #descendants < record.descendants then
		return false
	end
	local n = if root:IsA("BasePart") then 1 else 0
	for _, d in descendants do
		if d:IsA("BasePart") then
			n += 1
		end
	end
	return n >= record.parts
end
local function readManifest(world: string)
	local runtime = ReplicatedStorage:FindFirstChild(Config.RuntimeName)
	local folder = runtime and runtime:FindFirstChild(world)
	if folder == manifest then
		return
	end
	clearCache()
	manifest, records = folder, {}
	local json = folder and folder:GetAttribute("Manifest")
	if typeof(json) == "string" then
		local ok, decoded = pcall(function()
			return HttpService:JSONDecode(json)
		end)
		if ok then
			records = decoded
		end
	end
end
local function readiness(): State.Readiness
	readManifest(state.world)
	local requestWorld, requestRecords, requestCache, requestManifest, requestToken =
		state.world, records, cache, manifest, state.token
	local loaded, total = 0, 0
	local budget = os.clock() + Config.ScanBudgetSeconds
	for i, record in requestRecords do
		total += record.parts
		local item = requestCache[i]
		local root: Instance? = item and item.root
		if not root or not root:IsDescendantOf(Workspace) then
			if item then
				item.added:Disconnect()
				item.removing:Disconnect()
			end
			root = find(record.path)
			if root then
				local newItem: Cached
				local function changed()
					newItem.dirty = true
				end
				newItem = {
					root = root,
					complete = false,
					dirty = true,
					added = root.DescendantAdded:Connect(changed),
					removing = root.DescendantRemoving:Connect(changed),
				}
				requestCache[i], item = newItem, newItem
			else
				requestCache[i], item = nil, nil
			end
		end
		if item and item.dirty then
			item.complete, item.dirty = complete(item.root, record), false
		end
		if item and item.complete then
			loaded += record.parts
		end
		if os.clock() >= budget then
			RunService.RenderStepped:Wait()
			if requestToken ~= state.token then
				return {
					boot = false,
					profile = false,
					character = false,
					world = false,
					loaded = 0,
					total = 0,
					assets = false,
					scene = false,
				}
			end
			budget = os.clock() + Config.ScanBudgetSeconds
		end
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local spawn = requestManifest and requestManifest:GetAttribute("Spawn")
	local placed = root ~= nil
		and root:IsA("BasePart")
		and typeof(spawn) == "Vector3"
		and (root.Position - spawn).Magnitude < 80
	local profile = player:GetAttribute("ProfileState")
	if
		loaded == total
		and total > 0
		and not scenePending
		and requestToken == state.token
		and game:IsLoaded()
		and player:GetAttribute(Config.ClientReadyAttribute) == true
	then
		local roots = {}
		for _, item in requestCache do
			if item then
				table.insert(roots, item.root)
			end
		end
		if character then
			table.insert(roots, character)
		end
		local athletes = Workspace:FindFirstChild("PitcherVisuals")
		if athletes then
			table.insert(roots, athletes)
		end
		preloadScene(requestToken, roots)
	end
	player:SetAttribute("LoadingSceneParts", loaded)
	player:SetAttribute("LoadingSceneTotal", total)
	return {
		boot = game:IsLoaded() and player:GetAttribute(Config.ClientReadyAttribute) == true,
		profile = profile == "Ready",
		character = humanoid ~= nil and humanoid.Health > 0 and placed,
		world = player:GetAttribute("CurrentWorld") == requestWorld
			and (requestWorld ~= "rookie" or Environment.isBuilt()),
		loaded = loaded,
		total = total,
		assets = Screen.assetsReady(),
		scene = sceneReady and renderReady and renderedFrames >= Config.RenderReadyFrames,
		warmup = if sceneReady
			then math.min(
				0.99,
				renderState.elapsed / (Config.RenderWarmupSeconds[state.world] + Config.RenderStableSeconds)
			)
			else 0,
		failure = if profile == "LoadFailed" or profile == "LostOwnership"
			then "Profile unavailable — please rejoin"
			else nil,
	}
end
local function depart(token: number)
	-- Recheck actual character/profile readiness on the Play click as well.
	local r = lastReadiness
	local h = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if
		not r
		or not h
		or h.Health <= 0
		or (not state.capped and (not renderReady or not sceneReady))
		or player:GetAttribute("ProfileState") ~= "Ready"
	then
		return
	end
	if not State.leave(state, token) then
		return
	end
	player:SetAttribute("LoadingPhase", "Leaving")
	Screen.finish(function()
		if not State.finish(state, token) then
			return
		end
		clearCache()
		player:SetAttribute(Config.EnteredAttribute, true)
		player:SetAttribute("LoadingPhase", "Hidden")
		local runtime = ReplicatedStorage:FindFirstChild(Config.RuntimeName)
		local event = runtime and runtime:FindFirstChild(Config.LoadedEvent)
		if not state.capped and event and event:IsA("RemoteEvent") then
			event:FireServer(state.world)
		end
	end)
end
local function expireVisuals(token: number, elapsed: number, limit: number, r: State.Readiness): boolean
	if not State.cap(state, token, elapsed, limit, r) then
		return false
	end
	lastReadiness = r
	player:SetAttribute("LoadingVisualCapUsed", true)
	player:SetAttribute("LoadingPhase", "Ready")
	player:SetAttribute("LoadingLastDuration", elapsed)
	player:SetAttribute("LoadingProgress", 100)
	Screen.ready(function()
		depart(token)
	end)
	return true
end
local function coreReadiness(world: string): State.Readiness
	local runtime = ReplicatedStorage:FindFirstChild(Config.RuntimeName)
	local destination = runtime and runtime:FindFirstChild(world)
	local spawn = destination and destination:GetAttribute("Spawn")
	local character = player.Character
	local h = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local profile = player:GetAttribute("ProfileState")
	return {
		boot = game:IsLoaded() and player:GetAttribute(Config.ClientReadyAttribute) == true,
		profile = profile == "Ready",
		character = h ~= nil
			and h.Health > 0
			and root ~= nil
			and root:IsA("BasePart")
			and typeof(spawn) == "Vector3"
			and (root.Position - spawn).Magnitude < 80,
		world = player:GetAttribute("CurrentWorld") == world,
		loaded = 0,
		total = 0,
		assets = false,
		scene = false,
		failure = if profile == "LoadFailed" or profile == "LostOwnership"
			then "Profile unavailable — please rejoin"
			else nil,
	}
end
local function begin(mode: string, world: string)
	local token = State.begin(state, mode, world)
	clearCache()
	manifest, records, lastReadiness = nil, {}, nil
	sceneReady, scenePending, renderedFrames = false, false, 0
	renderState, renderReady, renderCamera, renderFov = RenderSettler.new(), false, nil, nil
	player:SetAttribute("LoadingRenderReady", false)
	player:SetAttribute("LoadingScenePreloaded", false)
	player:SetAttribute("LoadingSceneError", nil)
	player:SetAttribute("LoadingVisualCapUsed", false)
	Screen.show(mode, worldName(world))
	player:SetAttribute("LoadingPhase", "Loading")
	player:SetAttribute("LoadingProgress", 0)
	task.spawn(function()
		local startedAt = player:GetAttribute("LoadingScreenStartedAt")
		local start = if mode == "Join" and typeof(startedAt) == "number" then startedAt else os.clock()
		local capAt = if mode == "Join"
			then Config.MaxVisualSeconds
			else Config.MaxVisualSeconds - Config.CoverSeconds - Config.RevealSeconds
		-- Independent of scene scans/preload calls: visual work must not extend the cap.
		task.spawn(function()
			task.wait(math.max(0, capAt - (os.clock() - start)))
			while token == state.token and state.phase == "Loading" do
				if not waitingRequest and expireVisuals(token, os.clock() - start, capAt, coreReadiness(world)) then
					return
				end
				task.wait(0.1)
			end
		end)
		local requested = false
		local readyAt: number? = nil
		local reported = false
		while token == state.token and state.phase ~= "Hidden" and state.phase ~= "Leaving" do
			if waitingRequest then
				if os.clock() - start > Config.TimeoutSeconds then
					Screen.error("Travel request is still pending", nil)
					player:SetAttribute("LoadingPhase", "Error")
				end
				task.wait(Config.PollSeconds)
				continue
			end
			local r = readiness()
			if token ~= state.token or state.phase == "Leaving" or state.phase == "Hidden" or state.capped then
				return
			end
			lastReadiness = r
			if not requested and manifest then
				requested = true
				local spawn = manifest:GetAttribute("Spawn")
				if typeof(spawn) == "Vector3" and Workspace.StreamingEnabled then
					task.spawn(function()
						pcall(function()
							player:RequestStreamAroundAsync(spawn, Config.StreamTimeoutSeconds)
						end)
					end)
				end
			end
			local ready = State.update(state, token, r)
			player:SetAttribute("LoadingProgress", state.percent)
			player:SetAttribute("LoadingPhase", state.phase)
			if r.failure then
				Screen.error(r.failure, nil)
				return
			end
			local elapsed = os.clock() - start
			if expireVisuals(token, elapsed, capAt, r) then
				return
			end
			local text = if not r.profile
				then "Loading profile"
				elseif not r.character then "Preparing your character"
				elseif not r.world or r.loaded < r.total or r.total == 0 then "Loading stadium"
				elseif not r.assets then "Loading artwork"
				elseif not sceneReady then "Preparing stadium visuals"
				elseif not renderReady then "Rendering skyline and surroundings"
				else "Preparing opening view"
			Screen.progress(
				if ready
					then 100
					else State.displayProgress(elapsed, Config.MaxVisualSeconds, Config.ProgressCurveExponent),
				text
			)
			if ready then
				readyAt = readyAt or os.clock()
				if os.clock() - (readyAt :: number) >= Config.ReadySettleSeconds then
					if not reported then
						player:SetAttribute("LoadingLastDuration", os.clock() - start)
						reported = true
					end
					Screen.ready(function()
						depart(token)
					end)
				end
			else
				readyAt = nil
			end
			if not ready and not sceneReady and os.clock() - start > Config.TimeoutSeconds then
				state.phase = "Error"
				player:SetAttribute("LoadingPhase", "Error")
				Screen.error("Still waiting for the stadium", function()
					begin(mode, world)
				end)
				return
			end
			task.wait(Config.PollSeconds)
		end
	end)
end
function Controller.start()
	if started then
		return
	end
	started = true
	RunService.RenderStepped:Connect(function(dt)
		if sceneReady and state.phase ~= "Hidden" and state.phase ~= "Leaving" then
			renderedFrames += 1
			local camera = Workspace.CurrentCamera
			if not camera then
				return
			end
			local previous = renderCamera
			if
				previous
				and (
					(camera.CFrame.Position - previous.Position).Magnitude > 1
					or camera.CFrame.LookVector:Dot(previous.LookVector) < math.cos(math.rad(1))
					or math.abs(camera.FieldOfView - (renderFov :: number)) > 0.1
				)
			then
				renderState = RenderSettler.new()
			end
			renderCamera, renderFov = camera.CFrame, camera.FieldOfView
			renderReady = RenderSettler.update(
				renderState,
				dt,
				Stats.SceneTriangleCount,
				Config.RenderWarmupSeconds[state.world],
				Config.RenderStableSeconds,
				Config.RenderTriangleTolerance
			)
			player:SetAttribute("LoadingRenderReady", renderReady)
			player:SetAttribute("LoadingRenderSeconds", renderState.elapsed)
			player:SetAttribute("LoadingRenderStableSeconds", renderState.stable)
		end
	end)
	Screen.start()
	if not Config.Enabled then
		return
	end
	local id = player:GetAttribute("CurrentWorld")
	current = if typeof(id) == "string" then id else "rookie"
	begin("Join", current)
	player:GetAttributeChangedSignal("CurrentWorld"):Connect(function()
		local world = player:GetAttribute("CurrentWorld")
		if typeof(world) ~= "string" or world == current then
			return
		end
		current = world
		if world == state.world and state.phase ~= "Hidden" then
			return
		end
		begin(if state.entered then "Travel" else "Join", world)
	end)
end
function Controller.prepareTravel(world: string): boolean
	if not Config.Enabled then
		return true
	end
	if not state.entered or state.phase ~= "Hidden" then
		return false
	end
	waitingRequest = true
	begin("Travel", world)
	task.wait(Config.CoverSeconds)
	return true
end
function Controller.travelResult(ok: boolean)
	if not Config.Enabled then
		return
	end
	waitingRequest = false
	if ok then
		local world = player:GetAttribute("CurrentWorld")
		if typeof(world) == "string" then
			current = world
		end
	else
		state.token += 1
		state.phase = "Hidden"
		clearCache()
		Screen.cancel()
		player:SetAttribute("LoadingPhase", "Hidden")
	end
end
return Controller
