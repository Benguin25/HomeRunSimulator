--!strict
-- Names and payloads shared by server and client for batting.
--
-- Traffic per swing (nothing per frame; aim is only sent with a swing):
--   SwingRequest (client -> server): seq, clientTime, aimX, aimY, pitchId?
--   SwingResult  (server -> all clients): one SwingResultPayload
-- On contact the pitch is also aborted through PitchEvent ("Abort", ...,
-- "Contact", contactTime) so every client stops the ball at the contact time.

local ContactQuality = require(script.Parent.ContactQuality)
local SwingResolver = require(script.Parent.SwingResolver)
local SwingValidator = require(script.Parent.SwingValidator)

local BattingNet = {}

BattingNet.RuntimeFolderName = "BattingRuntime"
BattingNet.SwingRequestName = "SwingRequest"
BattingNet.SwingResultName = "SwingResult"

BattingNet.ContactAbortReason = "Contact"

export type SwingResultPayload = {
	userId: number,
	laneId: string?,
	seq: number,
	accepted: boolean,
	reason: SwingValidator.Reason,
	effectiveTime: number?,
	rewind: number?,
	allowedRewind: number?,
	clamped: boolean,
	aimX: number?,
	aimY: number?,
	pitchId: number?,
	contact: ContactQuality.ContactResult?,
	hitId: number?, -- batted-ball id (BattedBallNet) when the contact launched a ball
	missReason: SwingResolver.MissReason?,
	missAmount: number?, -- seconds for Early/Late, studs for the other reasons
	timingErrorSeconds: number?,
	minGap: number?,
}

return BattingNet
