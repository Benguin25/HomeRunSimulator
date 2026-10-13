--!strict
-- Shared instance adapter; the same spec produces the same baked/runtime appearance.
local Kit = require(script.Parent.EnvKit)
local Realizer = {}

local function color(c: Kit.Color): Color3
	return Color3.fromRGB(c[1], c[2], c[3])
end

local materialCache: { [string]: Enum.Material } = {}
local function material(name: string): Enum.Material
	local m = materialCache[name]
	if not m then
		local ok, value = pcall(function()
			return (Enum.Material :: any)[name]
		end)
		m = if ok and value then value else Enum.Material.SmoothPlastic
		materialCache[name] = m
	end
	return m :: Enum.Material
end

local function font(name: string?): Enum.Font
	local ok, value = pcall(function()
		return (Enum.Font :: any)[name or "GothamBlack"]
	end)
	return if ok and value then value else Enum.Font.GothamBlack
end

function Realizer.create(spec: Kit.Spec, parent: Instance): BasePart
	local part: BasePart
	if spec.shape == "Wedge" then
		part = Instance.new("WedgePart")
	else
		local p = Instance.new("Part")
		if spec.shape == "Cylinder" then
			p.Shape = Enum.PartType.Cylinder
		elseif spec.shape == "Ball" then
			p.Shape = Enum.PartType.Ball
		end
		part = p
	end
	part.Anchored = true
	part.CanCollide = spec.collide
	part.CanQuery = spec.collide
	part.CanTouch = false
	part.CastShadow = spec.shadow
	-- Parts are capped at 2,048 studs; very large ellipsoids (hills, massifs)
	-- keep their shape by scaling the sphere mesh instead.
	local meshScale = 1
	if spec.shape == "Ellipsoid" then
		meshScale = math.max(1, math.ceil(math.max(spec.size.X, spec.size.Y, spec.size.Z) / 2048))
	end
	part.Size = spec.size / meshScale
	part.CFrame = spec.cf
	part.Color = color(spec.color)
	part.Material = material(spec.material)
	part.Transparency = spec.transparency
	part.Reflectance = spec.reflectance
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	if spec.shape == "Ellipsoid" then
		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = Enum.MeshType.Sphere
		mesh.Scale = Vector3.one * meshScale
		mesh.Parent = part
	end
	local sign = spec.sign
	if sign then
		local face = sign.face or "Front"
		local w = spec.size.X
		local h = if face == "Top" then spec.size.Z else spec.size.Y
		local gui = Instance.new("SurfaceGui")
		gui.Face = (Enum.NormalId :: any)[face] or Enum.NormalId.Front
		gui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
		gui.CanvasSize = Vector2.new(400, math.clamp(400 * h / math.max(w, 0.01), 40, 800))
		gui.LightInfluence = 1
		gui.Brightness = 1
		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(0.94, 0.86)
		label.Position = UDim2.fromScale(0.03, 0.07)
		label.BackgroundTransparency = 1
		label.TextScaled = true
		label.Font = font(sign.font)
		label.TextColor3 = color(sign.color)
		label.Text = sign.text
		label.Parent = gui
		gui.Parent = part
	end
	if spec.tag then
		part:SetAttribute("EnvironmentTag", spec.tag)
	end
	part.Parent = parent
	return part
end

return Realizer
