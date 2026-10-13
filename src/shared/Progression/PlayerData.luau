--!strict
-- Storage schema, deliberately excluding networking snapshots and runtime IDs.
local Config = require(script.Parent.ProgressionConfig)
local Rules = require(script.Parent.ProgressionRules)
local Worlds = require(script.Parent.Parent.Worlds.WorldConfig)
local Gameplay = require(script.Parent.Parent.Gameplay.GameplayConfig)
local Schema = {}
Schema.Version = 1
export type Lifetime = {
	fairHits: number,
	totalDistanceMeters: number,
	over200: number,
	over300: number,
	over400: number,
}
export type Data = {
	schemaVersion: number,
	coins: number,
	earnedCoins: number,
	powerLevel: number,
	rebirths: number,
	unlockedWorlds: { [string]: boolean },
	selectedWorld: string,
	bestMeters: number,
	milestones: { [string]: boolean },
	lifetime: Lifetime,
}
function Schema.number(value: any, max: number, integer: boolean?): number
	if not Rules.finite(value) then
		return 0
	end
	local n = math.clamp(value, 0, max)
	return if integer then math.floor(n) else n
end
function Schema.defaults(): Data
	return {
		schemaVersion = Schema.Version,
		coins = 0,
		earnedCoins = 0,
		powerLevel = 0,
		rebirths = 0,
		unlockedWorlds = { rookie = true },
		selectedWorld = "rookie",
		bestMeters = 0,
		milestones = {},
		lifetime = { fairHits = 0, totalDistanceMeters = 0, over200 = 0, over300 = 0, over400 = 0 },
	}
end
-- Version 0 (pre-release) used currentWorld/qualifyingBestMeters. Future versions
-- fail closed so an older server can never downgrade a newer player's data.
function Schema.decode(raw: any): (Data?, string)
	if raw == nil then
		return Schema.defaults(), "New"
	end
	if typeof(raw) ~= "table" then
		return nil, "MalformedData"
	end
	local version = raw.schemaVersion or 0
	if not Rules.finite(version) or version % 1 ~= 0 or version < 0 then
		return nil, "MalformedVersion"
	end
	if version > Schema.Version then
		return nil, "FutureSchema"
	end
	local data = Schema.defaults()
	data.coins = Schema.number(raw.coins, Config.Limits.MaxCoins, true)
	data.earnedCoins = math.max(data.coins, Schema.number(raw.earnedCoins, Config.Limits.MaxCoins, true))
	data.powerLevel = Schema.number(raw.powerLevel, Config.Power.MaxLevel, true)
	data.rebirths = Schema.number(raw.rebirths, Config.Rebirth.MaxRebirths, true)
	data.bestMeters = Schema.number(raw.bestMeters or raw.qualifyingBestMeters, Config.Limits.MaxDistanceMeters)
	local unlocked = if typeof(raw.unlockedWorlds) == "table" then raw.unlockedWorlds else {}
	for _, world in Worlds.Worlds do
		if unlocked[world.id] == true or data.bestMeters >= world.requiredFeet * 0.3048 then
			data.unlockedWorlds[world.id] = true
		end
	end
	local selected = raw.selectedWorld or raw.currentWorld
	if typeof(selected) == "string" and data.unlockedWorlds[selected] then
		data.selectedWorld = selected
	end
	local milestones = if typeof(raw.milestones) == "table" then raw.milestones else {}
	for _, feet in Gameplay.Records.MilestonesFeet do
		if milestones[tostring(feet)] == true or data.bestMeters >= feet * 0.3048 then
			data.milestones[tostring(feet)] = true
		end
	end
	local lifetime = if typeof(raw.lifetime) == "table" then raw.lifetime else {}
	data.lifetime.fairHits = Schema.number(lifetime.fairHits, Config.Limits.MaxCoins, true)
	data.lifetime.totalDistanceMeters = Schema.number(lifetime.totalDistanceMeters, Config.Limits.MaxCoins)
	for _, key in { "over200", "over300", "over400" } do
		(data.lifetime :: any)[key] =
			math.min(data.lifetime.fairHits, Schema.number(lifetime[key], Config.Limits.MaxCoins, true))
	end
	return data, if version < Schema.Version then "Migrated" else "Loaded"
end
return Schema
