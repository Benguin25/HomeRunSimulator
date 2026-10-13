--!strict
-- Bramble Bay: the town around Rookie Park, generated on a street grid that
-- is aligned with the park (Grand Slam Boulevard runs straight out of centre
-- field toward the downtown skyline). Blocks are zoned by RegionMap distance
-- band; landmark lots come from RegionMap so metadata and visuals agree.
--
-- Ground layering (world Y tops): landscape -0.68 < street -0.56 < block lots
-- -0.5 (= the authoritative catchment top). Landed balls (centre -0.37) and the
-- Stage 4 landing marker (drawn 0.03 above the impact point) therefore always
-- sit on or above every visible surface. Buildings are visual only.

local Environment = script.Parent.Parent
local Config = require(Environment.EnvironmentConfig)
local Site = require(Environment.Site)
local Kit = require(Environment.EnvKit)
local RegionMap = require(Environment.RegionMap)
local A = require(script.Parent.Archetypes)

local Town = {}

local P = Config.Palette
local rgb = Config.rgb

Town.Street = 40
Town.Sidewalk = 9
Town.StepU = 290
Town.StepV = 270
Town.EastStart = 276 -- first north-south street centreline (stadium block edge + half street)
Town.NorthStart = 416 -- first east-west street beyond centre field
Town.SouthStart = -320 -- street south of the entrance plaza
Town.MidV = 48 -- cross street east and west of the park
Town.Boulevard = 70 -- Grand Slam Boulevard width (u = 0, north of the park)
Town.River = { Center = 2460, Width = 112, Amplitude = 34, Wavelength = 2200 }
Town.Highway = { V = 2981, Height = 34, Width = 48 }
Town.Y = { Street = -0.56, Lot = -0.5, Land = -0.68 }
Town.SolidFeet = 1100 -- buildings closer than this are character/camera solid
Town.MaxU = 4100
Town.MaxV = 7300
Town.MinV = -1900

export type Cell = {
	u0: number,
	u1: number,
	v0: number,
	v1: number,
	r: number,
	phi: number,
	feet: number,
	region: string,
	landmark: RegionMap.Landmark?,
	special: string?, -- "river" | "highway"
	group: string,
}

function Town.radiusLimit(phi: number): number
	local a = math.abs(phi)
	if a <= 50 then
		return 6300
	elseif a <= 95 then
		return 6300 + (2700 - 6300) * (a - 50) / 45
	end
	return 2700 + (1700 - 2700) * math.min(1, (a - 95) / 60)
end

-- Bramble Bay (north-east water) and the estuary are left to the landscape.
Town.Bay = { u0 = 2300, u1 = 15000, v0 = 6500, v1 = 10500 }
function Town.inWater(u: number, v: number): boolean
	local b = Town.Bay
	return u > b.u0 and u < b.u1 and v > b.v0 and v < b.v1
end

local function lines(start: number, step: number, limit: number, sign: number): { number }
	local out = {}
	local x = start
	while math.abs(x) <= limit do
		table.insert(out, x)
		x += sign * step
	end
	return out
end

function Town.cells(): { Cell }
	local us: { number } = {}
	for _, u in lines(-Town.EastStart, Town.StepU, Town.MaxU, -1) do
		table.insert(us, 1, u)
	end
	for _, u in lines(Town.EastStart, Town.StepU, Town.MaxU, 1) do
		table.insert(us, u)
	end
	local vs: { number } = {}
	for _, v in lines(Town.SouthStart, Town.StepV, -Town.MinV, -1) do
		table.insert(vs, 1, v)
	end
	-- Mid-block street beside the park so the side blocks are not 700 studs long.
	table.insert(vs, Town.MidV)
	for _, v in lines(Town.NorthStart, Town.StepV, Town.MaxV, 1) do
		table.insert(vs, v)
	end
	local out: { Cell } = {}
	local half = Town.Street / 2
	for i = 1, #us - 1 do
		for j = 1, #vs - 1 do
			local cu0, cu1, cv0, cv1 = us[i], us[i + 1], vs[j], vs[j + 1]
			if cu0 >= -Town.EastStart and cu1 <= Town.EastStart and cv0 >= Town.SouthStart and cv1 <= Town.NorthStart then
				continue -- the stadium precinct
			end
			local spans = { { cu0, cu1 } }
			if cu0 < 0 and cu1 > 0 and cv0 >= Town.NorthStart then
				spans = { { cu0, -Town.Boulevard / 2 + half }, { Town.Boulevard / 2 - half, cu1 } }
			end
			for _, span in spans do
				local u0, u1, v0, v1 = span[1] + half, span[2] - half, cv0 + half, cv1 - half
				local cu, cv = (u0 + u1) / 2, (v0 + v1) / 2
				local r = math.sqrt(cu * cu + cv * cv)
				local phi = math.deg(math.atan2(cu, cv))
				if r <= Town.radiusLimit(phi) and not Town.inWater(cu, cv) then
					local feet = RegionMap.studsToFeet(r)
					local cell: Cell = {
						u0 = u0,
						u1 = u1,
						v0 = v0,
						v1 = v1,
						r = r,
						phi = phi,
						feet = feet,
						region = RegionMap.regionForFeet(feet).id,
						landmark = nil,
						special = nil,
						group = `{math.floor(cu / 1200)}_{math.floor(cv / 1100)}`,
					}
					local river = Town.River
					if cv0 < river.Center + river.Width and cv1 > river.Center - river.Width then
						cell.special = "river"
					elseif cv0 < Town.Highway.V and cv1 > Town.Highway.V then
						cell.special = "highway"
					end
					table.insert(out, cell)
				end
			end
		end
	end
	-- Landmark lots: the cell containing each town landmark, else the nearest
	-- free cell within 200 studs (e.g. the square on the boulevard axis).
	for _, l in RegionMap.Landmarks do
		local u, v = RegionMap.landmarkStuds(l)
		local best: Cell? = nil
		local bestD = 200
		for _, c in out do
			local du = math.max(c.u0 - u, 0, u - c.u1)
			local dv = math.max(c.v0 - v, 0, v - c.v1)
			local d = math.sqrt(du * du + dv * dv)
			if not c.landmark and not c.special and d < bestD then
				best, bestD = c, d
			end
		end
		if best then
			best.landmark = l
		end
	end
	return out
end

-- Block helpers ------------------------------------------------------------

type Ctx = {
	k: Kit.Kit,
	site: Site.Site,
	mass: Kit.Chunk,
	props: Kit.Chunk,
}

local function flat(ctx: Ctx, u0: number, u1: number, v0: number, v1: number, top: number, color: Kit.Color, material: string, thickness: number?)
	local t = thickness or 0.4
	ctx.k:box(
		Site.cf(ctx.site, (u0 + u1) / 2, top - t / 2, (v0 + v1) / 2),
		Vector3.new(math.abs(u1 - u0), t, math.abs(v1 - v0)),
		color,
		material,
		false
	)
end

-- Sidewalk ring + interior lot surface (non-overlapping, same height). Far
-- cells (feet >= 2,600) use a single surface.
local function lot(ctx: Ctx, c: Cell, interior: Kit.Color, material: string)
	local s = Town.Sidewalk
	local y = Town.Y.Lot
	if c.feet >= 2600 then
		flat(ctx, c.u0, c.u1, c.v0, c.v1, y, interior, material)
		return
	end
	flat(ctx, c.u0, c.u1, c.v0, c.v0 + s, y, P.Sidewalk, "Concrete")
	flat(ctx, c.u0, c.u1, c.v1 - s, c.v1, y, P.Sidewalk, "Concrete")
	flat(ctx, c.u0, c.u0 + s, c.v0 + s, c.v1 - s, y, P.Sidewalk, "Concrete")
	flat(ctx, c.u1 - s, c.u1, c.v0 + s, c.v1 - s, y, P.Sidewalk, "Concrete")
	flat(ctx, c.u0 + s, c.u1 - s, c.v0 + s, c.v1 - s, y - 0.02, interior, material)
end

-- Calls fn(cf, length) for each side of the inner lot, cf on the lot edge
-- facing the street (LookVector outward). Sides: south, north, west, east.
local function sides(ctx: Ctx, c: Cell, inset: number, fn: (CFrame, number, string) -> ())
	local s = Town.Sidewalk + inset
	local cu, cv = (c.u0 + c.u1) / 2, (c.v0 + c.v1) / 2
	local y = Town.Y.Lot
	fn(Site.cf(ctx.site, cu, y, c.v0 + s, 180), (c.u1 - c.u0) - 2 * s, "S")
	fn(Site.cf(ctx.site, cu, y, c.v1 - s, 0), (c.u1 - c.u0) - 2 * s, "N")
	fn(Site.cf(ctx.site, c.u0 + s, y, cv, -90), (c.v1 - c.v0) - 2 * s, "W")
	fn(Site.cf(ctx.site, c.u1 - s, y, cv, 90), (c.v1 - c.v0) - 2 * s, "E")
end

local function streetTrees(ctx: Ctx, c: Cell, spacing: number)
	local k = ctx.k
	if c.feet > 2200 then
		return
	end
	spacing = if c.feet > 1400 then spacing * 1.6 else spacing
	k:use(ctx.props)
	local y = Town.Y.Lot
	for u = c.u0 + 14, c.u1 - 14, spacing do
		A.tree(k, Site.at(ctx.site, u, y, c.v0 + 4), k:range(14, 20))
		A.tree(k, Site.at(ctx.site, u, y, c.v1 - 4), k:range(14, 20))
	end
	k:use(ctx.mass)
end

local function parkedCars(ctx: Ctx, c: Cell, chance: number)
	local k = ctx.k
	if c.feet > 1800 then
		return
	end
	k:use(ctx.props)
	for u = c.u0 + 16, c.u1 - 16, 22 do
		if k:rand() < chance then
			A.car(k, Site.cf(ctx.site, u, Town.Y.Street, c.v0 - 6, 90))
		end
		if k:rand() < chance then
			A.car(k, Site.cf(ctx.site, u, Town.Y.Street, c.v1 + 6, -90))
		end
	end
	k:use(ctx.mass)
end

local function lights(ctx: Ctx, c: Cell)
	local k = ctx.k
	if c.feet > 1500 then
		return
	end
	k:use(ctx.props)
	local y = Town.Y.Lot
	for _, u in { c.u0 + 6, c.u1 - 6 } do
		A.streetlight(k, Site.at(ctx.site, u, y, c.v0 + 3), ctx.site.forward * -1)
		A.streetlight(k, Site.at(ctx.site, u, y, c.v1 - 3), ctx.site.forward)
	end
	k:use(ctx.mass)
end

-- Fillers --------------------------------------------------------------------

local SHOP_NAMES = {
	"BULLPEN BAR & GRILL",
	"HOT CORNER CAFE",
	"FAN GEAR",
	"DOUBLE PLAY DONUTS",
	"BOX SCORE BOOKS",
	"SLIDE SAFE SHOES",
	"CURVEBALL CREAMERY",
	"DUGOUT DELI",
	"PINCH HIT PHARMACY",
	"BASE HIT BARBER",
}

-- Brick walk-ups facing the park with rooftop bleachers (seen over the
-- outfield from the batter's box and in home-run flights).
local function rooftops(ctx: Ctx, c: Cell, lod: number)
	local k = ctx.k
	lot(ctx, c, rgb(160, 156, 148), "Pavement")
	local length = c.u1 - c.u0 - 2 * Town.Sidewalk
	local n = math.max(2, math.floor(length / 52))
	local w = length / n
	local f = Site.cf(ctx.site, (c.u0 + c.u1) / 2, Town.Y.Lot, c.v0 + Town.Sidewalk, 180)
	local names = { "ROOFTOP SEATS", "WAVELAND FLATS", "HOME RUN HOUSE", "BALLHAWK CLUB", "THE PERCH" }
	for i = 0, n - 1 do
		local x = -length / 2 + (i + 0.5) * w
		local h = 34 + (i % 2) * 6
		local color = k:pick(A.Brick)
		local b = f * CFrame.new(x, 0, 22)
		k:box(b * CFrame.new(0, h / 2, 0), Vector3.new(w - 1, h, 44), color, "Brick", false)
		k:box(b * CFrame.new(0, h + 0.5, 0), Vector3.new(w, 1, 45), P.Limestone, "Concrete", false)
		for s = 0, 2 do
			k:box(b * CFrame.new(0, 7 + s * 11, -22.1), Vector3.new(w * 0.7, 4.2, 0.3), rgb(54, 70, 86), "Glass", false)
		end
		-- Rooftop bleacher: steel frame rising away from the park, 4 rows.
		for row = 0, 3 do
			local y = h + 2 + row * 2.2
			k:box(b * CFrame.new(0, y, -14 + row * 4), Vector3.new(w - 6, 0.6, 3.6), rgb(196, 200, 204), "Metal", false)
			if lod >= 1 then
				for seat = -2, 2 do
					if k:rand() < 0.55 then
						local p = b * CFrame.new(seat * (w - 10) / 5, y + 1.3, -14 + row * 4)
						k:box(p, Vector3.new(1.4, 2.2, 0.9), k:pick(A.Awnings), "SmoothPlastic", false).shadow = false
						k:ball((p * CFrame.new(0, 1.7, 0)).Position, 1.05, rgb(234, 184, 146), "SmoothPlastic").shadow = false
					end
				end
			end
		end
		k:box(b * CFrame.new(0, h + 5, -2), Vector3.new(w - 5, 0.4, 26), rgb(90, 96, 104), "Metal", false)
		local sign = k:box(b * CFrame.new(0, h + 13, 1), Vector3.new(w - 8, 4, 0.4), P.Navy, "SmoothPlastic", false)
		sign.sign = { text = names[(i % #names) + 1], color = P.Yellow, font = "GothamBlack" }
		for _, sx in { -(w - 10) / 2, (w - 10) / 2 } do
			k:post((b * CFrame.new(sx, h + 1, 1)).Position, 12, 0.6, rgb(90, 96, 104), "Metal")
		end
	end
	streetTrees(ctx, c, 52)
	parkedCars(ctx, c, 0.5)
	lights(ctx, c)
end

local function fillGrounds(ctx: Ctx, c: Cell, lod: number)
	local k = ctx.k
	if c.v0 >= Town.NorthStart and math.abs((c.u0 + c.u1) / 2) < 600 then
		rooftops(ctx, c, lod)
		return
	end
	local cu, cv = (c.u0 + c.u1) / 2, (c.v0 + c.v1) / 2
	if cu < 0 and cv > 0 or cv < Town.SouthStart then
		-- Ballpark district: hotel, restaurants and a small green.
		lot(ctx, c, rgb(170, 166, 158), "Pavement")
		local f = Site.cf(ctx.site, cu, Town.Y.Lot, cv, if cv > 0 then 90 else 0)
		A.midrise(k, f * CFrame.new(-40, 0, 20), 80, 60, 9, lod)
		local hotel = k:box(f * CFrame.new(-40, 96, -10.5), Vector3.new(60, 8, 0.6), P.Navy, "SmoothPlastic", false)
		hotel.sign = { text = if cv > 0 then "ROOKIE INN" else "GRAND SLAM SUITES", color = P.Yellow, font = "GothamBlack" }
		A.shop(k, f * CFrame.new(60, 0, -40), 70, lod, k:pick(SHOP_NAMES))
		A.shop(k, f * CFrame.new(60, 0, 50), 70, lod, k:pick(SHOP_NAMES))
		flat(ctx, cu - 100, cu - 20, cv + 40, cv + 100, Town.Y.Lot + 0.05, P.Lawn, "Grass", 0.2)
		k:use(ctx.props)
		for i = 0, 3 do
			A.tree(k, Site.at(ctx.site, cu - 90 + i * 22, Town.Y.Lot, cv + 70), 18)
		end
		k:use(ctx.mass)
		streetTrees(ctx, c, 46)
		lights(ctx, c)
		return
	end
	lot(ctx, c, rgb(70, 72, 78), "Asphalt")
	-- Surface parking with striping and cars; a ballpark-facing shop row.
	local ru = c.u1 - c.u0
	-- Tree island down the middle of the lot.
	flat(ctx, c.u0 + 20, c.u1 - 20, (c.v0 + c.v1) / 2 - 5, (c.v0 + c.v1) / 2 + 5, Town.Y.Lot + 0.06, P.Lawn, "Grass", 0.2)
	k:use(ctx.props)
	for u = c.u0 + 30, c.u1 - 30, 40 do
		A.tree(k, Site.at(ctx.site, u, Town.Y.Lot, (c.v0 + c.v1) / 2), 16)
	end
	k:use(ctx.mass)
	for row = 0, 3 do
		local v = c.v0 + 30 + row * ((c.v1 - c.v0 - 60) / 3)
		for u = c.u0 + 20, c.u1 - 20, 12 do
			flat(ctx, u - 0.2, u + 0.2, v - 9, v + 9, Town.Y.Lot + 0.04, P.Paint, "SmoothPlastic", 0.05)
			if k:rand() < 0.55 then
				k:use(ctx.props)
				A.car(k, Site.cf(ctx.site, u + 6, Town.Y.Lot, v, 0))
				k:use(ctx.mass)
			end
		end
	end
	if ru > 120 then
		local name = SHOP_NAMES[math.floor(k:rand() * #SHOP_NAMES) + 1]
		A.shop(k, Site.cf(ctx.site, c.u0 + 40, Town.Y.Lot, c.v1 - 30, 0), 60, lod, name, 2)
	end
	lights(ctx, c)
end

local function fillRow(ctx: Ctx, c: Cell, lod: number)
	local k = ctx.k
	lot(ctx, c, rgb(160, 156, 148), "Pavement")
	sides(ctx, c, 0, function(cf, length, side)
		if side == "S" or side == "N" then
			-- Corner shops at both ends, rowhouses between.
			local shopW = 46
			A.shop(k, cf * CFrame.new(-length / 2 + shopW / 2, 0, 20), shopW, lod, k:pick(SHOP_NAMES))
			A.shop(k, cf * CFrame.new(length / 2 - shopW / 2, 0, 20), shopW, lod, if k:rand() < 0.5 then k:pick(SHOP_NAMES) else nil)
			A.rowhouses(k, cf * CFrame.new(0, 0, 17 + 2), length - 2 * shopW - 4, lod)
		end
	end)
	streetTrees(ctx, c, 46)
	parkedCars(ctx, c, 0.45)
	lights(ctx, c)
end

local function fillHouses(ctx: Ctx, c: Cell, lod: number)
	local k = ctx.k
	lot(ctx, c, P.Lawn, "Grass")
	-- Back fences dividing yards (one long hedge through the middle).
	local cv = (c.v0 + c.v1) / 2
	k:box(Site.cf(ctx.site, (c.u0 + c.u1) / 2, Town.Y.Lot + 2, cv), Vector3.new(c.u1 - c.u0 - 30, 4, 2.4), P.FoliageDark, "LeafyGrass", false)
	sides(ctx, c, 14, function(cf, length, side)
		if side == "S" or side == "N" then
			local n = math.max(1, math.floor(length / 44))
			for i = 0, n - 1 do
				local x = -length / 2 + (i + 0.5) * length / n
				A.house(k, cf * CFrame.new(x, 0, 14), lod)
			end
		end
	end)
	streetTrees(ctx, c, 40)
	if lod >= 2 then
		parkedCars(ctx, c, 0.2)
	end
end

local function fillTownCenter(ctx: Ctx, c: Cell, lod: number)
	local k = ctx.k
	-- Interior is the shared rear parking court (asphalt), framed by sidewalks.
	lot(ctx, c, rgb(74, 76, 82), "Asphalt")
	local onBoulevard = math.abs((c.u0 + c.u1) / 2) < 400
	sides(ctx, c, 0, function(cf, length, side)
		if side ~= "S" and side ~= "N" then
			return
		end
		local n = math.max(1, math.floor(length / 66))
		for i = 0, n - 1 do
			local x = -length / 2 + (i + 0.5) * length / n
			local w = length / n - 3
			do
				if k:rand() < (if onBoulevard then 0.6 else 0.35) then
					A.midrise(k, cf * CFrame.new(x, 0, 26), w, 50, math.floor(k:range(4, if onBoulevard then 9 else 6)), lod)
				else
					A.shop(k, cf * CFrame.new(x, 0, 20), w, lod, if lod >= 2 and k:rand() < 0.5 then k:pick(SHOP_NAMES) else nil)
				end
			end
		end
	end)
	-- Interior: cars and trees in the parking court.
	local cv = (c.v0 + c.v1) / 2
	k:use(ctx.props)
	for u = c.u0 + 40, c.u1 - 40, 24 do
		if k:rand() < 0.5 then
			A.car(k, Site.cf(ctx.site, u, Town.Y.Lot + 0.05, cv + (if k:rand() < 0.5 then -14 else 14), 0))
		end
	end
	for _, u in { c.u0 + 34, c.u1 - 34 } do
		A.tree(k, Site.at(ctx.site, u, Town.Y.Lot, cv), 18)
	end
	k:use(ctx.mass)
	streetTrees(ctx, c, 52)
	parkedCars(ctx, c, 0.35)
	lights(ctx, c)
end

local function fillFoundry(ctx: Ctx, c: Cell, lod: number)
	local k = ctx.k
	local r = k:rand()
	-- Parking lots use an asphalt lot interior (no raised overlay).
	lot(ctx, c, if r >= 0.75 then rgb(64, 66, 72) else rgb(116, 118, 122), if r >= 0.75 then "Asphalt" else "Concrete")
	local w, d = c.u1 - c.u0 - 30, c.v1 - c.v0 - 30
	local cu, cv = (c.u0 + c.u1) / 2, (c.v0 + c.v1) / 2
	if r < 0.45 then
		A.warehouse(k, Site.cf(ctx.site, cu, Town.Y.Lot, cv - d * 0.22, 0), w, d * 0.5, lod)
		A.warehouse(k, Site.cf(ctx.site, cu - w * 0.2, Town.Y.Lot, cv + d * 0.28, 0), w * 0.55, d * 0.4, lod)
	elseif r < 0.75 then
		-- Brick lofts.
		A.midrise(k, Site.cf(ctx.site, cu - w * 0.25, Town.Y.Lot, cv, 0), w * 0.45, d * 0.8, math.floor(k:range(5, 8)), lod)
		A.midrise(k, Site.cf(ctx.site, cu + w * 0.27, Town.Y.Lot, cv, 0), w * 0.4, d * 0.6, math.floor(k:range(3, 6)), lod)
	else
		-- Parking lot with a billboard.
		k:use(ctx.props)
		for i = 0, 10 do
			if k:rand() < 0.6 then
				A.car(k, Site.cf(ctx.site, c.u0 + 30 + i * 18, Town.Y.Lot, cv - 20, 0))
			end
		end
		k:use(ctx.mass)
		A.billboard(
			k,
			Site.cf(ctx.site, cu, Town.Y.Lot, c.v0 + 30, 180),
			k:pick({ "HIT IT FARTHER!", "SUNDIAL SODA", "GRAND SLAM PIZZA", "VISIT ROOKIE PARK", "BRAMBLE BAY BANK" }),
			k:pick({ P.Red, P.Navy, P.Yellow, rgb(40, 120, 80) }),
			P.White
		)
	end
end

local function fillDowntown(ctx: Ctx, c: Cell, lod: number)
	local k = ctx.k
	local roll = k:rand()
	local pocketPark = roll < 0.1 and c.feet < 4400
	-- Pocket parks use the lot interior itself (no raised overlay).
	lot(ctx, c, if pocketPark then rgb(98, 150, 76) else rgb(176, 174, 168), if pocketPark then "Grass" else "Pavement")
	local cu, cv = (c.u0 + c.u1) / 2, (c.v0 + c.v1) / 2
	-- Height peaks around 4,000 ft and near the boulevard.
	local core = math.clamp(1 - math.abs(c.feet - 4000) / 1600, 0.15, 1)
	local axis = math.clamp(1 - math.abs(cu) / 2600, 0.3, 1)
	local maxH = 140 + 420 * core * axis
	local w, d = c.u1 - c.u0 - 34, c.v1 - c.v0 - 34
	if pocketPark then
		-- Pocket plaza: lawn, fountain, trees.
		k:disc(Site.at(ctx.site, cu, Town.Y.Lot + 1.2, cv), 30, 1.2, P.Limestone, "Concrete", false)
		for i = 0, 5 do
			local a = i * math.pi / 3
			A.tree(k, Site.at(ctx.site, cu + math.cos(a) * w * 0.3, Town.Y.Lot, cv + math.sin(a) * d * 0.3), 22)
		end
		return
	elseif roll < 0.3 then
		A.midrise(k, Site.cf(ctx.site, cu - w * 0.22, Town.Y.Lot, cv, 0), w * 0.45, d * 0.8, math.floor(k:range(6, 12)), lod)
		A.tower(
			k,
			Site.cf(ctx.site, cu + w * 0.25, Town.Y.Lot, cv, 0),
			w * 0.36,
			d * 0.5,
			k:range(maxH * 0.4, maxH * 0.8),
			lod,
			k:pick({ "flat", "spire" })
		)
		return
	end
	if roll < 0.62 then
		A.tower(k, Site.cf(ctx.site, cu, Town.Y.Lot, cv, 0), w * 0.55, d * 0.55, k:range(maxH * 0.6, maxH), lod, k:pick({ "flat", "spire", "pyramid", "antenna" }))
	else
		A.tower(k, Site.cf(ctx.site, cu - w * 0.24, Town.Y.Lot, cv - d * 0.1, 0), w * 0.38, d * 0.5, k:range(maxH * 0.5, maxH * 0.9), lod, k:pick({ "flat", "antenna" }))
		A.tower(k, Site.cf(ctx.site, cu + w * 0.26, Town.Y.Lot, cv + d * 0.14, 0), w * 0.34, d * 0.42, k:range(maxH * 0.35, maxH * 0.7), lod, k:pick({ "flat", "pyramid" }))
	end
	if lod >= 1 then
		streetTrees(ctx, c, 60)
	end
end

local function fillHarbor(ctx: Ctx, c: Cell, _lod: number)
	local k = ctx.k
	flat(ctx, c.u0, c.u1, c.v0, c.v1, Town.Y.Lot, rgb(132, 132, 128), "Concrete")
	local cu, cv = (c.u0 + c.u1) / 2, (c.v0 + c.v1) / 2
	local r = k:rand()
	if r < 0.5 then
		A.warehouse(k, Site.cf(ctx.site, cu, Town.Y.Lot, cv, 0), c.u1 - c.u0 - 40, c.v1 - c.v0 - 60, 0)
	else
		-- Container stacks.
		for i = 0, 3 do
			for j = 0, 1 do
				local h = math.floor(k:range(1, 4))
				k:box(
					Site.cf(ctx.site, c.u0 + 50 + i * 50, Town.Y.Lot + h * 4.2, c.v0 + 60 + j * 90, 0),
					Vector3.new(30, h * 8.4, 70),
					k:pick({ rgb(196, 60, 40), rgb(40, 110, 170), rgb(230, 170, 40), rgb(60, 140, 80), rgb(150, 150, 156) }),
					"CorrodedMetal",
					false
				)
			end
		end
	end
end

-- Landmark lots ---------------------------------------------------------------

local function school(ctx: Ctx, c: Cell)
	local k = ctx.k
	lot(ctx, c, P.Lawn, "Grass")
	local cu, cv = (c.u0 + c.u1) / 2, (c.v0 + c.v1) / 2
	local f = Site.cf(ctx.site, cu, Town.Y.Lot, cv, 0)
	-- L-shaped two-storey brick school with entrance and sign.
	k:box(f * CFrame.new(-40, 12, -50), Vector3.new(150, 24, 50), rgb(170, 86, 62), "Brick", false)
	k:box(f * CFrame.new(-90, 12, 0), Vector3.new(50, 24, 120), rgb(170, 86, 62), "Brick", false)
	k:box(f * CFrame.new(-40, 24.8, -50), Vector3.new(152, 1.6, 52), P.Limestone, "Concrete", false)
	k:box(f * CFrame.new(-90, 24.8, 0), Vector3.new(52, 1.6, 122), P.Limestone, "Concrete", false)
	for s = 0, 1 do
		k:box(f * CFrame.new(-30, 6 + s * 11, -75.2), Vector3.new(120, 4, 0.3), rgb(54, 70, 86), "Glass", false)
	end
	local sign = k:box(f * CFrame.new(-10, 28.6, -76), Vector3.new(64, 5, 0.4), P.Navy, "SmoothPlastic", false)
	sign.sign = { text = "MAPLE HEIGHTS ELEMENTARY", color = P.White, font = "GothamBlack" }
	k:post((f * CFrame.new(30, 0, -90)).Position, 34, 0.6, P.White, "Metal")
	local flag = k:box(f * CFrame.new(33, 31, -90), Vector3.new(6, 3.6, 0.12), P.Navy, "Fabric", false)
	flag.tag = "Flag"
	-- Running track and field, playground.
	local track = f * CFrame.new(50, 0, 30)
	k:box(track * CFrame.new(0, 0.06, 0), Vector3.new(90, 0.14, 130), rgb(176, 72, 56), "Rubber", false)
	k:box(track * CFrame.new(0, 0.12, 0), Vector3.new(70, 0.14, 110), P.Grass, "Grass", false)
	for _, z in { -50, 50 } do
		k:box(track * CFrame.new(0, 4, z), Vector3.new(16, 8, 0.4), P.White, "Metal", false).transparency = 0.5
	end
	local play = f * CFrame.new(-40, 0, 40)
	k:box(play * CFrame.new(0, 0.08, 0), Vector3.new(40, 0.18, 34), rgb(214, 190, 140), "Sand", false)
	k:box(play * CFrame.new(-8, 5, 0), Vector3.new(10, 1, 10), rgb(230, 60, 50), "Plastic", false)
	k:wedge(play * CFrame.new(-8, 2.5, 9) * CFrame.Angles(0, math.pi, 0), Vector3.new(3, 5, 8), rgb(250, 200, 50), "Plastic", false)
	for _, x in { -12, -4 } do
		k:post((play * CFrame.new(x, 0, -4)).Position, 5, 0.5, rgb(40, 120, 200), "Metal")
	end
	k:box(play * CFrame.new(10, 6, -6), Vector3.new(14, 0.5, 0.5), rgb(40, 120, 200), "Metal", false)
	for _, x in { 4, 16 } do
		k:post((play * CFrame.new(x, 0, -6)).Position, 6, 0.4, rgb(40, 120, 200), "Metal")
	end
end

local function park(ctx: Ctx, c: Cell)
	local k = ctx.k
	lot(ctx, c, rgb(92, 150, 72), "Grass")
	local cu, cv = (c.u0 + c.u1) / 2, (c.v0 + c.v1) / 2
	local f = Site.cf(ctx.site, cu, Town.Y.Lot, cv, 0)
	-- Pond, paths, gazebo, basketball court, playground, trees.
	local pond = k:ellipsoid(f * CFrame.new(-40, -0.2, 20), Vector3.new(70, 0.6, 46), P.Water, "Glass")
	pond.reflectance = 0.25
	k:box(f * CFrame.new(0, 0.05, 0), Vector3.new(10, 0.12, c.v1 - c.v0 - 20), rgb(214, 200, 170), "Pebble", false)
	k:box(f * CFrame.new(0, 0.05, 0), Vector3.new(c.u1 - c.u0 - 20, 0.12, 10), rgb(214, 200, 170), "Pebble", false)
	local g = f * CFrame.new(0, 0, 0)
	k:disc(g.Position + Vector3.new(0, 1.2, 0), 18, 1.2, P.White, "WoodPlanks", false)
	for i = 0, 5 do
		local a = i * math.pi / 3
		k:post((g * CFrame.new(math.cos(a) * 7.5, 1.2, math.sin(a) * 7.5)).Position, 8, 0.5, P.White, "Wood")
	end
	k:ellipsoid(g * CFrame.new(0, 10.5, 0), Vector3.new(20, 5, 20), rgb(140, 70, 56), "RoofShingles")
	local court = f * CFrame.new(60, 0, -50)
	k:box(court * CFrame.new(0, 0.08, 0), Vector3.new(50, 0.16, 28), rgb(60, 110, 150), "SmoothPlastic", false)
	k:box(court * CFrame.new(0, 0.12, 0), Vector3.new(40, 0.16, 22), rgb(196, 110, 60), "SmoothPlastic", false)
	k:box(court * CFrame.new(0, 0.15, 0), Vector3.new(0.4, 0.16, 22), P.White, "SmoothPlastic", false)
	for _, x in { -19, 19 } do
		k:post((court * CFrame.new(x + (if x < 0 then -1.5 else 1.5), 0, 0)).Position, 10, 0.5, rgb(60, 60, 66), "Metal")
		k:box(court * CFrame.new(x, 10, 0), Vector3.new(0.3, 3.6, 6), P.White, "SmoothPlastic", false)
		k:cyl(court * CFrame.new(x + (if x < 0 then 1 else -1), 9, 0) * CFrame.Angles(0, 0, math.pi / 2), 0.15, 1.6, rgb(230, 90, 40), "Metal", false)
	end
	local sign = k:box(f * CFrame.new(0, 3, -(c.v1 - c.v0) / 2 + 12), Vector3.new(30, 4, 0.6), rgb(60, 100, 60), "Wood", false)
	sign.sign = { text = "DUGOUT COMMONS", color = P.White, font = "GothamBlack" }
	k:use(ctx.props)
	for _ = 1, 16 do
		local u = k:range(c.u0 + 20, c.u1 - 20)
		local v = k:range(c.v0 + 20, c.v1 - 20)
		if math.abs(u - cu) > 12 and math.abs(v - cv) > 12 then
			A.tree(k, Site.at(ctx.site, u, Town.Y.Lot, v), k:range(16, 26))
		end
	end
	k:use(ctx.mass)
end

local function square(ctx: Ctx, c: Cell)
	local k = ctx.k
	lot(ctx, c, rgb(196, 184, 160), "Cobblestone")
	local cu, cv = (c.u0 + c.u1) / 2, (c.v0 + c.v1) / 2
	local f = Site.cf(ctx.site, cu, Town.Y.Lot, cv, 0)
	-- Clock tower.
	k:box(f * CFrame.new(0, 2, 0), Vector3.new(26, 4, 26), P.Limestone, "Concrete", false)
	k:box(f * CFrame.new(0, 40, 0), Vector3.new(16, 76, 16), rgb(160, 80, 60), "Brick", false)
	k:box(f * CFrame.new(0, 80, 0), Vector3.new(19, 8, 19), P.Limestone, "Concrete", false)
	for i = 0, 3 do
		local face = f * CFrame.Angles(0, i * math.pi / 2, 0)
		k:cyl(face * CFrame.new(0, 70, -8.2) * CFrame.Angles(0, math.pi / 2, 0), 0.4, 11, P.White, "SmoothPlastic", false)
		k:box(face * CFrame.new(0, 71.5, -8.5), Vector3.new(0.5, 4, 0.2), P.Black, "SmoothPlastic", false)
		k:box(face * CFrame.new(1.2, 70, -8.5) * CFrame.Angles(0, 0, math.rad(60)), Vector3.new(0.5, 3, 0.2), P.Black, "SmoothPlastic", false)
	end
	A.gable(k, f * CFrame.new(0, 84, 0), 19, 19, 18, rgb(60, 90, 80), "Metal")
	-- Fountain, benches, trees.
	k:disc(f.Position + Vector3.new(40, 1.4, 30), 26, 1.4, P.Limestone, "Concrete", false)
	k:disc(f.Position + Vector3.new(40, 1.5, 30), 22, 0.4, P.Water, "Glass", false).reflectance = 0.3
	k:post(f.Position + Vector3.new(40, 1.4, 30), 6, 2.4, P.Limestone, "Concrete")
	k:use(ctx.props)
	for i = 0, 7 do
		local a = i * math.pi / 4
		A.tree(k, (f * CFrame.new(math.cos(a) * 70, 0, math.sin(a) * 60)).Position, 18)
	end
	k:use(ctx.mass)
end

local function gasStation(ctx: Ctx, c: Cell)
	local k = ctx.k
	lot(ctx, c, rgb(90, 92, 98), "Asphalt")
	local cu, cv = (c.u0 + c.u1) / 2, (c.v0 + c.v1) / 2
	local f = Site.cf(ctx.site, cu, Town.Y.Lot, cv, 0)
	k:box(f * CFrame.new(0, 16, -20), Vector3.new(80, 2.4, 40), P.White, "SmoothPlastic", false)
	k:box(f * CFrame.new(0, 14.4, -20), Vector3.new(80.4, 1.2, 40.4), P.Red, "SmoothPlastic", false)
	for _, x in { -28, 0, 28 } do
		k:post((f * CFrame.new(x, 0, -20)).Position, 15, 1.2, P.White, "Metal")
		k:box(f * CFrame.new(x + 6, 2.6, -20), Vector3.new(2.4, 5.2, 2), rgb(40, 44, 50), "Metal", false)
	end
	k:box(f * CFrame.new(10, 7, 50), Vector3.new(60, 14, 34), rgb(230, 226, 214), "Plaster", false)
	k:box(f * CFrame.new(10, 7, 32.9), Vector3.new(44, 8, 0.3), rgb(70, 100, 120), "Glass", false)
	local mart = k:box(f * CFrame.new(10, 12.6, 32.7), Vector3.new(40, 2.6, 0.3), P.Red, "SmoothPlastic", false)
	mart.sign = { text = "FILL-UP MART", color = P.White, font = "GothamBlack" }
	k:post((f * CFrame.new(-60, 0, -70)).Position, 40, 2, rgb(60, 64, 70), "Metal")
	local pylon = k:box(f * CFrame.new(-60, 44, -70), Vector3.new(16, 12, 2), P.Red, "SmoothPlastic", false)
	pylon.sign = { text = "FILL-UP", color = P.White, font = "LuckiestGuy" }
	k:use(ctx.props)
	A.car(k, f * CFrame.new(-14, 0, -20), nil)
	A.car(k, f * CFrame.new(14, 0, -24), nil)
	k:use(ctx.mass)
end

local function construction(ctx: Ctx, c: Cell)
	local k = ctx.k
	lot(ctx, c, rgb(160, 130, 96), "Ground")
	local cu, cv = (c.u0 + c.u1) / 2, (c.v0 + c.v1) / 2
	local f = Site.cf(ctx.site, cu, Town.Y.Lot, cv, 0)
	-- Steel frame of a rising tower, two cranes, site fence.
	for x = -30, 30, 20 do
		for z = -30, 30, 20 do
			k:box(f * CFrame.new(x, 50, z), Vector3.new(1.6, 100, 1.6), rgb(196, 110, 50), "Metal", false)
		end
	end
	for y = 20, 100, 20 do
		k:box(f * CFrame.new(0, y, 0), Vector3.new(62, 1.4, 62), rgb(170, 170, 170), "Concrete", false)
	end
	A.crane(k, (f * CFrame.new(50, 0, 40)).Position, 150, math.rad(30))
	A.crane(k, (f * CFrame.new(-70, 0, -50)).Position, 110, math.rad(200))
	local fence = k:box(f * CFrame.new(0, 4, -(c.v1 - c.v0) / 2 + 14), Vector3.new(c.u1 - c.u0 - 30, 8, 0.4), rgb(40, 110, 170), "Plastic", false)
	fence.sign = { text = "COMING SOON: FOUNDRY TOWER", color = P.White, font = "GothamBlack" }
end

local function crownTower(ctx: Ctx, c: Cell)
	local k = ctx.k
	lot(ctx, c, rgb(196, 192, 184), "Marble")
	local cu, cv = (c.u0 + c.u1) / 2, (c.v0 + c.v1) / 2
	A.tower(k, Site.cf(ctx.site, cu, Town.Y.Lot, cv, 0), 120, 110, 640, 2, "gold", rgb(60, 92, 120))
end

local function namedTower(ctx: Ctx, c: Cell, l: RegionMap.Landmark)
	local k = ctx.k
	lot(ctx, c, rgb(186, 184, 176), "Pavement")
	local cu, cv = (c.u0 + c.u1) / 2, (c.v0 + c.v1) / 2
	if l.id == "pennant_building" then
		-- Slim tower topped by a giant pennant.
		local top = A.tower(k, Site.cf(ctx.site, cu, Town.Y.Lot, cv, 0), 80, 80, 470, 2, "flat", rgb(120, 60, 60))
		local f = Site.cf(ctx.site, cu, Town.Y.Lot + top, cv, 0)
		k:post(f.Position, 70, 2, P.White, "Metal")
		local pennant = k:wedge(f * CFrame.new(16, 58, 0) * CFrame.Angles(0, math.pi / 2, math.pi / 2), Vector3.new(1, 30, 26), P.Red, "Fabric", false)
		pennant.tag = "Flag"
	else
		A.tower(k, Site.cf(ctx.site, cu, Town.Y.Lot, cv, 0), 100, 90, 540, 2, "pyramid", rgb(80, 120, 110))
		local f = Site.cf(ctx.site, cu, Town.Y.Lot, cv, 0)
		local s = k:box(f * CFrame.new(0, 60, -51), Vector3.new(60, 10, 0.5), P.Navy, "SmoothPlastic", false)
		s.sign = { text = "BRAMBLE BAY BANK", color = rgb(240, 210, 120), font = "GothamBlack" }
	end
end

local function cornerMart(ctx: Ctx, c: Cell, l: RegionMap.Landmark)
	local k = ctx.k
	lot(ctx, c, rgb(160, 156, 148), "Pavement")
	local cu = (c.u0 + c.u1) / 2
	local f = Site.cf(ctx.site, cu, Town.Y.Lot, c.v0 + 50, 180)
	if l.id == "corner_mart" then
		k:box(f * CFrame.new(0, 9, 0), Vector3.new(90, 18, 50), rgb(232, 226, 210), "Plaster", false)
		k:box(f * CFrame.new(0, 16, -25.4), Vector3.new(92, 4, 1), P.Red, "SmoothPlastic", false)
		local s = k:box(f * CFrame.new(0, 16, -26), Vector3.new(70, 3.2, 0.2), P.Red, "SmoothPlastic", false)
		s.sign = { text = "CORNER MART  24/7", color = P.White, font = "GothamBlack" }
		k:box(f * CFrame.new(0, 6, -25.2), Vector3.new(70, 8, 0.3), rgb(70, 100, 120), "Glass", false)
		k:box(f * CFrame.new(-38, 4, -30), Vector3.new(6, 8, 3), rgb(220, 40, 40), "Plastic", false)
	else
		-- Retro diner: stainless body, rounded roof, neon-free sign.
		k:box(f * CFrame.new(0, 8, 0), Vector3.new(80, 16, 34), rgb(214, 218, 222), "Metal", false)
		k:ellipsoid(f * CFrame.new(0, 16, 0), Vector3.new(82, 6, 36), rgb(200, 60, 60), "SmoothPlastic")
		k:box(f * CFrame.new(0, 8, -17.2), Vector3.new(70, 6, 0.3), rgb(70, 100, 120), "Glass", false)
		k:box(f * CFrame.new(0, 3, -17.4), Vector3.new(80, 1.2, 0.3), rgb(200, 60, 60), "SmoothPlastic", false)
		local s = k:box(f * CFrame.new(0, 26, -10), Vector3.new(56, 8, 1), rgb(40, 50, 90), "SmoothPlastic", false)
		s.sign = { text = "SEVENTH INNING DINER", color = rgb(255, 210, 90), font = "LuckiestGuy" }
		for _, x in { -20, 20 } do
			k:post((f * CFrame.new(x, 16, -10)).Position, 6, 0.6, rgb(150, 150, 156), "Metal")
		end
	end
	-- Rest of the block: rowhouses on the far side.
	local back = Site.cf(ctx.site, cu, Town.Y.Lot, c.v1 - 9, 0)
	A.rowhouses(k, back * CFrame.new(0, 0, 19), c.u1 - c.u0 - 30, 2)
	streetTrees(ctx, c, 46)
	lights(ctx, c)
end

local function garage(ctx: Ctx, c: Cell)
	local k = ctx.k
	lot(ctx, c, rgb(160, 156, 148), "Pavement")
	local cu, cv = (c.u0 + c.u1) / 2, (c.v0 + c.v1) / 2
	local w, d = c.u1 - c.u0 - 40, c.v1 - c.v0 - 40
	local f = Site.cf(ctx.site, cu, Town.Y.Lot, cv, -90)
	for level = 0, 4 do
		local y = level * 11
		k:box(f * CFrame.new(0, y + 0.6, 0), Vector3.new(d, 1.2, w), rgb(170, 168, 162), "Concrete", false)
		if level > 0 then
			k:box(f * CFrame.new(0, y + 2.4, -w / 2), Vector3.new(d, 3.6, 0.8), rgb(196, 192, 184), "Concrete", false)
			k:box(f * CFrame.new(0, y + 2.4, w / 2), Vector3.new(d, 3.6, 0.8), rgb(196, 192, 184), "Concrete", false)
		end
		if level < 4 then
			for x = -d / 2 + 6, d / 2 - 6, (d - 12) / 4 do
				for _, z in { -w / 2 + 6, 0, w / 2 - 6 } do
					k:box(f * CFrame.new(x, y + 5.5, z), Vector3.new(2, 10, 2), rgb(150, 148, 142), "Concrete", false)
				end
			end
		end
		k:use(ctx.props)
		for i = 0, 7 do
			if k:rand() < 0.6 then
				A.car(k, f * CFrame.new(-d / 2 + 14 + i * (d - 28) / 7, y + 1.2, -w / 4) * CFrame.Angles(0, math.pi / 2, 0))
			end
		end
		k:use(ctx.mass)
	end
	local s = k:box(f * CFrame.new(0, 50, -w / 2 - 1), Vector3.new(50, 8, 0.6), P.Navy, "SmoothPlastic", false)
	s.sign = { text = "BALLPARK GARAGE  P", color = P.White, font = "GothamBlack" }
	-- Stair/elevator core.
	k:box(f * CFrame.new(d / 2 - 8, 26, w / 2 - 8), Vector3.new(14, 52, 14), P.Brick, "Brick", false)
end

-- Special rows -----------------------------------------------------------------

function Town.riverCenter(u: number): number
	local r = Town.River
	return r.Center + r.Amplitude * math.sin(u / r.Wavelength * 2 * math.pi)
end

local function riverCell(ctx: Ctx, c: Cell)
	local k = ctx.k
	-- Banks (lawn) with the water channel cut through as strips.
	local step = 60
	for u = c.u0 - Town.Street / 2, c.u1 + Town.Street / 2 - 1, step do
		local u1 = math.min(u + step, c.u1 + Town.Street / 2)
		local mid = Town.riverCenter((u + u1) / 2)
		local half = Town.River.Width / 2
		local water = k:box(Site.cf(ctx.site, (u + u1) / 2, Town.Y.Land - 0.15, mid), Vector3.new(u1 - u + 0.2, 0.4, Town.River.Width), P.Water, "Glass", false)
		water.reflectance = 0.25
		flat(ctx, u, u1, c.v0 - Town.Street / 2, mid - half, Town.Y.Lot, rgb(92, 146, 70), "Grass")
		flat(ctx, u, u1, mid + half, c.v1 + Town.Street / 2, Town.Y.Lot, rgb(92, 146, 70), "Grass")
		-- Stone embankment edges.
		k:box(Site.cf(ctx.site, (u + u1) / 2, -1.0, mid - half - 1), Vector3.new(u1 - u + 0.2, 1.4, 2), rgb(150, 146, 136), "Slate", false)
		k:box(Site.cf(ctx.site, (u + u1) / 2, -1.0, mid + half + 1), Vector3.new(u1 - u + 0.2, 1.4, 2), rgb(150, 146, 136), "Slate", false)
	end
	k:use(ctx.props)
	for u = c.u0, c.u1, 34 do
		local mid = Town.riverCenter(u)
		A.tree(k, Site.at(ctx.site, u, Town.Y.Lot, mid - Town.River.Width / 2 - 12), k:range(16, 22))
		A.tree(k, Site.at(ctx.site, u + 17, Town.Y.Lot, mid + Town.River.Width / 2 + 12), k:range(16, 22))
	end
	k:use(ctx.mass)
end

local function bridges(k: Kit.Kit, site: Site.Site, us: { number })
	local half = Town.River.Width / 2 + 14
	for _, u in us do
		local mid = Town.riverCenter(u)
		local w = if u == 0 then Town.Boulevard else Town.Street
		k:box(Site.cf(site, u, Town.Y.Street - 0.5, mid), Vector3.new(w + 6, 1, 2 * half), rgb(150, 150, 146), "Concrete", false)
		for _, s in { -1, 1 } do
			k:box(Site.cf(site, u + s * (w / 2 + 2), 1.4, mid), Vector3.new(1.4, 2.8, 2 * half), rgb(196, 192, 184), "Concrete", false)
			k:box(Site.cf(site, u + s * (w / 2 + 2), -2.5, mid), Vector3.new(1.4, 4, 2 * half), rgb(120, 118, 112), "Concrete", false)
		end
		-- Arched under-structure.
		k:ellipsoid(Site.cf(site, u, -3, mid), Vector3.new(w + 4, 6, 2 * half - 20), rgb(120, 118, 112), "Concrete")
	end
end

local function highway(k: Kit.Kit, site: Site.Site)
	local H = Town.Highway
	local from, to = -3800, 3800
	local seg = 260
	for u = from, to - 1, seg do
		local cu = u + seg / 2
		local v = H.V
		k:box(Site.cf(site, cu, H.Height, v), Vector3.new(seg + 0.4, 3, H.Width), rgb(150, 150, 146), "Concrete", false)
		k:box(Site.cf(site, cu, H.Height + 1.55, v), Vector3.new(seg + 0.4, 0.1, H.Width - 6), rgb(66, 68, 74), "Asphalt", false)
		k:box(Site.cf(site, cu, H.Height + 1.62, v), Vector3.new(seg, 0.08, 0.6), P.PaintYellow, "SmoothPlastic", false)
		for _, s in { -1, 1 } do
			k:box(Site.cf(site, cu, H.Height + 3, v + s * (H.Width / 2 - 1)), Vector3.new(seg + 0.4, 3, 1.4), rgb(196, 192, 184), "Concrete", false)
		end
		-- Pier with a hammerhead cap.
		k:box(Site.cf(site, u, H.Height / 2 - 1, v), Vector3.new(7, H.Height - 2, 12), rgb(170, 168, 162), "Concrete", false)
		k:box(Site.cf(site, u, H.Height - 3, v), Vector3.new(9, 3, H.Width - 4), rgb(170, 168, 162), "Concrete", false)
	end
	-- Green guide signs on a gantry over the boulevard.
	for _, x in { -60, 60 } do
		k:post(Site.at(site, x, H.Height + 3, H.V - H.Width / 2 + 1), 16, 1, rgb(110, 114, 120), "Metal")
	end
	k:box(Site.cf(site, 0, H.Height + 18, H.V - H.Width / 2 + 1), Vector3.new(124, 1.4, 1.4), rgb(110, 114, 120), "Metal", false)
	for i, text in { "DOWNTOWN  NEXT EXIT", "HARBOR YARDS  2 MI" } do
		local s = k:box(Site.cf(site, (i - 1.5) * 60, H.Height + 13, H.V - H.Width / 2 + 0.2, 180), Vector3.new(54, 9, 0.4), rgb(30, 110, 60), "SmoothPlastic", false)
		s.sign = { text = text, color = P.White, font = "GothamBlack" }
	end
	-- Cars on the deck.
	for u = from + 40, to - 40, 90 do
		if k:rand() < 0.7 then
			A.car(k, Site.cf(site, u, H.Height + 1.6, H.V + (if k:rand() < 0.5 then -8 else 8), if k:rand() < 0.5 then 90 else -90))
		end
	end
end

-- Builds every town cell, the street network surfaces and special corridors.
function Town.build(k: Kit.Kit, site: Site.Site)
	local cells = Town.cells()
	local groups: { [string]: { mass: Kit.Chunk, props: Kit.Chunk } } = {}
	local function group(c: Cell)
		local g = groups[c.group]
		if not g then
			k:chunk(`TownProps_{c.group}`, Config.Lod.Props)
			local props = k.current :: Kit.Chunk
			k:chunk(`Town_{c.group}`, 0)
			local mass = k.current :: Kit.Chunk
			g = { mass = mass, props = props }
			groups[c.group] = g
		end
		return g
	end
	-- Near cells first so the realized world grows outward from the park.
	table.sort(cells, function(a, b)
		return a.r < b.r
	end)
	local bridgeUs: { [number]: boolean } = {}
	for _, c in cells do
		k:step()
		local g = group(c)
		local ctx: Ctx = { k = k, site = site, mass = g.mass, props = g.props }
		k:use(g.mass)
		-- Street surface under the cell plus half of each bordering street.
		local half = Town.Street / 2
		if c.special ~= "river" then
			flat(ctx, c.u0 - half, c.u1 + half, c.v0 - half, c.v1 + half, Town.Y.Street, P.Asphalt, "Asphalt", 0.3)
			-- Centre lines on the two streets this cell owns (north and east).
			if c.feet < 2600 then
				flat(ctx, c.u0, c.u1, c.v1 + half - 0.3, c.v1 + half + 0.3, Town.Y.Street + 0.03, P.PaintYellow, "SmoothPlastic", 0.06)
				flat(ctx, c.u1 + half - 0.3, c.u1 + half + 0.3, c.v0, c.v1, Town.Y.Street + 0.03, P.PaintYellow, "SmoothPlastic", 0.06)
			end
		end
		local nearLod = if c.feet < 1150 and math.abs(c.phi) < 55 then 2 elseif c.feet < 2400 then 1 else 0
		-- Buildings a free-roaming player can walk to are solid; distant massing
		-- stays non-colliding so it never interferes with the follow camera.
		k:solid(c.feet < Town.SolidFeet)
		local l = c.landmark
		local kind = l and l.kind
		if c.special == "river" then
			riverCell(ctx, c)
			for _, u in { c.u0 - half, c.u1 + half } do
				-- The two boulevard-side cells share one wide bridge at u = 0.
				bridgeUs[if math.abs(u) < Town.Boulevard then 0 else math.floor(u + 0.5)] = true
			end
		elseif kind == "School" then
			school(ctx, c)
		elseif kind == "Park" then
			park(ctx, c)
		elseif kind == "Square" then
			square(ctx, c)
		elseif kind == "GasStation" then
			gasStation(ctx, c)
		elseif kind == "Construction" then
			construction(ctx, c)
		elseif kind == "CrownTower" then
			crownTower(ctx, c)
		elseif kind == "Tower" and l then
			namedTower(ctx, c, l)
		elseif (kind == "CornerMart" or kind == "Diner") and l then
			cornerMart(ctx, c, l)
		elseif kind == "Garage" then
			garage(ctx, c)
		elseif c.special == "highway" then
			-- Under the overpass: surface parking and low warehouses.
			fillFoundry(ctx, c, 0)
		elseif c.region == "grounds" or c.region == "stadium" then
			fillGrounds(ctx, c, nearLod)
		elseif c.region == "ballpark_row" then
			fillRow(ctx, c, nearLod)
		elseif c.region == "maple_heights" then
			fillHouses(ctx, c, nearLod)
		elseif c.region == "town_center" then
			fillTownCenter(ctx, c, nearLod)
		elseif c.region == "foundry" then
			fillFoundry(ctx, c, nearLod)
		elseif c.region == "downtown" then
			fillDowntown(ctx, c, if c.feet < 4200 and math.abs((c.u0 + c.u1) / 2) < 1300 then 1 else 0)
		else
			fillHarbor(ctx, c, 0)
		end
	end
	-- Grand Slam Boulevard: asphalt and a tree-lined median between the cells.
	k:solid(false)
	k:chunk("Boulevard", 0)
	local rows: { [string]: { number } } = {}
	for _, c in cells do
		if c.v0 >= Town.NorthStart and math.abs(c.u0 - Town.Boulevard / 2) < 1 and c.special ~= "river" then
			rows[`{c.v0}`] = { c.v0, c.v1 }
		end
	end
	local half = Town.Street / 2
	for _, r in rows do
		local v0, v1 = r[1] - half, r[2] + half
		flat({ k = k, site = site, mass = k.current :: Kit.Chunk, props = k.current :: Kit.Chunk }, -15, 15, v0, v1, Town.Y.Street, P.Asphalt, "Asphalt", 0.3)
		flat({ k = k, site = site, mass = k.current :: Kit.Chunk, props = k.current :: Kit.Chunk }, -9, 9, r[1], r[2], Town.Y.Lot, rgb(84, 140, 66), "Grass", 0.3)
		for v = r[1] + 12, r[2] - 12, 36 do
			A.tree(k, Site.at(site, 0, Town.Y.Lot, v), 18)
		end
	end
	k:chunk("RiverBridges", 0)
	local us: { number } = {}
	for u in bridgeUs do
		table.insert(us, u)
	end
	table.sort(us)
	bridges(k, site, us)
	k:chunk("Highway", 0)
	highway(k, site)
	return cells
end

return Town
