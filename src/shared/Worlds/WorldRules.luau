--!strict
local Config = require(script.Parent.WorldConfig)
local Records = require(script.Parent.Parent.Gameplay.RecordRules)
local Economy = require(script.Parent.Parent.Progression.ProgressionRules)
local ProgressionConfig = require(script.Parent.Parent.Progression.ProgressionConfig)
local Landing = require(script.Parent.Parent.BattedBall.LandingDetector)
local Rules = {}
export type State = {
	currentWorld: string,
	unlockedWorlds: { [string]: boolean },
	qualifyingBestMeters: number,
	lastTravelSequence: number,
	lastTravelAt: number,
}
export type Context = { characterReady: boolean, hitBusy: boolean, returnReady: boolean, laneAvailable: boolean }
export type Result = { ok: boolean, reason: string }
function Rules.new(): State
	return {
		currentWorld = Config.DefaultId,
		unlockedWorlds = { [Config.DefaultId] = true },
		qualifyingBestMeters = 0,
		lastTravelSequence = 0,
		lastTravelAt = -math.huge,
	}
end
function Rules.resolve(state: State, outcome: Landing.OutcomePayload): { string }
	local unlocked = {}
	local _, reason = Economy.reward(outcome)
	if not Records.eligible(outcome) or reason ~= "Fair carry" then
		return unlocked
	end
	state.qualifyingBestMeters = math.max(state.qualifyingBestMeters, outcome.carryMeters :: number)
	-- Ascending requirements give a single exceptional hit all preceding worlds.
	for _, world in Config.Worlds do
		if state.qualifyingBestMeters >= world.requiredFeet * 0.3048 and not state.unlockedWorlds[world.id] then
			state.unlockedWorlds[world.id] = true
			table.insert(unlocked, world.id)
		end
	end
	return unlocked
end
function Rules.travel(
	state: State,
	target: any,
	sequence: any,
	expectedWorld: any,
	now: number,
	context: Context
): Result
	local function reject(reason: string): Result
		return { ok = false, reason = reason }
	end
	if
		not Economy.finite(now)
		or not Economy.finite(sequence)
		or sequence % 1 ~= 0
		or sequence <= 0
		or sequence > ProgressionConfig.Limits.MaxSequence
	then
		return reject("InvalidRequest")
	end
	if sequence <= state.lastTravelSequence then
		return reject("DuplicateRequest")
	end
	state.lastTravelSequence = sequence
	local elapsed = now - state.lastTravelAt
	state.lastTravelAt = now
	if elapsed < Config.TravelGapSeconds then
		return reject("RateLimited")
	end
	if typeof(target) ~= "string" or not Config.get(target) then
		return reject("UnknownWorld")
	end
	if not state.unlockedWorlds[target] then
		return reject("LockedWorld")
	end
	if expectedWorld ~= state.currentWorld then
		return reject("StaleWorld")
	end
	if target == state.currentWorld then
		return reject("AlreadyHere")
	end
	if not context.characterReady then
		return reject("CharacterNotReady")
	end
	if context.hitBusy or not context.returnReady then
		return reject("FinishHitFirst")
	end
	if not context.laneAvailable then
		return reject("WorldFull")
	end
	state.currentWorld = target
	return { ok = true, reason = "Traveled" }
end
return Rules
