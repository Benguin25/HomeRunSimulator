--!strict
-- Hit HUD: the live distance counter during the flight (the landing result
-- is shown by the Swing Analysis panel, SwingAnalysisHud). Reads the presented hit from BattingCamera's director each
-- frame; every number comes from HitPresentation (live = the flight's
-- horizontal distance from home plate, final = the server's outcome).
-- Also writes the camera / presentation section of the F7 debug overlay.
--
-- Animation is time based (no per-frame constants): panels fade with
-- CanvasGroup.GroupTransparency, the final number punches with a UIScale.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Presentation = Shared:WaitForChild("Presentation")
local CameraDirector = require(Presentation.CameraDirector)
local CameraMath = require(Presentation.CameraMath)
local HitPresentation = require(Presentation.HitPresentation)
local PresentationConfig = require(Presentation.PresentationConfig)

local BattingCamera = require(script.Parent.BattingCamera)
local HitEffects = require(script.Parent.HitEffects)
local PitchDebugView = require(script.Parent.PitchDebugView)

local HitHud = {}

local BIND_NAME = "HitHud"
local DEBUG_SECTION = "Camera"

local COLORS = {
	panel = Color3.fromRGB(14, 18, 28),
	text = Color3.fromRGB(255, 255, 255),
	muted = Color3.fromRGB(170, 178, 196),
	live = Color3.fromRGB(255, 82, 82),
	gold = Color3.fromRGB(255, 205, 64),
	foul = Color3.fromRGB(160, 168, 184),
	wall = Color3.fromRGB(255, 150, 70),
	neutral = Color3.fromRGB(120, 200, 255),
}

local hud = PresentationConfig.Hud

local screenGui: ScreenGui
local panelScales: { UIScale } = {}
local counter: CanvasGroup
local counterCaption: TextLabel
local counterNumber: TextLabel
local counterUnit: TextLabel
local counterScale: UIScale
local pill: Frame
local pillText: TextLabel

local counterAlpha = 0
local resultPlayedFor: any = nil -- the hit whose landing result cue has played
local lastCounterKind = "Hidden"
local punchAt = -math.huge
local displayedMeters: number? = nil
local lastDebug = 0

local function label(parent: Instance, name: string, font: Enum.Font, size: number, color: Color3): TextLabel
	local text = Instance.new("TextLabel")
	text.Name = name
	text.BackgroundTransparency = 1
	text.Font = font
	text.TextSize = size
	text.TextColor3 = color
	text.Text = ""
	text.Parent = parent
	return text
end

local function corner(parent: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = parent
end

local function panel(name: string, size: UDim2, anchor: Vector2, position: UDim2): CanvasGroup
	local group = Instance.new("CanvasGroup")
	group.Name = name
	group.AnchorPoint = anchor
	group.Position = position
	group.Size = size
	group.BackgroundColor3 = COLORS.panel
	group.BackgroundTransparency = 0.22
	group.BorderSizePixel = 0
	group.GroupTransparency = 1
	group.Visible = false
	corner(group, 16)
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.new(1, 1, 1)
	stroke.Transparency = 0.86
	stroke.Thickness = 1
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = group
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Transparency = NumberSequence.new(0, 0.25)
	gradient.Parent = group
	local scale = Instance.new("UIScale")
	scale.Parent = group
	table.insert(panelScales, scale)
	group.Parent = screenGui
	return group
end

local function buildCounter()
	counter = panel("DistanceCounter", UDim2.fromOffset(250, 116), Vector2.new(0.5, 0), UDim2.new(0.5, 0, 0, 24))

	counterCaption = label(counter, "Caption", Enum.Font.GothamBold, 13, COLORS.muted)
	counterCaption.Position = UDim2.fromOffset(18, 12)
	counterCaption.Size = UDim2.new(1, -110, 0, 16)
	counterCaption.TextXAlignment = Enum.TextXAlignment.Left

	pill = Instance.new("Frame")
	pill.Name = "Status"
	pill.AnchorPoint = Vector2.new(1, 0)
	pill.Position = UDim2.new(1, -14, 0, 10)
	pill.Size = UDim2.fromOffset(84, 20)
	pill.BackgroundColor3 = COLORS.live
	pill.BorderSizePixel = 0
	corner(pill, 10)
	pill.Parent = counter
	pillText = label(pill, "Text", Enum.Font.GothamBlack, 11, COLORS.text)
	pillText.Size = UDim2.fromScale(1, 1)

	local row = Instance.new("Frame")
	row.Name = "Value"
	row.BackgroundTransparency = 1
	row.AnchorPoint = Vector2.new(0.5, 0)
	row.Position = UDim2.new(0.5, 0, 0, 34)
	row.Size = UDim2.new(1, -24, 0, 70)
	row.Parent = counter
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	layout.Padding = UDim.new(0, 6)
	layout.Parent = row
	counterScale = Instance.new("UIScale")
	counterScale.Parent = row

	counterNumber = label(row, "Number", Enum.Font.GothamBlack, 64, COLORS.text)
	counterNumber.AutomaticSize = Enum.AutomaticSize.X
	counterNumber.Size = UDim2.fromOffset(0, 66)
	counterNumber.LayoutOrder = 1
	counterUnit = label(row, "Unit", Enum.Font.GothamBold, 22, COLORS.muted)
	counterUnit.AutomaticSize = Enum.AutomaticSize.X
	counterUnit.Size = UDim2.fromOffset(0, 48)
	counterUnit.LayoutOrder = 2
end

local function pillStyle(c: HitPresentation.Counter): Color3
	if c.kind == "Live" then
		return COLORS.live
	elseif c.kind == "Final" then
		return if c.fair then COLORS.gold else COLORS.foul
	elseif c.kind == "Wall" then
		return COLORS.wall
	end
	return COLORS.foul
end

local function setGroup(group: CanvasGroup, alpha: number)
	group.GroupTransparency = 1 - alpha
	group.Visible = alpha > 0.002
end

local function updateScale()
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local size = camera.ViewportSize
	local scale = math.min(size.X / hud.ReferenceWidth, size.Y / hud.ReferenceHeight)
	scale = math.clamp(scale, hud.MinScale, hud.MaxScale)
	for _, uiScale in panelScales do
		uiScale.Scale = scale
	end
end

local function writeDebug(director: CameraDirector.CameraDirector, now: number, c: HitPresentation.Counter?)
	if not PitchDebugView.isEnabled() then
		return
	end
	local clock = os.clock()
	if clock - lastDebug < 0.1 then
		return
	end
	lastDebug = clock
	local hit = director:getHit()
	local d = director.debug
	local focus = d.focus
	local camera = Workspace.CurrentCamera
	local lines = {
		string.format(
			"<b>CAMERA</b> %s (presentation %s) | last event: %s | transitions %d | sync corrections %d",
			director:getState(),
			director:getPhase(),
			director.lastEvent,
			director.transitions,
			director.corrections
		),
	}
	if hit then
		local mps = hit.flight.frame.metersPerStud
		local offset = d.desiredOffset
		table.insert(
			lines,
			string.format(
				"    pitch #%d %s | profile %s, power %.2f | target %s | follow offset %s m | smoothing error %.2f m | occlusion %s | fov %.1f",
				hit.pitchId,
				if hit.confirmed then "confirmed" else "predicted",
				hit.profile.name,
				hit.power,
				if focus then string.format("(%.0f, %.0f, %.0f)", focus.X, focus.Y, focus.Z) else "-",
				if offset then string.format("(%.1f, %.1f, %.1f)", offset.X * mps, offset.Y * mps, offset.Z * mps) else "-",
				d.smoothingErrorMeters,
				if BattingCamera.getOcclusionDistance() < math.huge then string.format("%.1f m", BattingCamera.getOcclusionDistance() * mps) else "clear",
				if camera then camera.FieldOfView else 0
			)
		)
		local outcome = hit.outcome
		table.insert(
			lines,
			string.format(
				"    displayed %s (%s) | authoritative %s | ball t %.2f s",
				if displayedMeters then string.format("%.1f m", displayedMeters) else "-",
				if c then c.kind else "Hidden",
				if outcome == nil then "pending"
					elseif outcome.carryMeters then string.format("carry %.1f m", outcome.carryMeters)
					elseif outcome.impactDistanceMeters then string.format("%s at %.1f m (no carry)", outcome.kind, outcome.impactDistanceMeters)
					else outcome.kind,
				CameraDirector.ballTime(hit, now)
			)
		)
	end
	PitchDebugView.setSection(DEBUG_SECTION, table.concat(lines, "\n"))
end

local function onRender(dt: number)
	updateScale()
	local director = BattingCamera.getDirector()
	local now = Workspace:GetServerTimeNow()
	local phase = director:getPhase()
	local hit = director:getHit()

	-- Counter
	local c: HitPresentation.Counter? = nil
	if hit and phase ~= "Idle" then
		c = HitPresentation.counter({
			flight = hit.flight,
			endTime = CameraDirector.endTimeOf(hit),
			outcome = hit.outcome,
			elapsed = now - hit.flight.launch.launchTime,
		})
	end
	local showCounter = c ~= nil and c.kind ~= "Hidden" and phase ~= "Returning"
	counterAlpha = CameraMath.damp(counterAlpha, if showCounter then 1 else 0, hud.CounterFadeSeconds / 3, dt)
	if c and c.kind ~= "Hidden" then
		local value, unit = HitPresentation.distanceParts(c.meters)
		displayedMeters = c.meters
		counterCaption.Text = c.label
		counterNumber.Text = value
		counterUnit.Text = unit
		pillText.Text = c.tag
		pill.BackgroundColor3 = pillStyle(c)
		local final = c.kind == "Final" or c.kind == "Wall" or c.kind == "Tracked"
		counterNumber.TextColor3 = if c.kind == "Final" and c.fair then COLORS.gold elseif c.kind == "Confirming" then COLORS.muted else COLORS.text
		if final and lastCounterKind ~= c.kind then
			punchAt = os.clock()
		end
		lastCounterKind = c.kind
	elseif not showCounter then
		lastCounterKind = "Hidden"
		displayedMeters = nil
	end
	local punch = (os.clock() - punchAt) / hud.FinalPunchSeconds
	counterScale.Scale = if punch < 1 then 1 + (hud.FinalPunchScale - 1) * (1 - punch) ^ 2 else 1
	setGroup(counter, counterAlpha)

	-- Landing result cue (the result itself is in the Swing Analysis panel).
	if hit and phase == "Landed" and resultPlayedFor ~= hit then
		local landedFor = now - (hit.flight.launch.launchTime + CameraDirector.endTimeOf(hit))
		if landedFor >= hud.CardDelaySeconds and (hit.outcome ~= nil or landedFor >= PresentationConfig.Timing.LandingHoldSeconds) then
			resultPlayedFor = hit
			HitEffects.playResult()
		end
	end

	writeDebug(director, now, c)
end

function HitHud.start()
	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "HitHud"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = 6
	buildCounter()
	screenGui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	-- After the camera (Camera + 1) so the HUD reads this frame's state.
	RunService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Camera.Value + 5, onRender)
end

return HitHud
