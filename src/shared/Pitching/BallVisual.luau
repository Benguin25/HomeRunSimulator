--!strict
-- Purely visual baseball: a white sphere with a red figure-eight seam (so
-- spin is visible), a short trail and an optional soft ground shadow for
-- depth. All parts are anchored and non-interactive (no collisions, touches
-- or raycast hits), and are moved together each frame with BulkMoveTo, so
-- there is no physics jitter or ownership churn.
--
-- The seam is the classic two-lobe curve on a sphere
--   (a cos t + b cos 3t, a sin t - b sin 3t, 2 sqrt(ab) sin 2t), a + b = 1,
-- drawn as short thin segments lying on the surface.

local PitchConfig = require(script.Parent.PitchConfig)

local BallVisual = {}
BallVisual.__index = BallVisual

export type BallVisual = typeof(setmetatable(
	{} :: {
		model: Model,
		parts: { BasePart },
		offsets: { CFrame },
		trail: Trail,
		cframes: { CFrame },
		shadow: Part?,
	},
	BallVisual
))

local function color(rgb: { number }): Color3
	return Color3.new(rgb[1], rgb[2], rgb[3])
end

local function makePart(name: string, shape: Enum.PartType, size: Vector3, partColor: Color3): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Shape = shape
	part.Size = size
	part.Color = partColor
	part.Material = Enum.Material.SmoothPlastic
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.Massless = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	return part
end

-- diameter: rendered diameter in studs.
function BallVisual.new(diameter: number, parent: Instance): BallVisual
	local cfg = PitchConfig.Ball
	local model = Instance.new("Model")
	model.Name = "Baseball"

	local ball = makePart("Ball", Enum.PartType.Ball, Vector3.one * diameter, color(cfg.Color))
	ball.Parent = model
	model.PrimaryPart = ball

	local parts: { BasePart } = { ball }
	local offsets: { CFrame } = { CFrame.identity }

	if cfg.TextureId ~= "" then
		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = Enum.MeshType.Sphere
		mesh.TextureId = cfg.TextureId
		mesh.Parent = ball
	else
		local seamColor = color(cfg.SeamColor)
		local b = cfg.SeamShape
		local a = 1 - b
		local lift = math.sqrt(a * b) * 2
		local function seam(t: number): Vector3
			return Vector3.new(a * math.cos(t) + b * math.cos(3 * t), a * math.sin(t) - b * math.sin(3 * t), lift * math.sin(2 * t))
				* (diameter * 0.505)
		end
		local count = cfg.SeamSegments
		for i = 1, count do
			local p0 = seam((i - 1) / count * 2 * math.pi)
			local p1 = seam(i / count * 2 * math.pi)
			local mid = (p0 + p1) / 2
			local segment = makePart(
				`Seam{i}`,
				Enum.PartType.Block,
				Vector3.new(diameter * 0.075, diameter * 0.03, (p1 - p0).Magnitude * 1.15),
				seamColor
			)
			segment.Parent = model
			table.insert(parts, segment)
			table.insert(offsets, CFrame.lookAt(mid, p1, mid.Unit))
		end
	end

	local a0 = Instance.new("Attachment")
	a0.Position = Vector3.new(0, diameter * 0.35, 0)
	a0.Parent = ball
	local a1 = Instance.new("Attachment")
	a1.Position = Vector3.new(0, -diameter * 0.35, 0)
	a1.Parent = ball
	local trail = Instance.new("Trail")
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.Lifetime = cfg.TrailLifetime
	trail.FaceCamera = true
	trail.LightInfluence = 0
	trail.Color = ColorSequence.new(Color3.new(1, 1, 1))
	trail.Transparency = NumberSequence.new(0.55, 1)
	trail.WidthScale = NumberSequence.new(1, 0.2)
	trail.Enabled = false
	trail.Parent = ball

	local shadow: Part? = nil
	if cfg.ShadowEnabled then
		local disc = makePart("Shadow", Enum.PartType.Cylinder, Vector3.new(0.02, diameter * 1.5, diameter * 1.5), Color3.new(0, 0, 0))
		disc.Material = Enum.Material.SmoothPlastic
		disc.Transparency = 1
		disc.Parent = model
		shadow = disc
	end

	model.Parent = parent

	local self = setmetatable({
		model = model,
		parts = parts,
		offsets = offsets,
		trail = trail,
		cframes = table.create(#parts, CFrame.identity),
		shadow = shadow,
	}, BallVisual)
	return self
end

function BallVisual.setCFrame(self: BallVisual, cframe: CFrame)
	local cframes = self.cframes
	for i, offset in self.offsets do
		cframes[i] = cframe * offset
	end
	workspace:BulkMoveTo(self.parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
end

function BallVisual.setTrailEnabled(self: BallVisual, enabled: boolean)
	self.trail.Enabled = enabled
end

function BallVisual.setTransparency(self: BallVisual, transparency: number)
	for _, part in self.parts do
		part.Transparency = transparency
	end
end

-- Soft contact shadow on the ground under the ball (nil = hidden).
function BallVisual.setShadow(self: BallVisual, ground: Vector3?, opacity: number)
	local shadow = self.shadow
	if shadow == nil then
		return
	end
	if ground == nil or opacity <= 0.01 then
		shadow.Transparency = 1
		return
	end
	shadow.Transparency = 1 - opacity
	-- A cylinder's axis is its X: stand it on the ground plane.
	shadow.CFrame = CFrame.new(ground) * CFrame.Angles(0, 0, math.pi / 2)
end

function BallVisual.destroy(self: BallVisual)
	self.model:Destroy()
	table.clear(self.parts)
end

return BallVisual
