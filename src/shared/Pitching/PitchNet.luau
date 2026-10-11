--!strict
-- Names shared by server and client for pitching replication.
--
-- Replication model (no per-frame traffic):
--   * Lane geometry inputs: attributes on ReplicatedStorage.PitchingRuntime.Lanes.<laneId>
--   * Lane state: "State" attribute on the same folder (a few changes per pitch)
--   * Batter assignment: "PitchLaneId" attribute on the Player
--   * PitchEvent (server -> client), one message per lifecycle event:
--       ("Start",  encodedPitch)                     at windup start (includes release time)
--       ("Result", laneId, pitchId, isStrike, crossPosition?)  when the ball crosses the plane
--       ("Abort",  laneId, pitchId, reason)          pitch cancelled
--   * GetActivePitches (client -> server RemoteFunction) for late joiners.

local PitchNet = {}

PitchNet.RuntimeFolderName = "PitchingRuntime"
PitchNet.LanesFolderName = "Lanes"
PitchNet.PitchEventName = "PitchEvent"
PitchNet.GetActivePitchesName = "GetActivePitches"

PitchNet.PlayerLaneAttribute = "PitchLaneId"

PitchNet.LaneAttributes = {
	PlateGround = "PlateGround",
	PitcherGround = "PitcherGround",
	ReleasePoint = "ReleasePoint", -- only set when an explicit release marker exists
	BatterGround = "BatterGround",
	State = "State",
	BatterUserId = "BatterUserId",
}

PitchNet.Messages = {
	Start = "Start",
	Result = "Result",
	Abort = "Abort",
}

return PitchNet
