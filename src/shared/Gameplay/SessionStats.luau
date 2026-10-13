--!strict
-- Pure server reducer. Hit registration is ordered by server-wide unique ID;
-- only registered pending hits can resolve. Terminal hits cannot award twice.
local LandingDetector = require(script.Parent.Parent.BattedBall.LandingDetector)
local Config = require(script.Parent.GameplayConfig)
local Rules = require(script.Parent.RecordRules)
local Stats = {}

export type Snapshot = {
	version: number,
	pitches: number,
	swings: number,
	contacts: number,
	misses: number,
	fairHits: number,
	measuredFairHits: number,
	totalDistanceMeters: number,
	averageDistanceMeters: number,
	longestMeters: number,
	over200: number,
	over300: number,
	over400: number,
	highestExitMph: number,
	contactPercent: number,
	nextMilestoneFeet: number?,
	milestoneProgress: number,
	award: Rules.Award?,
	lastResult: {
		hitId: number,
		kind: LandingDetector.OutcomeKind,
		territory: "Fair" | "Foul",
		eligible: boolean,
		distanceMeters: number?,
	}?,
}
export type State = {
	value: Snapshot,
	pitchIds: { [string]: number },
	lastSwing: number,
	lastHit: number,
	pending: { [number]: boolean },
	reached: { [number]: boolean },
}

function Stats.new(): State
	return {
		value = {
			version = 0,
			pitches = 0,
			swings = 0,
			contacts = 0,
			misses = 0,
			fairHits = 0,
			measuredFairHits = 0,
			totalDistanceMeters = 0,
			averageDistanceMeters = 0,
			longestMeters = 0,
			over200 = 0,
			over300 = 0,
			over400 = 0,
			highestExitMph = 0,
			contactPercent = 0,
			nextMilestoneFeet = Config.Records.MilestonesFeet[1],
			milestoneProgress = 0,
		},
		pitchIds = {},
		lastSwing = 0,
		lastHit = 0,
		pending = {},
		reached = {},
	}
end

local function changed(state: State)
	local v = state.value
	v.version += 1
	v.contactPercent = if v.swings > 0 then 100 * v.contacts / v.swings else 0
	v.averageDistanceMeters = if v.measuredFairHits > 0 then v.totalDistanceMeters / v.measuredFairHits else 0
	v.nextMilestoneFeet = nil
	v.milestoneProgress = 1
	for _, feet in Config.Records.MilestonesFeet do
		if not state.reached[feet] then
			v.nextMilestoneFeet = feet
			v.milestoneProgress = math.clamp(v.longestMeters / (feet * 0.3048), 0, 1)
			break
		end
	end
end

function Stats.restoreRecords(state: State, best: number, milestones: { [string]: boolean })
	state.value.longestMeters = best
	for _, feet in Config.Records.MilestonesFeet do
		if milestones[tostring(feet)] then
			state.reached[feet] = true
		end
	end
	changed(state)
end

function Stats.pitch(state: State, laneId: string, pitchId: number): boolean
	if pitchId <= (state.pitchIds[laneId] or 0) then
		return false
	end
	state.pitchIds[laneId] = pitchId
	state.value.pitches += 1
	changed(state)
	return true
end

-- All accepted swings, including practice; only a swing against a pitch can miss.
function Stats.swing(state: State, seq: number, pitchAssociated: boolean, contact: boolean): boolean
	if seq <= state.lastSwing then
		return false
	end
	state.lastSwing = seq
	state.value.swings += 1
	if pitchAssociated and not contact then
		state.value.misses += 1
	end
	changed(state)
	return true
end

function Stats.contact(state: State, hitId: number, exitMph: number): boolean
	if hitId <= state.lastHit then
		return false
	end
	state.lastHit = hitId
	state.pending[hitId] = true
	state.value.contacts += 1
	if Rules.finite(exitMph) and exitMph >= 0 then
		state.value.highestExitMph = math.max(state.value.highestExitMph, exitMph)
	end
	changed(state)
	return true
end

function Stats.resolve(state: State, hitId: number, outcome: LandingDetector.OutcomePayload): boolean
	if not state.pending[hitId] then
		return false
	end
	state.pending[hitId] = nil
	local v = state.value
	local eligible = Rules.eligible(outcome)
	-- A measured fair first impact counts as a resolved fair hit even if it is
	-- a wall/ceiling or a provisional infield landing. Carry eligibility is stricter.
	if outcome.territory == "Fair" and (outcome.kind == "Landed" or outcome.kind == "Obstacle") then
		v.fairHits += 1
	end
	v.award = nil
	v.lastResult = {
		hitId = hitId,
		kind = outcome.kind,
		territory = outcome.territory,
		eligible = eligible,
		distanceMeters = if eligible then outcome.carryMeters else nil,
	}
	if eligible then
		local meters = outcome.carryMeters :: number
		v.measuredFairHits += 1
		v.totalDistanceMeters += meters
		for _, threshold in { 200, 300, 400 } do
			if meters > threshold * 0.3048 then
				local key = if threshold == 200 then "over200" elseif threshold == 300 then "over300" else "over400"
				(v :: any)[key] += 1
			end
		end
		local award = Rules.award(hitId, meters, v.longestMeters, state.reached)
		if award.newRecord then
			v.longestMeters = meters
		end
		if award.newRecord or #award.milestonesFeet > 0 then
			v.award = award
		end
	end
	changed(state)
	return true
end

function Stats.cancel(state: State, hitId: number): boolean
	if not state.pending[hitId] then
		return false
	end
	state.pending[hitId] = nil
	changed(state)
	return true
end

function Stats.snapshot(state: State): Snapshot
	local result = table.clone(state.value)
	if result.award then
		result.award = table.clone(result.award)
		result.award.milestonesFeet = table.clone(result.award.milestonesFeet)
	end
	if result.lastResult then
		result.lastResult = table.clone(result.lastResult)
	end
	return result
end

return Stats
