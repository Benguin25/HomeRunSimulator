--!strict
-- Pure, non-yielding server transactions. Data is separate from Stage 5B stats.
local Config = require(script.Parent.ProgressionConfig)
local Rules = require(script.Parent.ProgressionRules)
local Landing = require(script.Parent.Parent.BattedBall.LandingDetector)
local Worlds = require(script.Parent.Parent.Worlds.WorldRules)
local Progression = {}
export type Award = { hitId: number, coins: number, reason: string }
export type Snapshot = {
	worlds: Worlds.State,
	worldUnlock: { hitId: number, ids: { string } }?,
	schemaVersion: number,
	version: number,
	coins: number,
	earnedCoins: number,
	powerLevel: number,
	multiplier: number,
	nextMultiplier: number?,
	nextCost: number?,
	award: Award?,
}
export type State = {
	worlds: Worlds.State,
	worldUnlock: { hitId: number, ids: { string } }?,
	coins: number,
	earnedCoins: number,
	powerLevel: number,
	version: number,
	lastHit: number,
	pending: { [number]: boolean },
	lastSequence: number,
	lastPurchase: number,
	award: Award?,
}
export type PurchaseResult = { ok: boolean, reason: string }
function Progression.new(): State
	return {
		worlds = Worlds.new(),
		coins = 0,
		earnedCoins = 0,
		powerLevel = 0,
		version = 0,
		lastHit = 0,
		pending = {},
		lastSequence = 0,
		lastPurchase = -math.huge,
		award = nil,
	}
end
function Progression.snapshot(state: State): Snapshot
	return {
		worlds = {
			currentWorld = state.worlds.currentWorld,
			unlockedWorlds = table.clone(state.worlds.unlockedWorlds),
			qualifyingBestMeters = state.worlds.qualifyingBestMeters,
			lastTravelSequence = state.worlds.lastTravelSequence,
			lastTravelAt = state.worlds.lastTravelAt,
		},
		worldUnlock = if state.worldUnlock
			then { hitId = state.worldUnlock.hitId, ids = table.clone(state.worldUnlock.ids) }
			else nil,
		schemaVersion = Config.SchemaVersion,
		version = state.version,
		coins = state.coins,
		earnedCoins = state.earnedCoins,
		powerLevel = state.powerLevel,
		multiplier = Rules.multiplier(state.powerLevel),
		nextMultiplier = if state.powerLevel < Config.Power.MaxLevel
			then Rules.multiplier(state.powerLevel + 1)
			else nil,
		nextCost = Rules.cost(state.powerLevel),
		award = if state.award then table.clone(state.award) else nil,
	}
end
function Progression.launch(state: State, hitId: number): boolean
	if not Rules.finite(hitId) or hitId % 1 ~= 0 or hitId <= state.lastHit then
		return false
	end
	state.lastHit = hitId
	state.pending[hitId] = true
	return true
end
function Progression.cancel(state: State, hitId: number)
	state.pending[hitId] = nil
end
function Progression.resolve(state: State, hitId: number, outcome: Landing.OutcomePayload): boolean
	if not state.pending[hitId] then
		return false
	end
	state.pending[hitId] = nil -- terminal even for invalid/unresolved outcomes
	local amount, reason = Rules.reward(outcome)
	amount = math.min(amount, Config.Limits.MaxCoins - state.coins, Config.Limits.MaxCoins - state.earnedCoins)
	state.coins += amount
	state.earnedCoins += amount
	state.award = { hitId = hitId, coins = amount, reason = reason }
	local unlocked = Worlds.resolve(state.worlds, outcome)
	if #unlocked > 0 then
		state.worldUnlock = { hitId = hitId, ids = unlocked }
	end
	state.version += 1
	return true
end
function Progression.travel(
	state: State,
	target: any,
	sequence: any,
	expectedWorld: any,
	now: number,
	context: Worlds.Context
): Worlds.Result
	local result = Worlds.travel(state.worlds, target, sequence, expectedWorld, now, context)
	if result.ok then
		state.version += 1
	end
	return result
end
function Progression.purchase(
	state: State,
	category: any,
	sequence: any,
	expectedLevel: any,
	now: number
): PurchaseResult
	local function reject(reason: string): PurchaseResult
		return { ok = false, reason = reason }
	end
	if not Rules.finite(now) then
		return reject("InvalidTime")
	end
	if not Rules.finite(sequence) or sequence % 1 ~= 0 or sequence <= 0 or sequence > Config.Limits.MaxSequence then
		return reject("InvalidRequest")
	end
	if sequence <= state.lastSequence then
		return reject("DuplicateRequest")
	end
	state.lastSequence = sequence -- rejected intent cannot be replayed later
	local elapsed = now - state.lastPurchase
	state.lastPurchase = now
	if elapsed < Config.Limits.PurchaseGapSeconds then
		return reject("RateLimited")
	end
	if category ~= "Power" or not Rules.level(expectedLevel) then
		return reject("InvalidUpgrade")
	end
	if
		not Rules.level(state.powerLevel)
		or not Rules.finite(state.coins)
		or state.coins < 0
		or state.coins > Config.Limits.MaxCoins
		or state.coins % 1 ~= 0
	then
		return reject("InvalidState")
	end
	if expectedLevel ~= state.powerLevel then
		return reject("StaleLevel")
	end
	local cost = Rules.cost(state.powerLevel)
	if not cost then
		return reject("MaxLevel")
	end
	if state.coins < cost then
		return reject("InsufficientCoins")
	end
	state.coins -= cost
	state.powerLevel += 1
	state.version += 1
	return { ok = true, reason = "Purchased" }
end
return Progression
