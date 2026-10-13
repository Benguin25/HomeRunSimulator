--!strict
-- Authoritative batting. Receives swing intent (seq, click time, aim),
-- validates it (SwingValidator), rebuilds the swing at the validated time and
-- resolves it against the lane's stored deterministic pitch trajectory
-- (SwingResolver). On contact the pitch is ended through PitchServer so it can
-- never also be called a strike, and the batted ball is launched through
-- BattedBallServer (only if the pitch was still active, so one contact can
-- never launch two balls). Every outcome is broadcast once.
--
-- Clients never report contact, quality or ball positions; anything they
-- predict locally is overwritten by this result.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PitchNet = require(Shared:WaitForChild("Pitching"):WaitForChild("PitchNet"))
local Batting = Shared:WaitForChild("Batting")
local BattingConfig = require(Batting.BattingConfig)
local BattingNet = require(Batting.BattingNet)
local SwingModel = require(Batting.SwingModel)
local SwingResolver = require(Batting.SwingResolver)
local SwingValidator = require(Batting.SwingValidator)

local BattedBallServer = require(script.Parent.BattedBallServer)
local PitchServer = require(script.Parent.PitchServer)
local GameplayServer = require(script.Parent.GameplayServer)

local BattingServer = {}

local states: { [Player]: SwingValidator.PlayerState } = {}
local assignedAt: { [Player]: number } = {}
local assignmentConnections: { [Player]: RBXScriptConnection } = {}
local resultEvent: RemoteEvent

local debugLogging = RunService:IsStudio() and BattingConfig.Debug.LogSwingsToOutput

local function log(player: Player, payload: BattingNet.SwingResultPayload, resolution: SwingResolver.Resolution?)
	if not debugLogging then
		return
	end
	local contact = payload.contact
	local outcome = if not payload.accepted
		then `REJECTED ({payload.reason})`
		elseif contact then string.format("%s contact (score %.2f)", contact.label, contact.score)
		elseif payload.pitchId then `MISS ({payload.missReason})`
		else "practice swing"
	print(
		string.format(
			"[Batting] %s seq %d: %s | timing %s | rewind %.0f ms%s | sweep iters %d",
			player.Name,
			payload.seq,
			outcome,
			if payload.timingErrorSeconds then string.format("%+.0f ms", payload.timingErrorSeconds * 1000) else "n/a",
			(payload.rewind or 0) * 1000,
			if payload.clamped then " (clamped)" else "",
			if resolution then resolution.iterations else 0
		)
	)
end

local function onSwingRequest(
	player: Player,
	seq: any,
	clientTime: any,
	aimX: any,
	aimY: any,
	pitchId: any,
	requestedLane: any
)
	local receiveTime = Workspace:GetServerTimeNow()
	local state = states[player]
	if state == nil then
		return
	end

	local laneId = player:GetAttribute(PitchNet.PlayerLaneAttribute)
	local sameAssignment = requestedLane == laneId
		and typeof(clientTime) == "number"
		and clientTime >= (assignedAt[player] or math.huge)
	local geometry = if sameAssignment
			and typeof(laneId) == "string"
			and GameplayServer.canSwing(laneId, player)
		then PitchServer.getGeometry(laneId)
		else nil
	local active = if typeof(laneId) == "string" then PitchServer.getActivePitch(laneId) else nil

	local request = SwingValidator.parse(seq, clientTime, aimX, aimY, pitchId)
	local validation = SwingValidator.validate(state, request, {
		receiveTime = receiveTime,
		ping = player:GetNetworkPing(),
		geometry = geometry,
		pitch = active and {
			id = active.data.id,
			releaseTime = active.data.releaseTime,
			endTime = active.data.releaseTime + active.flight.endTime,
		},
	})

	local payload: BattingNet.SwingResultPayload = {
		userId = player.UserId,
		laneId = if typeof(laneId) == "string" then laneId else nil,
		seq = if request then request.seq else 0,
		accepted = validation.accepted,
		reason = validation.reason,
		effectiveTime = validation.effectiveTime,
		rewind = validation.rewind,
		allowedRewind = validation.allowedRewind,
		clamped = validation.clamped,
		aimX = if request then request.aimX else nil,
		aimY = if request then request.aimY else nil,
		pitchId = validation.pitchId,
	}

	local resolution: SwingResolver.Resolution? = nil
	if validation.accepted and geometry and request and validation.effectiveTime then
		local swing = SwingModel.new(geometry, request.aimX, request.aimY, validation.effectiveTime)
		if active and validation.pitchId == active.data.id then
			local result = SwingResolver.resolve(geometry, active.flight, swing)
			resolution = result
			payload.missReason = result.missReason
			payload.missAmount = result.missAmount
			payload.timingErrorSeconds = result.timingErrorSeconds
			payload.ballX, payload.ballY = result.ballX, result.ballY
			payload.minGap = if result.minGap < math.huge then result.minGap else nil
			local contact = result.contact
			GameplayServer.swing(player, request.seq, payload.pitchId ~= nil, contact ~= nil)
			if contact then
				payload.contact = contact
				if
					PitchServer.resolveContact(
						laneId :: string,
						active.data.id,
						contact.contactTime,
						BattingNet.ContactAbortReason
					)
				then
					payload.hitId = BattedBallServer.launch(laneId :: string, active.data.id, player, contact)
				end
			end
		end
	end

	-- Malformed requests are only answered to the sender (nothing to show others).
	if payload.accepted and request then
		GameplayServer.swing(player, request.seq, payload.pitchId ~= nil, payload.hitId ~= nil)
	end
	if request then
		resultEvent:FireAllClients(payload)
	else
		resultEvent:FireClient(player, payload)
	end
	log(player, payload, resolution)
end

function BattingServer.start()
	local existing = ReplicatedStorage:FindFirstChild(BattingNet.RuntimeFolderName)
	if existing then
		existing:Destroy()
	end
	local runtime = Instance.new("Folder")
	runtime.Name = BattingNet.RuntimeFolderName

	local requestEvent = Instance.new("RemoteEvent")
	requestEvent.Name = BattingNet.SwingRequestName
	requestEvent.Parent = runtime

	resultEvent = Instance.new("RemoteEvent")
	resultEvent.Name = BattingNet.SwingResultName
	resultEvent.Parent = runtime

	requestEvent.OnServerEvent:Connect(onSwingRequest)

	local function onPlayerAdded(player: Player)
		states[player] = SwingValidator.newState()
		assignedAt[player] = Workspace:GetServerTimeNow()
		assignmentConnections[player] = player
			:GetAttributeChangedSignal(PitchNet.PlayerLaneAttribute)
			:Connect(function()
				assignedAt[player] = Workspace:GetServerTimeNow()
				local state = states[player]
				if state then
					table.clear(state.swingsAtPitch)
				end
			end)
	end
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(function(player)
		states[player], assignedAt[player] = nil, nil
		local connection = assignmentConnections[player]
		if connection then
			connection:Disconnect()
		end
		assignmentConnections[player] = nil
	end)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end

	runtime.Parent = ReplicatedStorage
end

return BattingServer
