--!strict
-- Server-side validation of swing requests (pure, so it is unit-testable).
--
-- The client sends only intent: a sequence number, the click time on the
-- synchronized server clock (Workspace:GetServerTimeNow()), and the aim. It
-- never sends ball positions, contact, or quality.
--
-- Timestamp policy (bounded latency compensation):
--   * A click stamped in the future (beyond clock-noise tolerance) is rejected.
--   * A click may be rewound at most min(MaxRewind, ping * factor + slack)
--     before the receive time. Older stamps are clamped forward to that limit
--     (the swing still happens, just later), and stamps older than
--     StaleRejectSeconds are rejected. A cheater therefore can't pick an
--     arbitrary past time; the most they can "rewind" is their real latency.
--   * The authoritative ball position always comes from the server's stored
--     deterministic trajectory sampled at the effective time.
-- Per-player state rejects duplicates (sequence numbers must increase),
-- request floods, swings during the previous swing's cycle, and more than
-- MaxSwingsPerPitch swings at one pitch.

local Pitching = script.Parent.Parent.Pitching
local LaneGeometry = require(Pitching.LaneGeometry)

local BattingConfig = require(script.Parent.BattingConfig)
local SwingModel = require(script.Parent.SwingModel)

local SwingValidator = {}

export type Request = {
	seq: number,
	clientTime: number,
	aimX: number,
	aimY: number,
	pitchId: number?, -- the pitch the client thinks it is swinging at (informational)
}

export type PlayerState = {
	lastSeq: number,
	lastReceiveTime: number,
	lastAcceptedStart: number,
	swingsAtPitch: { [number]: number }, -- pitchId -> accepted swings (latest pitch only)
}

export type PitchWindow = {
	id: number,
	releaseTime: number,
	endTime: number, -- server time the flight ends
}

export type Context = {
	receiveTime: number,
	ping: number, -- measured round trip, seconds
	geometry: LaneGeometry.Geometry?, -- nil if the player has no lane
	pitch: PitchWindow?, -- the lane's active pitch, if any
}

export type Reason =
	"Ok"
	| "PracticeSwing"
	| "InvalidInput"
	| "Duplicate"
	| "RateLimited"
	| "NoLane"
	| "AimOutOfBounds"
	| "FutureTimestamp"
	| "StaleTimestamp"
	| "Cooldown"
	| "AlreadySwung"

export type Validation = {
	accepted: boolean,
	reason: Reason,
	effectiveTime: number?, -- authoritative swing start (server time)
	rewind: number?, -- receiveTime - effectiveTime
	allowedRewind: number?,
	clamped: boolean,
	pitchId: number?, -- set when the swing is resolved against a pitch
}

local MAX_ABS_COORD = 1e6

local function isFiniteNumber(value: any): boolean
	return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

function SwingValidator.newState(): PlayerState
	return {
		lastSeq = 0,
		lastReceiveTime = -math.huge,
		lastAcceptedStart = -math.huge,
		swingsAtPitch = {},
	}
end

-- Shape/type check of the raw remote arguments. Never trusts anything.
function SwingValidator.parse(seq: any, clientTime: any, aimX: any, aimY: any, pitchId: any): Request?
	if not (isFiniteNumber(seq) and isFiniteNumber(clientTime) and isFiniteNumber(aimX) and isFiniteNumber(aimY)) then
		return nil
	end
	if seq < 1 or seq ~= math.floor(seq) or seq > 2 ^ 31 then
		return nil
	end
	if math.abs(aimX) > MAX_ABS_COORD or math.abs(aimY) > MAX_ABS_COORD then
		return nil
	end
	local id: number? = nil
	if pitchId ~= nil then
		if not isFiniteNumber(pitchId) then
			return nil
		end
		id = pitchId
	end
	return { seq = seq, clientTime = clientTime, aimX = aimX, aimY = aimY, pitchId = id }
end

function SwingValidator.allowedRewind(ping: number): number
	local net = BattingConfig.Network
	local measured = if isFiniteNumber(ping) and ping > 0 then ping else 0
	return math.min(net.MaxRewindSeconds, measured * net.PingRewindFactor + net.RewindSlackSeconds)
end

function SwingValidator.isAimInBounds(geometry: LaneGeometry.Geometry, aimX: number, aimY: number): boolean
	local minX, maxX, minY, maxY = SwingModel.aimBounds(geometry)
	local tolerance = geometry.units.toStuds(BattingConfig.Aim.ValidationToleranceMeters)
	return aimX >= minX - tolerance and aimX <= maxX + tolerance and aimY >= minY - tolerance and aimY <= maxY + tolerance
end

local function reject(reason: Reason): Validation
	return { accepted = false, reason = reason, clamped = false }
end

-- Validates and, if accepted, records the swing in `state`.
function SwingValidator.validate(state: PlayerState, request: Request?, context: Context): Validation
	local net = BattingConfig.Network
	if request == nil then
		return reject("InvalidInput")
	end
	if request.seq <= state.lastSeq then
		return reject("Duplicate")
	end
	-- From here on the request is well-formed and new: consume its sequence
	-- number so it can never be replayed, whatever the outcome.
	state.lastSeq = request.seq
	local receiveTime = context.receiveTime
	if receiveTime - state.lastReceiveTime < net.MinRequestIntervalSeconds then
		return reject("RateLimited")
	end
	state.lastReceiveTime = receiveTime

	local geometry = context.geometry
	if geometry == nil then
		return reject("NoLane")
	end
	if not SwingValidator.isAimInBounds(geometry, request.aimX, request.aimY) then
		return reject("AimOutOfBounds")
	end

	if request.clientTime > receiveTime + net.FutureToleranceSeconds then
		return reject("FutureTimestamp")
	end
	if request.clientTime < receiveTime - net.StaleRejectSeconds then
		return reject("StaleTimestamp")
	end
	local allowed = SwingValidator.allowedRewind(context.ping)
	local effective = math.min(request.clientTime, receiveTime)
	local clamped = false
	if effective < receiveTime - allowed then
		effective = receiveTime - allowed
		clamped = true
	end

	local timeline = SwingModel.timeline()
	if effective < state.lastAcceptedStart + timeline.total - net.CooldownToleranceSeconds then
		return reject("Cooldown")
	end

	local result: Validation = {
		accepted = true,
		reason = "Ok",
		effectiveTime = effective,
		rewind = receiveTime - effective,
		allowedRewind = allowed,
		clamped = clamped,
		pitchId = nil,
	}

	-- Is the swing at the pitch? Only if its Active window overlaps the flight.
	local pitch = context.pitch
	local activeStart = effective + timeline.windup
	local activeEnd = activeStart + timeline.active
	if pitch == nil or activeEnd < pitch.releaseTime or activeStart > pitch.endTime then
		result.reason = "PracticeSwing"
	else
		local swings = state.swingsAtPitch[pitch.id] or 0
		if swings >= net.MaxSwingsPerPitch then
			return reject("AlreadySwung")
		end
		table.clear(state.swingsAtPitch) -- only the latest pitch matters
		state.swingsAtPitch[pitch.id] = swings + 1
		result.pitchId = pitch.id
	end

	state.lastAcceptedStart = effective
	return result
end

return SwingValidator
