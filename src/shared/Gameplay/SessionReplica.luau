--!strict
-- Ignore stale initialization snapshots and duplicate/out-of-order updates.
local Net = require(script.Parent.GameplayNet)
local Replica = {}
export type State = { version: number, value: Net.Snapshot?, celebratedHit: number }
function Replica.new(): State
	return { version = -1, value = nil, celebratedHit = 0 }
end
function Replica.apply(state: State, snapshot: Net.Snapshot): boolean
	if snapshot.version <= state.version then
		return false
	end
	state.version, state.value = snapshot.version, snapshot
	return true
end
function Replica.celebration(state: State): number?
	local value = state.value
	local award = value and value.stats.award
	if not award or award.hitId <= state.celebratedHit then
		return nil
	end
	state.celebratedHit = award.hitId
	return award.hitId
end
return Replica
