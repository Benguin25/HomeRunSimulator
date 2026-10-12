--!strict
-- Thin runtime adapter around pure session reducers and return validation.
-- Existing pitching/batting/hit lifecycle call these validated server hooks.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Gameplay = Shared:WaitForChild("Gameplay")
local Net = require(Gameplay.GameplayNet)
local Stats = require(Gameplay.SessionStats)
local Gate = require(Gameplay.ReturnGate)
local LandingDetector = require(Shared.BattedBall.LandingDetector)
local PitchNet = require(Shared.Pitching.PitchNet)
local Config = require(Gameplay.GameplayConfig)
local ProgressionServer = require(script.Parent.ProgressionServer)
local Server = {}
type PlayerState = { stats: Stats.State, version: number, rejection: string, lastRequest: number }
type LaneState = { player: Player, gate: Gate.State }
local players: { [Player]: PlayerState } = {}
local lanes: { [string]: LaneState } = {}
local event: RemoteEvent
local epoch = 0

local function nextEpoch(): number
	epoch += 1
	return epoch
end
local function snapshot(player: Player): Net.Snapshot?
	local state = players[player]
	if not state then
		return nil
	end
	local loop: Net.Loop? = nil
	local laneId = player:GetAttribute(PitchNet.PlayerLaneAttribute)
	local lane = if typeof(laneId) == "string" then lanes[laneId] else nil
	if lane and lane.player == player then
		local g = lane.gate
		loop = {
			laneId = laneId :: string,
			epoch = g.epoch,
			hitId = g.hitId,
			pitchId = g.pitchId,
			phase = g.phase,
			characterReady = g.characterReady,
			cameraReady = g.cameraReady,
			pitchReady = Gate.canPitch(g),
			notBefore = g.notBefore,
			rejection = g.rejection,
		}
	end
	return { version = state.version, stats = Stats.snapshot(state.stats), loop = loop, rejection = state.rejection }
end
local function publish(player: Player)
	local state = players[player]
	if not state then
		return
	end
	state.version += 1
	local value = snapshot(player)
	if value then
		event:FireClient(player, value)
	end
end
local function alive(player: Player): boolean
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0 and character ~= nil and character.Parent ~= nil
end

function Server.assign(player: Player, laneId: string)
	lanes[laneId] = { player = player, gate = Gate.new(player.UserId, nextEpoch(), Workspace:GetServerTimeNow()) }
	publish(player)
end
function Server.character(player: Player, laneId: string, ready: boolean)
	local lane = lanes[laneId]
	if not lane or lane.player ~= player then
		return
	end
	Gate.character(lane.gate, ready, nextEpoch())
	publish(player)
end
function Server.canPitch(laneId: string): boolean
	local lane = lanes[laneId]
	return lane ~= nil and Gate.canPitch(lane.gate) and alive(lane.player)
end
function Server.canSwing(laneId: string, player: Player): boolean
	local lane = lanes[laneId]
	return lane ~= nil and lane.player == player and Gate.canPitch(lane.gate) and alive(player)
end
function Server.canFinish(laneId: string, hitId: number): boolean
	local lane = lanes[laneId]
	return lane == nil or (lane.gate.hitId == hitId and Gate.canPitch(lane.gate))
end
function Server.pitch(laneId: string, pitchId: number)
	local lane = lanes[laneId]
	local state = lane and players[lane.player]
	if lane and state and Stats.pitch(state.stats, laneId, pitchId) then
		publish(lane.player)
	end
end
function Server.swing(player: Player, seq: number, associated: boolean, contact: boolean)
	local state = players[player]
	if state and Stats.swing(state.stats, seq, associated, contact) then
		publish(player)
	end
end
function Server.launch(laneId: string, player: Player, hitId: number, pitchId: number, exitMph: number)
	local lane, state = lanes[laneId], players[player]
	if not lane or lane.player ~= player or not state then
		return
	end
	-- A rewound/predicted contact can abort the pitch before the release hook
	-- runs. This authoritative contact proves that pitch was received; dedupe it.
	Stats.pitch(state.stats, laneId, pitchId)
	if not Stats.contact(state.stats, hitId, exitMph) then
		return
	end
	Gate.begin(lane.gate, hitId, pitchId)
	ProgressionServer.launch(player, hitId)
	publish(player)
end
function Server.resolve(laneId: string, hitId: number, outcome: LandingDetector.OutcomePayload)
	local lane = lanes[laneId]
	local state = lane and players[lane.player]
	if not lane or not state then
		return
	end
	if Gate.resolve(lane.gate, hitId, Workspace:GetServerTimeNow()) then
		Stats.resolve(state.stats, hitId, outcome)
		ProgressionServer.resolve(lane.player, hitId, outcome)
		publish(lane.player)
	end
end
function Server.cancel(laneId: string, hitId: number)
	local lane = lanes[laneId]
	local state = lane and players[lane.player]
	if not lane or not state or lane.gate.hitId ~= hitId then
		return
	end
	Stats.cancel(state.stats, hitId)
	ProgressionServer.cancel(lane.player, hitId)
	local ready = lane.gate.characterReady
	lane.gate = Gate.new(lane.player.UserId, nextEpoch(), Workspace:GetServerTimeNow())
	lane.gate.characterReady = ready
	lane.gate.notBefore = Workspace:GetServerTimeNow() + Config.Pacing.ReturnSeconds
	publish(lane.player)
end

function Server.start()
	local runtime = Instance.new("Folder")
	runtime.Name = Net.RuntimeFolder
	event = Instance.new("RemoteEvent")
	event.Name = Net.Event
	event.Parent = runtime
	local request = Instance.new("RemoteEvent")
	request.Name = Net.Request
	request.Parent = runtime
	local getSnapshot = Instance.new("RemoteFunction")
	getSnapshot.Name = Net.GetSnapshot
	getSnapshot.Parent = runtime
	getSnapshot.OnServerInvoke = function(player: Player)
		return snapshot(player)
	end
	request.OnServerEvent:Connect(function(player: Player, kind: any, laneId: any, assignment: any, hitId: any)
		-- Owner is selected from the authenticated Player, never a supplied user ID.
		local state = players[player]
		if not state then
			return
		end
		local now = Workspace:GetServerTimeNow()
		local function reject(reason: string)
			if state.rejection ~= reason then
				state.rejection = reason
				publish(player)
			end
		end
		local lastRequest = state.lastRequest
		state.lastRequest = now
		if now - lastRequest < Config.Pacing.RequestMinGapSeconds then
			reject("RateLimited")
			return
		end
		local actualLane = player:GetAttribute(PitchNet.PlayerLaneAttribute)
		local lane = if typeof(laneId) == "string" then lanes[laneId] else nil
		if not lane or lane.player ~= player or actualLane ~= laneId then
			reject("WrongLaneOrOwner")
			return
		end
		if not alive(player) then
			reject("CharacterNotReady")
			return
		end
		local before = lane.gate.rejection
		local previous = state.rejection
		local ok, reason = Gate.request(lane.gate, player.UserId, assignment, hitId, kind, now)
		state.rejection = reason
		if ok or before ~= lane.gate.rejection or previous ~= reason then
			publish(player)
		end
	end)
	local function added(player: Player)
		players[player] = { stats = Stats.new(), version = 0, rejection = "", lastRequest = -math.huge }
	end
	Players.PlayerAdded:Connect(added)
	Players.PlayerRemoving:Connect(function(player)
		players[player] = nil
		for laneId, lane in lanes do
			if lane.player == player then
				lanes[laneId] = nil
			end
		end
	end)
	for _, player in Players:GetPlayers() do
		added(player)
	end
	RunService.Heartbeat:Connect(function()
		local now = Workspace:GetServerTimeNow()
		for _, lane in lanes do
			if Gate.recover(lane.gate, now) then
				publish(lane.player)
			end
		end
	end)
	runtime.Parent = ReplicatedStorage
end
return Server
