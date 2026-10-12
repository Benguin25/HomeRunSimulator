--!strict
local Data = require(script.Parent.PlayerProgression)
local Config = require(script.Parent.ProgressionConfig)
local Replica = {}
export type State = { value: Data.Snapshot?, version: number, awardedHit: number }
function Replica.new(): State
	return { value = nil, version = -1, awardedHit = 0 }
end
function Replica.apply(state: State, value: Data.Snapshot): boolean
	if value.schemaVersion ~= Config.SchemaVersion or value.version <= state.version then
		return false
	end
	state.version, state.value = value.version, value
	return true
end
function Replica.award(state: State): Data.Award?
	local award = state.value and state.value.award
	if not award or award.hitId <= state.awardedHit then
		return nil
	end
	state.awardedHit = award.hitId
	return award
end
return Replica
