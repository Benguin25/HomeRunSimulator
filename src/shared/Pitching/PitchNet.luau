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
--       ("Abort",  laneId, pitchId, reason, atTime?) pitch cancelled; atTime (server time,
--                                                    bat contact) = keep showing the ball until then
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
	BatterSide = "BatterSide",
	RightBatterGround = "RightBatterGround",
	LeftBatterGround = "LeftBatterGround",
	-- Optional field markers (batted-ball foul lines); only set when found.
	LeftFoulPole = "LeftFoulPole",
	RightFoulPole = "RightFoulPole",
	FirstBase = "FirstBase",
	ThirdBase = "ThirdBase",
	State = "State",
	BatterUserId = "BatterUserId",
	HitState = "HitState", -- batted-ball lifecycle state (Phase 3A), for debugging
}

-- Attributes that change during play and do not affect lane geometry.
PitchNet.RuntimeLaneAttributes = {
	[PitchNet.LaneAttributes.State] = true,
	[PitchNet.LaneAttributes.BatterUserId] = true,
	[PitchNet.LaneAttributes.HitState] = true,
}

PitchNet.Messages = {
	Start = "Start",
	Result = "Result",
	Abort = "Abort",
}

return PitchNet
