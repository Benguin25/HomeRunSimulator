--!strict
-- Everything the batter looks at: the padded outfield wall (on the authored
-- fence line), sponsor panels and distance markers, foul poles, a matte
-- batter's eye centred behind the pitcher, low home-run bleachers that balls
-- carry over, the right-centre scoreboard, light towers, corner party decks
-- and bullpens.
--
-- Placement rules for readability: nothing bright or busy within +/-12 deg of
-- centre field below the batter's-eye top; bleachers stay low (top row 14
-- studs) so typical home runs fly over them and land in open plazas/streets.

local Environment = script.Parent.Parent
local Config = require(Environment.EnvironmentConfig)
local Site = require(Environment.Site)
local Kit = require(Environment.EnvKit)
local Layout = require(script.Parent.Layout)
local Bowl = require(script.Parent.Bowl)

local Outfield = {}

local P = Config.Palette
local rgb = Config.rgb

Outfield.Bleachers = { Rows = 6, Depth = 3.2, Rise = 1.35, FirstTop = 6.6, MinPhi = 14, MaxPhi = 43, Step = 4.8 }
Outfield.EyeHalfDegrees = 11
Outfield.EyeHeight = 26
Outfield.Scoreboard = { Phi = 27, Radius = 404, Width = 92, Bottom = 30, Height = 40 }

-- Frame on a wall segment: Z = outward (away from home), so a part's Front
-- face looks back toward home plate. Returns the frame builder and length.
local function segmentFrame(site: Site.Site, a: Layout.P2, b: Layout.P2): ((number, number) -> CFrame, number)
	local du, dv = b[1] - a[1], b[2] - a[2]
	local len = math.sqrt(du * du + dv * dv)
	-- Outward normal (away from home plate).
	local nu, nv = dv / len, -du / len
	local mid = { (a[1] + b[1]) / 2, (a[2] + b[2]) / 2 }
	if nu * mid[1] + nv * mid[2] < 0 then
		nu, nv = -nu, -nv
	end
	local function cf(off: number, y: number): CFrame
		local p = Site.at(site, mid[1] + nu * off, y, mid[2] + nv * off)
		local out = site.right * nu + site.forward * nv
		return CFrame.fromMatrix(p, Vector3.new(0, 1, 0):Cross(out).Unit, Vector3.yAxis, out)
	end
	return cf, len
end

local function wallSegment(k: Kit.Kit, site: Site.Site, a: Layout.P2, b: Layout.P2, height: number)
	local cf, len = segmentFrame(site, a, b)
	-- Authored panel is 0.6 thick on the fence line: keep the field face there.
	k:box(cf(0.4, (height - 0.35) / 2), Vector3.new(len + 0.12, height - 0.35, 1.4), P.WallPad, "Fabric", true)
	k:box(cf(0.4, height - 0.175), Vector3.new(len + 0.12, 0.35, 1.42), P.WallCap, "SmoothPlastic", false)
	k:box(cf(0.5, height + 0.18), Vector3.new(len + 0.14, 0.36, 1.7), P.SteelDark, "Metal", false)
	return cf
end

local WALL_ADS: { Bowl.Ad } = {
	{ text = "GRAND SLAM PIZZA", fg = P.White, bg = P.Red },
	{ text = "BRAMBLE BAY BANK", fg = P.White, bg = P.Navy },
	{ text = "SUNDIAL SODA", fg = P.Navy, bg = rgb(250, 236, 200) },
	{ text = "CORNER MART", fg = rgb(30, 30, 30), bg = P.Yellow },
	{ text = "HIT IT HERE!", fg = P.Navy, bg = P.Yellow },
	{ text = "LAKESIDE TIRE", fg = P.White, bg = rgb(40, 110, 70) },
	{ text = "WHRS 1350 AM", fg = P.White, bg = rgb(36, 36, 44) },
	{ text = "MAPLE HEIGHTS\nHARDWARE", fg = P.White, bg = rgb(176, 84, 40) },
}

local function wall(k: Kit.Kit, layout: Layout.Layout)
	local site = layout.site
	local h = site.cfg.FenceHeight
	k:chunk("OutfieldWall", 0)
	local frames = {}
	for i = 1, #layout.fence - 1 do
		frames[i] = wallSegment(k, site, layout.fence[i], layout.fence[i + 1], h)
	end
	-- Corner walls from each pole to the stands front.
	for side = 1, 2 do
		local pole = layout.poles[side]
		local corner = layout.corner[side]
		wallSegment(k, site, pole, corner, h)
	end
	-- Sponsor panels on pairs of segments, leaving centre field plain and dark.
	local ad = 0
	for i = 1, #layout.fence - 2, 2 do
		local phi = (layout.fenceAngles[i] + layout.fenceAngles[i + 2]) / 2
		if math.abs(phi) > 13 then
			ad += 1
			local a, b = layout.fence[i], layout.fence[i + 2]
			local len = math.sqrt((b[1] - a[1]) ^ 2 + (b[2] - a[2]) ^ 2)
			local pick = WALL_ADS[(ad - 1) % #WALL_ADS + 1]
			local cf = segmentFrame(site, a, b)
			local panel = k:box(cf(-0.36, 3.2), Vector3.new(len - 1.2, 4.4, 0.12), pick.bg, "SmoothPlastic", false)
			panel.sign = { text = pick.text, color = pick.fg, font = "GothamBlack" }
		end
	end
	-- Distance markers painted high on the wall (poles and alleys only).
	local function marker(phi: number)
		local r = Site.fenceRadius(site, phi)
		local feet = math.floor(r * site.cfg.StudsToFeet + 0.5)
		-- Oriented to the fence face itself (the fence is not a circle).
		local a0, a1 = { Site.polarUV(Site.fenceRadius(site, phi - 0.3), phi - 0.3) }, { Site.polarUV(Site.fenceRadius(site, phi + 0.3), phi + 0.3) }
		local cf = segmentFrame(site, a0, a1)
		local m = k:box(cf(-0.42, 6.55), Vector3.new(6.5, 1.8, 0.1), P.WallPad, "Fabric", false)
		m.sign = { text = tostring(feet), color = P.White, font = "GothamBlack" }
	end
	for _, phi in { -41.5, -22.5, 22.5, 41.5 } do
		marker(phi)
	end
	-- Foul poles: tall, bright, with a fair-side screen.
	for side = 1, 2 do
		local p = layout.poles[side]
		local base = Site.at(site, p[1], 0, p[2])
		k:post(base, 44, 1.0, P.WallCap, "SmoothPlastic")
		-- Screen on the fair side, facing home plate.
		local fair = if side == 1 then 1 else -1
		local s2 = math.sqrt(0.5)
		local screen = k:box(
			Site.cf(site, p[1] + fair * s2, 26, p[2] + s2, if side == 1 then 135 else -135),
			Vector3.new(1.8, 34, 0.12),
			P.WallCap,
			"SmoothPlastic",
			false
		)
		screen.transparency = 0.45
		k:ball(base + Vector3.new(0, 44.6, 0), 1.6, P.WallCap, "SmoothPlastic")
	end
end

-- Low home-run bleachers in left and right field.
local function bleachers(k: Kit.Kit, layout: Layout.Layout)
	local site = layout.site
	local B = Outfield.Bleachers
	local Lh = { Depth = B.Depth, Rise = B.Rise }
	for _, sgn in { -1, 1 } do
		k:chunk(if sgn < 0 then "BleachersLF" else "BleachersRF", 0)
		local phis = {}
		local phi = B.MinPhi
		while phi < B.MaxPhi - 0.01 do
			table.insert(phis, phi)
			phi += B.Step
		end
		table.insert(phis, B.MaxPhi)
		for i = 1, #phis - 1 do
			local function station(p: number): Bowl.Station
				-- Normal of the fence curve itself (not radial): the fence radius
				-- changes ~1.5 studs per degree here, so radial frames would skew.
				local a = sgn * p
				local u, v = Site.polarUV(Site.fenceRadius(site, a), a)
				local u0, v0 = Site.polarUV(Site.fenceRadius(site, a - 0.2), a - 0.2)
				local u1, v1 = Site.polarUV(Site.fenceRadius(site, a + 0.2), a + 0.2)
				local tu, tv = u1 - u0, v1 - v0
				local len = math.sqrt(tu * tu + tv * tv)
				local nu, nv = tv / len, -tu / len
				if nu * u + nv * v < 0 then
					nu, nv = -nu, -nv
				end
				return { p = { u + nu * 1.4, v + nv * 1.4 }, n = { nu, nv } }
			end
			local s: Bowl.Section = {
				a = station(phis[i]),
				b = station(phis[i + 1]),
				side = "O",
				order = i,
				skip = 0,
				dugout = false,
				club = false,
				tunnel = false,
				upper = false,
				back = B.Rows * B.Depth,
				alongMid = nil,
				aisle = i > 1,
			}
			local f = Bowl.frame(site, s)
			local fillFront = B.FirstTop - B.Rise - 0.4
			local fillBack = B.FirstTop + B.Rise * (B.Rows - 1) - B.Rise - 0.4
			Bowl.slab(k, f, 0, s.back, 0, fillFront, P.ConcreteDark, "Concrete", true, 0)
			Bowl.wedgeFill(k, f, 0, s.back, fillFront, fillBack, P.ConcreteDark)
			for row = 0, B.Rows - 1 do
				local o = row * Lh.Depth
				local top = B.FirstTop + B.Rise * row
				Bowl.slab(k, f, o, o + Lh.Depth, top - B.Rise - 0.4, top, P.Concrete, "Concrete", true, 0)
				-- Aluminium bench plank + footboard.
				Bowl.slab(k, f, o + 1.3, o + 2.5, top + 1.2, top + 1.45, rgb(196, 200, 204), "Metal", false, 1.2)
				Bowl.crowdRow(k, f, o + 1.9, top + 1.45, 0.42, 1.5)
				if s.aisle then
					k:box(f.cf(o + Lh.Depth / 2, 0, top - B.Rise / 2 - 0.5), Vector3.new(2.4, 1.1, Lh.Depth), P.ConcreteDark, "Concrete", true)
				end
			end
			-- Back wall with a sign band facing the outfield plaza.
			local backTop = B.FirstTop + B.Rise * (B.Rows - 1) + 3.2
			Bowl.slab(k, f, s.back, s.back + 1, 0, backTop, P.Brick, "Brick", true, -0.05)
			Bowl.slab(k, f, s.back - 0.2, s.back + 1.2, backTop, backTop + 0.4, P.Limestone, "Concrete", false, -0.1)
			Bowl.slab(k, f, s.back - 0.5, s.back - 0.3, backTop - 3.2, backTop - 0.2, P.Steel, "Metal", false, 0.5).transparency = 0.6
		end
		-- End walls.
		for _, p in { B.MinPhi, B.MaxPhi } do
			local a = sgn * p
			local r = Site.fenceRadius(site, a) + 1.4
			local p0, p1 = Site.polar(site, r, a, 0), Site.polar(site, r + B.Rows * B.Depth + 1, a, 0)
			local top = B.FirstTop + B.Rise * (B.Rows - 1) + 3.6
			local mid = (p0 + p1) / 2
			k:box(
				CFrame.lookAt(mid + Vector3.new(0, top / 2, 0), p1 + Vector3.new(0, top / 2, 0)),
				Vector3.new(1.4, top, (p1 - p0).Magnitude),
				P.Brick,
				"Brick",
				true
			)
		end
	end
end

local function batterEye(k: Kit.Kit, layout: Layout.Layout)
	local site = layout.site
	k:chunk("BatterEye", 0)
	local half = Outfield.EyeHalfDegrees
	local steps = 6
	for i = 0, steps - 1 do
		local a0 = -half + 2 * half * i / steps
		local a1 = -half + 2 * half * (i + 1) / steps
		local r0 = Site.fenceRadius(site, a0) + 14
		local r1 = Site.fenceRadius(site, a1) + 14
		local p0, p1 = Site.polar(site, r0, a0, 0), Site.polar(site, r1, a1, 0)
		local mid = (p0 + p1) / 2
		local len = (p1 - p0).Magnitude + 0.3
		local cf = CFrame.lookAt(mid, mid + (p1 - p0)) * CFrame.Angles(0, math.pi / 2, 0)
		k:box(cf + Vector3.new(0, Outfield.EyeHeight / 2, 0), Vector3.new(len, Outfield.EyeHeight, 1.6), P.BatterEye, "Fabric", true)
		-- Dark planting along the top edge.
		for j = 0, 2 do
			local t = (j + 0.5) / 3
			local q = p0:Lerp(p1, t)
			k:ellipsoid(
				CFrame.new(q + Vector3.new(0, Outfield.EyeHeight + 1.6, 0)),
				Vector3.new(len / 3 + 2, 4.2, 4),
				P.FoliageDark,
				"LeafyGrass"
			)
		end
	end
	-- Dark grass slope between the wall and the eye.
	for i = 0, steps - 1 do
		local a0 = -half + 2 * half * i / steps
		local a1 = -half + 2 * half * (i + 1) / steps
		local q = {
			{ Site.polarUV(Site.fenceRadius(site, a0) + 1.2, a0) },
			{ Site.polarUV(Site.fenceRadius(site, a1) + 1.2, a1) },
			{ Site.polarUV(Site.fenceRadius(site, a1) + 13.4, a1) },
			{ Site.polarUV(Site.fenceRadius(site, a0) + 13.4, a0) },
		}
		k:poly(Site.lift(site, q :: any, 0.05), 0.3, rgb(40, 82, 46), "Grass", false)
	end
end

local function scoreboard(k: Kit.Kit, layout: Layout.Layout)
	local site = layout.site
	local S = Outfield.Scoreboard
	k:chunk("Scoreboard", 0)
	local u, v = Site.polarUV(S.Radius, S.Phi)
	-- Face home plate.
	local facing = Site.cf(site, u, 0, v, S.Phi + 180)
	local W, B0, Hh = S.Width, S.Bottom, S.Height
	-- Brick piers with limestone caps.
	for _, x in { -W / 2 + 6, W / 2 - 6 } do
		k:box(facing * CFrame.new(x, B0 / 2, 2), Vector3.new(8, B0, 7), P.Brick, "Brick", true)
		k:box(facing * CFrame.new(x, B0 + 0.4, 2), Vector3.new(9, 0.8, 8), P.Limestone, "Concrete", false)
		k:box(facing * CFrame.new(x, 1, 2), Vector3.new(9, 2, 8), P.Limestone, "Concrete", false)
	end
	-- Steel cabinet, green frame and the display face.
	local body = facing * CFrame.new(0, B0 + Hh / 2, 2)
	k:box(body, Vector3.new(W, Hh, 5), P.SteelDark, "Metal", false)
	k:box(body * CFrame.new(0, 0, -2.6), Vector3.new(W + 2, Hh + 2, 0.6), P.Steel, "Metal", false)
	-- Crown: arched header with branding.
	local crown = facing * CFrame.new(0, B0 + Hh + 6, 2)
	k:box(crown, Vector3.new(W * 0.62, 10, 4), P.Steel, "Metal", false)
	k:ellipsoid(crown * CFrame.new(0, 5, 0), Vector3.new(W * 0.62, 12, 4), P.Steel, "Metal")
	local brand = k:box(crown * CFrame.new(0, 1, -2.1), Vector3.new(W * 0.56, 7, 0.2), P.Navy, "SmoothPlastic", false)
	brand.sign = { text = "ROOKIE PARK", color = P.Yellow, font = "LuckiestGuy" }
	-- Baseball emblem on the crown.
	k:ball((crown * CFrame.new(0, 12, 0)).Position, 9, P.White, "SmoothPlastic")
	k:box(crown * CFrame.new(0, 12, -4.3) * CFrame.Angles(0, 0, math.rad(20)), Vector3.new(0.3, 7, 0.2), P.Red, "SmoothPlastic", false)
	k:box(crown * CFrame.new(-1.6, 12, -4.2) * CFrame.Angles(0, 0, math.rad(-20)), Vector3.new(0.3, 7, 0.2), P.Red, "SmoothPlastic", false)
	-- Display panels (front faces toward home). Tagged panels are live.
	local face = body * CFrame.new(0, 0, -2.95)
	local function panel(x: number, y: number, w: number, h: number, text: string, color: Kit.Color, bg: Kit.Color, tag: string?, font: string?)
		local p = k:box(face * CFrame.new(x, y, 0), Vector3.new(w, h, 0.2), bg, "SmoothPlastic", false)
		p.sign = { text = text, color = color, font = font or "GothamBlack" }
		p.tag = tag
		return p
	end
	local black = rgb(16, 18, 22)
	panel(0, Hh / 2 - 4.5, W - 6, 6, "HOME RUN SIMULATOR", P.White, rgb(150, 34, 34), nil, "LuckiestGuy")
	-- Local +X is the viewer's LEFT when facing the front: message left, stats right.
	panel(W / 4 - 1, 3.5, W / 2 - 6, 15, "BATTER UP!", P.Yellow, black, "ScoreboardMessage")
	panel(-W / 4 + 1, 8.5, W / 2 - 8, 4.2, "LAST  ---", P.White, black, "ScoreboardLast")
	panel(-W / 4 + 1, 3.6, W / 2 - 8, 4.2, "LONGEST  ---", P.White, black, "ScoreboardLongest")
	panel(-W / 4 + 1, -1.3, W / 2 - 8, 4.2, "TOP EV  ---", P.White, black, "ScoreboardExit")
	-- Line score strip (static decoration) and a clock.
	panel(0, -Hh / 2 + 6, W - 6, 6, "1  2  3  4  5  6  7  8  9   R  H  E", rgb(255, 210, 90), black, nil, "Arcade")
	panel(0, -Hh / 2 + 1.8, W - 6, 2.4, "BRAMBLE BAY  ROOKIES", P.White, P.Navy)
	-- Light bar under the cabinet.
	k:box(facing * CFrame.new(0, B0 - 0.6, 0.2), Vector3.new(W, 0.6, 1), P.Yellow, "SmoothPlastic", false)
	-- Flags on the crown (sway hooks).
	for i, x in { -W / 2 + 4, W / 2 - 4 } do
		local base = facing * CFrame.new(x, B0 + Hh + 1, 2)
		k:post(base.Position, 16, 0.4, P.White, "Metal")
		local flag = k:box(base * CFrame.new(2.6, 13.2, 0), Vector3.new(5, 3.2, 0.12), if i == 1 then P.Navy else P.Red, "Fabric", false)
		flag.tag = "Flag"
	end
end

local function lightTower(k: Kit.Kit, site: Site.Site, u: number, v: number, height: number)
	local base = Site.at(site, u, 0, v)
	local target = Site.at(site, 0, 30, 70)
	local flat = Vector3.new(target.X, base.Y, target.Z)
	local face = CFrame.lookAt(base, flat)
	-- Tapered mast: three stacked cylinders, base plinth.
	k:box(face * CFrame.new(0, 1.5, 0), Vector3.new(7, 3, 7), P.Concrete, "Concrete", true)
	k:post(base, height * 0.5, 3.2, P.Steel, "Metal")
	k:post(base + Vector3.new(0, height * 0.5, 0), height * 0.35, 2.5, P.Steel, "Metal")
	k:post(base + Vector3.new(0, height * 0.85, 0), height * 0.15, 1.9, P.Steel, "Metal")
	-- Head frame tilted toward the field, lamps in a grid.
	local head = face * CFrame.new(0, height + 6, 0) * CFrame.Angles(math.rad(-18), 0, 0)
	k:box(head * CFrame.new(0, 0, 1), Vector3.new(26, 13, 1.4), P.SteelDark, "Metal", false)
	k:box(head * CFrame.new(0, -7.2, 0), Vector3.new(27, 1, 3), P.Steel, "Metal", false)
	k:box(head * CFrame.new(0, 7.2, 0), Vector3.new(27, 1, 3), P.Steel, "Metal", false)
	for row = 0, 2 do
		for col = 0, 4 do
			k:cyl(
				head * CFrame.new(-10 + col * 5, -4 + row * 4, -0.2) * CFrame.Angles(0, math.pi / 2, 0),
				1.2,
				3.2,
				rgb(232, 236, 238),
				"Glass",
				false
			)
		end
	end
	-- Catwalk under the head.
	k:box(head * CFrame.new(0, -8, -1.5), Vector3.new(26, 0.3, 2), P.SteelDark, "DiamondPlate", false)
end

local function lights(k: Kit.Kit, layout: Layout.Layout)
	local site = layout.site
	k:chunk("LightTowers", 0)
	for _, sgn in { -1, 1 } do
		local u, v = Site.polarUV(332, sgn * 36)
		lightTower(k, site, u, v, 104)
		local p = Layout.sidePoint(layout, if sgn < 0 then 1 else 2, 180, 66)
		lightTower(k, site, p[1], p[2], 96)
		local q = Layout.sidePoint(layout, if sgn < 0 then 1 else 2, 92, 106)
		lightTower(k, site, q[1], q[2], 108)
	end
end

local function bullpens(k: Kit.Kit, layout: Layout.Layout)
	local site = layout.site
	for side = 1, 2 do
		k:chunk(if side == 1 then "BullpenLF" else "BullpenRF", Config.Lod.Detail)
		local dir = layout.lineDir[side]
		local function at(along: number, o: number, y: number): Vector3
			local p = Layout.sidePoint(layout, side, along, o)
			return Site.at(site, p[1], y, p[2])
		end
		local heading = math.deg(math.atan2(dir[1], dir[2]))
		local function cf(along: number, o: number, y: number, extra: number?): CFrame
			local p = Layout.sidePoint(layout, side, along, o)
			return Site.cf(site, p[1], y, p[2], heading + (extra or 0))
		end
		-- Dirt pad, two mound/plate lanes pitching toward home.
		for _, lane in { -24, -12 } do
			local moundAlong = 182
			local plateAlong = moundAlong - site.cfg.RubberDistance
			k:box(cf((moundAlong + plateAlong) / 2, lane, 0.06), Vector3.new(6, 0.3, moundAlong - plateAlong + 14), P.Dirt, "Ground", false)
			k:ellipsoid(cf(moundAlong, lane, -0.4), Vector3.new(11, 1.6, 11), P.Dirt, "Ground")
			k:box(cf(moundAlong, lane, 0.42), Vector3.new(2, 0.12, 0.5), P.White, "SmoothPlastic", false)
			k:disc(at(plateAlong, lane, 0.16), 7, 0.3, P.Dirt, "Ground", false)
			k:box(cf(plateAlong, lane, 0.2), Vector3.new(1.6, 0.1, 1.6), P.White, "SmoothPlastic", false)
		end
		-- Chain-link fence on the field side with a top rail.
		local f0, f1 = at(122, -32, 0), at(196, -32, 0)
		local fence = k:beam(f0 + Vector3.new(0, 3, 0), f1 + Vector3.new(0, 3, 0), 0.1, 6, rgb(150, 156, 160), "Metal", false)
		if fence then
			fence.transparency = 0.7
		end
		k:beam(f0 + Vector3.new(0, 6, 0), f1 + Vector3.new(0, 6, 0), 0.3, 0.3, P.Steel, "Metal", false)
		for along = 122, 196, 18.5 do
			k:post(at(along, -32, 0), 6.2, 0.35, P.Steel, "Metal")
		end
		for _, along in { 122, 196 } do
			local e = k:beam(at(along, -32, 3), at(along, -1, 3), 0.1, 6, rgb(150, 156, 160), "Metal", false)
			if e then
				e.transparency = 0.7
			end
		end
		-- Covered bench at the far end.
		local bench = cf(192, -8, 0)
		k:box(bench * CFrame.new(0, 0.9, 0), Vector3.new(12, 0.4, 2.2), P.Wood, "WoodPlanks", false)
		k:box(bench * CFrame.new(0, 8, 1.4), Vector3.new(14, 0.5, 6), P.Steel, "Metal", false)
		for _, x in { -6.6, 6.6 } do
			k:post((bench * CFrame.new(x, 0, 3.8)).Position, 8, 0.4, P.Steel, "Metal")
		end
		local sign = k:box(bench * CFrame.new(0, 9.4, -1.6) * CFrame.Angles(0, math.pi, 0), Vector3.new(10, 2.2, 0.2), P.Navy, "SmoothPlastic", false)
		sign.sign = { text = "BULLPEN", color = P.White, font = "GothamBlack" }
		-- Ball bucket and a rolled tarp along the wall.
		k:cyl(cf(186, -14, 0.9) * CFrame.Angles(0, 0, math.pi / 2), 1.8, 1.5, rgb(236, 120, 30), "Plastic", false)
		for i = 0, 4 do
			k:ball((cf(186, -14, 1.8) * CFrame.new(-0.4 + (i % 3) * 0.4, 0, -0.3 + (i % 2) * 0.5)).Position, 0.36, P.White, "SmoothPlastic")
		end
		local tarpA, tarpB = at(90, -3.4, 1.6), at(118, -3.4, 1.6)
		k:cyl(CFrame.lookAt((tarpA + tarpB) / 2, tarpB) * CFrame.Angles(0, math.pi / 2, 0), (tarpB - tarpA).Magnitude, 3.2, rgb(40, 80, 140), "Fabric", false)
	end
end

-- Corner party decks beyond the foul poles (foul territory, at the view edges).
-- Local frame: -Z = along the foul line away from home, +Z = toward home,
-- X across; `outX` points to the street side.
local function partyDecks(k: Kit.Kit, layout: Layout.Layout)
	local site = layout.site
	for side = 1, 2 do
		k:chunk(if side == 1 then "PartyDeckLF" else "PartyDeckRF", 0)
		local dir = layout.lineDir[side]
		local heading = math.deg(math.atan2(dir[1], dir[2]))
		local outX = if side == 2 then 1 else -1
		local function cf(along: number, out: number, y: number): CFrame
			local p = Layout.sidePoint(layout, side, along, out - layout.sideOffset)
			return Site.cf(site, p[1], y, p[2], heading)
		end
		local W, D = 40, 36
		local c = cf(294, 28, 0)
		for level, y in { 9, 18 } do
			k:box(c * CFrame.new(0, y - 0.5, 0), Vector3.new(W, 1, D), P.Concrete, "Concrete", true)
			k:box(c * CFrame.new(0, y - 1.2, 0), Vector3.new(W + 0.6, 0.4, D + 0.6), P.Steel, "Metal", false)
			-- Glass rails on the field-facing sides (toward home and toward fair territory).
			local railHome = k:box(c * CFrame.new(0, y + 1.6, D / 2), Vector3.new(W, 2.6, 0.2), P.Glass, "Glass", false)
			railHome.transparency = 0.5
			local railFair = k:box(c * CFrame.new(-outX * W / 2, y + 1.6, 0), Vector3.new(0.2, 2.6, D), P.Glass, "Glass", false)
			railFair.transparency = 0.5
			k:box(c * CFrame.new(0, y + 3, D / 2), Vector3.new(W, 0.3, 0.4), P.Steel, "Metal", false)
			for i = 0, 3 do
				local t = c * CFrame.new(-W / 2 + 8 + (i % 2) * 14 + level * 2, y, D / 2 - 7 - math.floor(i / 2) * 12)
				k:cyl(t * CFrame.new(0, 2.6, 0) * CFrame.Angles(0, 0, math.pi / 2), 0.3, 3.6, P.White, "Plastic", false)
				k:post(t.Position, 2.6, 0.3, P.Steel, "Metal")
				if level == 2 then
					k:post(t.Position, 8, 0.25, P.White, "Metal")
					k:ellipsoid(t * CFrame.new(0, 8, 0), Vector3.new(8, 1.6, 8), if i % 2 == 0 then P.Red else P.Yellow, "Fabric")
				end
				for g = 0, 2 do
					local a = g * 2.1
					local gp = t * CFrame.new(math.cos(a) * 2.6, 0, math.sin(a) * 2.6)
					k:box(gp * CFrame.new(0, 2.4, 0), Vector3.new(1.4, 2.8, 0.9), k:pick(Bowl.SHIRTS), "SmoothPlastic", false)
					k:ball((gp * CFrame.new(0, 4.4, 0)).Position, 1.05, rgb(234, 184, 146), "SmoothPlastic")
				end
			end
		end
		for _, x in { -W / 2 + 1, W / 2 - 1 } do
			for _, z in { -D / 2 + 1, 0, D / 2 - 1 } do
				k:box(c * CFrame.new(x, 13.5, z), Vector3.new(1.4, 27, 1.4), P.Steel, "Metal", true)
			end
		end
		k:box(c * CFrame.new(0, 27.5, 0), Vector3.new(W + 4, 1, D + 4), P.Roof, "Metal", false)
		k:box(c * CFrame.new(0, 26.3, D / 2 + 2), Vector3.new(W + 4, 2.4, 0.6), P.Steel, "Metal", false)
		local sign = k:box(
			c * CFrame.new(0, 26.3, D / 2 + 2.4) * CFrame.Angles(0, math.pi, 0),
			Vector3.new(W - 4, 2, 0.1),
			P.Steel,
			"SmoothPlastic",
			false
		)
		sign.sign = {
			text = if side == 1 then "HOME RUN PORCH" else "PICNIC PAVILION",
			color = P.Yellow,
			font = "GothamBlack",
		}
		-- Stairs up the street side; brick screen walls at street level.
		for i = 0, 8 do
			k:box(
				c * CFrame.new(outX * (W / 2 + 2.5), i + 0.5, D / 2 - 3 - i * 1.7),
				Vector3.new(4, 1, 1.7),
				P.Concrete,
				"Concrete",
				true
			)
		end
		k:box(c * CFrame.new(outX * (W / 2 - 0.6), 4, -4), Vector3.new(1.2, 8, D - 8), P.Brick, "Brick", true)
		k:box(c * CFrame.new(0, 4, -D / 2 + 0.6), Vector3.new(W, 8, 1.2), P.Brick, "Brick", true)
	end
end

function Outfield.build(k: Kit.Kit, layout: Layout.Layout)
	wall(k, layout)
	batterEye(k, layout)
	bleachers(k, layout)
	scoreboard(k, layout)
	lights(k, layout)
	partyDecks(k, layout)
	bullpens(k, layout)
end

return Outfield
