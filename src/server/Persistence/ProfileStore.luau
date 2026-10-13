--!strict
-- One UpdateAsync key contains both profile and lease. All transforms are
-- non-yielding and side-effect free; UpdateAsync may invoke them repeatedly.
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Data = require(Shared.Progression.PlayerProgression)
local Schema = require(Shared.Progression.PlayerData)
local Rules = require(Shared.Progression.ProgressionRules)
local Landing = require(Shared.BattedBall.LandingDetector)
local Config = require(script.Parent.PersistenceConfig)
local Store = {}
export type Adapter = { update: (string, (any) -> any) -> any, budget: () -> number }
export type Clock = { now: () -> number, wait: (number) -> (), random: () -> number }
export type Profile = {
	queued: { [number]: Landing.OutcomePayload },
	key: string,
	owner: string,
	state: Data.State?,
	status: string,
	busy: boolean,
	closing: boolean,
	expires: number,
	savedVersion: number,
	lastSave: number,
	retry: number,
	lastError: string,
	operation: number,
}
export type Manager = { adapter: Adapter, clock: Clock }
function Store.new(adapter: Adapter, clock: Clock): Manager
	return { adapter = adapter, clock = clock }
end
function Store.profile(key: string, owner: string): Profile
	return {
		queued = {},
		key = key,
		owner = owner,
		state = nil,
		status = "Loading",
		busy = false,
		closing = false,
		expires = 0,
		savedVersion = -1,
		lastSave = 0,
		retry = 0,
		lastError = "",
		operation = 0,
	}
end
function Store.writable(manager: Manager, profile: Profile): boolean
	return profile.state ~= nil
		and profile.status == "Ready"
		and not profile.closing
		and manager.clock.now() < profile.expires - Config.SafetySeconds
end
-- A finite retry/budget window shared by load/save/close. Transport calls can
-- outlast it (Roblox cannot cancel UpdateAsync); no new call starts past it.
local function request(manager: Manager, profile: Profile, transform: (any) -> any, deadline: number): (boolean, any)
	for attempt = 1, Config.MaxAttempts do
		profile.retry = attempt
		if manager.clock.now() >= deadline then
			break
		end
		while manager.adapter.budget() < 1 and manager.clock.now() < deadline do
			manager.clock.wait(math.min(0.25, deadline - manager.clock.now()))
		end
		if manager.clock.now() >= deadline then
			break
		end
		local ok, result = pcall(manager.adapter.update, profile.key, transform)
		if ok then
			profile.retry = 0
			return true, result
		end
		profile.lastError = "StorageUnavailable"
		if attempt < Config.MaxAttempts then
			local delay = math.min(Config.RetryMaxSeconds, Config.RetryBaseSeconds * 2 ^ (attempt - 1))
				* (0.75 + manager.clock.random() * 0.5)
			manager.clock.wait(math.min(delay, math.max(0, deadline - manager.clock.now())))
		end
	end
	return false, nil
end
local function validLock(lock: any): boolean
	return typeof(lock) == "table" and typeof(lock.owner) == "string" and Rules.finite(lock.expires)
end
function Store.load(manager: Manager, profile: Profile): boolean
	if profile.busy or profile.state or profile.status ~= "Loading" then
		return false
	end
	profile.busy = true
	local rejection = "Locked"
	local ok, record = request(manager, profile, function(raw: any): any
		local now = manager.clock.now()
		if raw ~= nil and typeof(raw) ~= "table" then
			rejection = "MalformedData"
			return nil
		end
		local envelope = raw and raw.format ~= nil
		if raw and not envelope and (raw.data ~= nil or raw.lock ~= nil or raw.operation ~= nil) then
			rejection = "MalformedEnvelope"
			return nil
		end
		if envelope and raw.format ~= 1 then
			rejection = "FutureEnvelope"
			return nil
		end
		local lock = if envelope then raw.lock else nil
		if lock ~= nil and not validLock(lock) then
			rejection = "MalformedLock"
			return nil
		end
		if lock and lock.owner ~= profile.owner and lock.expires > now then
			rejection = "Locked"
			return nil
		end
		local data, reason = Schema.decode(if envelope then raw.data else raw)
		if not data then
			rejection = reason
			return nil
		end
		-- An envelope with absent data is corruption, never a new-player default.
		if envelope and raw.data == nil then
			rejection = "MalformedData"
			return nil
		end
		return {
			format = 1,
			data = data,
			lock = { owner = profile.owner, expires = now + Config.LeaseSeconds },
			operation = if envelope then raw.operation else nil,
		}
	end, manager.clock.now() + Config.LoadTimeoutSeconds)
	profile.busy = false
	if not ok or not record or not validLock(record.lock) or record.lock.owner ~= profile.owner then
		profile.status, profile.lastError = "LoadFailed", if ok then rejection else "StorageUnavailable"
		return false
	end
	if record.lock.expires <= manager.clock.now() + Config.SafetySeconds then
		profile.status, profile.lastError = "LoadFailed", "LeaseExpired"
		return false
	end
	profile.state = Data.restore(record.data)
	profile.expires, profile.savedVersion, profile.lastSave = record.lock.expires, 0, manager.clock.now()
	profile.status, profile.lastError = "Ready", ""
	return true
end
function Store.save(manager: Manager, profile: Profile, release: boolean?, deadline: number?): boolean
	local state = profile.state
	if profile.busy or not state or profile.status == "Lost" or profile.status == "Closed" then
		return false
	end
	profile.busy = true
	profile.operation += 1
	local operation = `{profile.owner}:{profile.operation}`
	local version, data = state.version, Data.export(state)
	local lost = false
	local ok, record = request(manager, profile, function(raw: any): any
		local now = manager.clock.now()
		-- Idempotent acknowledgement after a write committed but its response was
		-- lost. Never overwrite a later owner, even for a release retry.
		if
			typeof(raw) == "table"
			and raw.operation == operation
			and (
				(release and raw.lock == nil)
				or (validLock(raw.lock) and raw.lock.owner == profile.owner and raw.lock.expires > now)
			)
		then
			return raw
		end
		if
			typeof(raw) ~= "table"
			or raw.format ~= 1
			or not validLock(raw.lock)
			or raw.lock.owner ~= profile.owner
			or raw.lock.expires <= now
		then
			lost = true
			return nil
		end
		return {
			format = 1,
			data = data,
			operation = operation,
			lock = if release then nil else { owner = profile.owner, expires = now + Config.LeaseSeconds },
		}
	end, deadline or (manager.clock.now() + Config.SaveTimeoutSeconds))
	profile.busy = false
	if ok and record and record.operation == operation then
		-- A successful commit can have a very late acknowledgement. Do not
		-- resume mutations or flush queued results on an already expired lease.
		if not release and record.lock.expires <= manager.clock.now() + Config.SafetySeconds then
			profile.expires = record.lock.expires
			profile.status = if profile.expires <= manager.clock.now() then "Lost" else "SaveDelayed"
			profile.lastError = "LeaseExpired"
			return false
		end
		profile.savedVersion, profile.lastSave, profile.retry = version, manager.clock.now(), 0
		profile.expires = if record.lock then record.lock.expires else 0
		profile.status, profile.lastError = if release then "Closed" else "Ready", ""
		if not release then
			for hitId, outcome in profile.queued do
				Data.resolve(state, hitId, outcome)
			end
			table.clear(profile.queued)
		end
		return true
	end
	profile.status = if lost or manager.clock.now() >= profile.expires then "Lost" else "SaveDelayed"
	profile.lastError = if lost then "OwnershipLost" else "StorageUnavailable"
	return false
end
function Store.close(manager: Manager, profile: Profile, deadline: number): boolean
	profile.closing = true -- immediately block mutations, including during a running save
	while profile.busy and manager.clock.now() < deadline do
		manager.clock.wait(0.05)
	end
	-- Confirm ownership, apply any authoritative results held during a temporary
	-- outage, then release with the latest state. Never throw away resolved hits.
	if next(profile.queued) ~= nil and not Store.save(manager, profile, false, deadline) then
		return false
	end
	return Store.save(manager, profile, true, deadline)
end
function Store.resolve(manager: Manager, profile: Profile, hitId: number, outcome: Landing.OutcomePayload): boolean
	local state = profile.state
	if not state or not state.pending[hitId] or profile.closing or profile.status == "Lost" then
		return false
	end
	if Store.writable(manager, profile) then
		return Data.resolve(state, hitId, outcome)
	end
	if profile.queued[hitId] then
		return false
	end
	profile.queued[hitId] = outcome
	return true
end
-- Exactly one non-yielding mutation pathway. A reducer may update runtime
-- deduplication even when rejecting intent; durable revisions only advance on success.
function Store.mutate(manager: Manager, profile: Profile, reducer: (Data.State) -> any): (boolean, any)
	if not Store.writable(manager, profile) then
		return false, nil
	end
	return true, reducer(profile.state :: Data.State)
end
return Store
