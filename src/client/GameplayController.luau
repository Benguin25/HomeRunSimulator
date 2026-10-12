--!strict
-- Versioned snapshots and one readiness message per transition (bounded retry).
-- No positions, distances or record claims travel from client to server.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Gameplay = Shared:WaitForChild("Gameplay")
local Config = require(Gameplay.GameplayConfig)
local Net = require(Gameplay.GameplayNet)
local Replica = require(Gameplay.SessionReplica)
local PitchNet = require(Shared.Pitching.PitchNet)
local BattingCamera = require(script.Parent.BattingCamera)
local BattingController = require(script.Parent.BattingController)
local Controller = {}
local state = Replica.new()
local request: RemoteEvent
local listeners: { (Net.Snapshot) -> () } = {}
local lastReadyAt = -math.huge
local lastSkipAt = -math.huge
local lastReturnCommand = ""

function Controller.getSnapshot(): Net.Snapshot?
	return state.value
end
function Controller.onSnapshot(listener: (Net.Snapshot) -> ())
	table.insert(listeners, listener)
	if state.value then
		listener(state.value)
	end
end
function Controller.canSkip(): boolean
	local snapshot = state.value
	local loop = snapshot and snapshot.loop
	local hit = BattingCamera.getHit()
	return loop ~= nil
		and loop.phase == "Resolved"
		and loop.characterReady
		and hit ~= nil
		and hit.confirmed
		and hit.outcome ~= nil
		and hit.pitchId == loop.pitchId
		and BattingCamera.getDirector():getState() == "Landing"
end
function Controller.skip()
	if not Controller.canSkip() then
		return
	end
	local loop = (state.value :: Net.Snapshot).loop :: Net.Loop
	local now = Workspace:GetServerTimeNow()
	if now - lastSkipAt < Config.Pacing.ReadyRetrySeconds then
		return
	end
	lastSkipAt = now
	request:FireServer("Skip", loop.laneId, loop.epoch, loop.hitId)
end
local function receive(snapshot: Net.Snapshot)
	if not Replica.apply(state, snapshot) then
		return
	end
	for _, listener in listeners do
		listener(snapshot)
	end
end
local function update()
	local snapshot = state.value
	local loop = snapshot and snapshot.loop
	if not loop or loop.laneId ~= Players.LocalPlayer:GetAttribute(PitchNet.PlayerLaneAttribute) then
		return
	end
	if loop.phase == "Returning" then
		local key = `{loop.laneId}/{loop.epoch}/{loop.hitId}/{loop.notBefore}`
		if lastReturnCommand ~= key then
			lastReturnCommand = key
			if not BattingCamera.skipResult(loop.laneId, loop.pitchId) then
				BattingCamera.recoverPresentation(loop.laneId, loop.pitchId)
			end
		end
	end
	local now = Workspace:GetServerTimeNow()
	if
		loop.phase ~= "Flying"
		and not loop.cameraReady
		and loop.characterReady
		and now >= loop.notBefore
		and BattingCamera.isReady()
		and BattingController.isSwingReady()
		and now - lastReadyAt >= Config.Pacing.ReadyRetrySeconds
	then
		lastReadyAt = now
		request:FireServer("Ready", loop.laneId, loop.epoch, loop.hitId)
	end
end
function Controller.start()
	BattingController.setReadinessCheck(function()
		local value = state.value
		local loop = value and value.loop
		return loop ~= nil
			and loop.pitchReady
			and loop.cameraReady
			and loop.laneId == Players.LocalPlayer:GetAttribute(PitchNet.PlayerLaneAttribute)
	end)
	local runtime = ReplicatedStorage:WaitForChild(Net.RuntimeFolder)
	request = runtime:WaitForChild(Net.Request) :: RemoteEvent
	local event = runtime:WaitForChild(Net.Event) :: RemoteEvent
	event.OnClientEvent:Connect(receive)
	local getSnapshot = runtime:WaitForChild(Net.GetSnapshot) :: RemoteFunction
	-- Subscribe first: a late initialization response cannot overwrite a live update.
	task.spawn(function()
		local ok, snapshot = pcall(function()
			return getSnapshot:InvokeServer()
		end)
		if ok and snapshot then
			receive(snapshot)
		end
	end)
	UserInputService.InputBegan:Connect(function(input, processed)
		if
			not processed
			and UserInputService:GetFocusedTextBox() == nil
			and input.KeyCode == (Enum.KeyCode :: any)[Config.Hud.SkipKey]
		then
			Controller.skip()
		end
	end)
	RunService:BindToRenderStep("GameplayReadiness", Enum.RenderPriority.Camera.Value + 6, update)
end
return Controller
