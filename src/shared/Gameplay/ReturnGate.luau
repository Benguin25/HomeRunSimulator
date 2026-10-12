--!strict
-- Server pacing guard: a readiness claim is scoped to owner, lane assignment
-- epoch and hit, after resolution and a server-clock minimum return interval.
local Config = require(script.Parent.GameplayConfig)
local Gate = {}
export type Phase = "Preparing" | "Flying" | "Resolved" | "Returning" | "Ready"
export type State = {
	owner: number,
	epoch: number,
	hitId: number,
	pitchId: number,
	phase: Phase,
	characterReady: boolean,
	cameraReady: boolean,
	resolvedAt: number,
	notBefore: number,
	lastRequest: number,
	rejection: string,
	recoverySent: boolean,
}

function Gate.new(owner: number, epoch: number, now: number): State
	return {
		owner = owner,
		epoch = epoch,
		hitId = 0,
		pitchId = 0,
		phase = "Preparing",
		characterReady = false,
		cameraReady = false,
		resolvedAt = math.huge,
		notBefore = now,
		lastRequest = -math.huge,
		rejection = "",
		recoverySent = false,
	}
end

function Gate.begin(state: State, hitId: number, pitchId: number)
	state.hitId, state.pitchId = hitId, pitchId
	state.phase, state.cameraReady = "Flying", false
	state.resolvedAt, state.notBefore = math.huge, math.huge
	state.recoverySent = false
	state.rejection = ""
end

function Gate.resolve(state: State, hitId: number, now: number): boolean
	if state.hitId ~= hitId or state.phase ~= "Flying" then
		return false
	end
	state.phase, state.resolvedAt = "Resolved", now
	state.notBefore = now + Config.Pacing.ReturnSeconds
	return true
end

function Gate.character(state: State, ready: boolean, epoch: number)
	state.epoch = epoch
	state.characterReady, state.cameraReady = ready, false
	state.lastRequest = -math.huge
	if state.hitId == 0 then
		state.phase = "Preparing"
	end
end

function Gate.request(state: State, owner: number, epoch: any, hitId: any, kind: any, now: number): (boolean, string)
	local reason = ""
	if owner ~= state.owner then
		reason = "WrongOwner"
	elseif now - state.lastRequest < Config.Pacing.RequestMinGapSeconds then
		reason = "RateLimited"
	elseif epoch ~= state.epoch then
		reason = "StaleAssignment"
	elseif hitId ~= state.hitId then
		reason = "WrongHit"
	elseif kind ~= "Ready" and kind ~= "Skip" then
		reason = "Malformed"
	elseif not state.characterReady then
		reason = "CharacterNotReady"
	elseif state.phase == "Flying" then
		reason = "NotResolved"
	elseif kind == "Skip" and state.phase ~= "Resolved" then
		reason = "NotSkippable"
	elseif kind == "Ready" and now < state.notBefore then
		reason = "ReturnTooSoon"
	elseif kind == "Ready" and state.cameraReady then
		reason = "AlreadyReady"
	end
	state.lastRequest = now
	state.rejection = reason
	if reason ~= "" then
		return false, reason
	end
	if kind == "Skip" then
		state.phase = "Returning"
		state.notBefore = now + Config.Pacing.ReturnSeconds
	else
		state.phase, state.cameraReady = "Ready", true
	end
	return true, ""
end

function Gate.recover(state: State, now: number): boolean
	if
		(state.phase ~= "Resolved" and state.phase ~= "Returning")
		or state.recoverySent
		or not state.characterReady
		or now < state.resolvedAt + Config.Pacing.RecoveryAfterSeconds
	then
		return false
	end
	state.phase, state.recoverySent = "Returning", true
	state.notBefore = now + Config.Pacing.ReturnSeconds
	return true
end

function Gate.canPitch(state: State): boolean
	return state.characterReady and state.cameraReady and state.phase == "Ready"
end

return Gate
