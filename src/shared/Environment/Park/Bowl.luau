--!strict
-- Seating bowl: a continuous lower bowl wrapping from the left-field corner,
-- behind home plate, to the right-field corner; an upper deck with press box
-- and cantilevered roof around the infield; the Home Plate Club walkway and
-- tunnel behind the backstop; dugouts cut into the stands; crowd.
--
-- Treads, aisles, walkways and walls are walkable (character collision only;
-- never part of the batted-ball landing set). Seats, crowd, rails and nets are
-- visual. The area around the authored SpawnLocation (48-66 studs behind the
-- plate on the centre line) is kept open as the club walkway.

local Environment = script.Parent.Parent
local Config = require(Environment.EnvironmentConfig)
local Site = require(Environment.Site)
local Kit = require(Environment.EnvKit)
local Layout = require(script.Parent.Layout)

local Bowl = {}

local P = Config.Palette
local rgb = Config.rgb

-- Profile (offsets are measured outward from the stands' front edge).
Bowl.Lower = { Rows = 15, Depth = 3.3, Rise = 1.3, FirstTop = 3.2 }
Bowl.Aisle = { Depth = 9 } -- cross-aisle walkway between the lower and upper tiers
Bowl.Upper = { Rows = 10, Depth = 3.1, Rise = 1.85 }
Bowl.AisleWidth = 2.6
Bowl.WallTop = 4.4
Bowl.CoreBack = 102
Bowl.LineBack = 61
Bowl.LeftAlong = { 244, 220, 196, 172, 148, 124, 104, 84, 40 } -- stays inside the 512-stud stadium block
Bowl.DugoutAlong = { 40, 84 }
Bowl.UpperMaxAlong = 84
Bowl.ArcSections = 9

local L, U = Bowl.Lower, Bowl.Upper
local function lowerTop(k: number): number
	return L.FirstTop + L.Rise * k
end
local aisleTop = lowerTop(L.Rows - 1) + L.Rise
local aisleFront = L.Rows * L.Depth
local upperFront = aisleFront + Bowl.Aisle.Depth
local function upperTop(j: number): number
	return aisleTop + U.Rise * (j + 1)
end
local upperBack = upperFront + U.Rows * U.Depth
Bowl.AisleTop = aisleTop
Bowl.UpperBack = upperBack

export type Station = { p: Layout.P2, n: Layout.P2, along: number?, angle: number? }
export type Section = {
	a: Station,
	b: Station,
	side: string, -- "L" | "H" | "R"
	order: number, -- 1.. from home outward on each side (arc: 0)
	skip: number, -- lower rows removed at the front (dugout/club)
	dugout: boolean,
	club: boolean,
	tunnel: boolean,
	upper: boolean,
	back: number,
	alongMid: number?,
	aisle: boolean, -- aisle stairs on the section's start edge
}

local function stations(layout: Layout.Layout): { Station }
	local list: { Station } = {}
	local tA = Layout.tangentAlong(layout)
	for _, along in Bowl.LeftAlong do
		table.insert(list, { p = Layout.sidePoint(layout, 1, along, 0), n = layout.outward[1], along = along })
	end
	local c, r = layout.backstopCenter, layout.backstopRadius
	local a0 = math.atan2(layout.outward[1][1], layout.outward[1][2])
	local a1 = math.atan2(layout.outward[2][1], layout.outward[2][2]) - 2 * math.pi
	for i = 0, Bowl.ArcSections do
		local a = a0 + (a1 - a0) * i / Bowl.ArcSections
		local n = { math.sin(a), math.cos(a) }
		table.insert(
			list,
			{ p = { c[1] + r * n[1], c[2] + r * n[2] }, n = n, angle = a, along = if i == 0 or i == Bowl.ArcSections then tA else nil }
		)
	end
	for i = #Bowl.LeftAlong, 1, -1 do
		local along = Bowl.LeftAlong[i]
		table.insert(list, { p = Layout.sidePoint(layout, 2, along, 0), n = layout.outward[2], along = along })
	end
	return list
end

function Bowl.sections(layout: Layout.Layout): { Section }
	local st = stations(layout)
	local out: { Section } = {}
	local nLeft = #Bowl.LeftAlong
	local arcStart, arcEnd = nLeft + 1, nLeft + 1 + Bowl.ArcSections
	for i = 1, #st - 1 do
		local a, b = st[i], st[i + 1]
		local side = if i < arcStart then "L" elseif i >= arcEnd then "R" else "H"
		local alongMid = if a.along and b.along then (a.along + b.along) / 2 else nil
		local order = if side == "L" then arcStart - i elseif side == "R" then i - arcEnd + 1 else 0
		local arcIndex = i - arcStart -- 0..ArcSections-1
		local centre = (Bowl.ArcSections - 1) / 2
		local club = side == "H" and math.abs(arcIndex - centre) <= 1
		local dugout = side ~= "H"
			and alongMid ~= nil
			and alongMid > Bowl.DugoutAlong[1]
			and alongMid < Bowl.DugoutAlong[2]
		local upper = side == "H" or (alongMid ~= nil and alongMid < Bowl.UpperMaxAlong)
		table.insert(out, {
			a = a,
			b = b,
			side = side,
			order = order,
			skip = if club then 5 elseif dugout then 4 else 0,
			dugout = dugout,
			club = club,
			tunnel = side == "H" and arcIndex == centre,
			upper = upper,
			back = if upper then Bowl.CoreBack else Bowl.LineBack,
			alongMid = alongMid,
			aisle = i ~= 1,
		})
	end
	return out
end

-- World helpers for a section ----------------------------------------------

local function v2(site: Site.Site, x: Layout.P2): Vector3
	return site.right * x[1] + site.forward * x[2]
end

type Frame = {
	site: Site.Site,
	s: Section,
	at: (offset: number, frac: number, y: number) -> Vector3,
	width: (offset: number) -> number,
	cf: (offset: number, frac: number, y: number) -> CFrame,
}

local function frame(site: Site.Site, s: Section): Frame
	local nA, nB = s.a.n, s.b.n
	local function point(offset: number, frac: number): Layout.P2
		local pa = { s.a.p[1] + nA[1] * offset, s.a.p[2] + nA[2] * offset }
		local pb = { s.b.p[1] + nB[1] * offset, s.b.p[2] + nB[2] * offset }
		return { pa[1] + (pb[1] - pa[1]) * frac, pa[2] + (pb[2] - pa[2]) * frac }
	end
	local nMid = { (nA[1] + nB[1]) / 2, (nA[2] + nB[2]) / 2 }
	local outward = v2(site, nMid).Unit
	local across = Vector3.new(0, 1, 0):Cross(outward).Unit
	local f: Frame = {
		site = site,
		s = s,
		at = function(offset: number, frac: number, y: number): Vector3
			local p = point(offset, frac)
			return Site.at(site, p[1], y, p[2])
		end,
		width = function(offset: number): number
			local p0, p1 = point(offset, 0), point(offset, 1)
			return math.sqrt((p1[1] - p0[1]) ^ 2 + (p1[2] - p0[2]) ^ 2)
		end,
		cf = function(offset: number, frac: number, y: number): CFrame
			local p = point(offset, frac)
			return CFrame.fromMatrix(Site.at(site, p[1], y, p[2]), across, Vector3.yAxis, outward)
		end,
	}
	return f
end

-- Box spanning offsets [o0, o1] and heights [y0, y1] across the section
-- (width measured at the mid offset, minus `inset` on each side).
local function slab(
	k: Kit.Kit,
	f: Frame,
	o0: number,
	o1: number,
	y0: number,
	y1: number,
	color: Kit.Color,
	material: string,
	collide: boolean,
	inset: number?,
	frac: number?,
	widthOverride: number?
): Kit.Spec
	local om = (o0 + o1) / 2
	-- Width at the outer edge: arc sections widen outward, so neighbours
	-- overlap slightly instead of opening gaps.
	local w = widthOverride or (f.width(math.max(o0, o1)) - 2 * (inset or 0))
	return k:box(f.cf(om, frac or 0.5, (y0 + y1) / 2), Vector3.new(math.max(w, 0.2), y1 - y0, o1 - o0), color, material, collide)
end

local function wedgeFill(
	k: Kit.Kit,
	f: Frame,
	o0: number,
	o1: number,
	y0: number,
	y1: number,
	color: Kit.Color,
	inset: number?,
	frac: number?,
	widthOverride: number?
)
	local om = (o0 + o1) / 2
	local w = widthOverride or (f.width(math.max(o0, o1)) - 2 * (inset or 0))
	-- WedgePart rises toward +Z, which the section frame points outward.
	k:wedge(f.cf(om, frac or 0.5, (y0 + y1) / 2), Vector3.new(w, y1 - y0, o1 - o0), color, "Concrete", true)
end

local SHIRTS = {
	P.Navy,
	P.Navy,
	P.Red,
	P.White,
	rgb(236, 236, 230),
	rgb(240, 196, 60),
	rgb(90, 160, 220),
	rgb(64, 132, 82),
	rgb(236, 128, 52),
	rgb(222, 110, 150),
	rgb(120, 120, 128),
	rgb(40, 40, 46),
	rgb(150, 70, 160),
	rgb(196, 52, 52),
}
local SKIN = { rgb(255, 214, 178), rgb(234, 184, 146), rgb(198, 144, 106), rgb(150, 100, 70), rgb(104, 70, 50), rgb(240, 200, 160) }
local HAIR = { rgb(40, 30, 24), rgb(80, 56, 36), rgb(196, 160, 96), rgb(26, 26, 30), P.Navy, P.Red }

local function crowdRow(k: Kit.Kit, f: Frame, offset: number, seatTop: number, density: number, inset: number)
	local w = f.width(offset) - 2 * inset
	local seats = math.floor(w / 2.1)
	if seats < 1 then
		return
	end
	for i = 1, seats do
		if k:rand() < density then
			local frac = (inset + (i - 0.5) * (w / seats)) / f.width(offset)
			local base = f.cf(offset, frac, seatTop)
			local shirt = k:pick(SHIRTS)
			local lean = (k:rand() - 0.5) * 0.25
			local standing = k:rand() < 0.06
			local h = if standing then 2.4 else 1.6
			k:box(
				base * CFrame.new(0, h / 2 + (if standing then 0.3 else 0), 0.15) * CFrame.Angles(lean * 0.3, 0, lean),
				Vector3.new(1.45, h, 0.85),
				shirt,
				"SmoothPlastic",
				false
			).shadow = false
			local headTop = h + (if standing then 0.3 else 0) + 0.55
			local hat = k:rand() < 0.2
			k:ball(
				(base * CFrame.new(lean * 0.4, headTop, 0.15)).Position,
				1.05,
				if hat then k:pick(HAIR) else k:pick(SKIN),
				"SmoothPlastic"
			).shadow = false
		end
	end
end

local function seatRow(k: Kit.Kit, f: Frame, o: number, depth: number, top: number, color: Kit.Color, inset: number)
	-- One continuous seat block per row: back + pan read as a seat line at range.
	slab(k, f, o + depth * 0.32, o + depth * 0.32 + 1.3, top, top + 1.25, color, "Plastic", false, inset)
	slab(k, f, o + depth * 0.32 + 1.0, o + depth * 0.32 + 1.45, top + 1.25, top + 2.0, color, "Plastic", false, inset)
end

-- Section builders ---------------------------------------------------------

local function lowerBowl(k: Kit.Kit, f: Frame, s: Section)
	local inset = Bowl.AisleWidth / 2
	local first = s.skip
	local front = first * L.Depth
	local fillTopFront = if first > 0 then lowerTop(first) - L.Rise - 0.4 else 0
	local fillTopBack = lowerTop(L.Rows - 1) - L.Rise - 0.4
	if first > 0 then
		if s.tunnel then
			-- Split support leaving a 10-stud tunnel on the centre line.
			local w = f.width((front + aisleFront) / 2)
			local side = (w - 10) / 2
			slab(k, f, front, aisleFront, 0, fillTopFront, P.ConcreteDark, "Concrete", true, 0, side / 2 / w, side)
			slab(k, f, front, aisleFront, 0, fillTopFront, P.ConcreteDark, "Concrete", true, 0, 1 - side / 2 / w, side)
			-- Tunnel portal trim and sign.
			local portal = f.cf(front - 0.3, 0.5, fillTopFront + 1.2)
			k:box(portal, Vector3.new(12, 2.4, 0.6), P.Navy, "SmoothPlastic", false)
			k:sign(portal * CFrame.new(0, 0, -0.35), Vector3.new(11, 1.8, 0.1), "TO GATES & CONCOURSE", P.White, P.Navy, "GothamBlack")
		else
			slab(k, f, front, aisleFront, 0, fillTopFront, P.ConcreteDark, "Concrete", true, 0)
		end
	end
	wedgeFill(k, f, front, aisleFront, fillTopFront, fillTopBack, P.ConcreteDark)
	-- Front (cheek) wall of a raised first row.
	if first > 0 and not s.dugout then
		slab(k, f, front - 0.8, front, 0, lowerTop(first) + 1.2, P.Concrete, "Concrete", true, 0)
	end
	local premium = s.side == "H" or (s.alongMid ~= nil and s.alongMid < 110)
	local density = if s.side == "H" then 0.62 elseif premium then 0.5 else 0.34
	for row = first, L.Rows - 1 do
		local o = row * L.Depth
		local top = lowerTop(row)
		slab(k, f, o, o + L.Depth, top - L.Rise - 0.4, top, P.Concrete, "Concrete", true, 0)
		local seatColor = if s.club then P.SeatPremium elseif row < first + 2 and premium then P.SeatAccent else P.Seat
		seatRow(k, f, o, L.Depth, top, seatColor, inset)
		crowdRow(k, f, o + L.Depth * 0.32 + 0.7, top + 1.25, density * (1 - row / (L.Rows * 2.2)), inset + 0.3)
	end
	-- Aisle steps at the section's start edge (two per row).
	if s.aisle then
		for row = first, L.Rows - 1 do
			local o = row * L.Depth
			local top = lowerTop(row)
			for step = 0, 1 do
				local o0 = o + step * L.Depth / 2
				local y = top - L.Rise + L.Rise * (step + 1) / 2
				local w = Bowl.AisleWidth
				k:box(
					f.cf(o0 + L.Depth / 4, 0, y - 0.55),
					Vector3.new(w, 1.1, L.Depth / 2),
					P.ConcreteDark,
					"Concrete",
					true
				)
			end
		end
		-- Handrail down the aisle centre.
		k:beam(
			f.at(front + 1, 0, lowerTop(first) + 2.4),
			f.at(aisleFront - 1, 0, lowerTop(L.Rows - 1) + 2.4),
			0.22,
			0.22,
			P.Steel,
			"Metal",
			false
		)
	end
end

local function crossAisle(k: Kit.Kit, f: Frame, s: Section)
	-- Walkway on top of the core block; the core's outer face is the facade.
	if s.tunnel then
		local w = f.width(s.back)
		local side = (w - 10) / 2
		slab(k, f, aisleFront, s.back, 0, aisleTop, P.Concrete, "Concrete", true, 0, side / 2 / w, side)
		slab(k, f, aisleFront, s.back, 0, aisleTop, P.Concrete, "Concrete", true, 0, 1 - side / 2 / w, side)
		slab(k, f, aisleFront, s.back, 8, aisleTop, P.Concrete, "Concrete", true, -0.05)
		slab(k, f, aisleFront, s.back, 0.02, 0.12, rgb(170, 164, 154), "Concrete", false, 0, 0.5, 10)
	else
		slab(k, f, aisleFront, s.back, 0, aisleTop, P.Concrete, "Concrete", true, -0.05)
	end
	if not s.upper then
		-- Parapet + rail at the back of the open-air walkway.
		slab(k, f, s.back - 1.2, s.back, aisleTop, aisleTop + 3.2, P.Brick, "Brick", true, -0.05)
		slab(k, f, s.back - 1.4, s.back + 0.2, aisleTop + 3.2, aisleTop + 3.6, P.Limestone, "Concrete", false, -0.1)
	end
end

local function upperDeck(k: Kit.Kit, f: Frame, _s: Section)
	local inset = Bowl.AisleWidth / 2
	-- Front parapet with glass guard.
	slab(k, f, upperFront - 0.8, upperFront, aisleTop, upperTop(0) + 1.4, P.Concrete, "Concrete", true, 0)
	local glass = slab(k, f, upperFront - 0.6, upperFront - 0.4, upperTop(0) + 1.4, upperTop(0) + 3.0, P.Glass, "Glass", false, 0.2)
	glass.transparency = 0.55
	wedgeFill(k, f, upperFront, upperBack, aisleTop, upperTop(U.Rows - 1) - U.Rise - 0.4, P.ConcreteDark)
	for row = 0, U.Rows - 1 do
		local o = upperFront + row * U.Depth
		local top = upperTop(row)
		slab(k, f, o, o + U.Depth, top - U.Rise - 0.4, top, P.Concrete, "Concrete", true, 0)
		seatRow(k, f, o, U.Depth, top, P.SeatAccent, inset)
		crowdRow(k, f, o + U.Depth * 0.32 + 0.7, top + 1.25, 0.3, inset + 0.3)
	end
	-- Aisle steps.
	for row = 0, U.Rows - 1 do
		local o = upperFront + row * U.Depth
		local top = upperTop(row)
		for step = 0, 1 do
			local y = top - U.Rise + U.Rise * (step + 1) / 2
			k:box(f.cf(o + step * U.Depth / 2 + U.Depth / 4, 0, y - 0.55), Vector3.new(Bowl.AisleWidth, 1.1, U.Depth / 2), P.ConcreteDark, "Concrete", true)
		end
	end
	-- Rear wall behind the last row (press box or open back).
	local backTop = upperTop(U.Rows - 1)
	slab(k, f, upperBack, upperBack + 1, aisleTop, backTop + 3, P.Concrete, "Concrete", true, -0.05)
end

local function core(k: Kit.Kit, f: Frame, s: Section)
	-- Exterior facade: brick with limestone bands and arched openings at grade.
	local outer = s.back
	local top = if s.upper then upperTop(U.Rows - 1) + 3 else aisleTop
	slab(k, f, outer, outer + 1.2, 0, top, P.Brick, "Brick", true, -0.1)
	slab(k, f, outer + 1.0, outer + 1.6, top - 0.2, top + 1.0, P.Limestone, "Concrete", false, -0.3)
	slab(k, f, outer + 1.0, outer + 1.5, aisleTop - 0.8, aisleTop + 0.4, P.Limestone, "Concrete", false, -0.3)
	local w = f.width(outer)
	local bays = math.max(1, math.floor(w / 13))
	for i = 1, bays do
		local frac = (i - 0.5) / bays
		-- Arched opening (dark recess) with a keystone band.
		k:box(f.cf(outer + 1.25, frac, 6), Vector3.new(7, 12, 0.2), rgb(46, 40, 38), "SmoothPlastic", false)
		k:cyl(f.cf(outer + 1.25, frac, 12) * CFrame.Angles(0, math.pi / 2, 0), 0.2, 7, rgb(46, 40, 38), "SmoothPlastic", false)
		k:box(f.cf(outer + 1.35, frac, 15.8), Vector3.new(1.4, 1.4, 0.3), P.Limestone, "Concrete", false)
		-- Pilaster.
		k:box(f.cf(outer + 1.6, (i - 1) / bays, top / 2), Vector3.new(1.8, top, 1.2), P.BrickDark, "Brick", false)
		if s.upper then
			-- Upper-level window band.
			k:box(f.cf(outer + 1.25, frac, aisleTop + 7), Vector3.new(8, 6, 0.2), P.Glass, "Glass", false).reflectance = 0.15
		end
	end
	if s.tunnel then
		-- Main entrance portal through the core.
		k:box(f.cf(outer + 1.3, 0.5, 5), Vector3.new(14, 10, 1.6), rgb(30, 28, 28), "SmoothPlastic", false)
	end
end

local function pressBox(k: Kit.Kit, f: Frame, s: Section)
	local o0, o1 = upperBack + 1, s.back
	local y0 = upperTop(U.Rows - 1) + 3
	local y1 = y0 + 13
	slab(k, f, o0, o1, y0, y0 + 1, P.Concrete, "Concrete", true, -0.05)
	slab(k, f, o0 + 1, o1, y0 + 1, y1, P.Limestone, "Concrete", false, -0.05)
	-- Broadcast window band facing the field.
	local band = slab(k, f, o0 + 0.6, o0 + 1.0, y0 + 3.5, y0 + 10, P.Glass, "Glass", false, 0.6)
	band.reflectance = 0.25
	-- Booth mullions.
	local w = f.width(o0)
	for i = 0, math.floor(w / 6) do
		k:box(f.cf(o0 + 0.5, i / math.max(1, math.floor(w / 6)), y0 + 6.75), Vector3.new(0.5, 6.5, 0.6), P.SteelDark, "Metal", false)
	end
	slab(k, f, o0 - 0.4, o1 + 0.4, y1, y1 + 0.8, P.Steel, "Metal", false, -0.3)
	-- Flag on the press-box roof (sways client-side).
	local mast = f.at(o1 - 2, 0.5, y1 + 0.8)
	k:post(mast, 14, 0.35, P.White, "Metal")
	local flag = k:box(f.cf(o1 - 2, 0.5, y1 + 12.4) * CFrame.new(2.6, 0, 0), Vector3.new(5, 3.2, 0.1), k:pick({ P.Navy, P.Red, P.Yellow }), "Fabric", false)
	flag.tag = "Flag"
end

local function canopy(k: Kit.Kit, f: Frame, s: Section, roofY: number)
	local o0 = upperFront - 3
	local o1 = s.back + 3
	-- Slightly pitched roof slab and fascia.
	local roof = slab(k, f, o0, o1, roofY, roofY + 1.2, P.Roof, "Metal", false, -0.15)
	roof.cf = roof.cf * CFrame.Angles(math.rad(3), 0, 0) -- field edge slightly higher
	slab(k, f, o0 - 0.6, o0 + 0.6, roofY - 2.2, roofY + 1.6, P.Steel, "Metal", false, -0.15)
	-- Cantilever trusses and back columns at section edges.
	for _, frac in { 0, 1 } do
		local back = f.at(s.back - 0.5, frac, 0)
		local top = f.at(s.back - 0.5, frac, roofY)
		k:beam(back, top, 1.4, 1.4, P.Steel, "Metal", true)
		k:beam(f.at(o0 + 1, frac, roofY - 0.4), f.at(s.back - 0.5, frac, roofY - 6), 0.9, 0.9, P.Steel, "Metal", false)
		k:beam(f.at(o0 + 1, frac, roofY - 0.4), f.at(s.back - 0.5, frac, roofY - 0.4), 0.8, 1.6, P.Steel, "Metal", false)
	end
end

local function dugout(k: Kit.Kit, f: Frame, s: Section, home: boolean)
	local depth = 12.5
	local roofY = lowerTop(s.skip) - L.Rise - 0.4
	-- Shell: back wall, side walls, roof with fascia sign, floor.
	slab(k, f, depth, depth + 1, 0, roofY, P.Navy, "Concrete", true, 0.2)
	for _, frac in { 0.02, 0.98 } do
		k:box(f.cf(depth / 2, frac, roofY / 2), Vector3.new(1, roofY, depth + 1), P.Concrete, "Concrete", true)
	end
	slab(k, f, -1.6, depth + 1, roofY - 0.9, roofY, P.Concrete, "Concrete", true, 0.2)
	local fascia = slab(k, f, -1.8, -1.5, roofY - 2.1, roofY, P.Navy, "SmoothPlastic", false, 0.6)
	fascia.sign = {
		text = if home then "ROOKIES" else "VISITORS",
		color = P.Yellow,
		font = "GothamBlack",
	}
	slab(k, f, 0.5, depth, 0.02, 0.12, rgb(70, 74, 80), "Rubber", false, 1.2)
	-- Front rail with padding.
	slab(k, f, -0.6, 0, 0, 3.2, P.WallPad, "Fabric", true, 0.8)
	slab(k, f, -0.8, 0.2, 3.2, 3.6, P.Yellow, "SmoothPlastic", false, 0.8)
	-- Bench, bat rack, helmet cubbies, coolers, ball bucket, bags.
	slab(k, f, depth - 3, depth - 1, 0, 1.6, P.Wood, "WoodPlanks", false, 2.5)
	slab(k, f, depth - 1.2, depth - 0.2, 1.6, 3.6, P.Wood, "WoodPlanks", false, 2.5)
	local rack = f.cf(depth - 0.6, 0.18, 2.6)
	k:box(rack, Vector3.new(7, 4.6, 0.8), P.SteelDark, "Metal", false)
	for i = 0, 7 do
		k:cyl(
			rack * CFrame.new(-3 + i * 0.85, 0.2, -0.6) * CFrame.Angles(0, 0, math.rad(90 + (i % 3 - 1) * 4)),
			4.2,
			0.32,
			if i % 3 == 0 then rgb(40, 30, 24) else rgb(196, 160, 110),
			"Wood",
			false
		)
	end
	local cubby = f.cf(depth - 0.6, 0.82, 3.4)
	k:box(cubby, Vector3.new(7, 2.4, 1.2), P.SteelDark, "Metal", false)
	for i = 0, 5 do
		k:ball((cubby * CFrame.new(-2.9 + i * 1.15, 0.2, -0.7)).Position, 0.9, if home then P.Navy else P.Red, "Plastic")
	end
	local cooler = f.cf(depth - 2, 0.6, 2.1)
	k:cyl(cooler * CFrame.Angles(0, 0, math.pi / 2), 2.2, 1.6, rgb(236, 120, 30), "Plastic", false)
	k:cyl(cooler * CFrame.new(0, 1.2, 0) * CFrame.Angles(0, 0, math.pi / 2), 0.3, 1.7, P.White, "Plastic", false)
	local cooler2 = f.cf(depth - 2, 0.66, 2.1)
	k:cyl(cooler2 * CFrame.Angles(0, 0, math.pi / 2), 2.2, 1.6, rgb(236, 120, 30), "Plastic", false)
	k:box(f.cf(depth - 4.5, 0.4, 0.8), Vector3.new(3.2, 1.6, 1.4), if home then P.Navy else P.Red, "Fabric", false)
	k:cyl(f.cf(depth - 4.2, 0.48, 0.9) * CFrame.Angles(0, 0, math.pi / 2), 1.6, 1.4, rgb(230, 230, 222), "Plastic", false)
end

local function netting(k: Kit.Kit, f: Frame, _s: Section, height: number)
	local net = slab(k, f, -0.9, -0.8, Bowl.WallTop, height, rgb(30, 34, 36), "SmoothPlastic", false, 0)
	net.transparency = 0.86
	net.shadow = false
	k:beam(f.at(-0.85, 0, height), f.at(-0.85, 1, height), 0.15, 0.15, rgb(40, 40, 40), "Metal", false)
	k:post(f.at(-0.85, 0, 0), height, 0.5, P.Steel, "Metal")
end

local function frontWall(k: Kit.Kit, f: Frame, s: Section)
	if s.dugout then
		return
	end
	local color = if s.side == "H" then P.Navy else P.WallPad
	slab(k, f, -1.2, 0, 0, Bowl.WallTop, color, "Fabric", true, -0.05)
	slab(k, f, -1.4, 0.2, Bowl.WallTop, Bowl.WallTop + 0.3, P.Yellow, "SmoothPlastic", false, -0.05)
	-- Rail on posts above the wall.
	local railY = Bowl.WallTop + 2.4
	k:beam(f.at(-0.4, 0, railY), f.at(-0.4, 1, railY), 0.25, 0.25, P.Steel, "Metal", false)
	k:post(f.at(-0.4, 0, Bowl.WallTop), 2.4, 0.3, P.Steel, "Metal")
end

export type Ad = { text: string, fg: Kit.Color, bg: Kit.Color }

local ADS: { Ad } = {
	{ text = "BRAMBLE BAY BANK", fg = P.White, bg = P.Navy },
	{ text = "CORNER MART", fg = rgb(30, 30, 30), bg = P.Yellow },
	{ text = "GRAND SLAM PIZZA", fg = P.White, bg = P.Red },
	{ text = "SUNDIAL SODA", fg = P.Navy, bg = rgb(250, 236, 200) },
	{ text = "LAKESIDE TIRE", fg = P.White, bg = rgb(40, 110, 70) },
	{ text = "MAPLE HEIGHTS DENTAL", fg = P.Navy, bg = P.White },
	{ text = "SEVENTH INNING DINER", fg = P.Yellow, bg = rgb(60, 40, 90) },
	{ text = "HARBOR FREIGHT LINES", fg = P.White, bg = rgb(50, 90, 150) },
}

function Bowl.build(k: Kit.Kit, layout: Layout.Layout)
	local site = layout.site
	local sections = Bowl.sections(layout)
	local adIndex = 0
	for index, s in sections do
		k:step()
		local f = frame(site, s)
		k:chunk(`Bowl{index}`, 0):solid(false)
		frontWall(k, f, s)
		-- Wall-face sponsor panel on baseline sections.
		if s.side ~= "H" and not s.dugout then
			adIndex += 1
			local ad = ADS[(adIndex - 1) % #ADS + 1]
			local panel = slab(k, f, -1.3, -1.2, 0.8, Bowl.WallTop - 0.5, ad.bg, "SmoothPlastic", false, 3)
			panel.sign = { text = ad.text, color = ad.fg, font = "GothamBlack" }
		end
		lowerBowl(k, f, s)
		crossAisle(k, f, s)
		core(k, f, s)
		if s.upper then
			upperDeck(k, f, s)
			if s.side == "H" then
				pressBox(k, f, s)
				canopy(k, f, s, upperTop(U.Rows - 1) + 19)
			else
				canopy(k, f, s, upperTop(U.Rows - 1) + 12)
			end
		end
		if s.dugout then
			dugout(k, f, s, s.side == "R")
		end
		-- Protective netting: tall behind home, tapering to the dugouts' far end.
		local reach = s.side == "H" or (s.alongMid ~= nil and s.alongMid < Bowl.DugoutAlong[2])
		if reach then
			netting(k, f, s, if s.side == "H" then 30 elseif s.dugout then 12 else 20)
		end
		if s.club then
			-- Home Plate Club: field-level terrace (open floor around the spawn line).
			slab(k, f, 0, s.skip * L.Depth, 0.02, 0.1, rgb(176, 170, 160), "Concrete", false, 0)
			if not s.tunnel then
				for _, frac in { 0.3, 0.7 } do
					local t = f.cf(8, frac, 0)
					k:cyl(t * CFrame.new(0, 3.3, 0) * CFrame.Angles(0, 0, math.pi / 2), 0.3, 3.2, P.Wood, "Wood", false)
					k:post(t.Position, 3.2, 0.35, P.SteelDark, "Metal")
				end
			end
		end
	end
	-- Corner end walls closing the bowl at both ends.
	for _, s in { sections[1], sections[#sections] } do
		local f = frame(site, s)
		local frac = if s == sections[1] then 0 else 1
		local p0 = f.at(-1.2, frac, 0)
		local p1 = f.at(s.back + 1.2, frac, 0)
		local mid = (p0 + p1) / 2
		k:box(
			CFrame.lookAt(mid + Vector3.new(0, aisleTop / 2 + 1.5, 0), p1 + Vector3.new(0, aisleTop / 2 + 1.5, 0)),
			Vector3.new(1.6, aisleTop + 3, (p1 - p0).Magnitude),
			P.Brick,
			"Brick",
			true
		)
	end
end

-- Shared with the outfield builders (bleachers reuse the section machinery).
Bowl.frame = frame
Bowl.slab = slab
Bowl.wedgeFill = wedgeFill
Bowl.crowdRow = crowdRow
Bowl.seatRow = seatRow
Bowl.SHIRTS = SHIRTS

return Bowl
