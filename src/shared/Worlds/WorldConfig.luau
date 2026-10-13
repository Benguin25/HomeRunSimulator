--!strict
-- Stable IDs and source-owned layout. Origins are studs; distances are feet/meters.
local Config = {}
export type Definition = {
	id: string,
	name: string,
	requiredFeet: number,
	origin: Vector3,
	yawDegrees: number,
	lanes: number,
	theme: string,
	accent: { number },
	description: string,
}
Config.DefaultId = "rookie"
Config.GeneratedFolder = "GeneratedWorlds"
Config.GenerationVersion = 1
Config.TravelGapSeconds = 1.5
Config.TileStuds = 1024
Config.LaneSpacingStuds = 2200
Config.GroundWidthStuds = 12500
Config.GroundForwardStuds = 6500
Config.GroundBackStuds = 450
Config.Environment = {
	power = {
		ClockTime = 18.5,
		Brightness = 2.5,
		Ambient = { 120, 135, 160 },
		OutdoorAmbient = { 155, 170, 200 },
		FogStart = 12000,
		FogEnd = 30000,
		FogColor = { 110, 130, 170 },
		AtmosphereDensity = 0.10,
		Tint = { 255, 255, 255 },
		Contrast = 0.08,
		Saturation = 0.08,
	},
	sky = {
		ClockTime = 14,
		Brightness = 2.8,
		Ambient = { 135, 148, 178 },
		OutdoorAmbient = { 178, 205, 225 },
		FogStart = 12000,
		FogEnd = 30000,
		FogColor = { 189, 223, 255 },
		AtmosphereDensity = 0.075,
		Tint = { 229, 247, 255 },
		Contrast = 0,
		Saturation = 0.1,
	},
}
-- Stage 2: the flat Rookie catchment now spans the visible world (about 20,000 ft
-- forward, +/-16,000 studs wide, 9,000 studs behind the park) so high-Power
-- hits at Rookie land on measured ground instead of resolving NoImpact, and no
-- visible street lacks ground. Same height (0.5 below plate level), same flat
-- surface and collision rules; client scenery is never added to it.
Config.Rookie = {
	CatchmentEnabled = true,
	ForwardStuds = 22000,
	WidthStuds = 32000,
	BackStuds = 9000,
	DropStuds = 0.5,
	TileStuds = 2000,
}
Config.Worlds = {
	{
		id = "rookie",
		name = "Rookie Park",
		requiredFeet = 0,
		origin = Vector3.zero,
		yawDegrees = 0,
		lanes = 0,
		theme = "rookie",
		accent = { 92, 193, 120 },
		description = "Your home field. Build your swing.",
	},
	{
		id = "power",
		name = "Power Arena",
		requiredFeet = 475,
		origin = Vector3.new(16000, 300, 0),
		yawDegrees = 18,
		lanes = 4,
		theme = "power",
		accent = { 255, 177, 55 },
		description = "Floodlights. Big stands. Bigger hits.",
	},
	{
		id = "sky",
		name = "Sky Stadium",
		requiredFeet = 1750,
		origin = Vector3.new(-16000, 900, 0),
		yawDegrees = -22,
		lanes = 4,
		theme = "sky",
		accent = { 111, 224, 255 },
		description = "Above the clouds. Chase the horizon.",
	},
} :: { Definition }
function Config.get(id: string): Definition?
	for _, world in Config.Worlds do
		if world.id == id then
			return world
		end
	end
	return nil
end
function Config.frame(world: Definition): CFrame
	return CFrame.new(world.origin) * CFrame.Angles(0, math.rad(world.yawDegrees), 0)
end
function Config.laneId(worldId: string, index: number): string
	return `{worldId}/Lane{index}`
end
return Config
