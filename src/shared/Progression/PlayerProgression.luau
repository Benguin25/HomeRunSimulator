--!strict
-- Pure, non-yielding server transactions. Data is separate from Stage 5B stats.
local Config = require(script.Parent.ProgressionConfig)
local Rules = require(script.Parent.ProgressionRules)
local Landing = require(script.Parent.Parent.BattedBall.LandingDetector)
local Worlds = require(script.Parent.Parent.Worlds.WorldRules)
local Schema = require(script.Parent.PlayerData)
local Gameplay = require(script.Parent.Parent.Gameplay.GameplayConfig)
local Progression = {}
export type Award = { hitId: number, coins: number, reason: string }
export type Snapshot = {
	rebirths: number,
	permanentMultiplier: number,
	nextRebirthMultiplier: number?,
	rebirthRequirement: number?,
	bestMeters: number,
	lifetime: Schema.Lifetime,
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
	rebirths: number,
	milestones: { [string]: boolean },
	lifetime: Schema.Lifetime,
	lastRebirthSequence: number,
	lastRebirthAt: number,
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
		rebirths = 0,
		milestones = {},
		lifetime = Schema.defaults().lifetime,
		lastRebirthSequence = 0,
		lastRebirthAt = -math.huge,
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
		rebirths = state.rebirths,
		permanentMultiplier = Rules.permanentMultiplier(state.rebirths),
		rebirthRequirement = Rules.rebirthRequirement(state.rebirths),
		nextRebirthMultiplier = if state.rebirths < Config.Rebirth.MaxRebirths
			then Rules.permanentMultiplier(state.rebirths + 1)
			else nil,
		bestMeters = state.worlds.qualifyingBestMeters,
		lifetime = table.clone(state.lifetime),
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
		multiplier = Rules.multiplier(state.powerLevel, state.rebirths),
		nextMultiplier = if state.powerLevel < Config.Power.MaxLevel
			then Rules.multiplier(state.powerLevel + 1, state.rebirths)
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
	if reason == "Fair carry" then
		local meters = outcome.carryMeters :: number
		state.lifetime.fairHits = math.min(Config.Limits.MaxCoins, state.lifetime.fairHits + 1)
		state.lifetime.totalDistanceMeters =
			math.min(Config.Limits.MaxCoins, state.lifetime.totalDistanceMeters + meters)
		for _, feet in Gameplay.Records.MilestonesFeet do
			if meters >= feet * 0.3048 then
				state.milestones[tostring(feet)] = true
			end
		end
		for _, feet in { 200, 300, 400 } do
			if meters > feet * 0.3048 then
				local key = `over{feet}`
				(state.lifetime :: any)[key] = math.min(Config.Limits.MaxCoins, (state.lifetime :: any)[key] + 1)
			end
		end
	end
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
	now: number,
	expectedRebirths: any?
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
	if expectedRebirths ~= nil and expectedRebirths ~= state.rebirths then
		return reject("StaleProgression")
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
function Progression.rebirth(
	state: State,
	sequence: any,
	expectedRebirths: any,
	expectedVersion: any,
	now: number
): PurchaseResult
	local function reject(reason: string): PurchaseResult
		return { ok = false, reason = reason }
	end
	if
		not Rules.finite(now)
		or not Rules.finite(sequence)
		or sequence % 1 ~= 0
		or sequence <= 0
		or sequence > Config.Limits.MaxSequence
	then
		return reject("InvalidRequest")
	end
	if sequence <= state.lastRebirthSequence then
		return reject("DuplicateRequest")
	end
	state.lastRebirthSequence = sequence
	local elapsed = now - state.lastRebirthAt
	state.lastRebirthAt = now
	if elapsed < Config.Rebirth.RequestGapSeconds then
		return reject("RateLimited")
	end
	if not Rules.rebirthCount(state.rebirths) or not Rules.level(state.powerLevel) then
		return reject("InvalidState")
	end
	if expectedRebirths ~= state.rebirths or expectedVersion ~= state.version then
		return reject("StaleProgression")
	end
	-- Prevent a delayed purchase with the same pre-reset level from spending a
	-- later cycle's coins; purchases also carry the progression epoch below.
	if next(state.pending) ~= nil then
		return reject("FinishHitFirst")
	end
	local required = Rules.rebirthRequirement(state.rebirths)
	if not required then
		return reject("MaxRebirths")
	end
	if state.powerLevel < required then
		return reject("InsufficientPower")
	end
	state.coins, state.powerLevel = 0, 0
	state.rebirths += 1
	state.version += 1
	return { ok = true, reason = "Reborn" }
end
function Progression.export(state: State): Schema.Data
	return {
		schemaVersion = Schema.Version,
		coins = state.coins,
		earnedCoins = state.earnedCoins,
		powerLevel = state.powerLevel,
		rebirths = state.rebirths,
		unlockedWorlds = table.clone(state.worlds.unlockedWorlds),
		selectedWorld = state.worlds.currentWorld,
		bestMeters = state.worlds.qualifyingBestMeters,
		milestones = table.clone(state.milestones),
		lifetime = table.clone(state.lifetime),
	}
end
function Progression.restore(data: Schema.Data): State
	local state = Progression.new()
	state.coins, state.earnedCoins, state.powerLevel, state.rebirths =
		data.coins, data.earnedCoins, data.powerLevel, data.rebirths
	state.worlds.currentWorld, state.worlds.unlockedWorlds, state.worlds.qualifyingBestMeters =
		data.selectedWorld, table.clone(data.unlockedWorlds), data.bestMeters
	state.milestones, state.lifetime = table.clone(data.milestones), table.clone(data.lifetime)
	return state
end
return Progression
