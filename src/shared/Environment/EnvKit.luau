--!strict
-- Pure part-spec emitter for environment builders.
--
-- Builders describe geometry as plain specs (shape, CFrame, size, color,
-- material, collision); EnvironmentRealizer realizes them in Studio or on the client.
-- No Instances are created here, so a whole plan is deterministic and can be
-- validated (budgets, collision flags, sightlines) in Lune tests.
--
-- Collision contract: `collide = true` only makes a part walkable / camera
-- solid for characters. Environment parts are NEVER part of the authoritative
-- batted-ball landing set (WorldCollision uses explicit roots), so scenery can
-- never change a measured distance.

local Kit = {}
Kit.__index = Kit

export type Color = { number } -- { r, g, b } in 0..255

export type Sign = {
	text: string,
	color: Color,
	font: string?,
	background: Color?,
	face: string?, -- Enum.NormalId name, default "Front"
}

export type Spec = {
	shape: string, -- "Block" | "Wedge" | "Cylinder" | "Ball" | "Ellipsoid"
	cf: CFrame,
	size: Vector3,
	color: Color,
	material: string,
	collide: boolean,
	transparency: number,
	reflectance: number,
	shadow: boolean,
	sign: Sign?,
	tag: string?, -- runtime hook name (flags, scoreboard displays)
}

export type Chunk = {
	name: string,
	lod: number, -- 0 = always present; otherwise camera distance (studs) beyond the chunk bounds that hides it
	center: Vector3,
	radius: number,
	parts: { Spec },
}

export type Kit = typeof(setmetatable(
	{} :: {
		chunks: { Chunk },
		current: Chunk?,
		defaultCollide: boolean,
		seed: number,
		yieldFn: (() -> ())?,
	},
	Kit
))

function Kit.new(seed: number?): Kit
	return setmetatable({ chunks = {}, current = nil, defaultCollide = false, seed = seed or 1, yieldFn = nil }, Kit)
end

-- Cooperative pause point for long plans (the client passes a frame-budget
-- yield; tests and tools leave it nil).
function Kit.step(self: Kit)
	local fn = self.yieldFn
	if fn then
		fn()
	end
end

-- Starts a new chunk. Specs go to the current chunk until the next call.
function Kit.chunk(self: Kit, name: string, lod: number?): Kit
	local chunk: Chunk = { name = name, lod = lod or 0, center = Vector3.zero, radius = 0, parts = {} }
	table.insert(self.chunks, chunk)
	self.current = chunk
	return self
end

-- Switches back to an existing chunk (e.g. alternating massing and props).
function Kit.use(self: Kit, chunk: Chunk): Kit
	self.current = chunk
	return self
end

-- Walkable/camera-solid default for the following specs.
function Kit.solid(self: Kit, value: boolean): Kit
	self.defaultCollide = value
	return self
end

-- Deterministic pseudo-random in [0, 1) (no global RNG state shared with gameplay).
function Kit.rand(self: Kit): number
	-- Park-Miller minimal standard generator.
	self.seed = (self.seed * 16807) % 2147483647
	return (self.seed - 1) / 2147483646
end

function Kit.range(self: Kit, a: number, b: number): number
	return a + (b - a) * self:rand()
end

function Kit.pick<T>(self: Kit, list: { T }): T
	return list[math.floor(self:rand() * #list) + 1]
end

local function push(self: Kit, spec: Spec): Spec
	local chunk = self.current
	if not chunk then
		self:chunk("Default")
		chunk = self.current
	end
	table.insert((chunk :: Chunk).parts, spec)
	return spec
end

local function make(shape: string, cf: CFrame, size: Vector3, color: Color, material: string?, collide: boolean): Spec
	return {
		shape = shape,
		cf = cf,
		size = size,
		color = color,
		material = material or "SmoothPlastic",
		collide = collide,
		transparency = 0,
		reflectance = 0,
		shadow = true,
		sign = nil,
		tag = nil,
	}
end

function Kit.box(self: Kit, cf: CFrame, size: Vector3, color: Color, material: string?, collide: boolean?): Spec
	return push(self, make("Block", cf, size, color, material, if collide == nil then self.defaultCollide else collide))
end

-- Roblox WedgePart: full bottom (-Y) and back (+Z) faces, slope rising toward +Z.
function Kit.wedge(self: Kit, cf: CFrame, size: Vector3, color: Color, material: string?, collide: boolean?): Spec
	return push(self, make("Wedge", cf, size, color, material, if collide == nil then self.defaultCollide else collide))
end

-- Cylinder whose axis is the CFrame's X axis.
function Kit.cyl(
	self: Kit,
	cf: CFrame,
	length: number,
	diameter: number,
	color: Color,
	material: string?,
	collide: boolean?
): Spec
	return push(
		self,
		make(
			"Cylinder",
			cf,
			Vector3.new(length, diameter, diameter),
			color,
			material,
			if collide == nil then self.defaultCollide else collide
		)
	)
end

-- Vertical cylinder standing on `base` (axis = world up).
function Kit.post(self: Kit, base: Vector3, height: number, diameter: number, color: Color, material: string?): Spec
	return self:cyl(
		CFrame.new(base + Vector3.new(0, height / 2, 0)) * CFrame.Angles(0, 0, math.pi / 2),
		height,
		diameter,
		color,
		material
	)
end

-- Flat disc lying on the ground with its top at `top.Y`.
function Kit.disc(
	self: Kit,
	top: Vector3,
	diameter: number,
	thickness: number,
	color: Color,
	material: string?,
	collide: boolean?
): Spec
	return self:cyl(
		CFrame.new(top - Vector3.new(0, thickness / 2, 0)) * CFrame.Angles(0, 0, math.pi / 2),
		thickness,
		diameter,
		color,
		material,
		collide
	)
end

function Kit.ball(self: Kit, center: Vector3, diameter: number, color: Color, material: string?): Spec
	return push(self, make("Ball", CFrame.new(center), Vector3.one * diameter, color, material, false))
end

-- Ellipsoid (SpecialMesh Sphere fitted to the part size); never collides.
function Kit.ellipsoid(self: Kit, cf: CFrame, size: Vector3, color: Color, material: string?): Spec
	return push(self, make("Ellipsoid", cf, size, color, material, false))
end

-- Box spanning a -> b (centerline), e.g. beams, rails, poles, wires.
function Kit.beam(
	self: Kit,
	a: Vector3,
	b: Vector3,
	width: number,
	height: number,
	color: Color,
	material: string?,
	collide: boolean?
): Spec?
	local length = (b - a).Magnitude
	if length < 1e-3 then
		return nil
	end
	local up = if math.abs((b - a).Unit.Y) > 0.99 then Vector3.xAxis else Vector3.yAxis
	return self:box(
		CFrame.lookAt((a + b) / 2, b, up),
		Vector3.new(width, height, length),
		color,
		material,
		collide
	)
end

-- Solid triangle whose TOP face is the triangle a-b-c (two wedges).
function Kit.tri(
	self: Kit,
	a: Vector3,
	b: Vector3,
	c: Vector3,
	thickness: number,
	color: Color,
	material: string?,
	collide: boolean?
)
	local ab, ac, bc = b - a, c - a, c - b
	local abd, acd, bcd = ab:Dot(ab), ac:Dot(ac), bc:Dot(bc)
	-- Make bc the longest edge; a is then the apex of the altitude split.
	if abd > acd and abd > bcd then
		c, a = a, c
	elseif acd > bcd and acd > abd then
		a, b = b, a
	end
	ab, ac, bc = b - a, c - a, c - b
	if ab.Magnitude < 1e-4 or ac.Magnitude < 1e-4 or bc.Magnitude < 1e-4 then
		return
	end
	local right = ac:Cross(ab)
	if right.Magnitude < 1e-6 then
		return
	end
	right = right.Unit
	local up = bc:Cross(right).Unit
	local back = bc.Unit
	local height = math.abs(ab:Dot(up))
	if height < 1e-4 then
		return
	end
	-- Shift so the face toward world up lies on the triangle plane.
	local sink = if right.Y >= 0 then -right else right
	local offset = sink * thickness / 2
	local d1, d2 = math.abs(ab:Dot(back)), math.abs(ac:Dot(back))
	if d1 > 1e-4 then
		self:wedge(
			CFrame.fromMatrix((a + b) / 2 + offset, right, up, back),
			Vector3.new(thickness, height, d1),
			color,
			material,
			collide
		)
	end
	if d2 > 1e-4 then
		self:wedge(
			CFrame.fromMatrix((a + c) / 2 + offset, -right, up, -back),
			Vector3.new(thickness, height, d2),
			color,
			material,
			collide
		)
	end
end

-- Convex polygon (ordered points) as a triangle fan.
function Kit.poly(self: Kit, points: { Vector3 }, thickness: number, color: Color, material: string?, collide: boolean?)
	for i = 2, #points - 1 do
		self:tri(points[1], points[i], points[i + 1], thickness, color, material, collide)
	end
end

-- Text board: the text faces the board's Front (-Z) side.
function Kit.sign(
	self: Kit,
	cf: CFrame,
	size: Vector3,
	text: string,
	textColor: Color,
	background: Color,
	font: string?,
	material: string?
): Spec
	local spec = self:box(cf, size, background, material or "SmoothPlastic", false)
	spec.sign = { text = text, color = textColor, font = font or "GothamBlack", background = background }
	return spec
end

-- Rounds chunk bounds; call once after building.
function Kit.finish(self: Kit): { Chunk }
	for _, chunk in self.chunks do
		local x0, y0, z0 = math.huge, math.huge, math.huge
		local x1, y1, z1 = -math.huge, -math.huge, -math.huge
		for _, spec in chunk.parts do
			local p = spec.cf.Position
			local half = spec.size.Magnitude / 2
			x0, y0, z0 = math.min(x0, p.X - half), math.min(y0, p.Y - half), math.min(z0, p.Z - half)
			x1, y1, z1 = math.max(x1, p.X + half), math.max(y1, p.Y + half), math.max(z1, p.Z + half)
		end
		if #chunk.parts > 0 then
			local min, max = Vector3.new(x0, y0, z0), Vector3.new(x1, y1, z1)
			chunk.center = (min + max) / 2
			chunk.radius = (max - min).Magnitude / 2
		end
	end
	return self.chunks
end

function Kit.count(self: Kit): number
	local n = 0
	for _, chunk in self.chunks do
		n += #chunk.parts
	end
	return n
end

return Kit
