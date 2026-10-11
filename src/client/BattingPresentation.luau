--!strict
-- Batting visuals and audio: the bat (built from the exact collision
-- dimensions), the aim reticle, the hit-quality label, sounds, and small
-- impact effects. It holds no gameplay state; BattingController tells it what
-- to show. All animation is driven by elapsed time, never by frame count.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Pitching = Shared:WaitForChild("Pitching")
local BallVisual = require(Pitching.BallVisual)
local LaneGeometry = require(Pitching.LaneGeometry)
local PitchConfig = require(Pitching.PitchConfig)
local Batting = Shared:WaitForChild("Batting")
local BattingConfig = require(Batting.BattingConfig)
local ContactQuality = require(Batting.ContactQuality)
local SwingModel = require(Batting.SwingModel)

local BattingCamera = require(script.Parent.BattingCamera)

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
local batParts: { BasePart } = {}
local batCFrames: { CFrame } = {}
local batModel: Model? = nil
local effects: { Effect } = {}
local sounds: { [string]: Sound } = {}
local kickStart = -math.huge

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
	sounds.Contact = makeSound("BatContact", cfg.ContactSoundId, cfg.ContactSoundSpeed, 0.9)
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
	reticle.Visible = visible
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
	if not cfg.ShowZoneOutline then
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

function BattingPresentation.showLabel(text: string, color: Color3, detail: string?)
	label.Text = text
	label.TextColor3 = color
	subLabel.Text = detail or ""
	labelShownAt = os.clock()
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

local function spawnFlash(position: Vector3, size: number)
	local flash = newPart("ContactFlash", Enum.PartType.Ball, Vector3.one * size, Color3.new(1, 1, 0.85), Enum.Material.Neon)
	flash.CFrame = CFrame.new(position)
	flash.Parent = folder
	local start = os.clock()
	addEffect({
		update = function(now)
			local f = (now - start) / 0.12
			if f >= 1 then
				return false
			end
			flash.Size = Vector3.one * size * (1 + f * 2.5)
			flash.Transparency = 0.2 + 0.8 * f
			return true
		end,
		destroy = function()
			flash:Destroy()
		end,
	})
end

local function spawnSparks(position: Vector3, normal: Vector3, amount: number)
	local holder = newPart("Sparks", Enum.PartType.Block, Vector3.one * 0.05, Color3.new(1, 1, 1), Enum.Material.SmoothPlastic)
	holder.Transparency = 1
	local side = if math.abs(normal.Y) < 0.95 then Vector3.new(0, 1, 0):Cross(normal).Unit else Vector3.new(1, 0, 0)
	holder.CFrame = CFrame.fromMatrix(position, side, normal) -- +Y (Top) along the impact normal
	local emitter = Instance.new("ParticleEmitter")
	emitter.Rate = 0
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.SpreadAngle = Vector2.new(55, 55)
	emitter.Speed = NumberRange.new(10, 22)
	emitter.Lifetime = NumberRange.new(0.15, 0.35)
	emitter.Drag = 6
	emitter.LightEmission = 1
	emitter.Size = NumberSequence.new(0.12, 0)
	emitter.Color = ColorSequence.new(Color3.fromRGB(255, 240, 180))
	emitter.Parent = holder
	holder.Parent = folder
	emitter:Emit(amount)
	local start = os.clock()
	addEffect({
		update = function(now)
			return now - start < 0.6
		end,
		destroy = function()
			holder:Destroy()
		end,
	})
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

-- TEMPORARY (Phase 2): short fading deflection along the impact normal so a
-- hit reads as a hit. Phase 3 replaces this with the batted-ball solver.
local function spawnDeflection(geometry: LaneGeometry.Geometry, contact: ContactQuality.ContactResult)
	local deflection = cfg.TemporaryDeflection
	if not deflection.Enabled then
		return
	end
	local units = geometry.units
	local ball = PitchConfig.Ball
	local visual = BallVisual.new(units.toStuds(ball.RadiusMeters * 2) * ball.VisualScale, folder)
	visual:setTrailEnabled(true)
	local velocity = contact.impactNormal * math.max(contact.closingSpeed, 0) * deflection.SpeedScale
	local gravity = Vector3.new(0, -units.accelToStuds(9.81), 0)
	local origin = contact.ballCenter
	local start = os.clock()
	visual:setCFrame(CFrame.new(origin))
	addEffect({
		update = function(now)
			local t = now - start
			if t >= deflection.Seconds then
				return false
			end
			visual:setCFrame(CFrame.new(origin + velocity * t + gravity * (0.5 * t * t)))
			visual:setTransparency(math.clamp((t / deflection.Seconds - 0.6) / 0.4, 0, 1))
			return true
		end,
		destroy = function()
			visual:destroy()
		end,
	})
end

function BattingPresentation.playContact(contact: ContactQuality.ContactResult, geometry: LaneGeometry.Geometry)
	local units = geometry.units
	local strong = contact.label == "Perfect" or contact.label == "Great"
	local sound = sounds.Contact
	sound.Volume = 0.5 + 0.5 * contact.score
	sound.PlaybackSpeed = cfg.ContactSoundSpeed * (0.85 + 0.25 * contact.score)
	sound:Play()
	spawnFlash(contact.contactPoint, units.toStuds(0.08 + 0.08 * contact.score))
	spawnSparks(contact.contactPoint, contact.impactNormal, if strong then 18 else 8)
	spawnMarker(contact.contactPoint, units.toStuds(0.04))
	spawnDeflection(geometry, contact)
	if strong then
		kickStart = os.clock()
	end
end

-- Per-frame animation of the label, effects and camera kick.
function BattingPresentation.update()
	local now = os.clock()

	local age = now - labelShownAt
	local duration = cfg.LabelSeconds
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

	if kickStart > -math.huge then
		local kick = (now - kickStart) / cfg.CameraKickSeconds
		if kick < 1 then
			BattingCamera.setOffset(CFrame.Angles(math.rad(cfg.CameraKickDegrees) * (1 - kick) ^ 2, 0, 0))
		else
			BattingCamera.setOffset(CFrame.identity)
			kickStart = -math.huge
		end
	end
end

return BattingPresentation
