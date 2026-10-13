--!strict
-- Reusable building and prop archetypes. Each takes a CFrame on the ground
-- (LookVector = the facade direction, i.e. toward the street) and a detail
-- level: 2 = near (full trim), 1 = mid (massing + key trim), 0 = far (massing).
-- All visual (non-colliding) unless stated: buildings are never landing
-- surfaces, and big volumes never block the follow camera.

local Environment = script.Parent.Parent
local Config = require(Environment.EnvironmentConfig)
local Kit = require(Environment.EnvKit)

local A = {}

local P = Config.Palette
local rgb = Config.rgb

A.Siding = {
	rgb(238, 234, 222),
	rgb(196, 214, 196),
	rgb(176, 196, 214),
	rgb(240, 224, 172),
	rgb(228, 176, 156),
	rgb(206, 202, 194),
	rgb(168, 186, 170),
	rgb(222, 206, 184),
}
A.Roofs = { rgb(70, 72, 80), rgb(96, 70, 56), rgb(134, 70, 52), rgb(84, 92, 104), rgb(60, 62, 66) }
A.Brick = { rgb(152, 72, 52), rgb(130, 62, 48), rgb(170, 96, 70), rgb(116, 78, 64), rgb(184, 150, 120) }
A.Commercial = {
	rgb(232, 222, 200),
	rgb(196, 90, 70),
	rgb(90, 120, 150),
	rgb(214, 186, 120),
	rgb(120, 150, 120),
	rgb(240, 240, 236),
	rgb(170, 110, 90),
}
A.Awnings = { P.Red, P.Navy, rgb(40, 120, 80), rgb(230, 150, 40), rgb(110, 60, 120), rgb(40, 130, 170) }
A.Glass = {
	rgb(86, 124, 150),
	rgb(70, 110, 128),
	rgb(110, 140, 160),
	rgb(64, 96, 120),
	rgb(120, 150, 150),
	rgb(60, 80, 96),
	rgb(130, 150, 170),
	rgb(90, 130, 120),
}
A.Stone = { rgb(214, 204, 184), rgb(196, 184, 164), rgb(176, 110, 84), rgb(160, 160, 158), rgb(120, 112, 104) }
A.Cars = {
	rgb(200, 40, 40),
	rgb(240, 240, 240),
	rgb(30, 30, 34),
	rgb(60, 90, 160),
	rgb(150, 150, 156),
	rgb(240, 200, 60),
	rgb(40, 110, 80),
	rgb(110, 40, 40),
	rgb(220, 120, 40),
}
local WINDOW = rgb(54, 70, 86)

-- Gable roof (two wedges) over a w x d footprint, ridge along X.
function A.gable(k: Kit.Kit, cf: CFrame, w: number, d: number, h: number, color: Kit.Color, material: string?)
	-- WedgePart rises toward +Z: the -Z half rises to the ridge as-is, the +Z
	-- half is turned around.
	local half = d / 2 + 0.6
	k:wedge(cf * CFrame.new(0, h / 2, -half / 2), Vector3.new(w + 1.2, h, half), color, material or "RoofShingles", false)
	k:wedge(cf * CFrame.new(0, h / 2, half / 2) * CFrame.Angles(0, math.pi, 0), Vector3.new(w + 1.2, h, half), color, material or "RoofShingles", false)
end

function A.tree(k: Kit.Kit, base: Vector3, size: number, kind: string?)
	local trunkH = size * 0.45
	k:post(base, trunkH, math.max(0.6, size * 0.09), P.Trunk, "Wood").shadow = size > 12
	local leaf = if kind == "pine" then P.FoliageDark elseif k:rand() < 0.3 then P.FoliageLight else P.Foliage
	if kind == "pine" then
		k:ellipsoid(CFrame.new(base + Vector3.new(0, trunkH + size * 0.55, 0)), Vector3.new(size * 0.55, size * 1.4, size * 0.55), leaf, "LeafyGrass")
	else
		k:ellipsoid(CFrame.new(base + Vector3.new(0, trunkH + size * 0.35, 0)), Vector3.new(size, size * 0.85, size), leaf, "LeafyGrass")
	end
end

function A.car(k: Kit.Kit, cf: CFrame, color: Kit.Color?)
	local c = color or k:pick(A.Cars)
	k:box(cf * CFrame.new(0, 1.6, 0), Vector3.new(6.2, 2.2, 14), c, "SmoothPlastic", false).shadow = false
	k:box(cf * CFrame.new(0, 3.3, 0.8), Vector3.new(5.6, 1.8, 7), rgb(40, 50, 60), "Glass", false).shadow = false
	k:box(cf * CFrame.new(0, 0.75, 0), Vector3.new(6.4, 1.5, 11.6), rgb(26, 26, 28), "Rubber", false).shadow = false
end

function A.bus(k: Kit.Kit, cf: CFrame, color: Kit.Color, text: string?)
	k:box(cf * CFrame.new(0, 5, 0), Vector3.new(8.5, 8, 36), color, "SmoothPlastic", false)
	k:box(cf * CFrame.new(0, 6.2, 0), Vector3.new(8.7, 2.6, 32), rgb(40, 50, 60), "Glass", false)
	k:box(cf * CFrame.new(0, 1, 0), Vector3.new(8.7, 2, 30), rgb(26, 26, 28), "Rubber", false)
	if text then
		local s = k:box(cf * CFrame.new(-4.4, 3, 0) * CFrame.Angles(0, -math.pi / 2, 0), Vector3.new(22, 2, 0.1), color, "SmoothPlastic", false)
		s.sign = { text = text, color = P.White, font = "GothamBlack" }
	end
end

-- Standing pedestrian (3 parts): legs, shirt, head. Purely visual.
A.Skin = { rgb(255, 214, 178), rgb(234, 184, 146), rgb(198, 144, 106), rgb(150, 100, 70), rgb(104, 70, 50) }
A.Shirts = {
	P.Navy,
	P.Red,
	P.White,
	rgb(240, 196, 60),
	rgb(90, 160, 220),
	rgb(64, 132, 82),
	rgb(236, 128, 52),
	rgb(222, 110, 150),
	rgb(120, 120, 128),
}
function A.person(k: Kit.Kit, cf: CFrame)
	local legs = k:box(cf * CFrame.new(0, 1.1, 0), Vector3.new(1.3, 2.2, 0.8), k:pick({ rgb(40, 50, 80), rgb(60, 60, 64), rgb(120, 100, 80) }), "SmoothPlastic", false)
	legs.shadow = false
	k:box(cf * CFrame.new(0, 3.2, 0), Vector3.new(1.6, 2.0, 0.9), k:pick(A.Shirts), "SmoothPlastic", false).shadow = false
	k:ball((cf * CFrame.new(0, 4.75, 0)).Position, 1.1, k:pick(A.Skin), "SmoothPlastic").shadow = false
end

-- Utility cart used by the grounds crew.
function A.cart(k: Kit.Kit, cf: CFrame)
	k:box(cf * CFrame.new(0, 1.6, 0), Vector3.new(4.4, 1.6, 8), rgb(40, 110, 70), "SmoothPlastic", false)
	k:box(cf * CFrame.new(0, 2.8, 2.2), Vector3.new(4.4, 1, 3.4), rgb(40, 110, 70), "SmoothPlastic", false)
	k:box(cf * CFrame.new(0, 5.6, -0.6), Vector3.new(4.6, 0.3, 4.4), P.White, "SmoothPlastic", false)
	for _, x in { -2, 2 } do
		k:post((cf * CFrame.new(x, 2.4, -2.6)).Position, 3.2, 0.25, rgb(40, 40, 44), "Metal")
	end
	for _, z in { -2.6, 2.6 } do
		k:cyl(cf * CFrame.new(0, 0.8, z), 4.8, 1.6, rgb(26, 26, 28), "Rubber", false)
	end
	k:box(cf * CFrame.new(0, 2.1, -3.2), Vector3.new(4, 0.8, 2.2), rgb(150, 110, 80), "WoodPlanks", false)
end

function A.streetlight(k: Kit.Kit, base: Vector3, toward: Vector3)
	k:post(base, 18, 0.5, rgb(40, 44, 48), "Metal").shadow = false
	local dir = Vector3.new(toward.X, 0, toward.Z).Unit
	local top = base + Vector3.new(0, 18, 0)
	k:beam(top, top + dir * 5, 0.35, 0.35, rgb(40, 44, 48), "Metal", false)
	k:box(CFrame.lookAt(top + dir * 5.5 - Vector3.new(0, 0.3, 0), top + dir * 7), Vector3.new(1.4, 0.6, 2.4), rgb(240, 236, 220), "SmoothPlastic", false)
end

-- Single-family house with optional garage, porch and backyard details.
function A.house(k: Kit.Kit, cf: CFrame, lod: number)
	local w, d = k:range(24, 34), k:range(22, 28)
	local stories = if k:rand() < 0.55 then 2 else 1
	local h = stories * 11
	local siding = k:pick(A.Siding)
	local roof = k:pick(A.Roofs)
	k:box(cf * CFrame.new(0, h / 2, 0), Vector3.new(w, h, d), siding, "Plaster")
	A.gable(k, cf * CFrame.new(0, h, 0), w, d, k:range(7, 10), roof)
	if lod >= 1 then
		-- Door, window band, trim.
		k:box(cf * CFrame.new(w * 0.18, 3.6, -d / 2 - 0.1), Vector3.new(3.4, 7.2, 0.3), rgb(110, 60, 50), "Wood", false)
		for s = 1, stories do
			k:box(cf * CFrame.new(-w * 0.12, (s - 1) * 11 + 6, -d / 2 - 0.1), Vector3.new(w * 0.55, 3.6, 0.25), WINDOW, "Glass", false)
		end
	end
	if lod >= 2 then
		if k:rand() < 0.6 then
			-- Garage wing with driveway.
			local gw = 14
			k:box(cf * CFrame.new(w / 2 + gw / 2, 5, 2), Vector3.new(gw, 10, d - 4), siding, "Plaster", false)
			k:box(cf * CFrame.new(w / 2 + gw / 2, 10.3, 2), Vector3.new(gw + 0.8, 0.6, d - 3), roof, "RoofShingles", false)
			k:box(cf * CFrame.new(w / 2 + gw / 2, 3.8, -d / 2 + 1.9), Vector3.new(11, 7.6, 0.3), rgb(236, 236, 230), "SmoothPlastic", false)
			k:box(cf * CFrame.new(w / 2 + gw / 2, 0.08, -d / 2 - 9), Vector3.new(11, 0.16, 18), P.Sidewalk, "Concrete", false)
			if k:rand() < 0.5 then
				A.car(k, cf * CFrame.new(w / 2 + gw / 2, 0.15, -d / 2 - 9), nil)
			end
		else
			-- Front porch.
			k:box(cf * CFrame.new(0, 0.6, -d / 2 - 3), Vector3.new(w * 0.7, 1.2, 6), rgb(200, 196, 188), "WoodPlanks", false)
			k:box(cf * CFrame.new(0, 9.4, -d / 2 - 3), Vector3.new(w * 0.72, 0.6, 6.4), roof, "RoofShingles", false)
			for _, x in { -w * 0.33, w * 0.33 } do
				k:post((cf * CFrame.new(x, 1.2, -d / 2 - 5.6)).Position, 8, 0.6, P.White, "Wood")
			end
		end
		-- Backyard: pool, shed or play set.
		local r = k:rand()
		if r < 0.25 then
			local pool = k:box(cf * CFrame.new(-w * 0.15, 0.1, d / 2 + 16), Vector3.new(14, 0.2, 9), rgb(80, 190, 230), "Glass", false)
			pool.reflectance = 0.2
			k:box(cf * CFrame.new(-w * 0.15, 0.04, d / 2 + 16), Vector3.new(17, 0.12, 12), P.Sidewalk, "Concrete", false)
		elseif r < 0.5 then
			k:box(cf * CFrame.new(w * 0.3, 3.5, d / 2 + 18), Vector3.new(8, 7, 7), rgb(150, 110, 80), "WoodPlanks", false)
		elseif r < 0.65 then
			k:box(cf * CFrame.new(0, 3, d / 2 + 15), Vector3.new(9, 0.4, 4), rgb(220, 60, 50), "Plastic", false)
			k:post((cf * CFrame.new(-4, 0, d / 2 + 15)).Position, 6, 0.4, rgb(240, 200, 60), "Plastic")
			k:post((cf * CFrame.new(4, 0, d / 2 + 15)).Position, 6, 0.4, rgb(240, 200, 60), "Plastic")
		end
	end
	return w
end

-- Attached brick rowhouses along a street frontage of `length`.
function A.rowhouses(k: Kit.Kit, cf: CFrame, length: number, lod: number)
	local n = math.max(2, math.floor(length / 22))
	local w = length / n
	for i = 0, n - 1 do
		local x = -length / 2 + (i + 0.5) * w
		local h = k:pick({ 26, 30, 34 })
		local color = k:pick(A.Brick)
		k:box(cf * CFrame.new(x, h / 2, 0), Vector3.new(w - 0.2, h, 34), color, "Brick")
		k:box(cf * CFrame.new(x, h + 0.6, -0.6), Vector3.new(w + 0.2, 1.2, 35.4), P.Limestone, "Concrete", false)
		if lod >= 2 then
			for s = 0, math.floor(h / 11) - 1 do
				k:box(cf * CFrame.new(x, s * 11 + 7, -17.1), Vector3.new(w * 0.7, 4.2, 0.3), WINDOW, "Glass", false)
			end
			k:box(cf * CFrame.new(x - w * 0.25, 1, -19.2), Vector3.new(5, 2, 4.4), P.Limestone, "Concrete", false)
			k:box(cf * CFrame.new(x - w * 0.25, 4, -17.2), Vector3.new(3.4, 6.5, 0.3), rgb(60, 40, 34), "Wood", false)
		end
	end
end

-- Storefront building with awning and optional sign text.
function A.shop(k: Kit.Kit, cf: CFrame, w: number, lod: number, text: string?, floors: number?)
	local f = floors or (if k:rand() < 0.5 then 1 else 2)
	local h = 13 + (f - 1) * 11
	local color = k:pick(A.Commercial)
	k:box(cf * CFrame.new(0, h / 2, 0), Vector3.new(w, h, 40), color, if k:rand() < 0.4 then "Brick" else "Plaster")
	k:box(cf * CFrame.new(0, h + 0.8, 0), Vector3.new(w + 0.6, 1.6, 40.6), rgb(90, 90, 96), "Concrete", false)
	if lod >= 1 then
		k:box(cf * CFrame.new(0, 5, -20.1), Vector3.new(w * 0.8, 7, 0.3), rgb(70, 100, 120), "Glass", false).reflectance = 0.2
		-- Awning: high edge against the facade, sloping down toward the street.
		k:wedge(cf * CFrame.new(0, 11.4, -22.4), Vector3.new(w * 0.86, 2, 4.6), k:pick(A.Awnings), "Fabric", false)
	end
	if text and lod >= 1 then
		local s = k:box(cf * CFrame.new(0, h - 2.6, -20.25), Vector3.new(w * 0.8, 3.6, 0.2), rgb(30, 34, 40), "SmoothPlastic", false)
		s.sign = { text = text, color = rgb(250, 236, 200), font = "GothamBlack" }
	end
	if f >= 2 and lod >= 1 then
		for s = 1, f - 1 do
			k:box(cf * CFrame.new(0, 13 + (s - 1) * 11 + 5.5, -20.1), Vector3.new(w * 0.75, 4, 0.3), WINDOW, "Glass", false)
		end
	end
	return h
end

-- Mid-rise (4-9 floors) with window bands, cornice and rooftop details.
function A.midrise(k: Kit.Kit, cf: CFrame, w: number, d: number, floors: number, lod: number)
	local h = floors * 11 + 4
	local brick = k:rand() < 0.5
	local color = if brick then k:pick(A.Brick) else k:pick(A.Commercial)
	k:box(cf * CFrame.new(0, h / 2, 0), Vector3.new(w, h, d), color, if brick then "Brick" else "Concrete")
	if lod >= 1 then
		local bands = if lod >= 2 then floors else math.ceil(floors / 2)
		for s = 0, bands - 1 do
			local y = 9 + s * (h - 9) / bands
			k:box(cf * CFrame.new(0, y, 0), Vector3.new(w + 0.3, 3.6, d + 0.3), WINDOW, "Glass", false)
		end
		k:box(cf * CFrame.new(0, h + 0.8, 0), Vector3.new(w + 1.4, 1.6, d + 1.4), P.Limestone, "Concrete", false)
	end
	if lod >= 2 then
		local r = k:rand()
		if r < 0.35 then
			-- Classic rooftop water tower.
			local top = cf * CFrame.new(w * 0.2, h + 1.6, d * 0.15)
			for _, o in { Vector3.new(-2.4, 0, -2.4), Vector3.new(2.4, 0, -2.4), Vector3.new(-2.4, 0, 2.4), Vector3.new(2.4, 0, 2.4) } do
				k:post((top * CFrame.new(o)).Position, 7, 0.5, rgb(70, 60, 50), "Wood")
			end
			k:cyl(top * CFrame.new(0, 11, 0) * CFrame.Angles(0, 0, math.pi / 2), 8, 8, rgb(150, 110, 80), "WoodPlanks", false)
			k:ellipsoid(top * CFrame.new(0, 15.2, 0), Vector3.new(8.4, 3.2, 8.4), rgb(80, 70, 60), "Metal")
		elseif r < 0.8 then
			k:box(cf * CFrame.new(-w * 0.2, h + 3, d * 0.1), Vector3.new(8, 4.4, 6), rgb(170, 172, 176), "Metal", false)
			k:box(cf * CFrame.new(w * 0.25, h + 2.6, -d * 0.2), Vector3.new(5, 3.6, 5), rgb(150, 152, 156), "Metal", false)
		end
	end
	return h
end

-- Office tower with podium, set-backs and a crown style.
function A.tower(
	k: Kit.Kit,
	cf: CFrame,
	w: number,
	d: number,
	h: number,
	lod: number,
	crown: string?,
	glass: Kit.Color?,
	style: string?
)
	local kind = style or (if glass then "glass" else k:pick({ "glass", "glass", "glass", "stone", "round" }))
	local g = glass or (if kind == "stone" then k:pick(A.Stone) else k:pick(A.Glass))
	local podium = 22
	k:box(cf * CFrame.new(0, podium / 2, 0), Vector3.new(w + 16, podium, d + 16), rgb(196, 192, 184), "Concrete")
	local tiers = if h > 300 then 3 elseif h > 160 then 2 else 1
	local y = podium
	local tw, td = w, d
	local fractions = if tiers == 1 then { 1 } elseif tiers == 2 then { 0.7, 0.3 } else { 0.6, 0.25, 0.15 }
	for t = 1, tiers do
		local th = (h - podium) * fractions[t]
		if kind == "round" then
			k:cyl(cf * CFrame.new(0, y + th / 2, 0) * CFrame.Angles(0, 0, math.pi / 2), th, math.min(tw, td), g, "Glass", false).reflectance =
				0.12
		else
			local shaft =
				k:box(cf * CFrame.new(0, y + th / 2, 0), Vector3.new(tw, th, td), g, if kind == "stone" then "Concrete" else "Glass", false)
			shaft.reflectance = if kind == "stone" then 0 else 0.12
		end
		if kind == "stone" then
			-- Punched-window look: dark bands every few floors.
			local bands = math.max(2, math.floor(th / 44))
			for b = 0, bands - 1 do
				k:box(
					cf * CFrame.new(0, y + (b + 0.5) * th / bands, 0),
					Vector3.new(tw + 0.3, th / bands * 0.4, td + 0.3),
					rgb(60, 70, 84),
					"Glass",
					false
				)
			end
		elseif kind == "round" then
			k:cyl(cf * CFrame.new(0, y + th - 1, 0) * CFrame.Angles(0, 0, math.pi / 2), 2, math.min(tw, td) + 1, rgb(210, 214, 220), "Metal", false)
		elseif lod >= 1 then
			-- Vertical fins on the street face and two horizontal bands.
			for i = -1, 1 do
				k:box(cf * CFrame.new(i * tw / 3, y + th / 2, -td / 2 - 0.3), Vector3.new(1.2, th, 0.8), rgb(210, 214, 220), "Metal", false)
			end
			k:box(cf * CFrame.new(0, y + th - 1, 0), Vector3.new(tw + 1, 2, td + 1), rgb(210, 214, 220), "Metal", false)
		end
		y += th
		tw, td = tw * 0.78, td * 0.78
	end
	if crown == "spire" then
		k:post((cf * CFrame.new(0, y, 0)).Position, h * 0.18, 2, rgb(220, 224, 228), "Metal")
	elseif crown == "pyramid" then
		A.gable(k, cf * CFrame.new(0, y, 0), tw, td, h * 0.08, rgb(80, 120, 140), "Metal")
	elseif crown == "gold" then
		k:box(cf * CFrame.new(0, y + 6, 0), Vector3.new(tw * 0.9, 12, td * 0.9), rgb(232, 190, 80), "Foil", false)
		k:post((cf * CFrame.new(0, y + 12, 0)).Position, h * 0.12, 1.6, rgb(240, 210, 120), "Foil")
	elseif crown == "antenna" then
		k:box(cf * CFrame.new(0, y + 4, 0), Vector3.new(tw * 0.5, 8, td * 0.5), rgb(160, 164, 170), "Metal", false)
		k:post((cf * CFrame.new(tw * 0.1, y + 8, 0)).Position, h * 0.1, 0.8, rgb(200, 60, 60), "Metal")
	end
	return y
end

function A.warehouse(k: Kit.Kit, cf: CFrame, w: number, d: number, lod: number)
	local h = k:range(22, 34)
	local color = k:pick({ rgb(150, 156, 160), rgb(176, 160, 132), rgb(120, 130, 136), rgb(160, 90, 70), rgb(196, 196, 190) })
	k:box(cf * CFrame.new(0, h / 2, 0), Vector3.new(w, h, d), color, if k:rand() < 0.5 then "CorrodedMetal" else "Concrete")
	if lod >= 1 then
		-- Sawtooth roof lights.
		local teeth = math.max(2, math.floor(d / 24))
		for i = 0, teeth - 1 do
			k:wedge(cf * CFrame.new(0, h + 3, -d / 2 + (i + 0.5) * d / teeth), Vector3.new(w - 2, 6, d / teeth), rgb(110, 116, 122), "Metal", false)
		end
		for i = 0, math.floor(w / 26) - 1 do
			k:box(cf * CFrame.new(-w / 2 + 13 + i * 26, 7, -d / 2 - 0.2), Vector3.new(14, 14, 0.4), rgb(70, 74, 80), "DiamondPlate", false)
		end
	end
	return h
end

function A.billboard(k: Kit.Kit, cf: CFrame, text: string, bg: Kit.Color, fg: Kit.Color)
	for _, x in { -10, 10 } do
		k:post((cf * CFrame.new(x, 0, 0)).Position, 34, 1.4, rgb(90, 94, 100), "Metal")
	end
	k:box(cf * CFrame.new(0, 40, 0.6), Vector3.new(50, 14, 1), rgb(60, 64, 70), "Metal", false)
	local s = k:box(cf * CFrame.new(0, 40, 0), Vector3.new(48, 12.4, 0.3), bg, "SmoothPlastic", false)
	s.sign = { text = text, color = fg, font = "LuckiestGuy" }
	k:box(cf * CFrame.new(0, 33, -1), Vector3.new(48, 0.5, 2.4), rgb(60, 64, 70), "DiamondPlate", false)
end

function A.crane(k: Kit.Kit, base: Vector3, height: number, yaw: number)
	local yellow = rgb(240, 186, 40)
	k:box(CFrame.new(base + Vector3.new(0, height / 2, 0)), Vector3.new(4, height, 4), yellow, "Metal", false)
	local top = CFrame.new(base + Vector3.new(0, height, 0)) * CFrame.Angles(0, yaw, 0)
	k:box(top * CFrame.new(0, 2, -30), Vector3.new(3, 3, 90), yellow, "Metal", false)
	k:box(top * CFrame.new(0, 1.5, 22), Vector3.new(6, 5, 14), rgb(140, 140, 146), "Concrete", false)
	k:box(top * CFrame.new(0, 5, 0), Vector3.new(4.5, 6, 4.5), yellow, "Metal", false)
	k:beam((top * CFrame.new(0, 0, -64)).Position, (top * CFrame.new(0, -height * 0.5, -64)).Position, 0.2, 0.2, rgb(40, 40, 40), "Metal", false)
end

return A
