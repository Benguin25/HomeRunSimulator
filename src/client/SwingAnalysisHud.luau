--!strict
-- Swing Analysis panel (bottom-left): swing timing, contact placement and one
-- coaching tip after every swing at a pitch, plus the hit's confirmed exit
-- velocity, launch angle and result. It replaces the old landing result card,
-- so there is one unified result surface.
--
-- Data: the server's SwingResult payload (timing error, aim, the ball's
-- crossing of the contact plane, contact factors, miss reason), the server's
-- launch record for EV/LA (only once the hit is confirmed) and the server's
-- landing outcome for distance. SwingAnalysis (pure) decides what to show.
--
-- Non-interactive (no Active surfaces: it never eats a swing click), hidden
-- while a menu is open, cleared when leaving the box or changing lanes, and
-- faded out late in the next windup so it never covers an incoming pitch.
-- H toggles a compact one-line layout.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Pitching = Shared:WaitForChild("Pitching")
local LaneGeometry = require(Pitching.LaneGeometry)
local PitchConfig = require(Pitching.PitchConfig)
local PitchNet = require(Pitching.PitchNet)
local BattingNet = require(Shared.Batting.BattingNet)
local SwingModel = require(Shared.Batting.SwingModel)
local Presentation = Shared:WaitForChild("Presentation")
local CameraMath = require(Presentation.CameraMath)
local HitPresentation = require(Presentation.HitPresentation)
local PresentationConfig = require(Presentation.PresentationConfig)
local SwingAnalysis = require(Presentation.SwingAnalysis)

local BattingCamera = require(script.Parent.BattingCamera)
local Input = require(script.Parent.InputCoordinator)
local PitchVisualController = require(script.Parent.PitchVisualController)
local HudStyle = require(script.Parent.HudStyle)

local Hud = {}

local cfg = PresentationConfig.SwingAnalysis
local hudCfg = PresentationConfig.Hud
local localPlayer = Players.LocalPlayer

local COLORS = {
	panel = HudStyle.Colors.panel,
	text = HudStyle.Colors.text,
	muted = HudStyle.Colors.muted,
	gold = HudStyle.Colors.gold,
	canvas = Color3.fromRGB(8, 11, 18),
	reticle = Color3.fromRGB(90, 220, 255),
	seam = Color3.fromRGB(205, 40, 40),
}
local TONE: { [string]: Color3 } = {
	Perfect = Color3.fromRGB(80, 225, 125),
	Good = Color3.fromRGB(190, 232, 90),
	Fair = Color3.fromRGB(255, 186, 60),
	Poor = Color3.fromRGB(255, 92, 92),
}

-- Timing meter geometry (pixels in the 200 x 128 timing canvas).
local FAN_DEGREES = 60
local BAT_PIXELS = 50
local PIVOT_Y = 50

type Entry = {
	laneId: string,
	pitchId: number,
	seq: number,
	hitId: number?,
	payload: BattingNet.SwingResultPayload,
	geometry: LaneGeometry.Geometry,
	showAt: number, -- os.clock
	shownAt: number?,
	exitSpeedMph: number?,
	launchAngleDegrees: number?,
	territory: ("Fair" | "Foul")?,
	distanceText: string?,
	resultHeadline: string?,
	personalBest: boolean,
	builtKey: string,
}

local gui: ScreenGui
local panel: CanvasGroup
local panelScale: UIScale
local header: TextLabel
local resultPill: Frame
local resultText: TextLabel
local handChip: TextLabel
local body: Frame
local timingCanvas: Frame
local timingBat: Frame? = nil
local timingLabel: TextLabel
local timingDetail: TextLabel
local timingPunch: UIScale
local placementCanvas: Frame
local placementDynamic: Frame
local placementText: TextLabel
local statsRow: Frame
local adviceText: TextLabel
local tipPill: Frame
local glow: UIStroke

local entry: Entry? = nil
local alpha = 0
local compact = false
local batAngleFrom, batAngleTo, batSweepAt = 0, 0, -math.huge
local punchAt = -math.huge

---------------------------------------------------------------------------
-- Small UI helpers
---------------------------------------------------------------------------

local function frame(parent: Instance, name: string, position: UDim2, size: UDim2, color: Color3, transparency: number): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.Position = position
	f.Size = size
	f.BackgroundColor3 = color
	f.BackgroundTransparency = transparency
	f.BorderSizePixel = 0
	f.Parent = parent
	return f
end

local function text(parent: Instance, name: string, value: string, size: number, color: Color3, font: Enum.Font?): TextLabel
	local t = Instance.new("TextLabel")
	t.Name = name
	t.BackgroundTransparency = 1
	t.Font = font or Enum.Font.GothamBold
	t.TextSize = size
	t.TextColor3 = color
	t.Text = value
	t.Parent = parent
	return t
end

local function round(parent: Instance, radius: number)
	HudStyle.corner(parent, radius)
end

local function stroke(parent: Instance, color: Color3, transparency: number, thickness: number): UIStroke
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Transparency = transparency
	s.Thickness = thickness
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = parent
	return s
end

-- A bar from `a` to `b` (pixels in the parent).
local function segment(parent: Instance, name: string, a: Vector2, b: Vector2, thickness: number, color: Color3, transparency: number): Frame
	local d = b - a
	local f = frame(
		parent,
		name,
		UDim2.fromOffset((a.X + b.X) / 2, (a.Y + b.Y) / 2),
		UDim2.fromOffset(math.max(d.Magnitude, 1), thickness),
		color,
		transparency
	)
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Rotation = math.deg(math.atan2(d.Y, d.X))
	return f
end

-- A ray of `length` from `pivot`, rotated clockwise by `degrees` (0 = +x).
-- GuiObjects rotate about their center, so the bar is the outer half of a
-- centered container.
local function ray(parent: Instance, name: string, pivot: Vector2, length: number, thickness: number, degrees: number): (Frame, Frame)
	local holder = frame(parent, name, UDim2.fromOffset(pivot.X, pivot.Y), UDim2.fromOffset(length * 2, thickness), Color3.new(), 1)
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Rotation = degrees
	local bar = frame(holder, "Bar", UDim2.fromScale(0.5, 0), UDim2.fromScale(0.5, 1), Color3.new(1, 1, 1), 0)
	return holder, bar
end

local function circle(parent: Instance, name: string, center: Vector2, diameter: number, color: Color3, transparency: number): Frame
	local f = frame(parent, name, UDim2.fromOffset(center.X, center.Y), UDim2.fromOffset(diameter, diameter), color, transparency)
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0.5, 0)
	c.Parent = f
	return f
end

local function clearChildren(parent: Instance, keep: { [any]: boolean }?)
	for _, child in parent:GetChildren() do
		if not child:IsA("UIBase") and not (keep and keep[child]) then
			child:Destroy()
		end
	end
end

---------------------------------------------------------------------------
-- Static layout
---------------------------------------------------------------------------

local function bandTone(position: number): string
	local range = cfg.MeterRangeFraction
	local size = math.abs(position) * range
	if size <= cfg.PerfectFraction then
		return "Perfect"
	elseif size <= cfg.GoodFraction then
		return "Good"
	elseif size <= 1 then
		return "Fair"
	end
	return "Poor"
end

local function sectionTitle(parent: Instance, value: string, x: number)
	local t = text(parent, "Title", value, 11, COLORS.muted)
	t.Position = UDim2.fromOffset(x, 42)
	t.Size = UDim2.fromOffset(200, 14)
	t.TextXAlignment = Enum.TextXAlignment.Left
end

local function buildPanel()
	panel = Instance.new("CanvasGroup")
	panel.Name = "SwingAnalysis"
	panel.AnchorPoint = Vector2.new(0, 1)
	panel.Position = UDim2.new(0, 16, 1, -70)
	panel.Size = UDim2.fromOffset(440, 262)
	panel.BackgroundColor3 = COLORS.panel
	panel.BackgroundTransparency = 0.16
	panel.BorderSizePixel = 0
	panel.GroupTransparency = 1
	panel.Visible = false
	panel.Active = false
	round(panel, 14)
	glow = stroke(panel, Color3.new(1, 1, 1), 0.86, 1)
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Transparency = NumberSequence.new(0, 0.2)
	gradient.Parent = panel
	panelScale = Instance.new("UIScale")
	panelScale.Parent = panel
	panel.Parent = gui

	-- Header: accent slash, title, batter hand, result pill.
	local accent = frame(panel, "Accent", UDim2.fromOffset(12, 10), UDim2.fromOffset(5, 20), COLORS.gold, 0)
	accent.Rotation = 12
	round(accent, 2)
	header = text(panel, "Header", "SWING ANALYSIS", 15, COLORS.text, Enum.Font.GothamBlack)
	header.Position = UDim2.fromOffset(24, 9)
	header.Size = UDim2.fromOffset(170, 22)
	header.TextXAlignment = Enum.TextXAlignment.Left
	handChip = text(panel, "Hand", "RHB", 11, COLORS.muted)
	handChip.Position = UDim2.fromOffset(180, 12)
	handChip.Size = UDim2.fromOffset(34, 16)
	handChip.BackgroundTransparency = 0.88
	handChip.BackgroundColor3 = Color3.new(1, 1, 1)
	round(handChip, 6)
	resultPill = frame(panel, "Result", UDim2.new(1, -12, 0, 9), UDim2.fromOffset(190, 22), TONE.Poor, 0.1)
	resultPill.AnchorPoint = Vector2.new(1, 0)
	round(resultPill, 11)
	resultText = text(resultPill, "Text", "", 12, Color3.fromRGB(14, 18, 28), Enum.Font.GothamBlack)
	resultText.Size = UDim2.fromScale(1, 1)

	body = frame(panel, "Body", UDim2.fromOffset(0, 0), UDim2.fromScale(1, 1), Color3.new(), 1)
	sectionTitle(body, "SWING TIMING", 16)
	sectionTitle(body, "CONTACT PLACEMENT", 228)

	-- Timing: a top-down plate with the bat's position when the ball arrived.
	timingCanvas = frame(body, "Timing", UDim2.fromOffset(14, 58), UDim2.fromOffset(200, 128), COLORS.canvas, 0.35)
	round(timingCanvas, 10)
	timingCanvas.ClipsDescendants = true
	timingLabel = text(timingCanvas, "Label", "", 15, COLORS.text, Enum.Font.GothamBlack)
	timingLabel.AnchorPoint = Vector2.new(0.5, 1)
	timingLabel.Position = UDim2.new(0.5, 0, 1, -17)
	timingLabel.Size = UDim2.fromOffset(180, 18)
	timingLabel.ZIndex = 5
	timingPunch = Instance.new("UIScale")
	timingPunch.Parent = timingLabel
	timingDetail = text(timingCanvas, "Detail", "", 11, COLORS.muted)
	timingDetail.AnchorPoint = Vector2.new(0.5, 1)
	timingDetail.Position = UDim2.new(0.5, 0, 1, -4)
	timingDetail.Size = UDim2.fromOffset(180, 14)
	timingDetail.ZIndex = 5

	-- Placement: the strike zone seen from the batting camera.
	placementCanvas = frame(body, "Placement", UDim2.fromOffset(226, 58), UDim2.fromOffset(200, 128), COLORS.canvas, 0.35)
	round(placementCanvas, 10)
	placementCanvas.ClipsDescendants = true
	placementDynamic = frame(placementCanvas, "Dynamic", UDim2.fromScale(0, 0), UDim2.fromScale(1, 1), Color3.new(), 1)
	placementText = text(placementCanvas, "Call", "", 11, COLORS.muted)
	placementText.AnchorPoint = Vector2.new(0.5, 1)
	placementText.Position = UDim2.new(0.5, 0, 1, -4)
	placementText.Size = UDim2.fromOffset(190, 14)
	placementText.ZIndex = 5

	statsRow = frame(body, "Stats", UDim2.fromOffset(14, 194), UDim2.new(1, -28, 0, 28), Color3.new(), 1)
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.Padding = UDim.new(0, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = statsRow

	tipPill = frame(panel, "Tip", UDim2.new(0, 14, 1, -34), UDim2.fromOffset(34, 20), COLORS.gold, 0)
	round(tipPill, 6)
	local tip = text(tipPill, "Text", "TIP", 11, Color3.fromRGB(14, 18, 28), Enum.Font.GothamBlack)
	tip.Size = UDim2.fromScale(1, 1)
	adviceText = text(panel, "Advice", "", 13, COLORS.text, Enum.Font.GothamMedium)
	adviceText.Position = UDim2.new(0, 56, 1, -40)
	adviceText.Size = UDim2.new(1, -68, 0, 32)
	adviceText.TextXAlignment = Enum.TextXAlignment.Left
	adviceText.TextYAlignment = Enum.TextYAlignment.Center
	adviceText.TextWrapped = true
end

---------------------------------------------------------------------------
-- Content
---------------------------------------------------------------------------

local function batterSide(geometry: LaneGeometry.Geometry): "Right" | "Left"
	return if geometry.inputs.batterSide == "Left" then "Left" else "Right"
end

local function buildTiming(report: SwingAnalysis.Report, side: "Right" | "Left")
	clearChildren(timingCanvas, { [timingLabel] = true, [timingDetail] = true })
	local right = side == "Right"
	local pivot = Vector2.new(if right then 50 else 150, PIVOT_Y)
	local base = if right then 0 else 180
	local function angleFor(position: number): number
		local m = position * FAN_DEGREES
		return if right then base + m else base - m
	end
	-- Home plate (top-down, pitcher at the top) and the batter's box line.
	local plate = frame(timingCanvas, "Plate", UDim2.fromOffset(100, PIVOT_Y - 4), UDim2.fromOffset(24, 14), Color3.new(1, 1, 1), 0.65)
	plate.AnchorPoint = Vector2.new(0.5, 0.5)
	local tipShape = frame(timingCanvas, "PlatePoint", UDim2.fromOffset(100, PIVOT_Y + 3), UDim2.fromOffset(17, 17), Color3.new(1, 1, 1), 0.65)
	tipShape.AnchorPoint, tipShape.Rotation = Vector2.new(0.5, 0.5), 45
	local boxX = if right then 20 else 180
	frame(timingCanvas, "Box", UDim2.fromOffset(boxX - 1, 12), UDim2.fromOffset(2, 76), Color3.new(1, 1, 1), 0.7)
	-- Colored fan: very early (bat out front) .. very late (behind).
	local steps = 40
	for i = 0, steps do
		local position = -1 + 2 * i / steps
		local _, bar = ray(timingCanvas, `Fan{i}`, pivot, BAT_PIXELS, 4, angleFor(position))
		bar.BackgroundColor3 = TONE[bandTone(position)]
		bar.BackgroundTransparency = 0.55
	end
	local pitcherArrow = text(timingCanvas, "ToPitcher", "TO PITCHER", 9, COLORS.muted)
	pitcherArrow.Position = UDim2.fromOffset(if right then 120 else 10, 4)
	pitcherArrow.Size = UDim2.fromOffset(70, 12)
	local timing = report.timing
	if timing then
		local holder, bar = ray(timingCanvas, "Bat", pivot, BAT_PIXELS + 6, 7, angleFor(timing.position))
		bar.BackgroundColor3 = Color3.fromRGB(232, 196, 140)
		round(bar, 3)
		stroke(bar, Color3.fromRGB(60, 36, 16), 0.2, 1)
		holder.ZIndex = 4
		bar.ZIndex = 4
		timingBat = holder
		batAngleFrom = angleFor(1) -- the swing comes around from behind
		batAngleTo = angleFor(timing.position)
		batSweepAt = os.clock()
		circle(timingCanvas, "Hands", pivot, 10, Color3.fromRGB(214, 170, 128), 0).ZIndex = 5
		timingLabel.Text = timing.label
		timingLabel.TextColor3 = TONE[timing.tone]
		timingDetail.Text = timing.detail
		punchAt = os.clock()
	else
		timingBat = nil
		timingLabel.Text = "TIMING N/A"
		timingLabel.TextColor3 = COLORS.muted
		timingDetail.Text = "the pitch never reached your swing"
	end
end

local function buildPlacement(report: SwingAnalysis.Report, geometry: LaneGeometry.Geometry)
	clearChildren(placementDynamic)
	local placement = report.placement
	if not placement then
		placementText.Text = "no aim recorded"
		return
	end
	local scale = 112 -- pixels per meter
	local centerY = 0.775
	local function px(x: number, y: number): Vector2
		return Vector2.new(100 + x * scale, 64 - (y - centerY) * scale)
	end
	local m = geometry.units.metersPerStud
	local zoneW = geometry.zoneWidth * m
	local bottom, top = geometry.zoneBottom * m, geometry.zoneTop * m
	local a, b = px(-zoneW / 2, top), px(zoneW / 2, bottom)
	local zone = frame(placementDynamic, "Zone", UDim2.fromOffset(a.X, a.Y), UDim2.fromOffset(b.X - a.X, b.Y - a.Y), Color3.new(1, 1, 1), 0.94)
	stroke(zone, Color3.new(1, 1, 1), 0.35, 1.5)
	for i = 1, 2 do
		local x = a.X + (b.X - a.X) * i / 3
		local y = a.Y + (b.Y - a.Y) * i / 3
		frame(placementDynamic, `GridV{i}`, UDim2.fromOffset(x, a.Y), UDim2.fromOffset(1, b.Y - a.Y), Color3.new(1, 1, 1), 0.7)
		frame(placementDynamic, `GridH{i}`, UDim2.fromOffset(a.X, y), UDim2.fromOffset(b.X - a.X, 1), Color3.new(1, 1, 1), 0.7)
	end
	-- Batter's side marker.
	local side = placement.batterSide
	local sideX = if side == "Right" then 14 else 186
	local batter = frame(placementDynamic, "Batter", UDim2.fromOffset(sideX, 64), UDim2.fromOffset(10, 62), Color3.new(1, 1, 1), 0.82)
	batter.AnchorPoint = Vector2.new(0.5, 0.5)
	round(batter, 5)
	local batterLabel = text(placementDynamic, "BatterLabel", if side == "Right" then "R" else "L", 10, COLORS.muted)
	batterLabel.Position = UDim2.fromOffset(sideX - 6, 98)
	batterLabel.Size = UDim2.fromOffset(12, 12)

	-- The swing: barrel line at the aim height and the sweet-spot reticle.
	local dims = SwingModel.dimensions(geometry)
	local across = if side == "Left" then -1 else 1
	local aim = px(placement.aimX, placement.aimY)
	local barrelFrom = px(placement.aimX - across * (dims.sweetSpot - dims.barrelStart) * m, placement.aimY)
	local barrelTo = px(placement.aimX + across * (dims.length - dims.sweetSpot) * m, placement.aimY)
	segment(placementDynamic, "Barrel", barrelFrom, barrelTo, math.max(3, dims.barrelRadius * 2 * m * scale), COLORS.reticle, 0.6)
	local reach = (dims.barrelRadius * m + PitchConfig.Ball.RadiusMeters) * 2 * scale
	local reticle = circle(placementDynamic, "Reticle", aim, math.max(12, reach), COLORS.reticle, 1)
	stroke(reticle, COLORS.reticle, 0, 2)
	circle(placementDynamic, "AimDot", aim, 4, COLORS.reticle, 0)

	local calls = {}
	if placement.ballX and placement.ballY then
		local ball = px(placement.ballX, placement.ballY)
		local clamped = Vector2.new(math.clamp(ball.X, 6, 194), math.clamp(ball.Y, 6, 110))
		if (clamped - aim).Magnitude > 3 then
			segment(placementDynamic, "Miss", aim, clamped, 2, TONE[report.tone], 0.15)
		end
		local diameter = math.max(11, PitchConfig.Ball.RadiusMeters * 2 * PitchConfig.Ball.VisualScale * scale)
		local icon = circle(placementDynamic, "Ball", clamped, diameter, Color3.fromRGB(246, 244, 236), 0)
		stroke(icon, COLORS.seam, 0.1, 1.5)
		icon.ZIndex = 4
		if placement.vertical then
			table.insert(calls, if placement.vertical == "High" then "AIMED HIGH" else "AIMED LOW")
		end
		if placement.lateral then
			table.insert(calls, if placement.lateral == "Inside" then "AIMED INSIDE" else "AIMED OUTSIDE")
		end
		if #calls == 0 then
			table.insert(calls, "ON THE BALL")
		end
		if placement.offsetCm and placement.offsetCm > 0 then
			table.insert(calls, `{placement.offsetCm} CM`)
		end
	else
		table.insert(calls, "ball crossing unavailable")
	end
	placementText.Text = table.concat(calls, "  ·  ")
end

local function buildStats(report: SwingAnalysis.Report, best: boolean)
	clearChildren(statsRow)
	local rows = report.stats
	if #rows == 0 then
		local miss = text(statsRow, "NoContact", "NO CONTACT  ·  no exit velocity or launch angle", 12, COLORS.muted)
		miss.Size = UDim2.fromScale(1, 1)
		miss.TextXAlignment = Enum.TextXAlignment.Left
		return
	end
	for i, row in rows do
		local chip = frame(statsRow, `Stat{i}`, UDim2.new(), UDim2.fromOffset(0, 28), Color3.new(1, 1, 1), 0.92)
		chip.AutomaticSize = Enum.AutomaticSize.X
		chip.LayoutOrder = i
		round(chip, 8)
		local padding = Instance.new("UIPadding")
		padding.PaddingLeft, padding.PaddingRight = UDim.new(0, 8), UDim.new(0, 8)
		padding.Parent = chip
		local label = text(chip, "Text", "", 12, COLORS.text, Enum.Font.GothamBlack)
		label.RichText = true
		label.AutomaticSize = Enum.AutomaticSize.X
		label.Size = UDim2.fromOffset(0, 28)
		label.Text = `<font color="#AAB2C4" size="10">{row.label}</font>  {row.value}`
	end
	if best then
		local pb = frame(statsRow, "PersonalBest", UDim2.new(), UDim2.fromOffset(44, 28), COLORS.gold, 0)
		pb.LayoutOrder = #rows + 1
		round(pb, 8)
		local label = text(pb, "Text", "PB!", 13, Color3.fromRGB(14, 18, 28), Enum.Font.GothamBlack)
		label.Size = UDim2.fromScale(1, 1)
	end
end

local function reportFor(e: Entry): SwingAnalysis.Report
	local p = e.payload
	return SwingAnalysis.report({
		batterSide = batterSide(e.geometry),
		metersPerStud = e.geometry.units.metersPerStud,
		aimX = p.aimX,
		aimY = p.aimY,
		ballX = p.ballX,
		ballY = p.ballY,
		timingErrorSeconds = p.timingErrorSeconds,
		missReason = p.missReason,
		missAmount = p.missAmount,
		contact = p.contact :: any,
		exitSpeedMph = e.exitSpeedMph,
		launchAngleDegrees = e.launchAngleDegrees,
		territory = e.territory,
		distanceText = e.distanceText,
		resultHeadline = e.resultHeadline,
		personalBest = e.personalBest,
	})
end

local function rebuild(e: Entry, full: boolean)
	local report = reportFor(e)
	handChip.Text = if batterSide(e.geometry) == "Left" then "LHB" else "RHB"
	resultText.Text = report.headline
	resultPill.BackgroundColor3 = if e.territory == "Fair"
		then COLORS.gold
		elseif e.territory == "Foul" then Color3.fromRGB(160, 168, 184)
		else TONE[report.tone]
	adviceText.Text = report.advice
	if full then
		buildTiming(report, batterSide(e.geometry))
		buildPlacement(report, e.geometry)
	end
	buildStats(report, e.personalBest)
	glow.Color = if report.primary == "Perfect" then COLORS.gold else Color3.new(1, 1, 1)
	glow.Transparency = if report.primary == "Perfect" then 0.2 else 0.86
	e.builtKey = string.format(
		"%s|%s|%s|%s|%s",
		tostring(e.exitSpeedMph),
		tostring(e.launchAngleDegrees),
		tostring(e.distanceText),
		tostring(e.territory),
		tostring(e.personalBest)
	)
end

local function applyCompact()
	body.Visible = not compact
	panel.Size = if compact then UDim2.fromOffset(440, 82) else UDim2.fromOffset(440, 262)
end

---------------------------------------------------------------------------
-- Per frame
---------------------------------------------------------------------------

local function dismiss()
	entry = nil
end

-- Pulls the confirmed launch record and server outcome for a hit.
local function refreshHit(e: Entry)
	local hit = BattingCamera.getHit()
	if not hit or hit.laneId ~= e.laneId or hit.pitchId ~= e.pitchId or not hit.confirmed then
		return
	end
	e.exitSpeedMph = hit.flight.exitSpeedMph
	e.launchAngleDegrees = hit.flight.launchAngleDegrees
	local outcome = hit.outcome
	if outcome then
		local summary = HitPresentation.summary({ flight = hit.flight, outcome = outcome, contactLabel = hit.contactLabel })
		e.territory = if summary.tone == "Neutral" then nil else (outcome.territory :: any)
		e.resultHeadline = summary.headline
		e.distanceText = if summary.distanceValue then `{summary.distanceValue} {summary.distanceUnit or ""}` else nil
	end
end

local function onRender(dt: number)
	local camera = Workspace.CurrentCamera
	if camera then
		local size = camera.ViewportSize
		panelScale.Scale = math.clamp(
			math.min(size.X / hudCfg.ReferenceWidth, size.Y / hudCfg.ReferenceHeight),
			hudCfg.MinScale,
			hudCfg.MaxScale
		)
	end
	local e = entry
	local clock = os.clock()
	local laneId = localPlayer:GetAttribute(PitchNet.PlayerLaneAttribute)
	if e and (laneId ~= e.laneId or localPlayer:GetAttribute("BattingMode") ~= "Batting") then
		dismiss()
		e = nil
	end
	if e then
		local age = clock - e.showAt
		if age > (if e.hitId then cfg.MaxContactSeconds else cfg.MaxMissSeconds) then
			dismiss()
			e = nil
		else
			-- Fade out late in the next windup on this lane.
			local flight = PitchVisualController.getActiveFlight(e.laneId)
			if flight and flight.data.id > e.pitchId and Workspace:GetServerTimeNow() > flight.data.releaseTime - cfg.HideBeforeReleaseSeconds then
				dismiss()
				e = nil
			end
		end
	end
	local visible = false
	if e and clock >= e.showAt then
		if e.hitId then
			refreshHit(e)
		end
		if e.shownAt == nil then
			e.shownAt = clock
			rebuild(e, true)
		else
			local key = string.format(
				"%s|%s|%s|%s|%s",
				tostring(e.exitSpeedMph),
				tostring(e.launchAngleDegrees),
				tostring(e.distanceText),
				tostring(e.territory),
				tostring(e.personalBest)
			)
			if key ~= e.builtKey then
				rebuild(e, false)
			end
		end
		visible = not Input.isMenuOpen()
	end
	alpha = CameraMath.damp(alpha, if visible then 1 else 0, (if visible then cfg.InSeconds else cfg.OutSeconds) / 3, dt)
	panel.GroupTransparency = 1 - alpha
	panel.Visible = alpha > 0.01
	panel.Position = UDim2.new(0, 16 - 24 * (1 - alpha), 1, -70)

	-- Bat sweeps into its measured position; the timing call punches.
	local bat = timingBat
	if bat and bat.Parent then
		local f = CameraMath.easeOutCubic(math.clamp((clock - batSweepAt) / 0.35, 0, 1))
		bat.Rotation = batAngleFrom + (batAngleTo - batAngleFrom) * f
	end
	local punch = (clock - punchAt) / 0.25
	timingPunch.Scale = if punch < 1 then 1 + 0.3 * (1 - punch) ^ 2 else 1
end

---------------------------------------------------------------------------
-- API
---------------------------------------------------------------------------

-- Called by BattingController once the server answered a swing at a pitch
-- and the moment of contact / miss has come.
function Hud.present(payload: BattingNet.SwingResultPayload, geometry: LaneGeometry.Geometry)
	local laneId, pitchId = payload.laneId, payload.pitchId
	if not payload.accepted or laneId == nil or pitchId == nil then
		return
	end
	if not SwingAnalysis.supersedes(entry, { laneId = laneId, pitchId = pitchId, seq = payload.seq }) then
		return -- stale, duplicate or out of order
	end
	local contact = payload.contact ~= nil
	entry = {
		laneId = laneId,
		pitchId = pitchId,
		seq = payload.seq,
		hitId = if contact then payload.hitId else nil,
		payload = payload,
		geometry = geometry,
		showAt = os.clock() + (if contact then cfg.ContactDelaySeconds else cfg.MissDelaySeconds),
		shownAt = nil,
		exitSpeedMph = nil,
		launchAngleDegrees = nil,
		territory = nil,
		distanceText = nil,
		resultHeadline = nil,
		personalBest = false,
		builtKey = "",
	}
end

-- Session snapshot listener: marks a confirmed new personal best.
function Hud.onAward(hitId: number, newRecord: boolean)
	local e = entry
	if e and e.hitId == hitId and newRecord then
		e.personalBest = true
	end
end

function Hud.isShowing(): boolean
	return entry ~= nil
end

function Hud.start()
	gui = Instance.new("ScreenGui")
	gui.Name = "SwingAnalysisHud"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 6
	buildPanel()
	applyCompact()
	gui.Parent = localPlayer:WaitForChild("PlayerGui")
	local ok, key = pcall(function()
		return (Enum.KeyCode :: any)[cfg.CompactKey]
	end)
	if ok and key then
		UserInputService.InputBegan:Connect(function(input, processed)
			if not processed and input.KeyCode == key and UserInputService:GetFocusedTextBox() == nil then
				compact = not compact
				applyCompact()
			end
		end)
	end
	RunService:BindToRenderStep("SwingAnalysisHud", Enum.RenderPriority.Camera.Value + 5, onRender)
end

return Hud
