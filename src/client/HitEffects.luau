--!strict
-- Cosmetic hit feedback: the impact burst at the real contact point, the
-- tiered bat-crack sounds, the landing puff / thud and the optional flight
-- whoosh. Scaled by HitPresentation.intensity (measured contact properties),
-- never random in strength. Nothing here touches physics or timing.
--
-- Effects are animated by elapsed time from one render binding and destroy
-- themselves; sounds are created once and rate limited so rapid events never
-- stack up.

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PitchConfig = require(Shared:WaitForChild("Pitching"):WaitForChild("PitchConfig"))
local Presentation = Shared:WaitForChild("Presentation")
local HitPresentation = require(Presentation.HitPresentation)
local PresentationConfig = require(Presentation.PresentationConfig)

local HitEffects = {}

local BIND_NAME = "HitEffects"
local UP = Vector3.new(0, 1, 0)

type Effect = {
	update: (now: number) -> boolean, -- false = finished
	destroy: () -> (),
}

type SoundSpec = { Id: string, Volume: number, Speed: number }

local folder: Folder
local effects: { Effect } = {}
local sounds: { [string]: Sound } = {}
local lastPlayed: { [string]: number } = {}

local function studs(meters: number): number
	return meters / PitchConfig.Units.MetersPerStud
end

local function newPart(name: string, shape: Enum.PartType, size: Vector3, color: Color3): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Shape = shape
	part.Size = size
	part.Color = color
	part.Material = Enum.Material.Neon
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	return part
end

local function addEffect(effect: Effect)
	table.insert(effects, effect)
end

local function soundFor(key: string): Sound?
	local spec = (PresentationConfig.Sounds :: any)[key] :: SoundSpec?
	if spec == nil or spec.Id == "" then
		return nil
	end
	local existing = sounds[key]
	if existing then
		return existing
	end
	local sound = Instance.new("Sound")
	sound.Name = `Hit{key}`
	sound.SoundId = spec.Id
	sound.Parent = SoundService
	sounds[key] = sound
	return sound
end

-- Plays a configured sound (volume scaled by `gain`), at most once per MinGapSeconds.
local function play(key: string, gain: number?)
	local spec = (PresentationConfig.Sounds :: any)[key] :: SoundSpec?
	local sound = soundFor(key)
	if spec == nil or sound == nil then
		return
	end
	local now = os.clock()
	if now - (lastPlayed[key] or -math.huge) < PresentationConfig.Sounds.MinGapSeconds then
		return
	end
	lastPlayed[key] = now
	sound.Volume = spec.Volume * (gain or 1) * PresentationConfig.Sounds.MasterVolume
	sound.PlaybackSpeed = spec.Speed
	sound.TimePosition = 0
	sound:Play()
end

local function spawnFlash(position: Vector3, diameter: number, seconds: number)
	local flash = newPart("ImpactFlash", Enum.PartType.Ball, Vector3.one * diameter, Color3.new(1, 1, 0.88))
	flash.CFrame = CFrame.new(position)
	flash.Parent = folder
	local start = os.clock()
	addEffect({
		update = function(now)
			local f = (now - start) / seconds
			if f >= 1 then
				return false
			end
			flash.Size = Vector3.one * diameter * (1 + f * 2.2)
			flash.Transparency = 0.15 + 0.85 * f
			return true
		end,
		destroy = function()
			flash:Destroy()
		end,
	})
end

-- Thin expanding ring facing along `axis` (the ball's outgoing direction).
local function spawnRing(position: Vector3, axis: Vector3, maxDiameter: number, seconds: number)
	local ring = newPart("ImpactRing", Enum.PartType.Cylinder, Vector3.new(0.05, 0.1, 0.1), Color3.new(1, 0.96, 0.82))
	-- Cylinder axis = part X: point it along the travel direction.
	local side = if math.abs(axis:Dot(UP)) < 0.95 then axis:Cross(UP).Unit else Vector3.new(1, 0, 0)
	ring.CFrame = CFrame.fromMatrix(position, axis, side)
	ring.Parent = folder
	local start = os.clock()
	addEffect({
		update = function(now)
			local f = (now - start) / seconds
			if f >= 1 then
				return false
			end
			local eased = 1 - (1 - f) ^ 3
			local d = maxDiameter * (0.15 + 0.85 * eased)
			ring.Size = Vector3.new(0.04, d, d)
			ring.Transparency = 0.35 + 0.65 * f
			return true
		end,
		destroy = function()
			ring:Destroy()
		end,
	})
end

local function spawnParticles(
	position: Vector3,
	normal: Vector3,
	amount: number,
	color: Color3,
	speed: NumberRange,
	spread: number,
	lifetime: NumberRange,
	size: number
)
	if amount <= 0 then
		return
	end
	local holder = newPart("Burst", Enum.PartType.Block, Vector3.one * 0.05, Color3.new(1, 1, 1))
	holder.Transparency = 1
	local side = if math.abs(normal:Dot(UP)) < 0.95 then UP:Cross(normal).Unit else Vector3.new(1, 0, 0)
	holder.CFrame = CFrame.fromMatrix(position, side, normal) -- +Y (Top) along `normal`
	local emitter = Instance.new("ParticleEmitter")
	emitter.Rate = 0
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.SpreadAngle = Vector2.new(spread, spread)
	emitter.Speed = speed
	emitter.Lifetime = lifetime
	emitter.Drag = 6
	emitter.LightEmission = 0.6
	emitter.Size = NumberSequence.new(size, 0)
	emitter.Transparency = NumberSequence.new(0.1, 1)
	emitter.Color = ColorSequence.new(color)
	emitter.Parent = holder
	holder.Parent = folder
	emitter:Emit(amount)
	local start = os.clock()
	local life = lifetime.Max + 0.1
	addEffect({
		update = function(now)
			return now - start < life
		end,
		destroy = function()
			holder:Destroy()
		end,
	})
end

-- The bat-ball moment. `direction` = the ball's outgoing direction if known.
function HitEffects.playImpact(point: Vector3, normal: Vector3, direction: Vector3?, intensity: number)
	local cfg = PresentationConfig.Impact
	local tier = HitPresentation.tier(intensity)
	local diameter = studs(cfg.FlashMinMeters + (cfg.FlashMaxMeters - cfg.FlashMinMeters) * intensity)
	spawnFlash(point, diameter, cfg.FlashSeconds)
	if cfg.RingEnabled and tier ~= "Weak" then
		spawnRing(point, direction or normal, studs(cfg.RingMaxMeters * intensity), cfg.RingSeconds)
	end
	local sparks = if tier == "Crushed"
		then cfg.SparksCrushed
		elseif tier == "Solid" then cfg.SparksSolid
		else cfg.SparksWeak
	spawnParticles(
		point,
		normal,
		sparks,
		Color3.fromRGB(255, 236, 170),
		NumberRange.new(10 + 8 * intensity, 18 + 16 * intensity),
		50,
		NumberRange.new(0.12, 0.3),
		0.12
	)
	play(tier, 0.75 + 0.25 * intensity)
	if tier == "Crushed" then
		play("CrushedLayer")
	end
end

-- The first impact (server-confirmed point).
function HitEffects.playLanding(point: Vector3, kind: string, surface: string?)
	local cfg = PresentationConfig.Impact
	local wall = kind == "Obstacle"
	if cfg.LandingPuffEnabled then
		spawnParticles(
			point,
			UP,
			cfg.LandingPuffParticles,
			if wall then Color3.fromRGB(220, 220, 220) else Color3.fromRGB(196, 170, 120),
			NumberRange.new(4, 9),
			70,
			NumberRange.new(0.35, 0.7),
			0.5
		)
	end
	play(if wall or surface == "Ceiling" then "Wall" else "Landing")
end

function HitEffects.playResult()
	play("Result")
end

-- Optional looping whoosh parented to the ball (destroyed with it).
function HitEffects.attachWhoosh(ballPart: BasePart?)
	local spec = PresentationConfig.Sounds.Whoosh
	if ballPart == nil or spec.Id == "" then
		return
	end
	local sound = Instance.new("Sound")
	sound.Name = "Whoosh"
	sound.SoundId = spec.Id
	sound.Looped = true
	sound.Volume = spec.Volume * PresentationConfig.Sounds.MasterVolume
	sound.PlaybackSpeed = spec.Speed
	sound.RollOffMaxDistance = 300
	sound.Parent = ballPart
	sound:Play()
end

local function onRender()
	local now = os.clock()
	for i = #effects, 1, -1 do
		local effect = effects[i]
		if not effect.update(now) then
			effect.destroy()
			table.remove(effects, i)
		end
	end
end

function HitEffects.clear()
	for _, effect in effects do
		effect.destroy()
	end
	table.clear(effects)
end
function HitEffects.start()
	local shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
	local net = require(shared.Pitching.PitchNet)
	game:GetService("Players").LocalPlayer:GetAttributeChangedSignal(net.PlayerLaneAttribute):Connect(HitEffects.clear)
	folder = Instance.new("Folder")
	folder.Name = "HitEffects"
	folder.Parent = Workspace
	RunService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Camera.Value + 4, onRender)
end

-- Live effect count (debug / leak checks).
function HitEffects.count(): number
	return #effects
end

return HitEffects
