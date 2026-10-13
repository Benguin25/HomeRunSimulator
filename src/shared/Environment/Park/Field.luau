--!strict
-- The playing surface: layered grass with a diagonal mowing pattern, clay
-- infield skin with base cutouts, a domed mound at the authored rubber height,
-- warning track, chalk details and a painted home-plate logo.
--
-- Every surface is visual (non-colliding). The authored Stadium field stays
-- the collision/landing surface underneath; visual tops match its heights.

local Environment = script.Parent.Parent
local Config = require(Environment.EnvironmentConfig)
local Site = require(Environment.Site)
local Kit = require(Environment.EnvKit)
local Layout = require(script.Parent.Layout)

local Field = {}

local P = Config.Palette
-- Layer tops (world Y). Gaps of >= 0.05 keep overlapping layers from
-- z-fighting at follow-camera distances; all stay below the authored chalk
-- (0.31) and plate (0.32), and within 0.12 of the authored collision tops.
local H = {
	Base = 0.0,
	Stripe = 0.07,
	Track = 0.13,
	Skin = 0.18,
	InfieldGrass = 0.24,
	Cutout = 0.29,
	Chalk = 0.34,
}

local function fanFromPlate(layout: Layout.Layout): { Layout.P2 }
	local poly: { Layout.P2 } = { { 0, 0 } }
	for _, p in layout.fence do
		table.insert(poly, p)
	end
	return poly
end

-- Clips a convex cell against every edge of a convex polygon (inside = left of
-- each edge for a counter-clockwise polygon).
local function clipConvex(cell: { Layout.P2 }, poly: { Layout.P2 }): { Layout.P2 }
	local ccw = Site.area(poly) > 0
	local out = cell
	for i = 1, #poly do
		local a, b = poly[i], poly[i % #poly + 1]
		local du, dv = b[1] - a[1], b[2] - a[2]
		local nu, nv = -dv, du
		if not ccw then
			nu, nv = dv, -du
		end
		out = Site.clip(out, a[1], a[2], nu, nv)
		if #out < 3 then
			return out
		end
	end
	return out
end

local function fill(k: Kit.Kit, site: Site.Site, poly: { Layout.P2 }, top: number, color: Kit.Color, material: string)
	if #poly >= 3 then
		k:poly(Site.lift(site, poly, top), 0.4, color, material, false)
	end
end

local function chalkLine(k: Kit.Kit, site: Site.Site, a: Layout.P2, b: Layout.P2, width: number?)
	k:beam(
		Site.at(site, a[1], H.Chalk - 0.02, a[2]),
		Site.at(site, b[1], H.Chalk - 0.02, b[2]),
		width or 0.22,
		0.05,
		P.Chalk,
		"SmoothPlastic",
		false
	)
end

local function rectOutline(k: Kit.Kit, site: Site.Site, cu: number, cv: number, w: number, l: number, heading: number)
	local a = math.rad(heading)
	local function at(x: number, z: number): Layout.P2
		return { cu + x * math.cos(a) + z * math.sin(a), cv - x * math.sin(a) + z * math.cos(a) }
	end
	local c = { at(-w / 2, -l / 2), at(w / 2, -l / 2), at(w / 2, l / 2), at(-w / 2, l / 2) }
	for i = 1, 4 do
		chalkLine(k, site, c[i], c[i % 4 + 1], 0.18)
	end
end

function Field.build(k: Kit.Kit, layout: Layout.Layout)
	local site = layout.site
	k:chunk("Field", 0)

	-- 1. Base grass across the whole enclosure (convex pieces).
	local fan = fanFromPlate(layout)
	fill(k, site, fan, H.Base, P.Grass, "Grass")
	local t, c, pl = layout.tangent, layout.corner, layout.poles
	fill(k, site, { { 0, 0 }, t[2], c[2], pl[2] }, H.Base, P.FoulGrass, "Grass")
	fill(k, site, { { 0, 0 }, pl[1], c[1], t[1] }, H.Base, P.FoulGrass, "Grass")
	local cap: { Layout.P2 } = { { 0, 0 }, t[2] }
	local center, radius = layout.backstopCenter, layout.backstopRadius
	local a0 = math.atan2(layout.outward[2][1], layout.outward[2][2])
	local a1 = math.atan2(layout.outward[1][1], layout.outward[1][2]) + 2 * math.pi
	for i = 1, 15 do
		local a = a0 + (a1 - a0) * i / 16
		table.insert(cap, { center[1] + radius * math.sin(a), center[2] + radius * math.cos(a) })
	end
	table.insert(cap, t[1])
	fill(k, site, cap, H.Base, P.FoulGrass, "Grass")

	-- 2. Diagonal mowing pattern in fair territory (cells aligned with the basepaths).
	-- Fair territory is the x >= 0, y >= 0 quadrant of a frame whose axes run
	-- along the first-base (x) and third-base (y) lines.
	local cell = 15
	local s2 = math.sqrt(0.5)
	local function at(x: number, y: number): Layout.P2
		return { (x - y) * s2, (x + y) * s2 }
	end
	for i = 0, 22 do
		for j = 0, 22 do
			if (i + j) % 2 == 0 then
				local x0, y0 = i * cell, j * cell
				local quad = { at(x0, y0), at(x0 + cell, y0), at(x0 + cell, y0 + cell), at(x0, y0 + cell) }
				local clipped = clipConvex(quad, fan)
				local area = math.abs(Site.area(clipped))
				if #clipped >= 3 and area > cell * cell - 0.5 then
					-- Whole cell inside fair territory: one rotated box.
					local mid = at(x0 + cell / 2, y0 + cell / 2)
					k:box(
						Site.cf(site, mid[1], H.Stripe - 0.2, mid[2], 45),
						Vector3.new(cell, 0.4, cell),
						P.GrassStripe,
						"Grass",
						false
					)
				elseif #clipped >= 3 and area > 4 then
					fill(k, site, clipped, H.Stripe, P.GrassStripe, "Grass")
				end
			end
		end
	end

	-- 3. Warning track ring inside the whole enclosure wall.
	local outer = layout.enclosure
	local inner = Site.offset(outer, 11, true)
	for i = 1, #outer do
		local j = i % #outer + 1
		local quad = { outer[i], outer[j], inner[j], inner[i] }
		if math.abs(Site.area(quad)) > 0.5 then
			fill(k, site, quad, H.Track, P.Track, "Ground")
		end
	end

	-- 4. Infield skin: arc around the rubber, clipped a little past each foul line.
	local rubber = layout.rubber
	local skin = Site.circle(rubber[1], rubber[2], 76, 56)
	skin = Site.clip(skin, 2.83, -2.83, -s2, s2)
	skin = Site.clip(skin, -2.83, -2.83, s2, s2)
	fill(k, site, skin, H.Skin, P.Dirt, "Ground")

	-- 5. Infield grass inside the basepaths.
	local d = layout.base * s2
	local side = layout.base - 4.8
	k:box(Site.cf(site, 0, H.InfieldGrass - 0.15, d, 45), Vector3.new(side, 0.3, side), P.Grass, "Grass", false)
	-- Lip of slightly darker grass along the infield edge for definition.
	for _, b in layout.bases do
		k:disc(Site.at(site, b[1], H.Cutout, b[2]), 18, 0.3, P.Dirt, "Ground", false)
	end
	k:disc(Site.at(site, 0, H.Cutout, 0), 20.8, 0.3, P.Dirt, "Ground", false)
	k:disc(Site.at(site, 0, H.Cutout + 0.01, 0), 15.5, 0.3, P.DirtDark, "Ground", false)

	-- 6. Mound dome. Plateau = authored mound top; the rubber part stays authored.
	local cfg = site.cfg
	-- Smooth dome: an ellipsoid whose crown is the authored mound top, so the
	-- pitcher's feet and the authored rubber keep their exact heights.
	local crown = cfg.MoundTop - 0.04
	k:ellipsoid(
		Site.cf(site, rubber[1], crown - 1.0, rubber[2]),
		Vector3.new(16.4, 2.0, 16.4),
		P.Dirt,
		"Ground"
	)
	k:ellipsoid(Site.cf(site, rubber[1], cfg.MoundTop - 0.3, rubber[2] + 0.6), Vector3.new(6.5, 0.62, 4.6), P.DirtDark, "Ground")

	-- 7. Chalk details (authored foul lines and batter's boxes stay visible).
	-- Catcher's box.
	chalkLine(k, site, { -1.9, -2.5 }, { -1.9, -9 })
	chalkLine(k, site, { 1.9, -2.5 }, { 1.9, -9 })
	chalkLine(k, site, { -1.9, -9 }, { 1.9, -9 })
	-- Running lane (second half of the first-base line).
	local function lineOut(along: number, out: number): Layout.P2
		return { (along + out) * s2, (along - out) * s2 }
	end
	chalkLine(k, site, lineOut(layout.base / 2, 2.4), lineOut(layout.base - 1, 2.4))
	chalkLine(k, site, lineOut(layout.base / 2, 0), lineOut(layout.base / 2, 2.4))
	-- Coaches' boxes beyond first and third.
	for _, sgn in { -1, 1 } do
		local along, out = layout.base + 4, 11
		local cu = sgn * (along * s2 + out * s2)
		local cv = along * s2 - out * s2
		rectOutline(k, site, cu, cv, 7, 15, sgn * 45)
	end
	-- Foul-line extension along the warning track to the wall.
	-- On-deck circles with a navy rubber mat.
	for _, sgn in { -1, 1 } do
		local cu, cv = sgn * 30, -12
		k:disc(Site.at(site, cu, H.Chalk - 0.03, cv), 4.6, 0.2, P.Chalk, "SmoothPlastic", false)
		k:disc(Site.at(site, cu, H.Chalk - 0.01, cv), 4.0, 0.2, P.Navy, "Rubber", false)
	end
	-- Painted logo in foul territory behind home (reads from the follow camera and free roam).
	local logo = k:box(Site.cf(site, 0, H.Base + 0.03, -30, 180), Vector3.new(30, 0.05, 8), P.FoulGrass, "Grass", false)
	logo.transparency = 1
	logo.sign = { text = "ROOKIE PARK", color = P.Chalk, font = "GothamBlack", face = "Top" }
end

return Field
