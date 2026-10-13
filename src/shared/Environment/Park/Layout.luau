--!strict
-- Rookie Park plan geometry shared by the park builders (all in plate-local
-- u/v studs, see Site). Derived from the authored field so new architecture
-- wraps the existing diamond, fence and markers without moving any of them.

local Site = require(script.Parent.Parent.Site)

local Layout = {}

export type P2 = Site.P2

export type Layout = {
	site: Site.Site,
	base: number, -- home -> first base
	rubber: P2, -- rubber centre (u, v)
	bases: { P2 }, -- 1B, 2B, 3B
	fence: { P2 }, -- fence polyline from the left pole to the right pole
	fenceAngles: { number },
	-- Field enclosure (top of the stands' front wall / backstop line).
	backstopCenter: P2,
	backstopRadius: number,
	sideOffset: number, -- stands front wall distance from each foul line
	tangent: { P2 }, -- { left, right } points where the backstop arc meets the side walls
	corner: { P2 }, -- { left, right } stand-front corners level with the poles
	poles: { P2 }, -- { left, right }
	enclosure: { P2 }, -- full boundary loop (counter-clockwise viewed from above)
	lineDir: { P2 }, -- unit foul-line directions { left, right }
	outward: { P2 }, -- unit outward normals of the side walls { left, right }
	standsEnd: number, -- along-line distance where the baseline stands end
}

Layout.FenceStepDegrees = 1.875 -- authored post spacing

local function add(a: P2, b: P2, s: number): P2
	return { a[1] + b[1] * s, a[2] + b[2] * s }
end

function Layout.new(site: Site.Site): Layout
	local cfg = site.cfg
	local s2 = math.sqrt(0.5)
	local base = cfg.BaseDistance
	local d = base * s2
	local fence: { P2 } = {}
	local angles: { number } = {}
	local steps = math.floor(90 / Layout.FenceStepDegrees + 0.5)
	for i = 0, steps do
		local phi = -45 + i * Layout.FenceStepDegrees
		local u, v = Site.polarUV(Site.fenceRadius(site, phi), phi)
		table.insert(fence, { u, v })
		table.insert(angles, phi)
	end
	-- Backstop: 48 studs behind home, stands fronts 54 studs off each foul line.
	local behind, side = 48, 54
	local c = (side - behind) / (1 - s2)
	local radius = behind + c
	local center: P2 = { 0, c }
	local lineDir = { { -s2, s2 }, { s2, s2 } }
	local outward = { { -s2, -s2 }, { s2, -s2 } }
	local tangent = { add(center, outward[1], radius), add(center, outward[2], radius) }
	local poles = { fence[1], fence[#fence] }
	local corner = { add(poles[1], outward[1], side), add(poles[2], outward[2], side) }
	-- Enclosure: fence (left pole -> right pole), right corner wall, right side,
	-- backstop arc behind home, left side, left corner wall.
	local loop: { P2 } = {}
	for i = #fence, 1, -1 do
		table.insert(loop, fence[i])
	end
	-- loop now runs right pole -> left pole (counter-clockwise in u/v).
	table.insert(loop, corner[1])
	table.insert(loop, tangent[1])
	local a0 = math.atan2(outward[1][1], outward[1][2]) -- -135 deg
	local a1 = math.atan2(outward[2][1], outward[2][2]) + (-2 * math.pi) -- 135 deg - 360
	local arcSteps = 20
	for i = 1, arcSteps - 1 do
		local a = a0 + (a1 - a0) * i / arcSteps
		table.insert(loop, { center[1] + radius * math.sin(a), center[2] + radius * math.cos(a) })
	end
	table.insert(loop, tangent[2])
	table.insert(loop, corner[2])
	return {
		site = site,
		base = base,
		rubber = { 0, cfg.RubberDistance },
		bases = { { d, d }, { 0, 2 * d }, { -d, d } },
		fence = fence,
		fenceAngles = angles,
		backstopCenter = center,
		backstopRadius = radius,
		sideOffset = side,
		tangent = tangent,
		corner = corner,
		poles = poles,
		enclosure = loop,
		lineDir = lineDir,
		outward = outward,
		standsEnd = cfg.FenceCornerRadius + 14,
	}
end

-- Along-line / outward coordinates for side `i` (1 = third-base/left, 2 = first-base/right).
function Layout.sidePoint(layout: Layout, i: number, along: number, out: number): P2
	local dir, n = layout.lineDir[i], layout.outward[i]
	return {
		dir[1] * along + n[1] * (layout.sideOffset + out),
		dir[2] * along + n[2] * (layout.sideOffset + out),
	}
end

-- Along-line distance of the side tangent point.
function Layout.tangentAlong(layout: Layout): number
	local t, dir = layout.tangent[2], layout.lineDir[2]
	return t[1] * dir[1] + t[2] * dir[2]
end

return Layout
