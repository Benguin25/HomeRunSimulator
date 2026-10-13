--!strict
-- Rookie Park world regions and landmarks: stable IDs, distance bands and
-- positions. Pure data + pure functions, shared by the environment builders
-- (single source of truth for where landmarks are drawn) and, in a future
-- stage, by server-side landing rewards.
--
-- Coordinates: distance in FEET from home plate along the ground, spray in
-- degrees (0 = straightaway centre field, + = right field), exactly like the
-- authoritative batted-ball record. Use `fromField` with the server's
-- LandingDetector impact (field metres x = forward, z = right) to classify a
-- confirmed landing; never classify from client positions.
--
-- Nothing here grants rewards. Future landmark discoveries should call
-- `classify` on the server with the confirmed, non-provisional fair impact and
-- keep their own deduplication/persistence.

local PitchConfig = require(script.Parent.Parent.Pitching.PitchConfig)

local RegionMap = {}

RegionMap.Version = 1

local METERS_PER_FOOT = 0.3048

export type Region = {
	id: string,
	name: string,
	minFeet: number,
	maxFeet: number, -- math.huge for the outermost band
	description: string,
}

export type Landmark = {
	id: string,
	name: string,
	region: string,
	feet: number, -- distance of the landmark centre from home plate
	spray: number, -- degrees
	radiusFeet: number, -- "landed at" radius for future discovery checks
	kind: string, -- builder hook
}

RegionMap.Regions = {
	{ id = "stadium", name = "Rookie Park", minFeet = 0, maxFeet = 300, description = "The ballpark itself." },
	{ id = "grounds", name = "Ballpark Grounds", minFeet = 300, maxFeet = 600, description = "Plazas, garage and the streets around the park." },
	{ id = "ballpark_row", name = "Ballpark Row", minFeet = 600, maxFeet = 1000, description = "Rowhouses, corner shops and the diner." },
	{ id = "maple_heights", name = "Maple Heights", minFeet = 1000, maxFeet = 1500, description = "Houses, backyards, the school and the park." },
	{ id = "town_center", name = "Bramble Bay Town Center", minFeet = 1500, maxFeet = 2200, description = "Main Street, the square and the gas station." },
	{ id = "foundry", name = "Foundry District", minFeet = 2200, maxFeet = 3200, description = "Across the river: warehouses, the overpass, cranes." },
	{ id = "downtown", name = "Downtown Bramble Bay", minFeet = 3200, maxFeet = 4500, description = "The skyline: Crown Tower and friends." },
	{ id = "harbor_yards", name = "Harbor Yards", minFeet = 4500, maxFeet = 6500, description = "Rail yard, container port and the bay." },
	{ id = "greenfield", name = "Greenfield Outskirts", minFeet = 6500, maxFeet = 9000, description = "Farms, forests and Mirror Lake." },
	{ id = "landmark_coast", name = "Lakeshore Landmarks", minFeet = 9000, maxFeet = 13000, description = "Fun park, Grand Span Bridge, observatory." },
	{ id = "timberline", name = "Timberline Wilds", minFeet = 13000, maxFeet = 18000, description = "Mountains, canyons and Silver Falls." },
	{ id = "titan_peaks", name = "Titan Peaks", minFeet = 18000, maxFeet = math.huge, description = "The far range and the Golden Diamond." },
} :: { Region }

RegionMap.Landmarks = {
	{ id = "scoreboard", name = "Rookie Park Scoreboard", region = "grounds", feet = 371, spray = 27, radiusFeet = 40, kind = "Scoreboard" },
	{ id = "batters_eye", name = "Batter's Eye", region = "grounds", feet = 306, spray = 0, radiusFeet = 30, kind = "BatterEye" },
	{ id = "home_run_porch", name = "Home Run Porch", region = "stadium", feet = 271, spray = -50, radiusFeet = 30, kind = "PartyDeck" },
	{ id = "ballpark_garage", name = "Ballpark Garage", region = "grounds", feet = 480, spray = 76, radiusFeet = 90, kind = "Garage" },
	{ id = "corner_mart", name = "Corner Mart", region = "ballpark_row", feet = 760, spray = -22, radiusFeet = 45, kind = "CornerMart" },
	{ id = "seventh_inning_diner", name = "Seventh Inning Diner", region = "ballpark_row", feet = 820, spray = 20, radiusFeet = 45, kind = "Diner" },
	{ id = "maple_heights_elementary", name = "Maple Heights Elementary", region = "maple_heights", feet = 1260, spray = -24, radiusFeet = 110, kind = "School" },
	{ id = "dugout_commons", name = "Dugout Commons Park", region = "maple_heights", feet = 1280, spray = 16, radiusFeet = 110, kind = "Park" },
	{ id = "town_square", name = "Town Square Clock Tower", region = "town_center", feet = 1900, spray = 0, radiusFeet = 90, kind = "Square" },
	{ id = "fill_up_station", name = "Fill-Up Gas Station", region = "town_center", feet = 1780, spray = 28, radiusFeet = 60, kind = "GasStation" },
	{ id = "bramble_river", name = "Bramble River", region = "foundry", feet = 2260, spray = 0, radiusFeet = 60, kind = "River" },
	{ id = "foundry_crane", name = "Foundry Construction Site", region = "foundry", feet = 2900, spray = 16, radiusFeet = 90, kind = "Construction" },
	{ id = "riverside_overpass", name = "Riverside Overpass", region = "foundry", feet = 2760, spray = -12, radiusFeet = 60, kind = "Overpass" },
	{ id = "crown_tower", name = "Crown Tower", region = "downtown", feet = 3950, spray = -7, radiusFeet = 70, kind = "CrownTower" },
	{ id = "pennant_building", name = "Pennant Building", region = "downtown", feet = 3700, spray = 13, radiusFeet = 60, kind = "Tower" },
	{ id = "bramble_bank_tower", name = "Bramble Bank Tower", region = "downtown", feet = 4150, spray = -24, radiusFeet = 60, kind = "Tower" },
	{ id = "harbor_rail_yard", name = "Harbor Rail Yard", region = "harbor_yards", feet = 5200, spray = -28, radiusFeet = 300, kind = "RailYard" },
	{ id = "container_port", name = "Container Port", region = "harbor_yards", feet = 5800, spray = 24, radiusFeet = 300, kind = "Port" },
	{ id = "mirror_lake", name = "Mirror Lake", region = "greenfield", feet = 7800, spray = -32, radiusFeet = 600, kind = "Lake" },
	{ id = "red_barn_farm", name = "Red Barn Farm", region = "greenfield", feet = 7400, spray = 18, radiusFeet = 250, kind = "Farm" },
	{ id = "windmill_ridge", name = "Windmill Ridge", region = "greenfield", feet = 8500, spray = 40, radiusFeet = 400, kind = "Windmills" },
	{ id = "slugger_monument", name = "Slugger Monument", region = "landmark_coast", feet = 9800, spray = 0, radiusFeet = 120, kind = "Monument" },
	{ id = "lucky_pier", name = "Lucky Pier Fun Park", region = "landmark_coast", feet = 10600, spray = 22, radiusFeet = 400, kind = "FunPark" },
	{ id = "grand_span_bridge", name = "Grand Span Bridge", region = "landmark_coast", feet = 11800, spray = -6, radiusFeet = 300, kind = "Bridge" },
	{ id = "star_ridge_observatory", name = "Star Ridge Observatory", region = "landmark_coast", feet = 12300, spray = -32, radiusFeet = 200, kind = "Observatory" },
	{ id = "red_rock_canyon", name = "Red Rock Canyon", region = "timberline", feet = 14800, spray = -26, radiusFeet = 800, kind = "Canyon" },
	{ id = "silver_falls", name = "Silver Falls", region = "timberline", feet = 15600, spray = 14, radiusFeet = 300, kind = "Waterfall" },
	{ id = "timberline_peak", name = "Timberline Peak", region = "timberline", feet = 17000, spray = 2, radiusFeet = 900, kind = "Peak" },
	{ id = "titan_arch", name = "Titan Arch", region = "titan_peaks", feet = 19500, spray = -20, radiusFeet = 500, kind = "Arch" },
	{ id = "golden_diamond", name = "The Golden Diamond", region = "titan_peaks", feet = 20500, spray = 0, radiusFeet = 600, kind = "GoldenDiamond" },
} :: { Landmark }

function RegionMap.feetToStuds(feet: number): number
	return feet * METERS_PER_FOOT / PitchConfig.Units.MetersPerStud
end

function RegionMap.studsToFeet(studs: number): number
	return studs * PitchConfig.Units.MetersPerStud / METERS_PER_FOOT
end

function RegionMap.region(id: string): Region?
	for _, r in RegionMap.Regions do
		if r.id == id then
			return r
		end
	end
	return nil
end

function RegionMap.landmark(id: string): Landmark?
	for _, l in RegionMap.Landmarks do
		if l.id == id then
			return l
		end
	end
	return nil
end

function RegionMap.regionForFeet(feet: number): Region
	local list = RegionMap.Regions
	if feet ~= feet or feet < 0 then
		return list[1]
	end
	for _, r in list do
		if feet < r.maxFeet then
			return r
		end
	end
	return list[#list]
end

-- Plate-local position of a polar point: (forward feet, right feet).
local function polarFeet(feet: number, spray: number): (number, number)
	local a = math.rad(spray)
	return feet * math.cos(a), feet * math.sin(a)
end

-- Landmark position in plate-local studs (u = right, v = forward).
function RegionMap.landmarkStuds(l: Landmark): (number, number)
	local forward, right = polarFeet(l.feet, l.spray)
	return RegionMap.feetToStuds(right), RegionMap.feetToStuds(forward)
end

export type Classification = {
	region: Region,
	landmark: Landmark?,
	distanceFeet: number,
	sprayDegrees: number,
}

function RegionMap.classify(distanceFeet: number, sprayDegrees: number): Classification
	local region = RegionMap.regionForFeet(distanceFeet)
	local fx, fz = polarFeet(distanceFeet, sprayDegrees)
	local best: Landmark? = nil
	local bestDistance = math.huge
	for _, l in RegionMap.Landmarks do
		local lx, lz = polarFeet(l.feet, l.spray)
		local d = math.sqrt((fx - lx) ^ 2 + (fz - lz) ^ 2)
		if d <= l.radiusFeet and d < bestDistance then
			best, bestDistance = l, d
		end
	end
	return { region = region, landmark = best, distanceFeet = distanceFeet, sprayDegrees = sprayDegrees }
end

-- From authoritative field metres (LandingDetector impact x = forward, z = right).
function RegionMap.fromField(xMeters: number, zMeters: number): Classification
	local feet = math.sqrt(xMeters * xMeters + zMeters * zMeters) / METERS_PER_FOOT
	local spray = if xMeters * xMeters + zMeters * zMeters < 1e-9 then 0 else math.deg(math.atan2(zMeters, xMeters))
	return RegionMap.classify(feet, spray)
end

return RegionMap
