--!strict
-- Stage 2 environment: pure plan checks (no Instances), so they run in Lune.
-- Visual quality itself still needs Studio; these guard the gameplay contract.
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Environment.EnvironmentConfig)
local Plan = require(Shared.Environment.EnvironmentPlan)
local Site = require(Shared.Environment.Site)
local Layout = require(Shared.Environment.Park.Layout)
local RegionMap = require(Shared.Environment.RegionMap)
local Town = require(Shared.Environment.World.Town)
local WorldConfig = require(Shared.Worlds.WorldConfig)
local PitchConfig = require(Shared.Pitching.PitchConfig)
local Test = require(script.Parent.TestUtil)

local STADIUM_PREFIXES = {
	"Field",
	"Bowl",
	"OutfieldWall",
	"BatterEye",
	"Bleachers",
	"Scoreboard",
	"LightTowers",
	"PartyDeck",
	"Bullpen",
	"ParkApron",
	"Concourse",
	"Perimeter",
	"Plaza",
	"ParkStreet",
}

local function isStadium(name: string): boolean
	for _, prefix in STADIUM_PREFIXES do
		if string.sub(name, 1, #prefix) == prefix then
			return true
		end
	end
	return false
end

local cached: Plan.Plan? = nil
local function plan(): Plan.Plan
	if not cached then
		cached = Plan.build()
	end
	return cached :: Plan.Plan
end

-- World-space axis-aligned half extents of a rotated spec.
local function halfExtents(spec: any): Vector3
	local cf, h = spec.cf, spec.size / 2
	local r, u, b = cf.RightVector, cf.UpVector, cf.LookVector
	return Vector3.new(
		math.abs(r.X) * h.X + math.abs(u.X) * h.Y + math.abs(b.X) * h.Z,
		math.abs(r.Y) * h.X + math.abs(u.Y) * h.Y + math.abs(b.Y) * h.Z,
		math.abs(r.Z) * h.X + math.abs(u.Z) * h.Y + math.abs(b.Z) * h.Z
	)
end

local function insideBox(spec: any, p: Vector3, pad: number): boolean
	local l = spec.cf:PointToObjectSpace(p)
	local h = spec.size / 2
	return math.abs(l.X) <= h.X + pad and math.abs(l.Y) <= h.Y + pad and math.abs(l.Z) <= h.Z + pad
end

local function pointInPolygon(poly: { Layout.P2 }, u: number, v: number): boolean
	local inside = false
	local j = #poly
	for i = 1, #poly do
		local a, b = poly[i], poly[j]
		if (a[2] > v) ~= (b[2] > v) and u < (b[1] - a[1]) * (v - a[2]) / (b[2] - a[2]) + a[1] then
			inside = not inside
		end
		j = i
	end
	return inside
end

return function(t)
	t.test("environment plan is deterministic and within part budgets", function()
		local a = plan()
		local b = Plan.build()
		Test.assertEqual(a.count, b.count, "same seed and site must give the same plan")
		Test.assertEqual(#a.chunks, #b.chunks)
		local first, last = a.chunks[1].parts[1], a.chunks[#a.chunks].parts[#a.chunks[#a.chunks].parts]
		local first2, last2 = b.chunks[1].parts[1], b.chunks[#b.chunks].parts[#b.chunks[#b.chunks].parts]
		Test.assertTrue((first.cf.Position - first2.cf.Position).Magnitude < 1e-4, "first spec position")
		Test.assertTrue((last.cf.Position - last2.cf.Position).Magnitude < 1e-4, "last spec position")
		Test.assertTrue(a.count <= Config.Build.PartBudget, `plan has {a.count} parts (budget {Config.Build.PartBudget})`)
		local stadium = 0
		for _, chunk in a.chunks do
			if isStadium(chunk.name) then
				stadium += #chunk.parts
			end
		end
		Test.assertTrue(stadium > 3000, "the stadium is the detailed hero")
		Test.assertTrue(stadium <= Config.Build.StadiumBudget, `stadium has {stadium} parts`)
		-- The first chunk realized is the field, so the authored field is never hidden early.
		Test.assertEqual(a.chunks[1].name, "Field")
	end)

	t.test("every spec is well formed (finite sizes, known shapes, valid colours)", function()
		local shapes = { Block = true, Wedge = true, Cylinder = true, Ball = true, Ellipsoid = true }
		for _, chunk in plan().chunks do
			for _, s in chunk.parts do
				Test.assertTrue(shapes[s.shape] == true, `shape {s.shape}`)
				local size = s.size
				Test.assertTrue(size.X > 0 and size.Y > 0 and size.Z > 0, `positive size in {chunk.name}`)
				-- Parts are capped at 2,048 studs; ellipsoids are realized with a mesh scale.
				local limit = if s.shape == "Ellipsoid" then 2048 * 4 else 2048
				Test.assertTrue(size.X <= limit and size.Y <= limit and size.Z <= limit, `engine size limit in {chunk.name}`)
				local p = s.cf.Position
				Test.assertTrue(p.X == p.X and p.Y == p.Y and p.Z == p.Z, `finite position in {chunk.name}`)
				for _, c in s.color do
					Test.assertTrue(c >= 0 and c <= 255, "colour channel")
				end
				Test.assertTrue(s.transparency >= 0 and s.transparency < 1 or s.transparency == 1, "transparency")
			end
		end
	end)

	t.test("batter's sightline to the pitcher and centre field stays clear for both hands", function()
		local site = plan().site
		local units = PitchConfig.Units.MetersPerStud
		local cam = PitchConfig.Camera
		for _, sign in { -1, 1 } do
			local eye = Site.at(site, sign * cam.SideMeters / units, cam.HeightMeters / units + 0.3, -cam.BackMeters / units)
			for _, du in { -3, 0, 3 } do
				local target = Site.at(site, du * 5, 7.2, 300)
				local steps = math.floor((target - eye).Magnitude)
				for _, chunk in plan().chunks do
					if not isStadium(chunk.name) then
						continue
					end
					for _, s in chunk.parts do
						-- Coarse reject by bounding sphere to the segment.
						local c = s.cf.Position
						local ab = target - eye
						local u = math.clamp((c - eye):Dot(ab) / ab:Dot(ab), 0, 1)
						if (c - (eye + ab * u)).Magnitude <= s.size.Magnitude / 2 + 2 then
							for i = 0, steps do
								local p = eye:Lerp(target, i / steps)
								Test.assertTrue(not insideBox(s, p, 1.5), `{chunk.name} blocks the pitch sightline`)
							end
						end
					end
				end
			end
		end
	end)

	t.test("no neon or bright clutter behind the pitcher; batter's eye is matte and dark", function()
		local site = plan().site
		for _, chunk in plan().chunks do
			for _, s in chunk.parts do
				local u, v = Site.toLocal(site, s.cf.Position)
				local r = math.sqrt(u * u + v * v)
				local phi = math.deg(math.atan2(u, v))
				if r > 60 and r < 900 and math.abs(phi) < 12 and s.cf.Position.Y < 40 then
					Test.assertTrue(s.material ~= "Neon", `neon behind the pitcher in {chunk.name}`)
				end
			end
		end
		local eye = 0
		for _, chunk in plan().chunks do
			if chunk.name == "BatterEye" then
				for _, s in chunk.parts do
					local lum = 0.2126 * s.color[1] + 0.7152 * s.color[2] + 0.0722 * s.color[3]
					Test.assertTrue(lum < 90, "batter's eye stays dark")
					eye += 1
				end
			end
		end
		Test.assertTrue(eye > 0, "batter's eye exists")
	end)

	t.test("no walkable or camera-solid scenery inside the field of play", function()
		local p = plan()
		local inset = Site.offset(p.layout.enclosure, 3, true)
		for _, chunk in p.chunks do
			for _, s in chunk.parts do
				if s.collide then
					local u, v = Site.toLocal(p.site, s.cf.Position)
					local top = s.cf.Position.Y + halfExtents(s).Y
					Test.assertTrue(
						not pointInPolygon(inset, u, v) or top < 0.3,
						`{chunk.name} adds collision inside the field at ({u}, {v})`
					)
				end
			end
		end
	end)

	t.test("spawn walkway, roam spawn and both batter's boxes stay unobstructed", function()
		local p = plan()
		local zones = {
			{ u0 = -6, u1 = 6, v0 = -63, v1 = -53 }, -- authored 8x8 SpawnLocation (club walkway)
			{ u0 = -4, u1 = 4, v0 = -16, v1 = -9 }, -- free-roam spawn behind the plate
			{ u0 = -6, u1 = 6, v0 = -4, v1 = 4 }, -- both batter's boxes
		}
		-- Sample each zone volume (character height) against every nearby spec's
		-- oriented box: nothing solid, and nothing visible taller than ground marks.
		for _, z in zones do
			local points = {}
			for u = z.u0, z.u1, 1 do
				for v = z.v0, z.v1, 1 do
					for _, y in { 0.6, 2.5, 4.5, 6.5 } do
						table.insert(points, Site.at(p.site, u, y, v))
					end
				end
			end
			local center = Site.at(p.site, (z.u0 + z.u1) / 2, 3, (z.v0 + z.v1) / 2)
			for _, chunk in p.chunks do
				for _, spec in chunk.parts do
					if (spec.cf.Position - center).Magnitude <= spec.size.Magnitude / 2 + 12 then
						for _, point in points do
							if insideBox(spec, point, 0) then
								Test.assertTrue(not spec.collide, `{chunk.name} collision in a spawn/batting zone`)
								Test.assertTrue(spec.transparency >= 0.8, `{chunk.name} visual clutter in a spawn/batting zone`)
							end
						end
					end
				end
			end
		end
	end)

	t.test("mound and rubber keep the authored heights (pitcher neither floats nor sinks)", function()
		local p = plan()
		local cfg = Config.Site
		local rubber = Site.at(p.site, 0, 0, cfg.RubberDistance)
		for _, chunk in p.chunks do
			for _, s in chunk.parts do
				local d = Vector3.new(s.cf.Position.X - rubber.X, 0, s.cf.Position.Z - rubber.Z).Magnitude
				if d < 2 and chunk.name == "Field" then
					local top = s.cf.Position.Y + halfExtents(s).Y
					Test.assertTrue(top <= cfg.RubberTop - 0.05, "nothing covers the authored rubber")
					Test.assertTrue(top <= cfg.MoundTop + 0.05, "mound crown matches the authored mound top")
				end
			end
		end
	end)

	t.test("all visible ground lies on the authoritative catchment (no ground without landing)", function()
		local rookie = WorldConfig.Rookie
		local half = rookie.WidthStuds / 2
		for _, c in Town.cells() do
			Test.assertTrue(c.u0 >= -half and c.u1 <= half, "town inside catchment width")
			Test.assertTrue(c.v1 <= rookie.ForwardStuds and c.v0 >= -rookie.BackStuds, "town inside catchment length")
		end
		local p = plan()
		for _, chunk in p.chunks do
			if chunk.name == "LandGround" then
				for _, s in chunk.parts do
					local u, v = Site.toLocal(p.site, s.cf.Position)
					Test.assertTrue(math.abs(u) + s.size.X / 2 <= half + 1, "ground tile inside catchment width")
					Test.assertTrue(v + s.size.Z / 2 <= rookie.ForwardStuds + 1, "ground tile inside catchment forward")
					Test.assertTrue(v - s.size.Z / 2 >= -rookie.BackStuds - 1, "ground tile inside catchment back")
				end
			end
		end
		-- The deepest current hit (~3,200 ft) is well inside the catchment.
		Test.assertTrue(RegionMap.feetToStuds(3300) < rookie.ForwardStuds, "max carry covered")
	end)

	t.test("large town and plaza surfaces never cover landed balls or the landing marker", function()
		-- The Stage 4 marker is drawn 0.03 above the authoritative impact point,
		-- and landed balls rest 0.13 above it: big ground surfaces stay at or
		-- below the Rookie catchment top (-0.5 below plate level).
		local catchmentTop = -WorldConfig.Rookie.DropStuds
		local p = plan()
		for _, chunk in p.chunks do
			local name = chunk.name
			local ground = string.sub(name, 1, 5) == "Town_"
				or name == "Plaza"
				or name == "ParkStreets"
				or name == "Boulevard"
				or name == "LandGround"
				or name == "Water"
			if ground then
				for _, s in chunk.parts do
					local half = halfExtents(s)
					local area = 4 * half.X * half.Z
					if half.Y < 0.5 and area > 20000 then
						local top = s.cf.Position.Y + half.Y
						Test.assertTrue(top <= catchmentTop + 0.001, `{name} surface top {top} hides landings`)
					end
				end
			end
		end
	end)

	t.test("region bands are contiguous and landmark metadata is consistent", function()
		local previous = 0
		local ids: { [string]: boolean } = {}
		for _, r in RegionMap.Regions do
			Test.assertEqual(r.minFeet, previous, `{r.id} starts where the previous band ends`)
			Test.assertTrue(r.maxFeet > r.minFeet)
			Test.assertTrue(not ids[r.id], "unique region id")
			ids[r.id] = true
			previous = r.maxFeet
		end
		Test.assertEqual(previous, math.huge, "outermost band is open-ended")
		local lids: { [string]: boolean } = {}
		for _, l in RegionMap.Landmarks do
			Test.assertTrue(not lids[l.id], `unique landmark id {l.id}`)
			lids[l.id] = true
			Test.assertEqual(RegionMap.regionForFeet(l.feet).id, l.region, `{l.id} region matches its distance`)
			local c = RegionMap.classify(l.feet, l.spray)
			Test.assertTrue(c.landmark ~= nil and c.landmark.id == l.id, `{l.id} classifies at its own centre`)
		end
		Test.assertEqual(RegionMap.regionForFeet(150).id, "stadium")
		Test.assertEqual(RegionMap.regionForFeet(450).id, "grounds")
		Test.assertEqual(RegionMap.regionForFeet(3100).id, "foundry")
		Test.assertEqual(RegionMap.regionForFeet(25000).id, "titan_peaks")
		Test.assertEqual(RegionMap.regionForFeet(-5).id, "stadium", "invalid input falls back safely")
		-- Authoritative field metres (x forward, z right) -> feet and spray.
		local c = RegionMap.fromField(100, 0)
		Test.assertNear(c.distanceFeet, 328.08, 0.05)
		Test.assertNear(c.sprayDegrees, 0, 1e-6)
		Test.assertEqual(c.region.id, "grounds")
		local right = RegionMap.fromField(0, 50)
		Test.assertNear(right.sprayDegrees, 90, 1e-6)
	end)

	t.test("town landmarks are built where RegionMap says they are", function()
		local kinds = {
			CornerMart = true,
			Diner = true,
			School = true,
			Park = true,
			Square = true,
			GasStation = true,
			Construction = true,
			CrownTower = true,
			Tower = true,
			Garage = true,
		}
		local placed: { [string]: boolean } = {}
		for _, c in Town.cells() do
			if c.landmark then
				placed[c.landmark.id] = true
			end
		end
		for _, l in RegionMap.Landmarks do
			if kinds[l.kind] then
				Test.assertTrue(placed[l.id] == true, `{l.id} has a town lot`)
			end
		end
	end)
end
