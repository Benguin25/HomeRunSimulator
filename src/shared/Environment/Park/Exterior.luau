--!strict
-- The stadium block outside the bowl: outfield concourse (kiosks, picnic lawn,
-- kids' field, perimeter fence), the south entrance plaza (gate arch, ticket
-- booths, fountain) with landmark pavilions for the existing Power shop, World
-- travel and Rebirth systems plus shuttered storefronts reserved for future
-- shops, and the half-streets that close the block into the town grid.
--
-- Pavilions are visual: the shop/world/rebirth UI keeps working exactly as
-- before (buttons / G). Plaza layout keeps the spawn line and gate clear.

local Environment = script.Parent.Parent
local Config = require(Environment.EnvironmentConfig)
local Site = require(Environment.Site)
local Kit = require(Environment.EnvKit)
local Layout = require(script.Parent.Layout)
local A = require(Environment.World.Archetypes)

local Exterior = {}

local P = Config.Palette
local rgb = Config.rgb

Exterior.PlazaTop = -0.5 -- flush with the catchment so landing markers stay visible
Exterior.ApronTop = -0.08
Exterior.Block = { u = 256, vMin = -116, vMax = 396, plazaMin = -300 }

local function flat(k: Kit.Kit, site: Site.Site, u0: number, u1: number, v0: number, v1: number, top: number, color: Kit.Color, material: string, t: number?)
	local th = t or 0.4
	return k:box(Site.cf(site, (u0 + u1) / 2, top - th / 2, (v0 + v1) / 2), Vector3.new(math.abs(u1 - u0), th, math.abs(v1 - v0)), color, material, false)
end

local function kiosk(k: Kit.Kit, cf: CFrame, text: string, color: Kit.Color)
	k:box(cf * CFrame.new(0, 5, 0), Vector3.new(16, 10, 10), rgb(240, 236, 226), "Plaster", true)
	k:box(cf * CFrame.new(0, 4.4, -5.1), Vector3.new(12, 4, 0.3), rgb(60, 50, 44), "SmoothPlastic", false)
	k:box(cf * CFrame.new(0, 2.6, -5.8), Vector3.new(14, 0.6, 1.6), rgb(170, 130, 90), "Wood", false)
	k:wedge(cf * CFrame.new(0, 11, -6.5), Vector3.new(18, 2.4, 3.4), color, "Fabric", false)
	k:box(cf * CFrame.new(0, 10.6, 0), Vector3.new(18, 1.2, 12), color, "SmoothPlastic", false)
	local s = k:box(cf * CFrame.new(0, 13.4, -1), Vector3.new(15, 3.6, 0.5), color, "SmoothPlastic", false)
	s.sign = { text = text, color = P.White, font = "GothamBlack" }
end

local function picnic(k: Kit.Kit, cf: CFrame, umbrella: Kit.Color?)
	k:box(cf * CFrame.new(0, 2.6, 0), Vector3.new(8, 0.4, 3.2), P.Wood, "WoodPlanks", false)
	for _, z in { -2.6, 2.6 } do
		k:box(cf * CFrame.new(0, 1.5, z), Vector3.new(8, 0.3, 1.2), P.Wood, "WoodPlanks", false)
	end
	k:box(cf * CFrame.new(0, 1.2, 0), Vector3.new(0.6, 2.4, 6), P.Wood, "Wood", false)
	if umbrella then
		k:post((cf * CFrame.new(0, 2.8, 0)).Position, 6, 0.25, P.White, "Metal")
		k:ellipsoid(cf * CFrame.new(0, 8.6, 0), Vector3.new(9, 1.6, 9), umbrella, "Fabric")
	end
end

local function fenceRun(k: Kit.Kit, a: Vector3, b: Vector3, gaps: { number }?)
	local len = (b - a).Magnitude
	local n = math.max(1, math.floor(len / 28))
	for i = 0, n - 1 do
		local t0, t1 = i / n, (i + 1) / n
		local skip = false
		for _, g in (gaps or {}) :: { number } do
			if math.abs((t0 + t1) / 2 * len - g) < 16 then
				skip = true
			end
		end
		local p0, p1 = a:Lerp(b, t0), a:Lerp(b, t1)
		k:post(p0, 7.4, 0.6, P.Black, "Metal").shadow = false
		if not skip then
			local panel = k:beam(p0 + Vector3.new(0, 3.6, 0), p1 + Vector3.new(0, 3.6, 0), 0.15, 6, rgb(30, 32, 36), "Metal", true)
			if panel then
				panel.transparency = 0.72
			end
			k:beam(p0 + Vector3.new(0, 6.8, 0), p1 + Vector3.new(0, 6.8, 0), 0.3, 0.3, P.Black, "Metal", false)
		end
	end
	k:post(b, 7.4, 0.6, P.Black, "Metal")
end

local function concourse(k: Kit.Kit, layout: Layout.Layout)
	local site = layout.site
	local B = Exterior.Block
	k:chunk("ParkApron", 0)
	-- Apron paving over the authored baseplate (hidden locally; collision unchanged).
	flat(k, site, -B.u, B.u, B.vMin, B.vMax, Exterior.ApronTop, rgb(176, 172, 164), "Pavement", 0.3)
	-- Grass "Home Run Lawn" behind the batter's eye and planted beds.
	local function lawn(u0: number, u1: number, v0: number, v1: number)
		flat(k, site, u0, u1, v0, v1, 0.0, P.Lawn, "Grass", 0.3)
	end
	lawn(-70, 70, 352, 388)
	lawn(-250, -150, 300, 388)
	lawn(150, 250, 300, 330)
	k:chunk("Concourse", Config.Lod.Detail)
	local foods: { { text: string, color: Kit.Color } } = {
		{ text = "HOT DOGS", color = P.Red },
		{ text = "LEMONADE", color = rgb(230, 180, 40) },
		{ text = "PEANUTS", color = rgb(150, 100, 60) },
		{ text = "BURGERS", color = rgb(200, 90, 40) },
		{ text = "ICE CREAM", color = rgb(220, 120, 170) },
		{ text = "PRETZELS", color = rgb(160, 110, 60) },
		{ text = "TEAM STORE", color = P.Navy },
	}
	local spots = { { -150, 345 }, { -96, 368 }, { 96, 368 }, { -212, 252 }, { 212, 236 }, { -232, 160 }, { 238, 120 } }
	for i, s in spots do
		local f = foods[i]
		-- Face the stadium interior (toward the plate).
		local cf = CFrame.lookAt(Site.at(site, s[1], 0, s[2]), Site.at(site, 0, 0, 0))
		kiosk(k, cf, f.text, f.color)
	end
	-- Picnic area behind the left-field bleachers.
	for i = 0, 8 do
		local u, v = -230 + (i % 3) * 22, 312 + math.floor(i / 3) * 22
		picnic(k, Site.cf(site, u, 0, v, 15), if i % 2 == 0 then k:pick({ P.Red, P.Yellow, P.Sky }) else nil)
	end
	-- "Home Run Lawn" picnic blankets and sign.
	for i = 0, 5 do
		flat(k, site, -60 + i * 20, -48 + i * 20, 360 + (i % 2) * 10, 368 + (i % 2) * 10, 0.08, k:pick({ P.Red, P.Navy, P.Yellow, rgb(240, 240, 236) }), "Fabric", 0.1)
	end
	local lawnSign = k:box(Site.cf(site, 0, 4, 391, 180), Vector3.new(36, 4, 0.6), rgb(60, 100, 60), "Wood", false)
	lawnSign.sign = { text = "HOME RUN LAWN", color = P.White, font = "GothamBlack" }
	-- Kids' wiffle field behind the right-field bleachers.
	local kid = Site.cf(site, 205, 0, 290, -40)
	k:box(kid * CFrame.new(0, 0.04, 0), Vector3.new(34, 0.12, 34) , P.Dirt, "Ground", false)
	k:box(kid * CFrame.new(0, 0.08, 0) * CFrame.Angles(0, math.rad(45), 0), Vector3.new(16, 0.12, 16), P.Grass, "Grass", false)
	for _, o in { Vector3.new(0, 0, 11), Vector3.new(11, 0, 0), Vector3.new(0, 0, -11), Vector3.new(-11, 0, 0) } do
		k:box(kid * CFrame.new(o + Vector3.new(0, 0.2, 0)), Vector3.new(1.4, 0.2, 1.4), P.White, "SmoothPlastic", false)
	end
	local kidSign = k:box(kid * CFrame.new(0, 3, 20), Vector3.new(20, 3, 0.4), P.Yellow, "SmoothPlastic", false)
	kidSign.sign = { text = "KIDS FIELD", color = P.Navy, font = "GothamBlack" }
	-- Fans on the concourse.
	for _ = 1, 28 do
		local a = math.rad(k:range(-44, 44))
		local r = Site.fenceRadius(site, math.deg(a)) + k:range(30, 60)
		local u, v = Site.polarUV(r, math.deg(a))
		if math.abs(u) < 245 and v < 388 then
			A.person(k, Site.cf(site, u, 0, v, k:range(-180, 180)))
		end
	end
	-- Grounds crew corner: maintenance gate, cart, hose reel and rakes.
	local crew = Site.cf(site, 236, 0, 40, -90)
	k:box(crew * CFrame.new(0, 7, 6), Vector3.new(26, 14, 1.2), P.Brick, "Brick", true)
	k:box(crew * CFrame.new(0, 5, 5.2), Vector3.new(14, 10, 0.4), rgb(110, 116, 122), "CorrodedMetal", false)
	local gateSign = k:box(crew * CFrame.new(0, 11.8, 5.1), Vector3.new(16, 2, 0.2), P.Navy, "SmoothPlastic", false)
	gateSign.sign = { text = "GROUNDS CREW ONLY", color = P.White, font = "GothamBlack" }
	A.cart(k, crew * CFrame.new(-6, 0, -4))
	k:cyl(crew * CFrame.new(8, 1.6, -2) * CFrame.Angles(0, math.pi / 2, 0), 1.2, 3.2, rgb(40, 110, 70), "Plastic", false)
	for i = 0, 2 do
		k:box(crew * CFrame.new(11 + i * 0.8, 3, 4.6) * CFrame.Angles(math.rad(-12), 0, 0), Vector3.new(0.2, 6, 0.2), P.Wood, "Wood", false)
	end
	-- Perimeter fence along the block edge with gates on each street.
	k:chunk("Perimeter", 0)
	local y = 0
	fenceRun(k, Site.at(site, -B.u + 2, y, B.vMax - 2), Site.at(site, B.u - 2, y, B.vMax - 2), { 256 })
	fenceRun(k, Site.at(site, B.u - 2, y, B.vMax - 2), Site.at(site, B.u - 2, y, 20), { 120 })
	fenceRun(k, Site.at(site, -B.u + 2, y, B.vMax - 2), Site.at(site, -B.u + 2, y, 20), { 120 })
	-- Trees and lamp posts just inside the fence.
	k:chunk("PerimeterTrees", Config.Lod.Detail)
	for u = -B.u + 16, B.u - 16, 40 do
		if math.abs(u) > 30 then
			A.tree(k, Site.at(site, u, 0, B.vMax - 10), k:range(16, 22))
		end
	end
	for v = 40, B.vMax - 30, 46 do
		A.tree(k, Site.at(site, B.u - 10, 0, v), k:range(16, 22))
		A.tree(k, Site.at(site, -B.u + 10, 0, v), k:range(16, 22))
	end
end

-- Landmark pavilion with a rooftop emblem; front faces the plaza centre.
local function pavilion(k: Kit.Kit, cf: CFrame, w: number, d: number, h: number, body: Kit.Color, trim: Kit.Color, title: string, subtitle: string?)
	k:box(cf * CFrame.new(0, h / 2, 0), Vector3.new(w, h, d), body, "Brick", true)
	k:box(cf * CFrame.new(0, h + 1, 0), Vector3.new(w + 2, 2, d + 2), trim, "Concrete", false)
	k:box(cf * CFrame.new(0, 6, -d / 2 - 0.2), Vector3.new(w * 0.7, 9, 0.3), rgb(70, 100, 120), "Glass", false).reflectance = 0.2
	k:box(cf * CFrame.new(0, 5, -d / 2 - 0.3), Vector3.new(7, 10, 0.3), rgb(40, 40, 44), "SmoothPlastic", false)
	k:wedge(cf * CFrame.new(0, 12.6, -d / 2 - 2.6), Vector3.new(w * 0.8, 2.4, 5), trim, "Fabric", false)
	local s = k:box(cf * CFrame.new(0, h - 4, -d / 2 - 0.4), Vector3.new(w * 0.9, 6, 0.4), trim, "SmoothPlastic", false)
	s.sign = { text = title, color = P.White, font = "LuckiestGuy" }
	if subtitle then
		local s2 = k:box(cf * CFrame.new(0, h - 8.4, -d / 2 - 0.4), Vector3.new(w * 0.6, 2.4, 0.3), P.Black, "SmoothPlastic", false)
		s2.sign = { text = subtitle, color = P.Yellow, font = "GothamBlack" }
	end
end

local function plaza(k: Kit.Kit, layout: Layout.Layout)
	local site = layout.site
	local B = Exterior.Block
	k:chunk("Plaza", 0)
	local top = Exterior.PlazaTop
	-- Paving: field of pavers with a brick ring and gate axis.
	flat(k, site, -B.u, B.u, B.plazaMin, B.vMin, top, rgb(196, 190, 178), "Pavement", 0.3)
	flat(k, site, -14, 14, B.plazaMin, -150, top + 0.05, rgb(170, 90, 70), "Brick", 0.3)
	k:disc(Site.at(site, 0, top + 0.05, -232), 96, 0.3, rgb(170, 90, 70), "Brick", false)
	k:disc(Site.at(site, 0, top + 0.1, -232), 84, 0.3, rgb(204, 198, 186), "Pavement", false)
	-- Home Run Fountain: basin, water, giant ball.
	local fountain = Site.at(site, 0, top, -232)
	k:disc(fountain + Vector3.new(0, 2.4, 0), 52, 2.4, P.Limestone, "Concrete", true)
	k:disc(fountain + Vector3.new(0, 2.5, 0), 46, 0.4, P.Water, "Glass", false).reflectance = 0.3
	k:post(fountain, 9, 7, P.Limestone, "Concrete")
	k:ball(fountain + Vector3.new(0, 15, 0), 14, P.White, "SmoothPlastic")
	for i = 0, 7 do
		local a = i * math.pi / 4
		local spray = k:box(CFrame.new(fountain + Vector3.new(math.cos(a) * 14, 6, math.sin(a) * 14)) * CFrame.Angles(math.sin(a) * 0.4, 0, -math.cos(a) * 0.4), Vector3.new(0.8, 8, 0.8), rgb(220, 236, 250), "Glass", false)
		spray.transparency = 0.35
		spray.shadow = false
	end
	-- Gate arch at the tunnel line (facade at v ~ -151).
	local gate = Site.cf(site, 0, top, -160, 180)
	for _, x in { -22, 22 } do
		k:box(gate * CFrame.new(x, 20, 0), Vector3.new(12, 40, 12), P.Brick, "Brick", true)
		k:box(gate * CFrame.new(x, 41, 0), Vector3.new(14, 2, 14), P.Limestone, "Concrete", false)
		k:ball((gate * CFrame.new(x, 46, 0)).Position, 8, P.White, "SmoothPlastic")
	end
	k:box(gate * CFrame.new(0, 34, 0), Vector3.new(56, 10, 6), P.Steel, "Metal", false)
	local title = k:box(gate * CFrame.new(0, 34, -3.2), Vector3.new(50, 8, 0.4), P.Navy, "SmoothPlastic", false)
	title.sign = { text = "ROOKIE PARK", color = P.Yellow, font = "LuckiestGuy" }
	local est = k:box(gate * CFrame.new(0, 28.2, -3.2), Vector3.new(26, 2.4, 0.3), P.Steel, "SmoothPlastic", false)
	est.sign = { text = "HOME OF THE BRAMBLE BAY ROOKIES", color = P.White, font = "GothamBlack" }
	-- Ticket booths either side of the gate.
	for _, x in { -46, 46 } do
		local b = gate * CFrame.new(x, 0, -6)
		k:box(b * CFrame.new(0, 6, 0), Vector3.new(14, 12, 10), P.White, "Plaster", true)
		k:box(b * CFrame.new(0, 6.5, -5.1), Vector3.new(10, 4, 0.3), rgb(70, 100, 120), "Glass", false)
		k:box(b * CFrame.new(0, 12.6, 0), Vector3.new(16, 1.2, 12), P.Red, "SmoothPlastic", false)
		local s = k:box(b * CFrame.new(0, 10, -5.3), Vector3.new(10, 2, 0.2), P.Red, "SmoothPlastic", false)
		s.sign = { text = "TICKETS", color = P.White, font = "GothamBlack" }
	end
	-- Pavilions for the existing systems (visual only) and reserved storefronts.
	local function facing(u: number, v: number): CFrame
		return CFrame.lookAt(Site.at(site, u, top, v), Site.at(site, 0, top, -232))
	end
	pavilion(k, facing(-190, -196), 64, 40, 26, rgb(176, 52, 44), P.Navy, "POWER SHOP", "UPGRADE YOUR SWING")
	-- Giant bat on the Power Shop roof.
	local ps = facing(-190, -196)
	k:cyl(ps * CFrame.new(0, 34, 4) * CFrame.Angles(0, 0, math.rad(12)), 60, 6, rgb(196, 150, 96), "Wood", false)
	k:cyl(ps * CFrame.new(-28, 28, 4) * CFrame.Angles(0, 0, math.rad(12)), 10, 3, rgb(60, 40, 30), "Wood", false)
	-- Hall of Fame (rebirths): limestone temple front with columns.
	local hof = facing(-160, -268)
	k:box(hof * CFrame.new(0, 2, 0), Vector3.new(70, 4, 46), P.Limestone, "Marble", true)
	k:box(hof * CFrame.new(0, 18, 6), Vector3.new(60, 28, 30), rgb(226, 220, 206), "Marble", true)
	for i = 0, 5 do
		k:post((hof * CFrame.new(-25 + i * 10, 4, -14)).Position, 24, 3.2, rgb(240, 236, 226), "Marble")
	end
	k:box(hof * CFrame.new(0, 29, -8), Vector3.new(64, 3, 18), P.Limestone, "Marble", false)
	A.gable(k, hof * CFrame.new(0, 30.5, -2), 64, 34, 8, rgb(226, 220, 206), "Marble")
	local hofSign = k:box(hof * CFrame.new(0, 29, -17.2), Vector3.new(48, 2.6, 0.3), P.Limestone, "Marble", false)
	hofSign.sign = { text = "HALL OF FAME  -  REBIRTH", color = rgb(150, 110, 40), font = "GothamBlack" }
	-- Stadium Express (world travel): station canopy and a branded bus.
	local stn = facing(190, -196)
	k:box(stn * CFrame.new(0, 16, 6), Vector3.new(70, 1.6, 30), P.Steel, "Metal", false)
	for _, x in { -32, 32 } do
		for _, z in { -6, 18 } do
			k:post((stn * CFrame.new(x, 0, z)).Position, 16, 1.2, P.Steel, "Metal")
		end
	end
	local board = k:box(stn * CFrame.new(0, 20, -6), Vector3.new(46, 6, 0.6), rgb(20, 22, 26), "SmoothPlastic", false)
	board.sign = { text = "STADIUM EXPRESS  -  ALL WORLDS", color = rgb(255, 200, 70), font = "Arcade" }
	A.bus(k, stn * CFrame.new(0, 0, 16) * CFrame.Angles(0, math.pi / 2, 0), rgb(40, 110, 170), "STADIUM EXPRESS")
	for i = 0, 2 do
		k:box(stn * CFrame.new(-20 + i * 20, 2, 2), Vector3.new(10, 0.5, 2), P.Wood, "WoodPlanks", false)
	end
	-- Reserved storefronts for future shops (bats, gems, multiplier balls).
	local row = facing(170, -270)
	for i, name in { "BAT VAULT", "GEM EXCHANGE", "BALL LAB" } do
		local f = row * CFrame.new(-44 + (i - 1) * 44, 0, 0)
		k:box(f * CFrame.new(0, 11, 0), Vector3.new(42, 22, 30), k:pick(A.Commercial), "Brick", true)
		k:box(f * CFrame.new(0, 6, -15.2), Vector3.new(30, 10, 0.4), rgb(120, 124, 130), "CorrodedMetal", false)
		local s = k:box(f * CFrame.new(0, 16.5, -15.3), Vector3.new(34, 4, 0.3), P.Navy, "SmoothPlastic", false)
		s.sign = { text = name, color = P.White, font = "GothamBlack" }
		local soon = k:box(f * CFrame.new(0, 7, -15.5), Vector3.new(20, 3, 0.2), P.Yellow, "SmoothPlastic", false)
		soon.sign = { text = "COMING SOON", color = P.Navy, font = "GothamBlack" }
	end
	-- Banners, trees, benches around the plaza.
	k:chunk("PlazaDetail", Config.Lod.Detail)
	for i = 0, 9 do
		local a = math.rad(-150 + i * 33.3)
		local p = Site.at(site, math.sin(a) * 70, top, -232 + math.cos(a) * 70)
		k:post(p, 20, 0.6, P.Steel, "Metal")
		local banner = k:box(CFrame.lookAt(p + Vector3.new(0, 15, 0), Site.at(site, 0, top + 15, -232)) * CFrame.new(1.4, 0, 0), Vector3.new(2.6, 7, 0.1), if i % 2 == 0 then P.Navy else P.Red, "Fabric", false)
		banner.tag = "Flag"
		if i % 2 == 1 then
			A.tree(k, Site.at(site, math.sin(a) * 104, top, -232 + math.cos(a) * 104), 20)
		end
	end
	for _, u in { -100, -60, 60, 100 } do
		k:box(Site.cf(site, u, top + 1.2, -300 + 18), Vector3.new(8, 0.5, 2.4), P.Wood, "WoodPlanks", false)
	end
	-- Brick planters with flowers framing the gate axis.
	for _, p in { { -40, -190 }, { 40, -190 }, { -40, -278 }, { 40, -278 } } do
		local c = Site.cf(site, p[1], top, p[2])
		k:box(c * CFrame.new(0, 1.2, 0), Vector3.new(22, 2.4, 10), P.Brick, "Brick", true)
		k:box(c * CFrame.new(0, 2.5, 0), Vector3.new(20, 0.4, 8), rgb(80, 60, 44), "Ground", false)
		for i = 0, 5 do
			k:ellipsoid(
				c * CFrame.new(-8 + i * 3.2, 3.2, (i % 2) * 2 - 1),
				Vector3.new(3, 1.8, 3),
				k:pick({ P.Red, P.Yellow, rgb(220, 110, 170), rgb(250, 250, 240), rgb(140, 90, 200) }),
				"Fabric"
			)
		end
		A.tree(k, (c * CFrame.new(0, 2.6, 0)).Position, 14)
	end
	-- Rows of trees along the facade and the plaza edges.
	for u = -230, 230, 46 do
		if math.abs(u) > 70 then
			A.tree(k, Site.at(site, u, top, -132), 18)
		end
		A.tree(k, Site.at(site, u, top, -296), 18)
	end
	-- Food truck, bike rack and fans arriving for the game.
	local truck = Site.cf(site, 110, top, -250, 90)
	k:box(truck * CFrame.new(0, 5.4, 0), Vector3.new(8, 8.4, 22), P.Yellow, "SmoothPlastic", false)
	k:box(truck * CFrame.new(0, 2.2, -9), Vector3.new(8, 4, 5), P.Yellow, "SmoothPlastic", false)
	k:box(truck * CFrame.new(-4.1, 6, 2), Vector3.new(0.3, 3.6, 10), rgb(40, 50, 60), "Glass", false)
	k:wedge(truck * CFrame.new(-5.4, 8.6, 2) * CFrame.Angles(0, -math.pi / 2, 0), Vector3.new(11, 1, 2.4), P.Red, "Fabric", false)
	local menu = k:box(truck * CFrame.new(-4.2, 11.2, 2) * CFrame.Angles(0, -math.pi / 2, 0), Vector3.new(14, 2.4, 0.2), P.Red, "SmoothPlastic", false)
	menu.sign = { text = "STREET TACOS", color = P.White, font = "LuckiestGuy" }
	k:box(truck * CFrame.new(0, 0.8, 0), Vector3.new(8.2, 1.6, 18), rgb(26, 26, 28), "Rubber", false)
	for i = 0, 5 do
		local rack = Site.cf(site, -120 + i * 3, top, -140)
		k:cyl(rack * CFrame.new(0, 1.6, 0) * CFrame.Angles(math.pi / 2, 0, 0), 2.6, 0.25, rgb(60, 64, 70), "Metal", false)
	end
	for _ = 1, 34 do
		local u = k:range(-220, 220)
		local v = k:range(-290, -150)
		local inFountain = (u * u + (v + 232) ^ 2) < 40 ^ 2
		local inPavilion = math.abs(u) > 135 and v < -165
		if not inFountain and not inPavilion and math.abs(u) > 4 then
			A.person(k, Site.cf(site, u, top, v, k:range(-180, 180)))
		end
	end
end

-- Half-streets and crosswalks that close the stadium cell into the grid.
local function streets(k: Kit.Kit, layout: Layout.Layout)
	local site = layout.site
	local B = Exterior.Block
	k:chunk("ParkStreets", 0)
	local y = -0.56
	flat(k, site, B.u, B.u + 20, B.plazaMin - 20, B.vMax + 20, y, P.Asphalt, "Asphalt", 0.3)
	flat(k, site, -B.u - 20, -B.u, B.plazaMin - 20, B.vMax + 20, y, P.Asphalt, "Asphalt", 0.3)
	flat(k, site, -B.u, B.u, B.vMax, B.vMax + 20, y, P.Asphalt, "Asphalt", 0.3)
	flat(k, site, -B.u, B.u, B.plazaMin - 20, B.plazaMin, y, P.Asphalt, "Asphalt", 0.3)
	-- Plaza edge between the apron and the plaza (east and west of the grandstand).
	-- Zebra crosswalks at the stadium corners and gates.
	local function zebra(u: number, v: number, alongU: boolean)
		for i = -4, 4 do
			local o = i * 4
			if alongU then
				flat(k, site, u + o - 1.2, u + o + 1.2, v - 18, v + 18, y + 0.04, P.Paint, "SmoothPlastic", 0.06)
			else
				flat(k, site, u - 18, u + 18, v + o - 1.2, v + o + 1.2, y + 0.04, P.Paint, "SmoothPlastic", 0.06)
			end
		end
	end
	zebra(0, B.vMax + 20, true)
	zebra(B.u + 20, 48, false)
	zebra(-B.u - 20, 48, false)
	zebra(0, B.plazaMin - 20, true)
	-- Parked cars and a few street lights along the park.
	k:chunk("ParkStreetProps", Config.Lod.Props)
	for v = -280, 380, 26 do
		if math.abs(v - 48) > 30 and k:rand() < 0.55 then
			A.car(k, Site.cf(site, B.u + 26, y, v, 0))
		end
		if math.abs(v - 48) > 30 and k:rand() < 0.55 then
			A.car(k, Site.cf(site, -B.u - 26, y, v, 180))
		end
	end
	for v = -260, 380, 80 do
		A.streetlight(k, Site.at(site, B.u - 4, 0, v), site.right)
		A.streetlight(k, Site.at(site, -B.u + 4, 0, v), -site.right)
	end
end

function Exterior.build(k: Kit.Kit, layout: Layout.Layout)
	concourse(k, layout)
	plaza(k, layout)
	streets(k, layout)
end

return Exterior
