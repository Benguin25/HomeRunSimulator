--!strict
-- Names shared by server and client for batted-ball replication.
--
-- Traffic per hit (nothing per frame):
--   BattedBallEvent (server -> all clients)
--     ("Launch", encodedLaunch)                   at contact; carries the launch record and
--                                                 the server's flight end time
--     ("Resolved", hitId, laneId, OutcomePayload) at the first impact (server time)
--     ("Cancelled", hitId, laneId, reason)        the hit was abandoned (batter left)
-- Clients rebuild the flight from the launch record; they never report
-- ball positions, impacts or distances.

local BattedBallNet = {}

BattedBallNet.RuntimeFolderName = "BattedBallRuntime"
BattedBallNet.EventName = "BattedBallEvent"

BattedBallNet.Messages = {
	Launch = "Launch",
	Resolved = "Resolved",
	Cancelled = "Cancelled",
}

-- The hit state is mirrored on the lane folder as PitchNet.LaneAttributes.HitState.

return BattedBallNet
