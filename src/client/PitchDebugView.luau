--!strict
-- Development pitching debug overlay (toggle with PitchConfig.Debug.ToggleKey).
-- Draws the strike zone, release point, intended target, actual crossing and
-- the trajectory, and shows speed / flight time / targeting error in a HUD.
-- Also compares the client's locally simulated crossing with the server's
-- authoritative one ("sync" line) to verify replication consistency.
-- Other systems (batting) add HUD sections and world drawings through
-- setSection / getWorldFolder so they share the same toggle.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Pitching = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Pitching")
local LaneGeometry = require(Pitching.LaneGeometry)
local Pitch = require(Pitching.Pitch)
local PitchConfig = require(Pitching.PitchConfig)
local PitchPhysics = require(Pitching.PitchPhysics)
local Shared = Pitching.Parent
local DebugToggle = require(Shared.Presentation.DebugToggle)
local GameplayConfig = require(Shared.Gameplay.GameplayConfig)

local PitchVisualController = require(script.Parent.PitchVisualController)

local PitchDebugView = {}

local cfg = PitchConfig.Debug

local root: Folder
local hudLabel: TextLabel
local screenGui: ScreenGui
local toggle = DebugToggle.new(false)
local TOGGLE_ACTION = "HomeRunDebugToggle"
local pitchFolders: { Folder } = {}
local lastFlights: { [string]: Pitch.Flight } = {}
local hudLines: { [string]: string } = {}
local sections: { [string]: string } = {}
local sectionOrder: { string } = {}
local started = false

local function marker(parent: Instance, name: string, position: Vector3, size: number, color: Color3, transparency: number?): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.one * size
	part.CFrame = CFrame.new(position)
	part.Color = color
	part.Material = Enum.Material.Neon
	part.Transparency = transparency or 0
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.Parent = parent
	return part
end

local function bar(parent: Instance, a: Vector3, b: Vector3, thickness: number, color: Color3)
	local part = Instance.new("Part")
	part.Name = "Edge"
	part.Size = Vector3.new(thickness, thickness, (b - a).Magnitude)
	part.CFrame = CFrame.lookAt((a + b) / 2, b)
	part.Color = color
	part.Material = Enum.Material.Neon
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.Parent = parent
end

local function drawZone(laneId: string, geometry: LaneGeometry.Geometry)
	local existing = root:FindFirstChild(`Zone_{laneId}`)
	if existing then
		existing:Destroy()
	end
	if not cfg.ShowStrikeZone then
		return
	end
	local folder = Instance.new("Folder")
	folder.Name = `Zone_{laneId}`
	local hw = geometry.zoneWidth / 2
	local corners = {
		LaneGeometry.zonePoint(geometry, -hw, geometry.zoneBottom),
		LaneGeometry.zonePoint(geometry, hw, geometry.zoneBottom),
		LaneGeometry.zonePoint(geometry, hw, geometry.zoneTop),
		LaneGeometry.zonePoint(geometry, -hw, geometry.zoneTop),
	}
	local thickness = geometry.units.toStuds(0.012)
	for i = 1, 4 do
		bar(folder, corners[i], corners[i % 4 + 1], thickness, Color3.fromRGB(255, 255, 255))
	end
	if cfg.ShowReleasePoint then
		marker(folder, "NominalRelease", geometry.releasePoint, geometry.units.toStuds(0.06), Color3.fromRGB(255, 200, 0), 0.5)
	end
	folder.Parent = root
end

local function renderHud()
	local lines = {}
	for id, line in hudLines do
		table.insert(lines, `<b>{id}</b>  {line}`)
	end
	table.sort(lines)
	for _, key in sectionOrder do
		table.insert(lines, sections[key])
	end
	hudLabel.Text = `<b>PITCH DEBUG</b> ({cfg.ToggleKey} to toggle)\n` .. table.concat(lines, "\n")
end

local function setHud(laneId: string, text: string)
	hudLines[laneId] = text
	renderHud()
end

local function describe(geometry: LaneGeometry.Geometry, flight: Pitch.Flight): string
	local units = geometry.units
	local errorMm = if flight.targetError then units.toMeters(flight.targetError) * 1000 else -1
	local x, y = 0, 0
	if flight.crossing then
		x, y = LaneGeometry.zoneCoords(geometry, flight.crossing.position)
	end
	return string.format(
		"#%d %s | release %.1f mph | plate %.1f mph | flight %.3f s\n"
			.. "    target error %.2f mm | crossing x=%.2f m, h=%.2f m | %s",
		flight.data.id,
		flight.data.pitchType,
		flight.releaseSpeedMph,
		flight.plateSpeedMph or 0,
		flight.crossTime or -1,
		errorMm,
		units.toMeters(x),
		units.toMeters(y),
		if flight.isStrike then "strike (local)" else "ball (local)"
	)
end

local function drawPitch(geometry: LaneGeometry.Geometry, flight: Pitch.Flight)
	local laneId = flight.data.laneId
	lastFlights[laneId] = flight
	if cfg.ShowHud then
		setHud(laneId, describe(geometry, flight))
	end

	local folder = Instance.new("Folder")
	folder.Name = `Pitch_{laneId}_{flight.data.id}`
	local units = geometry.units
	local dotSize = units.toStuds(0.025)

	if cfg.ShowReleasePoint then
		marker(folder, "Release", flight.data.releasePosition, units.toStuds(0.06), Color3.fromRGB(255, 200, 0))
	end
	if cfg.ShowTarget then
		marker(folder, "Target", flight.data.target, units.toStuds(0.05), Color3.fromRGB(40, 255, 90))
	end
	local crossing = flight.crossing
	if cfg.ShowCrossing and crossing then
		marker(folder, "Crossing", crossing.position, units.toStuds(0.074), Color3.fromRGB(255, 60, 60), 0.35)
	end
	if cfg.ShowTrajectory then
		local traj = flight.trajectory
		local every = math.max(1, cfg.TrajectoryDotEverySteps)
		for i = 1, traj.count, every do
			marker(folder, "Dot", traj.positions[i], dotSize, Color3.fromRGB(0, 200, 255), 0.2)
		end
		-- Mark the plane crossing time on the path too.
		if crossing then
			marker(folder, "CrossTime", PitchPhysics.sample(traj, crossing.time), dotSize * 1.6, Color3.fromRGB(255, 255, 255))
		end
	end
	folder.Parent = root

	table.insert(pitchFolders, folder)
	while #pitchFolders > math.max(1, cfg.KeepTrajectories) do
		local old = table.remove(pitchFolders, 1)
		if old then
			old:Destroy()
		end
	end
	-- Fade older pitches.
	for index, pitchFolder in pitchFolders do
		local fade = (#pitchFolders - index) * 0.25
		for _, part in pitchFolder:GetChildren() do
			if part:IsA("BasePart") then
				part.LocalTransparencyModifier = math.min(fade, 0.9)
			end
		end
	end
end

local function onResult(info: PitchVisualController.ResultInfo)
	local flight = lastFlights[info.laneId]
	local geometry = PitchVisualController.getGeometry(info.laneId)
	if not flight or not geometry or flight.data.id ~= info.pitchId or not cfg.ShowHud then
		return
	end
	local sync = "n/a"
	if info.crossPosition and flight.crossing then
		sync = string.format("%.3f mm", geometry.units.toMeters((info.crossPosition - flight.crossing.position).Magnitude) * 1000)
	end
	setHud(
		info.laneId,
		describe(geometry, flight) .. `\n    server call: {if info.isStrike then "STRIKE" else "BALL"} | server/client crossing diff {sync}`
	)
end

local function applyVisibility()
	root.Parent = if toggle.visible then Workspace else nil
	screenGui.Enabled = toggle.visible and cfg.ShowHud
end

function PitchDebugView.isEnabled(): boolean
	return started
end

function PitchDebugView.isVisible(): boolean
	return started and toggle.visible
end

-- Extra HUD text below the pitch lines (RichText allowed). No-op when disabled.
function PitchDebugView.setSection(key: string, text: string)
	if not started then
		return
	end
	if sections[key] == nil then
		table.insert(sectionOrder, key)
	end
	sections[key] = text
	renderHud()
end

-- Folder for debug geometry; hidden together with the overlay. nil when disabled.
function PitchDebugView.getWorldFolder(): Folder?
	return if started then root else nil
end

function PitchDebugView.start()
	if started or not DebugToggle.allowed(RunService:IsStudio(), cfg.Enabled, cfg.EnableInPublished) then
		return
	end
	local ok, key = pcall(function()
		return (Enum.KeyCode :: any)[cfg.ToggleKey]
	end)
	local toggleKey: Enum.KeyCode? = if ok then key else nil
	if toggleKey == nil or toggleKey == Enum.KeyCode.None
		or cfg.ToggleKey == GameplayConfig.Hud.StatsKey or cfg.ToggleKey == GameplayConfig.Hud.SkipKey
		or toggleKey == Enum.KeyCode.Escape then
		warn("[Debug] Invalid or conflicting debug toggle key; debug UI disabled.")
		return
	end
	toggle = DebugToggle.new(true)
	started = true

	root = Instance.new("Folder")
	root.Name = "PitchDebug"

	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "PitchDebugHud"
	screenGui.Enabled = false -- hide before parenting, including the first rendered frame
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = false
	hudLabel = Instance.new("TextLabel")
	hudLabel.Name = "Text"
	hudLabel.BackgroundColor3 = Color3.new(0, 0, 0)
	hudLabel.BackgroundTransparency = 0.45
	hudLabel.TextColor3 = Color3.new(1, 1, 1)
	hudLabel.Font = Enum.Font.Code
	hudLabel.TextSize = 14
	hudLabel.RichText = true
	hudLabel.TextXAlignment = Enum.TextXAlignment.Left
	hudLabel.TextYAlignment = Enum.TextYAlignment.Top
	hudLabel.AutomaticSize = Enum.AutomaticSize.XY
	hudLabel.Position = UDim2.fromOffset(12, 12)
	hudLabel.Text = `<b>PITCH DEBUG</b> ({cfg.ToggleKey} to toggle)\nwaiting for first pitch...`
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 8)
	padding.PaddingRight = UDim.new(0, 8)
	padding.PaddingTop = UDim.new(0, 6)
	padding.PaddingBottom = UDim.new(0, 6)
	padding.Parent = hudLabel
	hudLabel.Parent = screenGui
	screenGui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	applyVisibility()

	PitchVisualController.onGeometry(drawZone)
	PitchVisualController.onPitchStarted(drawPitch)
	PitchVisualController.onPitchResult(onResult)
	PitchVisualController.onPitchAborted(function(laneId, pitchId, reason)
		if cfg.ShowHud then
			setHud(laneId, `#{pitchId} aborted ({reason})`)
		end
	end)

	local function onKey(down: boolean)
		if DebugToggle.input(toggle, down, UserInputService:GetFocusedTextBox() ~= nil) then
			applyVisibility()
		end
	end
	ContextActionService:BindActionAtPriority(TOGGLE_ACTION, function(_, state)
		if state == Enum.UserInputState.Begin then
			onKey(true)
		elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
			onKey(false)
		end
		return if UserInputService:GetFocusedTextBox() then Enum.ContextActionResult.Pass else Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value + 1, toggleKey)
	-- Studio/CoreGui may mark F7 processed. This dedicated diagnostic key must
	-- still toggle; ordinary gameplay listeners retain their processed guards.
	-- The shared edge latch prevents this fallback and the action from doubling.
	UserInputService.InputBegan:Connect(function(input)
		if input.KeyCode == toggleKey then
			onKey(true)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.KeyCode == toggleKey then
			onKey(false)
		end
	end)
	UserInputService.WindowFocusReleased:Connect(function()
		DebugToggle.release(toggle)
	end)
end

return PitchDebugView
