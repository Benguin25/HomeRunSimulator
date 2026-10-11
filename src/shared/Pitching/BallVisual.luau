--!strict
-- Purely visual baseball: a white sphere with two red seam bands (so spin is
-- visible) and a short trail. All parts are anchored and non-interactive
-- (no collisions, touches or raycast hits), and are moved together each frame
-- with BulkMoveTo, so there is no physics jitter or ownership churn.
--
-- The seam bands are cylinders slightly wider than the ball and very thin:
-- only their rims poke out of the sphere, which reads as stitching.

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
		local seamSize = Vector3.new(diameter * 0.06, diameter * 1.02, diameter * 1.02)
		-- Two bands at different tilts approximate the figure-eight seam.
		local seamOffsets = {
			CFrame.Angles(0, 0, math.rad(90)) * CFrame.Angles(math.rad(25), 0, 0),
			CFrame.Angles(0, math.rad(90), 0) * CFrame.Angles(0, 0, math.rad(25)),
		}
		for i, offset in seamOffsets do
			local seam = makePart(`Seam{i}`, Enum.PartType.Cylinder, seamSize, seamColor)
			seam.Parent = model
			table.insert(parts, seam)
			table.insert(offsets, offset)
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

	model.Parent = parent

	local self = setmetatable({
		model = model,
		parts = parts,
		offsets = offsets,
		trail = trail,
		cframes = table.create(#parts, CFrame.identity),
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

function BallVisual.destroy(self: BallVisual)
	self.model:Destroy()
	table.clear(self.parts)
end

return BallVisual
