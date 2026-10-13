--!strict
-- Versioned snapshots and one readiness message per transition (bounded retry).
-- No positions, distances or record claims travel from client to server.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Gameplay = Shared:WaitForChild("Gameplay")
local Config = require(Gameplay.GameplayConfig)
local Net = require(Gameplay.GameplayNet)
local Replica = require(Gameplay.SessionReplica)
local PitchNet = require(Shared.Pitching.PitchNet)
local BattingCamera = require(script.Parent.BattingCamera)
local BattingController = require(script.Parent.BattingController)
local Binding = require(script.Parent.ActionBinding)
local ActionInput = require(Shared.Presentation.ActionInput)
local PitchConfig = require(Shared.Pitching.PitchConfig)
local PreviewConfig = require(Shared.Presentation.PitchPreviewConfig)
local Controller = {}
local state = Replica.new()
local request: RemoteEvent
local listeners: { (Net.Snapshot) -> () } = {}
local lastReadyAt = -math.huge
local pendingSkip: { laneId: string, pitchId: number, lastSent: number, epoch: number }? = nil
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
	return BattingCamera.getDirector():canSkipPresentation(Workspace:GetServerTimeNow())
end
function Controller.wasSkipped(laneId: string, pitchId: number): boolean
	return BattingCamera.getDirector():wasSkipped(laneId, pitchId)
end
function Controller.isWaiting(): boolean
	local loop = state.value and state.value.loop
	return loop ~= nil
		and loop.phase == "Flying"
		and BattingCamera.isReady()
		and (loop.presentationSkipped == true or Controller.wasSkipped(loop.laneId, loop.pitchId))
end
function Controller.skip()
	if not Controller.canSkip() then
		return
	end
	local hit = BattingCamera.getHit()
	if hit and BattingCamera.skipPresentation(hit.laneId, hit.pitchId) then
		pendingSkip = { laneId = hit.laneId, pitchId = hit.pitchId, lastSent = -math.huge, epoch = -1 }
	end
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
	local skip = pendingSkip
	if skip then
		if skip.laneId ~= loop.laneId then
			pendingSkip = nil
		elseif
			loop.pitchId == skip.pitchId
			and loop.characterReady
			and (loop.phase == "Flying" or loop.phase == "Resolved")
		then
			if skip.epoch ~= loop.epoch then
				skip.epoch, skip.lastSent = loop.epoch, -math.huge
			end
			if loop.presentationSkipped ~= true and now - skip.lastSent >= Config.Pacing.ReadyRetrySeconds then
				skip.lastSent = now
				request:FireServer("Skip", loop.laneId, loop.epoch, loop.hitId)
			end
		end
	end
	if
		(loop.phase ~= "Flying" or loop.presentationSkipped == true)
		and not loop.cameraReady
		and loop.characterReady
		and now >= loop.notBefore
		and (BattingCamera.isReady() or (Players.LocalPlayer:GetAttribute("BattingMode") == "FreeRoam" and Players.LocalPlayer:GetAttribute(
			"BattingExitPending"
		) == true and BattingCamera.isFreeRoamReady()))
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
	local ok, key = pcall(function()
		return (Enum.KeyCode :: any)[Config.Hud.SkipKey]
	end)
	if
		ok
		and key ~= Enum.KeyCode.None
		and ActionInput.distinct(
			Config.Hud.SkipKey,
			{ Config.Hud.StatsKey, PitchConfig.Debug.ToggleKey, PreviewConfig.ToggleKey }
		)
	then
		Binding.bind("HomeRunSkipPresentation", key, Config.Hud.SkipInputPriority, function()
			return Controller.canSkip()
				or BattingCamera.getDirector():getState() == "Returning"
				or Controller.isWaiting()
		end, Controller.skip)
	else
		warn("[Gameplay] Invalid/conflicting skip key; use the skip button.")
	end
	RunService:BindToRenderStep("GameplayReadiness", Enum.RenderPriority.Camera.Value + 6, update)
end
return Controller
