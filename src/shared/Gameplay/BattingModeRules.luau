--!strict
-- Pure admission/exit policy. Reservations and character writes stay in the adapter.
local Config = require(script.Parent.BattingModeConfig)
local Rules = {}
export type Guard = { sequence: number, lastAt: number }
export type Entry = {
	profileReady: boolean,
	characterReady: boolean,
	assigned: boolean,
	sameWorld: boolean,
	laneAvailable: boolean,
	distance: number,
	side: any,
}
function Rules.new(): Guard
	return { sequence = 0, lastAt = -math.huge }
end
function Rules.request(guard: Guard, now: number, sequence: any): string?
	if
		typeof(sequence) ~= "number"
		or sequence ~= sequence
		or sequence % 1 ~= 0
		or sequence <= 0
		or sequence > 1e12
	then
		return "InvalidRequest"
	end
	if sequence <= guard.sequence then
		return "DuplicateRequest"
	end
	guard.sequence = sequence
	local elapsed = now - guard.lastAt
	guard.lastAt = now
	return if elapsed < Config.RequestGapSeconds then "RateLimited" else nil
end
function Rules.entry(context: Entry): string?
	if not context.profileReady then
		return "DataUnavailable"
	end
	if not context.characterReady then
		return "CharacterNotReady"
	end
	if context.assigned then
		return "AlreadyBatting"
	end
	if context.side ~= "Right" and context.side ~= "Left" then
		return "UnknownBox"
	end
	if not context.sameWorld then
		return "WrongWorld"
	end
	if not context.laneAvailable then
		return "LaneOccupied"
	end
	if context.distance ~= context.distance or context.distance < 0 or context.distance > Config.EntryDistanceStuds then
		return "TooFarAway"
	end
	return nil
end
function Rules.exit(ownsLane: boolean, expectedEpoch: any, epoch: number, pending: boolean): string?
	if not ownsLane then
		return "NotBatting"
	end
	if expectedEpoch ~= epoch then
		return "StaleAssignment"
	end
	if pending then
		return "AlreadyLeaving"
	end
	return nil
end
function Rules.canRelease(hitBusy: boolean): boolean
	-- Busy includes resolved/landing/returning until the authoritative lifecycle finishes.
	return not hitBusy
end
return Rules
