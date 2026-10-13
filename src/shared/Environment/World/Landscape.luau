--!strict
-- Everything beyond the town: ground cover, Bramble Bay, the estuary, Mirror
-- Lake, farm patchwork, forests, distant landmarks and a mountain ring that
-- closes the horizon in every direction. Built for distance: few, large,
-- simple parts whose silhouettes read through the atmosphere.
--
-- Distances: the deepest hit currently possible is ~3,200 ft (~3,500 studs).
-- Everything here is the scenic horizon for those flights and is ready for
-- future power scaling; the authoritative catchment underneath stays flat.

local Environment = script.Parent.Parent
local Config = require(Environment.EnvironmentConfig)
local Site = require(Environment.Site)
local Kit = require(Environment.EnvKit)
local RegionMap = require(Environment.RegionMap)
local A = require(script.Parent.Archetypes)
local Town = require(script.Parent.Town)

local Landscape = {}

local P = Config.Palette
local rgb = Config.rgb

-- Ground cover matches the authoritative Rookie catchment (WorldConfig.Rookie);
-- only the mountain ring stands beyond it, hiding the world edge.
Landscape.Extent = { u0 = -16000, u1 = 16000, v0 = -9000, v1 = 22000 }
Landscape.Water = -0.6
Landscape.Land = -0.68
Landscape.Estuary = { V = 12750, Width = 640 }
Landscape.Lake = { u = -4600, v = 7300, a = 1100, b = 700 }

local MEADOW = { rgb(96, 140, 70), rgb(104, 148, 74), rgb(88, 132, 66), rgb(112, 150, 80) }
local CROPS = {
	rgb(208, 182, 96),
	rgb(186, 160, 84),
	rgb(122, 160, 72),
	rgb(96, 136, 60),
	rgb(150, 116, 80),
	rgb(196, 196, 120),
	rgb(140, 170, 90),
}
local ROCK = { rgb(124, 120, 116), rgb(110, 108, 106), rgb(136, 128, 118), rgb(98, 100, 104) }

local function lm(id: string): (number, number)
	local l = assert(RegionMap.landmark(id), id)
	return RegionMap.landmarkStuds(l)
end

local function landTop(site: Site.Site, u: number, v: number, y: number): Vector3
	return Site.at(site, u, y, v)
end

local function inLake(u: number, v: number, margin: number): boolean
	local L = Landscape.Lake
	return ((u - L.u) / (L.a + margin)) ^ 2 + ((v - L.v) / (L.b + margin)) ^ 2 < 1
end

local function inEstuary(v: number, margin: number): boolean
	local E = Landscape.Estuary
	return math.abs(v - E.V) < E.Width / 2 + margin
end

-- Ground cover: tiles sized by distance (fields near the town, big tiles far).
local function ground(k: Kit.Kit, site: Site.Site)
	local E = Landscape.Extent
	k:chunk("LandGround", 0)
	local function tile(u0: number, u1: number, v0: number, v1: number, color: Kit.Color, material: string)
		k:box(
			Site.cf(site, (u0 + u1) / 2, Landscape.Land - 0.3, (v0 + v1) / 2),
			Vector3.new(u1 - u0, 0.6, v1 - v0),
			color,
			material,
			false
		)
	end
	local step = 2000
	for u = E.u0, E.u1 - 1, step do
		for v = E.v0, E.v1 - 1, step do
			local cu, cv = u + step / 2, v + step / 2
			local r = math.sqrt(cu * cu + cv * cv)
			local farmBand = r > 6800 and r < 10400 and math.abs(math.deg(math.atan2(cu, cv))) < 75
			if farmBand then
				-- Patchwork of 500-stud fields with a hedge line between rows.
				local fs = 500
				for fu = u, u + step - 1, fs do
					for fv = v, v + step - 1, fs do
						local fcu, fcv = fu + fs / 2, fv + fs / 2
						if not inLake(fcu, fcv, 0) and not Town.inWater(fcu, fcv) and not inEstuary(fcv, 0) then
							tile(fu, fu + fs, fv, fv + fs, k:pick(CROPS), if k:rand() < 0.5 then "Grass" else "Ground")
						else
							tile(fu, fu + fs, fv, fv + fs, k:pick(MEADOW), "Grass")
						end
					end
				end
			else
				local far = r > 15000
				tile(u, math.min(u + step, E.u1), v, math.min(v + step, E.v1), if far then rgb(84, 116, 70) else k:pick(MEADOW), "Grass")
			end
		end
	end
end

local function water(k: Kit.Kit, site: Site.Site)
	k:chunk("Water", 0)
	local function sheet(cf: CFrame, size: Vector3, shape: string)
		local s = if shape == "Ellipsoid"
			then k:ellipsoid(cf, size, P.Water, "Glass")
			else k:box(cf, size, P.Water, "Glass", false)
		s.reflectance = 0.25
		s.shadow = false
	end
	-- Bramble Bay: tiled sheet (parts are capped at 2,048 studs) + shoreline lobes.
	local b = Town.Bay
	for u = b.u0, b.u1 - 1, 2000 do
		for v = b.v0, b.v1 - 1, 2000 do
			local u1, v1 = math.min(u + 2000, b.u1), math.min(v + 2000, b.v1)
			sheet(Site.cf(site, (u + u1) / 2, Landscape.Water - 0.3, (v + v1) / 2), Vector3.new(u1 - u + 0.5, 0.6, v1 - v + 0.5), "Block")
		end
	end
	for i = 0, 4 do
		local u = b.u0 + (i + 0.5) * (b.u1 - b.u0) / 5
		sheet(Site.cf(site, u, Landscape.Water - 0.32, b.v0), Vector3.new((b.u1 - b.u0) / 4, 0.6, 900), "Ellipsoid")
	end
	sheet(Site.cf(site, b.u0, Landscape.Water - 0.32, (b.v0 + b.v1) / 2), Vector3.new(1300, 0.6, b.v1 - b.v0 - 600), "Ellipsoid")
	-- Estuary across the north, joining the bay.
	local E = Landscape.Estuary
	for u = Landscape.Extent.u0, Landscape.Extent.u1 - 1, 2000 do
		local wiggle = 160 * math.sin(u / 2600)
		sheet(Site.cf(site, u + 1000, Landscape.Water - 0.3, E.V + wiggle), Vector3.new(2020, 0.6, E.Width), "Block")
	end
	-- Channel joining the bay to the estuary (two sheets: 2,048-stud part cap).
	local c0, c1 = b.v1 - 100, E.V
	local cm = (c0 + c1) / 2
	sheet(Site.cf(site, 9000, Landscape.Water - 0.3, (c0 + cm) / 2), Vector3.new(1600, 0.6, cm - c0 + 2), "Block")
	sheet(Site.cf(site, 9000, Landscape.Water - 0.3, (cm + c1) / 2), Vector3.new(1600, 0.6, c1 - cm + 2), "Block")
	-- Mirror Lake.
	local L = Landscape.Lake
	sheet(Site.cf(site, L.u, Landscape.Water - 0.3, L.v), Vector3.new(2 * L.a, 0.6, 2 * L.b), "Ellipsoid")
	-- Sandy shore ring around the lake.
	k:ellipsoid(Site.cf(site, L.u, Landscape.Land - 0.25, L.v), Vector3.new(2 * L.a + 120, 0.6, 2 * L.b + 120), rgb(210, 196, 150), "Sand")
end

local function forests(k: Kit.Kit, site: Site.Site)
	k:chunk("Forests", 0)
	-- Canopy clumps: each "tree" here is a 60-140 stud mass that reads as forest.
	local clusters = {
		{ -9000, 4200, 1800, 22 },
		{ 9800, 3600, 1500, 18 },
		{ -11000, 9800, 2400, 26 },
		{ -2600, 9900, 900, 10 },
		{ 6500, 13800, 2200, 24 },
		{ -6000, 15200, 2600, 26 },
		{ 2500, 16200, 1800, 20 },
		{ 12500, 15500, 2400, 22 },
		{ -13500, 17000, 2600, 22 },
		{ 0, -5200, 2600, 22 },
		{ -6200, -3000, 2000, 18 },
		{ 6400, -3200, 2000, 18 },
	}
	for _, c in clusters do
		for _ = 1, c[4] do
			local a = k:rand() * math.pi * 2
			local d = math.sqrt(k:rand()) * c[3]
			local u, v = c[1] + math.cos(a) * d, c[2] + math.sin(a) * d
			if not inLake(u, v, 80) and not Town.inWater(u, v) and not inEstuary(v, 60) then
				local s = k:range(70, 150)
				local dark = k:rand() < 0.5
				k:ellipsoid(
					CFrame.new(landTop(site, u, v, s * 0.32)),
					Vector3.new(s, s * 0.8, s * k:range(0.8, 1.2)),
					if dark then P.FoliageDark else P.Foliage,
					"LeafyGrass"
				).shadow = false
			end
		end
	end
	-- Hedgerows and single trees along farm field edges.
	for _ = 1, 70 do
		local a = math.rad(k:range(-70, 70))
		local r = k:range(7000, 10200)
		local u, v = r * math.sin(a), r * math.cos(a)
		if not inLake(u, v, 60) and not Town.inWater(u, v) then
			k:ellipsoid(CFrame.new(landTop(site, u, v, 14)), Vector3.new(k:range(30, 50), 34, k:range(30, 50)), P.Foliage, "LeafyGrass").shadow = false
		end
	end
end

local function farms(k: Kit.Kit, site: Site.Site)
	k:chunk("Farms", 0)
	local function farmstead(u: number, v: number, yaw: number, big: boolean)
		local f = Site.cf(site, u, Landscape.Land, v, yaw)
		local s = if big then 1.6 else 1
		k:box(f * CFrame.new(0, 14 * s, 0), Vector3.new(40 * s, 28 * s, 60 * s), rgb(170, 50, 40), "WoodPlanks", false)
		A.gable(k, f * CFrame.new(0, 28 * s, 0) * CFrame.Angles(0, math.pi / 2, 0), 60 * s, 40 * s, 16 * s, rgb(70, 70, 76), "Metal")
		k:box(f * CFrame.new(0, 10 * s, -30.2 * s), Vector3.new(16 * s, 20 * s, 0.4), P.White, "WoodPlanks", false)
		for i, x in { 34, 46 } do
			k:cyl(f * CFrame.new(x * s, 26 * s, 10 * s) * CFrame.Angles(0, 0, math.pi / 2), 52 * s, (if i == 1 then 14 else 11) * s, rgb(200, 204, 208), "Metal", false)
			k:ellipsoid(f * CFrame.new(x * s, 52 * s, 10 * s), Vector3.new(14 * s, 8 * s, 14 * s), rgb(160, 164, 170), "Metal")
		end
		k:box(f * CFrame.new(-50 * s, 9 * s, 30 * s), Vector3.new(36 * s, 18 * s, 26 * s), P.White, "Plaster", false)
		A.gable(k, f * CFrame.new(-50 * s, 18 * s, 30 * s), 36 * s, 26 * s, 10 * s, rgb(90, 60, 50))
	end
	local bu, bv = lm("red_barn_farm")
	farmstead(bu, bv, 20, true)
	for _, p in { { -2000, 7600, -30 }, { 5200, 8800, 60 }, { -7400, 9600, 10 }, { 7800, 6600, 0 }, { -9800, 5600, 45 } } do
		if not Town.inWater(p[1], p[2]) then
			farmstead(p[1], p[2], p[3], false)
		end
	end
	-- Windmill Ridge: modern turbines on a low ridge.
	local wu, wv = lm("windmill_ridge")
	k:ellipsoid(Site.cf(site, wu, -40, wv, 40), Vector3.new(2600, 180, 900), rgb(104, 140, 76), "Grass")
	for i = -3, 3 do
		local tu, tv = wu + i * 330 * math.cos(math.rad(40)), wv - i * 330 * math.sin(math.rad(40))
		local base = landTop(site, tu, tv, 40)
		k:post(base, 230, 7, P.White, "SmoothPlastic").shadow = false
		local hub = CFrame.new(base + Vector3.new(0, 232, 0)) * CFrame.Angles(0, math.rad(-150), 0)
		k:box(hub, Vector3.new(9, 9, 22), P.White, "SmoothPlastic", false)
		for b = 0, 2 do
			k:box(hub * CFrame.new(0, 0, -11) * CFrame.Angles(0, 0, math.rad(b * 120 + i * 17)) * CFrame.new(0, 55, 0), Vector3.new(5, 110, 1.4), P.White, "SmoothPlastic", false).shadow = false
		end
	end
end

local function harbor(k: Kit.Kit, site: Site.Site)
	k:chunk("Harbor", 0)
	-- Container port cranes and quay along the bay's south-west shore.
	local pu, _ = lm("container_port")
	local quay = Site.cf(site, pu + 500, Landscape.Land, Town.Bay.v0 - 40, 0)
	k:box(quay * CFrame.new(0, 1.5, 0), Vector3.new(1800, 3, 80), rgb(150, 150, 146), "Concrete", false)
	for i = 0, 5 do
		local c = quay * CFrame.new(-750 + i * 300, 0, 0)
		for _, x in { -14, 14 } do
			for _, z in { -10, 18 } do
				k:box(c * CFrame.new(x, 60, z), Vector3.new(3, 120, 3), rgb(220, 70, 50), "Metal", false)
			end
		end
		k:box(c * CFrame.new(0, 122, 20), Vector3.new(34, 6, 150), rgb(220, 70, 50), "Metal", false)
		k:box(c * CFrame.new(0, 128, -30), Vector3.new(14, 10, 20), rgb(236, 236, 230), "Metal", false)
	end
	-- Ships at berth.
	for i = 0, 2 do
		local ship = quay * CFrame.new(-560 + i * 560, 0, 120) * CFrame.Angles(0, math.pi / 2, 0)
		k:box(ship * CFrame.new(0, 10, 0), Vector3.new(60, 22, 380), rgb(40, 60, 90), "Metal", false)
		k:box(ship * CFrame.new(0, 30, 150), Vector3.new(50, 30, 40), P.White, "Metal", false)
		for j = 0, 5 do
			k:box(ship * CFrame.new(0, 28, -140 + j * 46), Vector3.new(50, 16, 40), k:pick({ rgb(196, 60, 40), rgb(40, 110, 170), rgb(230, 170, 40), rgb(60, 140, 80) }), "CorrodedMetal", false)
		end
	end
	-- Harbor Rail Yard: long gravel beds with freight trains.
	local ru, rv = lm("harbor_rail_yard")
	local yard = Site.cf(site, ru, Landscape.Land, rv, 60)
	for t = 0, 7 do
		k:box(yard * CFrame.new(t * 22 - 77, 0.4, 0), Vector3.new(14, 1, 1500), rgb(120, 112, 100), "Pebble", false)
		k:box(yard * CFrame.new(t * 22 - 77, 1.1, 0), Vector3.new(6, 0.4, 1500), rgb(90, 80, 70), "Metal", false)
		if t % 2 == 0 then
			local cars = math.floor(k:range(6, 14))
			for i = 0, cars do
				k:box(yard * CFrame.new(t * 22 - 77, 7, -600 + i * 46), Vector3.new(11, 12, 42), k:pick({ rgb(150, 70, 50), rgb(60, 80, 100), rgb(170, 150, 90), rgb(70, 90, 70) }), "CorrodedMetal", false)
			end
		end
	end
end

local function monument(k: Kit.Kit, site: Site.Site)
	local u, v = lm("slugger_monument")
	k:chunk("SluggerMonument", 0)
	local f = Site.cf(site, u, Landscape.Land, v, 0)
	-- Plaza, pedestal, a giant bat leaning on a giant baseball.
	k:disc(f.Position + Vector3.new(0, 1, 0), 420, 1.6, rgb(206, 198, 180), "Limestone", false)
	k:box(f * CFrame.new(0, 20, 0), Vector3.new(160, 40, 160), rgb(196, 186, 168), "Limestone", false)
	k:ball((f * CFrame.new(-30, 40 + 95, 0)).Position, 190, P.White, "Leather")
	for _, sgn in { -1, 1 } do
		k:box(f * CFrame.new(-30 + sgn * 40, 135, -88) * CFrame.Angles(0, 0, math.rad(sgn * 25)), Vector3.new(6, 150, 4), P.Red, "SmoothPlastic", false)
	end
	k:cyl(f * CFrame.new(40, 160, 10) * CFrame.Angles(0, 0, math.rad(65)), 340, 34, rgb(196, 150, 96), "Wood", false)
	k:cyl(f * CFrame.new(-28, 300, 10) * CFrame.Angles(0, 0, math.rad(65)), 60, 18, rgb(60, 40, 30), "Wood", false)
	local s = k:box(f * CFrame.new(0, 20, -80.5), Vector3.new(120, 16, 0.6), rgb(160, 130, 70), "Foil", false)
	s.sign = { text = "SLUGGER MONUMENT", color = rgb(60, 40, 20), font = "GothamBlack" }
end

local function funPark(k: Kit.Kit, site: Site.Site)
	local u, v = lm("lucky_pier")
	k:chunk("LuckyPier", 0)
	local f = Site.cf(site, u, Landscape.Land, v, 0)
	k:box(f * CFrame.new(0, 2, 0), Vector3.new(900, 4, 700), rgb(190, 170, 130), "WoodPlanks", false)
	-- Ferris wheel (rim, spokes, cabins) facing the stadium.
	local wheel = f * CFrame.new(-200, 190, 0)
	for i = 0, 23 do
		local a = i * math.pi * 2 / 24
		local p0 = wheel * CFrame.new(math.cos(a) * 160, math.sin(a) * 160, 0)
		local p1 = wheel * CFrame.new(math.cos(a + math.pi / 12) * 160, math.sin(a + math.pi / 12) * 160, 0)
		k:beam(p0.Position, p1.Position, 4, 4, P.White, "Metal", false)
		if i % 2 == 0 then
			k:beam(wheel.Position, p0.Position, 2, 2, rgb(200, 200, 206), "Metal", false)
			k:box(p0 * CFrame.new(0, -10, 0), Vector3.new(14, 14, 14), k:pick({ P.Red, P.Yellow, P.Sky, rgb(60, 180, 100) }), "SmoothPlastic", false)
		end
	end
	for _, z in { -20, 20 } do
		for _, x in { -90, 90 } do
			k:beam((wheel * CFrame.new(0, 0, z)).Position, (f * CFrame.new(-200 + x, 4, z * 3)).Position, 6, 6, P.White, "Metal", false)
		end
	end
	-- Roller coaster: lift hill and loops sketched with beams on supports.
	local coaster = f * CFrame.new(180, 0, 60)
	local pts = {}
	for i = 0, 40 do
		local t = i / 40 * math.pi * 2
		table.insert(pts, coaster * CFrame.new(math.cos(t) * 200, 60 + 70 * math.sin(t * 3) + 50 * math.cos(t), math.sin(t) * 120))
	end
	for i = 1, #pts - 1 do
		k:beam(pts[i].Position, pts[i + 1].Position, 6, 2, P.Red, "Metal", false)
		if i % 3 == 0 then
			local p = pts[i].Position
			k:beam(p, Vector3.new(p.X, f.Position.Y + 4, p.Z), 2, 2, P.White, "Metal", false)
		end
	end
	-- Striped big-top tents.
	for i, p in { { 40, -220 }, { 260, -200 } } do
		k:post((f * CFrame.new(p[1], 4, p[2])).Position, 70, 3, P.White, "Metal")
		k:ellipsoid(f * CFrame.new(p[1], 40, p[2]), Vector3.new(130, 70, 130), if i == 1 then P.Red else P.Sky, "Fabric")
	end
	local s = k:box(f * CFrame.new(0, 60, -352), Vector3.new(220, 40, 2), P.Navy, "SmoothPlastic", false)
	s.sign = { text = "LUCKY PIER FUN PARK", color = P.Yellow, font = "LuckiestGuy" }
	for _, x in { -100, 100 } do
		k:post((f * CFrame.new(x, 4, -352)).Position, 80, 4, P.White, "Metal")
	end
end

local function bridge(k: Kit.Kit, site: Site.Site)
	local u, _ = lm("grand_span_bridge")
	local E = Landscape.Estuary
	local v = E.V + 160 * math.sin(u / 2600)
	k:chunk("GrandSpanBridge", 0)
	local span = E.Width + 900
	local f = Site.cf(site, u, Landscape.Land, v, 0)
	local deckY = 70
	k:box(f * CFrame.new(0, deckY, 0), Vector3.new(60, 6, span), rgb(110, 116, 124), "Metal", false)
	k:box(f * CFrame.new(0, deckY + 3.1, 0), Vector3.new(50, 0.4, span), rgb(60, 62, 68), "Asphalt", false)
	local red = rgb(196, 70, 50)
	local towerZ = { -E.Width / 2 + 40, E.Width / 2 - 40 }
	for _, z in towerZ do
		for _, x in { -28, 28 } do
			k:box(f * CFrame.new(x, 180, z), Vector3.new(10, 360, 12), red, "Metal", false)
		end
		k:box(f * CFrame.new(0, 350, z), Vector3.new(66, 10, 12), red, "Metal", false)
		k:box(f * CFrame.new(0, 210, z), Vector3.new(66, 8, 12), red, "Metal", false)
	end
	-- Main cables (catenary sketched in segments) and approach ramps.
	for _, x in { -28, 28 } do
		local prev: Vector3? = nil
		for i = 0, 24 do
			local t = i / 24
			local z = -span / 2 + t * span
			local zt = (z - towerZ[1]) / (towerZ[2] - towerZ[1])
			local y
			if z < towerZ[1] then
				y = deckY + 10 + (350 - deckY - 10) * (z + span / 2) / (towerZ[1] + span / 2)
			elseif z > towerZ[2] then
				y = deckY + 10 + (350 - deckY - 10) * (span / 2 - z) / (span / 2 - towerZ[2])
			else
				y = 110 + 240 * (2 * zt - 1) ^ 2
			end
			local p = (f * CFrame.new(x, y, z)).Position
			if prev then
				k:beam(prev, p, 2, 2, red, "Metal", false)
			end
			prev = p
		end
	end
	for _, z in { -span / 2 - 200, span / 2 + 200 } do
		local p0 = f * CFrame.new(0, deckY / 2, z * 0.86)
		k:wedge(p0 * (if z < 0 then CFrame.new() else CFrame.Angles(0, math.pi, 0)), Vector3.new(56, deckY, 420), rgb(150, 150, 146), "Concrete", false)
	end
	for i = 0, 6 do
		A.car(k, f * CFrame.new(if i % 2 == 0 then -8 else 8, deckY + 3.3, -span / 2 + 80 + i * span / 8) * CFrame.Angles(0, if i % 2 == 0 then 0 else math.pi, 0))
	end
end

local function observatory(k: Kit.Kit, site: Site.Site)
	local u, v = lm("star_ridge_observatory")
	k:chunk("Observatory", 0)
	k:ellipsoid(Site.cf(site, u, -60, v, 20), Vector3.new(2400, 700, 1800), rgb(96, 128, 72), "Grass")
	local top = Site.cf(site, u, 288, v, 20)
	k:cyl(top * CFrame.new(0, 20, 0) * CFrame.Angles(0, 0, math.pi / 2), 40, 120, P.White, "Concrete", false)
	k:ellipsoid(top * CFrame.new(0, 40, 0), Vector3.new(118, 100, 118), rgb(226, 230, 236), "Metal")
	k:box(top * CFrame.new(0, 64, 0) * CFrame.Angles(0, 0, math.rad(-35)), Vector3.new(12, 50, 16), rgb(50, 54, 60), "Metal", false)
	k:box(top * CFrame.new(90, 14, 0), Vector3.new(80, 28, 50), P.White, "Concrete", false)
end

local function ridge(k: Kit.Kit, site: Site.Site, u: number, v: number, length: number, width: number, height: number, yaw: number, snow: boolean)
	local f = Site.cf(site, u, Landscape.Land - 2, v, yaw)
	local color = k:pick(ROCK)
	-- Triangular prism ridge (two wedges back to back) plus a snow cap.
	k:wedge(f * CFrame.new(0, height / 2, -width / 4), Vector3.new(length, height, width / 2), color, "Rock", false).shadow = false
	k:wedge(f * CFrame.new(0, height / 2, width / 4) * CFrame.Angles(0, math.pi, 0), Vector3.new(length, height, width / 2), color, "Rock", false).shadow = false
	if snow then
		local sh, sw = height * 0.28, width * 0.28
		k:wedge(f * CFrame.new(0, height - sh / 2 + 1, -sw / 4), Vector3.new(length * 0.8, sh, sw / 2), rgb(240, 244, 248), "Snow", false).shadow = false
		k:wedge(f * CFrame.new(0, height - sh / 2 + 1, sw / 4) * CFrame.Angles(0, math.pi, 0), Vector3.new(length * 0.8, sh, sw / 2), rgb(240, 244, 248), "Snow", false).shadow = false
	end
end

-- A mountain massif: forested ellipsoid base, two or three rocky crests and
-- an optional snow cap. Reads as a natural mountain from any side.
local function massif(k: Kit.Kit, site: Site.Site, u: number, v: number, size: number, height: number, snow: boolean)
	local yaw = k:range(0, 180)
	k:ellipsoid(
		Site.cf(site, u, -height * 0.12, v, yaw),
		Vector3.new(size, height * 0.95, size * k:range(0.65, 0.9)),
		k:pick({ rgb(70, 98, 66), rgb(78, 104, 70), rgb(88, 106, 78) }),
		"Grass"
	).shadow = false
	height = math.min(height, 2000) -- crests are wedges, capped at 2,048 studs
	local crests = if size > 2600 then 3 else 2
	for i = 1, crests do
		local o = (i - (crests + 1) / 2) * size * 0.16
		local main = i == math.ceil(crests / 2)
		local h = height * (if main then 1 else k:range(0.72, 0.88))
		local a = math.rad(yaw)
		ridge(k, site, u + o * math.cos(a), v - o * math.sin(a), size * k:range(0.32, 0.46), size * 0.42, h, yaw + k:range(-25, 25), snow and main)
	end
end

local function mountains(k: Kit.Kit, site: Site.Site)
	k:chunk("Mountains", 0)
	-- Northern range: the horizon of every long hit. Lower directly behind
	-- centre field so the batter's view stays calm.
	for i = 0, 22 do
		local u = -17000 + i * 1550 + k:range(-400, 400)
		local v = 19500 + k:range(0, 4500)
		local behindCenter = math.abs(u) < 4500
		local h = if behindCenter then k:range(900, 1500) else k:range(1500, 2000)
		massif(k, site, u, v, k:range(2600, 4200), h, h > 1700)
	end
	for _, sgn in { -1, 1 } do
		for i = 0, 9 do
			local v = -7000 + i * 2900 + k:range(-500, 500)
			local u = sgn * (15200 + k:range(0, 2400))
			local h = k:range(1000, 2200)
			massif(k, site, u, v, k:range(2600, 4000), h, h > 1800)
		end
	end
	for i = 0, 9 do
		local u = -14000 + i * 3100 + k:range(-500, 500)
		local v = -8000 + k:range(-600, 600)
		massif(k, site, u, v, k:range(2600, 3800), k:range(600, 1200), false)
	end
	-- Rolling foothills between the outskirts and the ranges.
	for _ = 1, 26 do
		local a = math.rad(k:range(-75, 75))
		local r = k:range(11000, 16500)
		local u, v = r * math.sin(a), r * math.cos(a)
		if not inEstuary(v, 300) then
			k:ellipsoid(Site.cf(site, u, -30, v, k:range(0, 180)), Vector3.new(k:range(1400, 3000), k:range(240, 520), k:range(900, 1800)), rgb(92, 126, 70), "Grass").shadow = false
		end
	end
end

local function wilds(k: Kit.Kit, site: Site.Site)
	k:chunk("Wilds", 0)
	-- Red Rock Canyon: stepped mesas.
	local cu, cv = lm("red_rock_canyon")
	for _ = 0, 11 do
		local u = cu + k:range(-1200, 1200)
		local v = cv + k:range(-900, 900)
		local h = k:range(160, 520)
		local w = k:range(240, 600)
		local f = Site.cf(site, u, Landscape.Land, v, k:range(0, 90))
		k:box(f * CFrame.new(0, h / 2, 0), Vector3.new(w, h, w * k:range(0.6, 1.2)), rgb(186, 96, 64), "Sandstone", false).shadow = false
		k:box(f * CFrame.new(0, h + 12, 0), Vector3.new(w * 0.7, 24, w * 0.6), rgb(206, 120, 80), "Sandstone", false).shadow = false
	end
	-- Silver Falls: cliff, falling water, mist and a plunge pool.
	local fu, fv = lm("silver_falls")
	local f = Site.cf(site, fu, Landscape.Land, fv, 0)
	k:box(f * CFrame.new(0, 300, 120), Vector3.new(1400, 600, 240), rgb(110, 108, 106), "Rock", false).shadow = false
	local fall = k:box(f * CFrame.new(0, 290, -2), Vector3.new(120, 580, 6), rgb(220, 236, 246), "Glass", false)
	fall.transparency = 0.15
	fall.shadow = false
	k:ellipsoid(f * CFrame.new(0, 20, -40), Vector3.new(260, 80, 160), rgb(240, 246, 250), "SmoothPlastic").transparency = 0.4
	k:ellipsoid(f * CFrame.new(0, -0.2, -200), Vector3.new(520, 0.6, 320), P.Water, "Glass").reflectance = 0.25
	k:box(f * CFrame.new(0, 600, 60), Vector3.new(130, 6, 120), P.Water, "Glass", false)
	-- Timberline Peak: a tall summit with a lookout.
	local pu, pv = lm("timberline_peak")
	-- Kept under ~4 degrees from the batter's box (it sits behind centre field).
	massif(k, site, pu, pv, 4200, 1250, true)
	-- Titan Arch.
	local au, av = lm("titan_arch")
	local arch = Site.cf(site, au, Landscape.Land, av, 15)
	for _, x in { -320, 320 } do
		k:box(arch * CFrame.new(x, 300, 0), Vector3.new(160, 600, 200), rgb(170, 100, 70), "Sandstone", false).shadow = false
	end
	k:box(arch * CFrame.new(0, 640, 0), Vector3.new(820, 120, 200), rgb(176, 104, 72), "Sandstone", false).shadow = false
	-- The Golden Diamond: a mesa crowned with a golden baseball diamond.
	local gu, gv = lm("golden_diamond")
	local g = Site.cf(site, gu, Landscape.Land, gv, 0)
	k:box(g * CFrame.new(0, 450, 0), Vector3.new(1800, 900, 1800), rgb(140, 110, 90), "Sandstone", false).shadow = false
	k:box(g * CFrame.new(0, 901, 0) * CFrame.Angles(0, math.rad(45), 0), Vector3.new(700, 2, 700), rgb(236, 196, 70), "Foil", false)
	k:ball((g * CFrame.new(0, 1020, 0)).Position, 220, rgb(250, 214, 90), "Foil")
end

function Landscape.build(k: Kit.Kit, site: Site.Site)
	water(k, site)
	harbor(k, site)
	farms(k, site)
	forests(k, site)
	monument(k, site)
	funPark(k, site)
	bridge(k, site)
	observatory(k, site)
	wilds(k, site)
	mountains(k, site)
	ground(k, site)
end

return Landscape
