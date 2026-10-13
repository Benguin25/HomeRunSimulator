--!strict
-- Plate-relative layout frame for the Rookie environment.
--
-- Local layout coordinates: u = studs toward the first-base side (field
-- "right"), v = studs from home plate toward centre field (field "forward"),
-- y = ABSOLUTE world height (the authored surfaces are measured in world Y).
-- Polar form: r studs from home plate at spray angle phi degrees (+ = first
-- base / right field), matching FieldFrame's spray convention.

local Config = require(script.Parent.EnvironmentConfig)

local Site = {}

export type Site = {
	plate: Vector3, -- plate centre, y = 0
	forward: Vector3, -- unit, horizontal, toward the pitcher
	right: Vector3, -- unit, horizontal, toward first base
	yaw: number, -- radians; CFrame yaw that maps local -Z to forward
	cfg: typeof(Config.Site),
}

export type P2 = { number } -- { u, v }

function Site.new(plate: Vector3?, forward: Vector3?): Site
	local f = (forward or Config.Site.Forward)
	f = Vector3.new(f.X, 0, f.Z).Unit
	local p = plate or Config.Site.Plate
	local right = f:Cross(Vector3.yAxis).Unit
	return {
		plate = Vector3.new(p.X, 0, p.Z),
		forward = f,
		right = right,
		yaw = math.atan2(-f.X, -f.Z),
		cfg = Config.Site,
	}
end

function Site.at(site: Site, u: number, y: number, v: number): Vector3
	return site.plate + site.right * u + site.forward * v + Vector3.new(0, y, 0)
end

-- CFrame at (u, y, v) whose LookVector is `heading` degrees from forward
-- (+ toward first base). heading 0 = facing centre field.
function Site.cf(site: Site, u: number, y: number, v: number, heading: number?): CFrame
	return CFrame.new(Site.at(site, u, y, v)) * CFrame.Angles(0, site.yaw - math.rad(heading or 0), 0)
end

function Site.polarUV(r: number, phi: number): (number, number)
	local a = math.rad(phi)
	return r * math.sin(a), r * math.cos(a)
end

function Site.polar(site: Site, r: number, phi: number, y: number): Vector3
	local u, v = Site.polarUV(r, phi)
	return Site.at(site, u, y, v)
end

-- Looking outward along the spray direction.
function Site.polarCf(site: Site, r: number, phi: number, y: number): CFrame
	local u, v = Site.polarUV(r, phi)
	return Site.cf(site, u, y, v, phi)
end

function Site.toLocal(site: Site, world: Vector3): (number, number)
	local d = world - site.plate
	return d:Dot(site.right), d:Dot(site.forward)
end

-- Authored outfield fence radius (studs) at spray angle phi (degrees).
function Site.fenceRadius(site: Site, phi: number): number
	local c = site.cfg
	local a = math.clamp(phi, -45, 45)
	return c.FenceCornerRadius + (c.FenceCenterRadius - c.FenceCornerRadius) * math.cos(math.rad(2 * a))
end

-- 2D polygon helpers in (u, v) --------------------------------------------

-- Keeps the part of a convex/ordered polygon on the side where
-- (p - origin) . normal >= 0. Sutherland-Hodgman against one half-plane.
function Site.clip(poly: { P2 }, ou: number, ov: number, nu: number, nv: number): { P2 }
	local out: { P2 } = {}
	local n = #poly
	for i = 1, n do
		local a, b = poly[i], poly[i % n + 1]
		local da = (a[1] - ou) * nu + (a[2] - ov) * nv
		local db = (b[1] - ou) * nu + (b[2] - ov) * nv
		if da >= 0 then
			table.insert(out, a)
		end
		if (da >= 0) ~= (db >= 0) then
			local t = da / (da - db)
			table.insert(out, { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t })
		end
	end
	return out
end

function Site.circle(cu: number, cv: number, r: number, segments: number): { P2 }
	local out: { P2 } = {}
	for i = 0, segments - 1 do
		local a = 2 * math.pi * i / segments
		table.insert(out, { cu + r * math.sin(a), cv + r * math.cos(a) })
	end
	return out
end

-- Polygon area sign: > 0 when counter-clockwise in (u, v).
function Site.area(poly: { P2 }): number
	local s = 0
	for i = 1, #poly do
		local a, b = poly[i], poly[i % #poly + 1]
		s += a[1] * b[2] - b[1] * a[2]
	end
	return s / 2
end

-- Lifts a (u, v) polygon to world points at height y.
function Site.lift(site: Site, poly: { P2 }, y: number): { Vector3 }
	local out = table.create(#poly)
	for i, p in poly do
		out[i] = Site.at(site, p[1], y, p[2])
	end
	return out
end

-- Offsets an ordered polygon/polyline by `d` along the left normal of travel
-- (miter joins, clamped). Positive d with a counter-clockwise polygon moves
-- outward when travelling clockwise; callers pick the sign they need.
function Site.offset(points: { P2 }, d: number, closed: boolean): { P2 }
	local n = #points
	local out: { P2 } = {}
	for i = 1, n do
		local prev = points[if i == 1 then (if closed then n else 1) else i - 1]
		local nextP = points[if i == n then (if closed then 1 else n) else i + 1]
		local cur = points[i]
		local function normal(a: P2, b: P2): (number, number)
			local du, dv = b[1] - a[1], b[2] - a[2]
			local len = math.sqrt(du * du + dv * dv)
			if len < 1e-6 then
				return 0, 0
			end
			return -dv / len, du / len
		end
		local n1u, n1v = normal(prev, cur)
		local n2u, n2v = normal(cur, nextP)
		if prev == cur then
			n1u, n1v = n2u, n2v
		elseif nextP == cur then
			n2u, n2v = n1u, n1v
		end
		local mu, mv = n1u + n2u, n1v + n2v
		local ml = math.sqrt(mu * mu + mv * mv)
		if ml < 1e-6 then
			mu, mv, ml = n1u, n1v, 1
		end
		mu, mv = mu / ml, mv / ml
		local cosHalf = math.max(mu * n1u + mv * n1v, 0.35)
		table.insert(out, { cur[1] + mu * d / cosHalf, cur[2] + mv * d / cosHalf })
	end
	return out
end

return Site
