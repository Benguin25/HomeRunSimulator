--!strict
-- Pure partitioning: preserve every spec, but bound spatial streaming subtrees.
local Config = require(script.Parent.EnvironmentConfig)
local Kit = require(script.Parent.EnvKit)
local Plan = require(script.Parent.EnvironmentPlan)
local RegionMap = require(script.Parent.RegionMap)
local Layout = {}

export type Group = { id: string, region: string, chunk: string, keep: boolean, parts: { Kit.Spec } }

function Layout.groups(plan: Plan.Plan): { Group }
	local result: { Group } = {}
	local current: { [string]: Group } = {}
	local serial: { [string]: number } = {}
	for _, chunk in plan.chunks do
		local town = string.sub(chunk.name, 1, 4) == "Town"
		local landscape = chunk.name == "LandGround"
			or chunk.name == "Water"
			or chunk.name == "Forests"
			or chunk.name == "Farms"
			or chunk.name == "Harbor"
			or chunk.name == "Mountains"
			or chunk.name == "Wilds"
			or chunk.name == "SluggerMonument"
			or chunk.name == "LuckyPier"
			or chunk.name == "GrandSpanBridge"
			or chunk.name == "Observatory"
		local corridor = chunk.name == "Boulevard" or chunk.name == "RiverBridges" or chunk.name == "Highway"
		for _, spec in chunk.parts do
			local delta = spec.cf.Position - plan.site.plate
			local distance = Vector3.new(delta.X, 0, delta.Z).Magnitude
			local region = if town
					or landscape
					or corridor
				then RegionMap.regionForFeet(RegionMap.studsToFeet(distance)).id
				else if chunk.name == "Field" or string.sub(chunk.name, 1, 4) == "Bowl"
					then "stadium"
					else "grounds"
			local x, z = math.floor(spec.cf.X / Config.Baked.CellStuds), math.floor(spec.cf.Z / Config.Baked.CellStuds)
			local key = `{region}/{chunk.name}/{x}_{z}`
			local group = current[key]
			if not group or #group.parts >= Config.Baked.BatchParts then
				serial[key] = (serial[key] or 0) + 1
				group = {
					id = `{x}_{z}_{serial[key]}`,
					region = region,
					chunk = chunk.name,
					keep = not town and not corridor,
					parts = {},
				}
				current[key] = group :: Group
				table.insert(result, group :: Group)
			end
			table.insert(group.parts, spec)
		end
	end
	return result
end

function Layout.isVerified(root: Instance?): boolean
	return root ~= nil
		and root:IsA("Folder")
		and root:GetAttribute("SourceOwner") == Config.Baked.Owner
		and root:GetAttribute("BakeVersion") == Config.Baked.Version
		and root:GetAttribute("Verified") == true
end

return Layout
