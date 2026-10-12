--!strict
-- Batting visuals and audio: the bat (built from the exact collision
-- dimensions), the aim reticle, the hit-quality label, swing/miss sounds and
-- the contact marker. The contact burst, crack sounds and camera impulse are
-- HitEffects / BattingCamera (Stage 4), scaled by the contact intensity.
-- It holds no gameplay state; BattingController tells it what to show. All
-- animation is driven by elapsed time, never by frame count.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Pitching = Shared:WaitForChild("Pitching")
local LaneGeometry = require(Pitching.LaneGeometry)
local PitchConfig = require(Pitching.PitchConfig)
local Batting = Shared:WaitForChild("Batting")
local BattingConfig = require(Batting.BattingConfig)
local ContactQuality = require(Batting.ContactQuality)
local SwingModel = require(Batting.SwingModel)

local HitEffects = require(script.Parent.HitEffects)

local BattingPresentation = {}

local cfg = BattingConfig.Presentation

local LABEL_COLORS: { [string]: Color3 } = {
	Perfect = Color3.fromRGB(255, 214, 64),
	Great = Color3.fromRGB(110, 235, 120),
	Good = Color3.fromRGB(120, 200, 255),
	Weak = Color3.fromRGB(200, 200, 200),
	Miss = Color3.fromRGB(255, 95, 85),
}

type Effect = {
	update: (now: number) -> boolean, -- false = finished
	destroy: () -> (),
}

local folder: Folder
local screenGui: ScreenGui
local reticle: Frame
local reticleStroke: UIStroke
local barrelLine: Frame
local cursorDot: Frame
local zoneLines: { Frame } = {}
local label: TextLabel
local subLabel: TextLabel
local labelScale: UIScale
local labelShownAt = -math.huge
local labelSeconds = cfg.LabelSeconds
local batParts: { BasePart } = {}
local batCFrames: { CFrame } = {}
local batModel: Model? = nil
local effects: { Effect } = {}
local sounds: { [string]: Sound } = {}
local aimVisible = true

local function rgb(values: { number }): Color3
	return Color3.new(values[1], values[2], values[3])
end

local function newPart(name: string, shape: Enum.PartType, size: Vector3, color: Color3, material: Enum.Material): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Shape = shape
	part.Size = size
	part.Color = color
	part.Material = material
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	return part
end

local function newFrame(parent: Instance, name: string): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.BorderSizePixel = 0
	frame.BackgroundColor3 = rgb(cfg.ReticleColor)
	frame.Parent = parent
	return frame
end

local function placeLine(frame: Frame, a: Vector2, b: Vector2, thickness: number)
	local delta = b - a
	local mid = (a + b) / 2
	frame.Position = UDim2.fromOffset(mid.X, mid.Y)
	frame.Size = UDim2.fromOffset(delta.Magnitude, thickness)
	frame.Rotation = math.deg(math.atan2(delta.Y, delta.X))
end

local function makeSound(name: string, id: string, speed: number, volume: number): Sound
	local sound = Instance.new("Sound")
	sound.Name = name
	sound.SoundId = id
	sound.PlaybackSpeed = speed
	sound.Volume = volume
	sound.Parent = SoundService
	return sound
end

local function buildGui()
	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "BattingHud"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true -- viewport coordinates == GUI coordinates
	screenGui.DisplayOrder = 5

	for i = 1, 4 do
		local line = newFrame(screenGui, `ZoneEdge{i}`)
		line.BackgroundTransparency = cfg.ZoneOutlineTransparency
		line.Visible = false
		zoneLines[i] = line
	end

	barrelLine = newFrame(screenGui, "BarrelLine")
	barrelLine.BackgroundTransparency = 0.7
	barrelLine.Visible = false

	-- Hollow ring so the ball is never covered.
	reticle = newFrame(screenGui, "Reticle")
	reticle.BackgroundTransparency = 1
	reticle.Visible = false
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = reticle
	reticleStroke = Instance.new("UIStroke")
	reticleStroke.Thickness = cfg.ReticleThicknessPixels
	reticleStroke.Color = rgb(cfg.ReticleColor)
	reticleStroke.Transparency = 0.1
	reticleStroke.Parent = reticle
	local dot = newFrame(reticle, "Center")
	dot.Position = UDim2.fromScale(0.5, 0.5)
	dot.Size = UDim2.fromOffset(3, 3)

	cursorDot = newFrame(screenGui, "Cursor")
	cursorDot.Size = UDim2.fromOffset(5, 5)
	cursorDot.BackgroundTransparency = 0.5
	cursorDot.Visible = false
	local cursorCorner = Instance.new("UICorner")
	cursorCorner.CornerRadius = UDim.new(0.5, 0)
	cursorCorner.Parent = cursorDot

	label = Instance.new("TextLabel")
	label.Name = "Quality"
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.24)
	label.Size = UDim2.fromOffset(420, 56)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBlack
	label.TextSize = 44
	label.TextTransparency = 1
	label.Text = ""
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Transparency = 0.3
	stroke.Parent = label
	labelScale = Instance.new("UIScale")
	labelScale.Parent = label
	label.Parent = screenGui

	subLabel = Instance.new("TextLabel")
	subLabel.Name = "Detail"
	subLabel.AnchorPoint = Vector2.new(0.5, 0)
	subLabel.Position = UDim2.new(0.5, 0, 0.24, 30)
	subLabel.Size = UDim2.fromOffset(420, 24)
	subLabel.BackgroundTransparency = 1
	subLabel.Font = Enum.Font.GothamMedium
	subLabel.TextSize = 18
	subLabel.TextColor3 = Color3.new(1, 1, 1)
	subLabel.TextTransparency = 1
	subLabel.Text = ""
	local subStroke = Instance.new("UIStroke")
	subStroke.Thickness = 1.5
	subStroke.Transparency = 0.4
	subStroke.Parent = subLabel
	subLabel.Parent = screenGui

	screenGui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
end

function BattingPresentation.start()
	folder = Instance.new("Folder")
	folder.Name = "BattingVisuals"
	folder.Parent = Workspace
	buildGui()
	sounds.Swing = makeSound("BatSwing", cfg.SwingSoundId, cfg.SwingSoundSpeed, 0.5)
	sounds.Miss = makeSound("BatMiss", cfg.MissSoundId, cfg.MissSoundSpeed, 0.35)
end

-- (Re)builds the bat from the lane's collision dimensions.
function BattingPresentation.buildBat(dims: SwingModel.BatDimensions)
	if batModel then
		batModel:Destroy()
	end
	local barrelColor = rgb(cfg.BatBarrelColor)
	local handleColor = rgb(cfg.BatHandleColor)
	local model = Instance.new("Model")
	model.Name = "Bat"
	local handleLength = dims.barrelStart
	local barrelLength = dims.length - dims.barrelStart
	-- Capsules, exactly like BatCollision: cylinders plus spherical end caps.
	local parts: { BasePart } = {
		newPart("Handle", Enum.PartType.Cylinder, Vector3.new(handleLength, dims.handleRadius * 2, dims.handleRadius * 2), handleColor, Enum.Material.SmoothPlastic),
		newPart("Knob", Enum.PartType.Ball, Vector3.one * dims.handleRadius * 2.6, handleColor, Enum.Material.SmoothPlastic),
		newPart("Barrel", Enum.PartType.Cylinder, Vector3.new(barrelLength, dims.barrelRadius * 2, dims.barrelRadius * 2), barrelColor, Enum.Material.Wood),
		newPart("Tip", Enum.PartType.Ball, Vector3.one * dims.barrelRadius * 2, barrelColor, Enum.Material.Wood),
		newPart("Taper", Enum.PartType.Ball, Vector3.one * dims.barrelRadius * 2, barrelColor, Enum.Material.Wood),
	}
	for _, part in parts do
		part.Parent = model
	end
	model.Parent = folder
	batModel = model
	batParts = parts
	batCFrames = table.create(#parts, CFrame.identity)
end

function BattingPresentation.setBatPose(pose: SwingModel.Pose, dims: SwingModel.BatDimensions)
	if #batParts == 0 then
		return
	end
	local dir = pose.direction
	local frame = CFrame.fromMatrix(Vector3.zero, dir, pose.planeNormal)
	local split = pose.knob + dir * dims.barrelStart
	batCFrames[1] = frame + (pose.knob + split) / 2
	batCFrames[2] = frame + pose.knob
	batCFrames[3] = frame + (split + pose.tip) / 2
	batCFrames[4] = frame + pose.tip
	batCFrames[5] = frame + split
	Workspace:BulkMoveTo(batParts, batCFrames, Enum.BulkMoveMode.FireCFrameChanged)
end

function BattingPresentation.setVisible(visible: boolean)
	if batModel then
		batModel.Parent = if visible then folder else nil
	end
	screenGui.Enabled = visible
end

local function toScreen(camera: Camera, point: Vector3): (Vector2, boolean)
	local p, onScreen = camera:WorldToViewportPoint(point)
	return Vector2.new(p.X, p.Y), onScreen and p.Z > 0
end

-- Positions the reticle at the 3D aim point (projected, so it is exact at any
-- resolution / aspect ratio). `cursor` is shown when the aim is clamped.
function BattingPresentation.updateReticle(
	camera: Camera,
	geometry: LaneGeometry.Geometry,
	aimX: number,
	aimY: number,
	cursor: Vector2?
)
	local dims = SwingModel.dimensions(geometry)
	local world = SwingModel.aimToWorld(geometry, aimX, aimY)
	local center, visible = toScreen(camera, world)
	visible = visible and aimVisible
	reticle.Visible = visible
	if not visible then
		cursorDot.Visible = false
	end
	if not visible then
		barrelLine.Visible = false
		return
	end
	-- Physically sized: the ring's radius is the vertical reach of the barrel
	-- (barrel radius + ball radius) at the aim point.
	local ballRadius = geometry.units.toStuds(PitchConfig.Ball.RadiusMeters)
	local edge = toScreen(camera, world + geometry.up * (dims.barrelRadius + ballRadius))
	local diameter = math.max(cfg.ReticleMinPixels, (edge - center).Magnitude * 2 * cfg.ReticleScale)
	reticle.Position = UDim2.fromOffset(center.X, center.Y)
	reticle.Size = UDim2.fromOffset(diameter, diameter)

	if cfg.ShowBarrelLine then
		-- Where the barrel will be when square: barrel start -> tip.
		local across = geometry.right * -SwingModel.batterSideSign()
		local a = toScreen(camera, world - across * (dims.sweetSpot - dims.barrelStart))
		local b = toScreen(camera, world + across * (dims.length - dims.sweetSpot))
		placeLine(barrelLine, a, b, cfg.ReticleThicknessPixels)
		barrelLine.Visible = true
	end

	if cursor then
		cursorDot.Position = UDim2.fromOffset(cursor.X, cursor.Y)
		cursorDot.Visible = true
	else
		cursorDot.Visible = false
	end
end

function BattingPresentation.drawZone(camera: Camera, geometry: LaneGeometry.Geometry)
	if not cfg.ShowZoneOutline or not aimVisible then
		return
	end
	local plane = SwingModel.contactPlane(geometry)
	local hw = geometry.zoneWidth / 2
	local corners = {
		plane.point + geometry.right * -hw + geometry.up * geometry.zoneBottom,
		plane.point + geometry.right * hw + geometry.up * geometry.zoneBottom,
		plane.point + geometry.right * hw + geometry.up * geometry.zoneTop,
		plane.point + geometry.right * -hw + geometry.up * geometry.zoneTop,
	}
	for i = 1, 4 do
		local a, aVisible = toScreen(camera, corners[i])
		local b, bVisible = toScreen(camera, corners[i % 4 + 1])
		placeLine(zoneLines[i], a, b, 1)
		zoneLines[i].Visible = aVisible and bVisible
	end
end

-- `seconds` overrides how long the label stays up (default Presentation.LabelSeconds).
function BattingPresentation.showLabel(text: string, color: Color3, detail: string?, seconds: number?)
	label.Text = text
	label.TextColor3 = color
	subLabel.Text = detail or ""
	labelShownAt = os.clock()
	labelSeconds = seconds or cfg.LabelSeconds
end

function BattingPresentation.showContactLabel(contact: ContactQuality.ContactResult, geometry: LaneGeometry.Geometry)
	local units = geometry.units
	local parts = {}
	local timing = contact.timingErrorSeconds
	if timing then
		local ms = math.floor(math.abs(timing) * 1000 + 0.5)
		table.insert(parts, if ms <= 5 then "on time" else `{ms} ms {if timing < 0 then "early" else "late"}`)
	end
	local offCm = math.floor(math.abs(units.toMeters(contact.sweetSpotOffset)) * 100 + 0.5)
	table.insert(parts, if offCm <= 2 then "sweet spot" else `{offCm} cm off the sweet spot`)
	BattingPresentation.showLabel(`{string.upper(contact.label)}!`, LABEL_COLORS[contact.label], table.concat(parts, "  ·  "))
end

-- Headline and hint per miss reason. `amount` is seconds for Early/Late and
-- studs for the rest (see MissClassifier).
local MISS_HEADLINE: { [string]: string } = {
	Early = "TOO EARLY",
	Late = "TOO LATE",
	Over = "OVER THE BALL",
	Under = "UNDER THE BALL",
	Inside = "INSIDE",
	Outside = "OUTSIDE",
}

local function missDetail(reason: string, amount: number?, geometry: LaneGeometry.Geometry?): string
	local size = ""
	if amount then
		if reason == "Early" or reason == "Late" then
			size = string.format(" (~%d ms)", math.floor(amount * 1000 + 0.5))
		elseif geometry then
			size = string.format(" (~%d cm)", math.floor(geometry.units.toMeters(amount) * 100 + 0.5))
		end
	end
	if reason == "Early" then
		return "swing a little later" .. size
	elseif reason == "Late" then
		return "swing a little sooner" .. size
	elseif reason == "Over" then
		return "aim lower" .. size
	elseif reason == "Under" then
		return "aim higher" .. size
	elseif reason == "Inside" then
		return "pitch was closer to you" .. size
	end
	return "pitch was farther out" .. size
end

function BattingPresentation.showMissLabel(reason: string?, amount: number?, geometry: LaneGeometry.Geometry?)
	local headline = reason and MISS_HEADLINE[reason]
	if headline == nil or reason == nil then
		BattingPresentation.showLabel("MISS", LABEL_COLORS.Miss, nil)
		return
	end
	BattingPresentation.showLabel(headline, LABEL_COLORS.Miss, missDetail(reason, amount, geometry))
end

function BattingPresentation.playSwing()
	sounds.Swing:Play()
end

function BattingPresentation.playMiss()
	sounds.Miss:Play()
end

local function addEffect(effect: Effect)
	table.insert(effects, effect)
end

local function spawnMarker(position: Vector3, size: number)
	local marker = newPart("ContactMarker", Enum.PartType.Ball, Vector3.one * size, Color3.fromRGB(255, 80, 200), Enum.Material.Neon)
	marker.CFrame = CFrame.new(position)
	marker.Transparency = 0.15
	marker.Parent = folder
	local start = os.clock()
	addEffect({
		update = function(now)
			local f = (now - start) / cfg.ContactMarkerSeconds
			if f >= 1 then
				return false
			end
			marker.Transparency = 0.15 + 0.85 * f * f
			return true
		end,
		destroy = function()
			marker:Destroy()
		end,
	})
end

-- `intensity` (0..1, HitPresentation.intensity) scales the burst and picks the crack.
function BattingPresentation.playContact(contact: ContactQuality.ContactResult, geometry: LaneGeometry.Geometry, intensity: number, direction: Vector3?)
	HitEffects.playImpact(contact.contactPoint, contact.impactNormal, direction, intensity)
	spawnMarker(contact.contactPoint, geometry.units.toStuds(0.04))
end

-- Hides the aim reticle and zone outline (ball-follow camera); the bat and labels stay.
function BattingPresentation.setAimVisible(visible: boolean)
	if aimVisible == visible then
		return
	end
	aimVisible = visible
	if not visible then
		reticle.Visible = false
		barrelLine.Visible = false
		cursorDot.Visible = false
		for _, line in zoneLines do
			line.Visible = false
		end
	end
end

-- Per-frame animation of the label and effects.
function BattingPresentation.update()
	local now = os.clock()

	local age = now - labelShownAt
	local duration = labelSeconds
	if age <= duration then
		labelScale.Scale = 1 + 0.35 * math.max(0, 1 - age / 0.12) ^ 2
		local fade = math.clamp((age - (duration - 0.3)) / 0.3, 0, 1)
		label.TextTransparency = fade
		subLabel.TextTransparency = 0.15 + 0.85 * fade
	elseif label.TextTransparency < 1 then
		label.TextTransparency = 1
		subLabel.TextTransparency = 1
	end

	for i = #effects, 1, -1 do
		local effect = effects[i]
		if not effect.update(now) then
			effect.destroy()
			table.remove(effects, i)
		end
	end
end

return BattingPresentation
