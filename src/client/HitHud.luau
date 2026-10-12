--!strict
-- Hit HUD: the live distance counter during the flight and the result card
-- at the landing. Reads the presented hit from BattingCamera's director each
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
local card: CanvasGroup
local cardHeadline: TextLabel
local cardNote: TextLabel
local cardDistanceLabel: TextLabel
local cardDistanceValue: TextLabel
local cardStats: Frame
local statLabels: { { label: TextLabel, value: TextLabel, frame: Frame } } = {}

local counterAlpha = 0
local cardAlpha = 0
local cardShownFor: any = nil -- the hit whose card is built
local cardShownAt = -math.huge
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

local function buildCard()
	card = panel("ResultCard", UDim2.fromOffset(440, 196), Vector2.new(0.5, 1), UDim2.new(0.5, 0, 1, -40))

	cardHeadline = label(card, "Headline", Enum.Font.GothamBlack, 26, COLORS.gold)
	cardHeadline.Position = UDim2.fromOffset(0, 14)
	cardHeadline.Size = UDim2.new(1, 0, 0, 28)

	cardNote = label(card, "Note", Enum.Font.GothamMedium, 13, COLORS.muted)
	cardNote.Position = UDim2.fromOffset(0, 42)
	cardNote.Size = UDim2.new(1, 0, 0, 16)

	cardDistanceLabel = label(card, "DistanceLabel", Enum.Font.GothamBold, 12, COLORS.muted)
	cardDistanceLabel.Position = UDim2.fromOffset(0, 64)
	cardDistanceLabel.Size = UDim2.new(1, 0, 0, 14)

	cardDistanceValue = label(card, "DistanceValue", Enum.Font.GothamBlack, 44, COLORS.text)
	cardDistanceValue.Position = UDim2.fromOffset(0, 78)
	cardDistanceValue.Size = UDim2.new(1, 0, 0, 46)
	cardDistanceValue.RichText = true

	cardStats = Instance.new("Frame")
	cardStats.Name = "Stats"
	cardStats.BackgroundTransparency = 1
	cardStats.AnchorPoint = Vector2.new(0.5, 1)
	cardStats.Position = UDim2.new(0.5, 0, 1, -14)
	cardStats.Size = UDim2.new(1, -28, 0, 50)
	cardStats.Parent = card
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Padding = UDim.new(0, 8)
	layout.Parent = cardStats

	for i = 1, 3 do
		local chip = Instance.new("Frame")
		chip.Name = `Stat{i}`
		chip.LayoutOrder = i
		chip.Size = UDim2.new(1 / 3, -6, 1, 0)
		chip.BackgroundColor3 = Color3.new(1, 1, 1)
		chip.BackgroundTransparency = 0.93
		chip.BorderSizePixel = 0
		corner(chip, 10)
		chip.Parent = cardStats
		local caption = label(chip, "Label", Enum.Font.GothamBold, 11, COLORS.muted)
		caption.Position = UDim2.fromOffset(0, 7)
		caption.Size = UDim2.new(1, 0, 0, 13)
		local value = label(chip, "Value", Enum.Font.GothamBlack, 19, COLORS.text)
		value.Position = UDim2.fromOffset(0, 21)
		value.Size = UDim2.new(1, 0, 0, 22)
		statLabels[i] = { label = caption, value = value, frame = chip }
	end
end

local function toneColor(tone: string): Color3
	if tone == "Fair" then
		return COLORS.gold
	elseif tone == "Foul" then
		return COLORS.foul
	end
	return COLORS.neutral
end

local function fillCard(summary: HitPresentation.Summary)
	cardHeadline.Text = summary.headline
	cardHeadline.TextColor3 = toneColor(summary.tone)
	cardNote.Text = summary.note or ""
	if summary.distanceValue then
		cardDistanceLabel.Text = summary.distanceLabel or ""
		cardDistanceValue.Text = `{summary.distanceValue}<font size="22" color="#AAB2C4"> {summary.distanceUnit or ""}</font>`
	else
		cardDistanceLabel.Text = ""
		cardDistanceValue.Text = ""
	end
	for i, slot in statLabels do
		local row = summary.rows[i]
		slot.frame.Visible = row ~= nil
		if row then
			slot.label.Text = row.label
			slot.value.Text = row.value
		end
	end
	local count = #summary.rows
	for _, slot in statLabels do
		slot.frame.Size = UDim2.new(1 / math.max(count, 1), -6, 1, 0)
	end
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

	-- Result card
	local showCard = false
	if hit and phase == "Landed" then
		local landedFor = now - (hit.flight.launch.launchTime + CameraDirector.endTimeOf(hit))
		local timing = PresentationConfig.Timing
		showCard = landedFor >= hud.CardDelaySeconds and (hit.outcome ~= nil or landedFor >= timing.LandingHoldSeconds)
		if showCard and cardShownFor ~= hit then
			cardShownFor = hit
			cardShownAt = os.clock()
			fillCard(HitPresentation.summary({ flight = hit.flight, outcome = hit.outcome, contactLabel = hit.contactLabel }))
			HitEffects.playResult()
		elseif showCard and hit.outcome and cardHeadline.Text == "RESULT UNAVAILABLE" then
			fillCard(HitPresentation.summary({ flight = hit.flight, outcome = hit.outcome, contactLabel = hit.contactLabel }))
		end
	end
	if showCard then
		local f = math.clamp((os.clock() - cardShownAt) / hud.CardInSeconds, 0, 1)
		cardAlpha = CameraMath.easeOutCubic(f)
		card.Position = UDim2.new(0.5, 0, 1, -40 + 18 * (1 - cardAlpha))
	else
		cardAlpha = CameraMath.damp(cardAlpha, 0, hud.CardOutSeconds / 3, dt)
		if cardAlpha <= 0.002 then
			cardShownFor = nil
		end
	end
	setGroup(card, cardAlpha)

	writeDebug(director, now, c)
end

function HitHud.start()
	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "HitHud"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = 6
	buildCounter()
	buildCard()
	screenGui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	-- After the camera (Camera + 1) so the HUD reads this frame's state.
	RunService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Camera.Value + 5, onRender)
end

return HitHud
