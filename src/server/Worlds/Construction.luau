--!strict
-- Small reusable primitives. Each primitive explicitly declares collision; cosmetic trim stays query-free.
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Worlds.WorldConfig)
local Build = {}
function Build.part(
	parent: Instance,
	name: string,
	size: Vector3,
	cf: CFrame,
	color: Color3,
	collidable: boolean,
	material: Enum.Material?
): Part
	local p = Instance.new("Part")
	p.Name, p.Size, p.CFrame, p.Color = name, size, cf, color
	p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch = true, collidable, collidable, false
	p.Material, p.TopSurface, p.BottomSurface =
		material or Enum.Material.SmoothPlastic, Enum.SurfaceType.Smooth, Enum.SurfaceType.Smooth
	p.CastShadow = collidable
	p.Parent = parent
	return p
end
function Build.ground(
	parent: Instance,
	frame: CFrame,
	x0: number,
	x1: number,
	z0: number,
	z1: number,
	y: number,
	color: Color3
)
	if x1 <= x0 or z1 <= z0 then
		return
	end
	local nx, nz = math.ceil((x1 - x0) / Config.TileStuds), math.ceil((z1 - z0) / Config.TileStuds)
	local dx, dz = (x1 - x0) / nx, (z1 - z0) / nz
	for ix = 1, nx do
		for iz = 1, nz do
			Build.part(
				parent,
				"LandingGround",
				Vector3.new(dx, 4, dz),
				frame * CFrame.new(x0 + (ix - 0.5) * dx, y - 2, z0 + (iz - 0.5) * dz),
				color,
				true,
				Enum.Material.Grass
			)
		end
	end
end
function Build.line(parent: Instance, frame: CFrame, a: Vector3, b: Vector3, width: number, color: Color3)
	local mid = (a + b) / 2
	Build.part(
		parent,
		"FieldStripe",
		Vector3.new(width, 0.05, (b - a).Magnitude),
		frame * CFrame.lookAt(mid, b),
		color,
		false
	)
end
function Build.sign(parent: Instance, frame: CFrame, position: Vector3, text: string, accent: Color3, width: number)
	local board = Build.part(
		parent,
		"BrandBoard",
		Vector3.new(width, width * 0.25, 2),
		frame * CFrame.new(position),
		Color3.fromRGB(13, 20, 35),
		true
	)
	local surface = Instance.new("SurfaceGui")
	surface.Face, surface.CanvasSize, surface.Parent = Enum.NormalId.Back, Vector2.new(800, 200), board
	local label = Instance.new("TextLabel")
	label.Size, label.BackgroundTransparency = UDim2.fromScale(1, 1), 1
	label.Font, label.TextScaled, label.TextColor3, label.Text = Enum.Font.GothamBlack, true, accent, text
	label.Parent = surface
end
function Build.marker(parent: Instance, name: string, position: Vector3): Part
	local p = Build.part(
		parent,
		name,
		Vector3.new(1, 0.2, 1),
		CFrame.new(position + Vector3.new(0, 0.1, 0)),
		Color3.new(1, 1, 1),
		false
	)
	p.Transparency = 1
	return p
end
return Build
