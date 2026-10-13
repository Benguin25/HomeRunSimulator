--!strict
-- Client side of pitching: tracks lane geometry, receives one message per
-- pitch, rebuilds the identical trajectory locally, and renders it against the
-- synchronized server clock. One RenderStepped binding drives every active
-- pitch; at most one playback exists per lane (a new pitch replaces the old).
--
-- Clients never report ball positions to the server.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Pitching = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Pitching")
local LaneGeometry = require(Pitching.LaneGeometry)
local Pitch = require(Pitching.Pitch)
local PitchNet = require(Pitching.PitchNet)
local PitchPlayback = require(Pitching.PitchPlayback)

local PitchVisualController = {}

export type ResultInfo = {
	laneId: string,
	pitchId: number,
	isStrike: boolean,
	crossPosition: Vector3?,
}

type Listener<T...> = (T...) -> ()

local geometries: { [string]: LaneGeometry.Geometry } = {}
local playbacks: { [string]: PitchPlayback.PitchPlayback } = {}
local playbackPitchIds: { [string]: number } = {}
local visualsFolder: Folder

local geometryListeners: { Listener<string, LaneGeometry.Geometry> } = {}
local pitchListeners: { Listener<LaneGeometry.Geometry, Pitch.Flight> } = {}
local resultListeners: { Listener<ResultInfo> } = {}
local abortListeners: { Listener<string, number, string, number?> } = {}
local cutListeners: { Listener<string, number, number?> } = {}

local RENDER_BIND_NAME = "PitchingBallRender"

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

local function readLane(folder: Instance)
	local attrs = PitchNet.LaneAttributes
	local plate = folder:GetAttribute(attrs.PlateGround)
	local pitcher = folder:GetAttribute(attrs.PitcherGround)
	if typeof(plate) ~= "Vector3" or typeof(pitcher) ~= "Vector3" then
		return
	end
	local function optional(name: string): Vector3?
		local value = folder:GetAttribute(name)
		return if typeof(value) == "Vector3" then value else nil
	end
	local geometry = LaneGeometry.new({
		plateGround = plate,
		pitcherGround = pitcher,
		releasePoint = optional(attrs.ReleasePoint),
		batterGround = optional(attrs.BatterGround),
		batterSide = if folder:GetAttribute(attrs.BatterSide) == "Left" then "Left" else "Right",
		rightBatterGround = optional(attrs.RightBatterGround),
		leftBatterGround = optional(attrs.LeftBatterGround),
		leftFoulPole = optional(attrs.LeftFoulPole),
		rightFoulPole = optional(attrs.RightFoulPole),
		firstBase = optional(attrs.FirstBase),
		thirdBase = optional(attrs.ThirdBase),
	})
	geometries[folder.Name] = geometry
	for _, listener in geometryListeners do
		task.spawn(listener, folder.Name, geometry)
	end
end

local function stopPlayback(laneId: string)
	local playback = playbacks[laneId]
	if playback then
		playback:destroy()
		playbacks[laneId] = nil
		playbackPitchIds[laneId] = nil
	end
end

local function startPitch(data: Pitch.PitchData)
	local geometry = geometries[data.laneId]
	if not geometry then
		return
	end
	local currentId = playbackPitchIds[data.laneId]
	if currentId and currentId >= data.id then
		return -- duplicate or older (late-join snapshot raced the live message)
	end
	local flight = Pitch.buildFlight(geometry, data)
	-- Stale: the pitch already finished before we heard about it.
	if serverNow() > data.releaseTime + flight.endTime + 0.5 then
		return
	end
	stopPlayback(data.laneId)
	playbacks[data.laneId] = PitchPlayback.new(geometry, flight, visualsFolder)
	playbackPitchIds[data.laneId] = data.id
	for _, listener in pitchListeners do
		task.spawn(listener, geometry, flight)
	end
end

local function onRender()
	local now = serverNow()
	for laneId, playback in playbacks do
		if not playback:update(now) then
			playbacks[laneId] = nil
			playbackPitchIds[laneId] = nil
		end
	end
end

local function onPitchEvent(kind: string, ...: any)
	if kind == PitchNet.Messages.Start then
		local data = Pitch.decode(...)
		if data then
			startPitch(data)
		end
	elseif kind == PitchNet.Messages.Result then
		local laneId, pitchId, isStrike, crossPosition = ...
		local info: ResultInfo = {
			laneId = laneId,
			pitchId = pitchId,
			isStrike = isStrike == true,
			crossPosition = if typeof(crossPosition) == "Vector3" then crossPosition else nil,
		}
		for _, listener in resultListeners do
			task.spawn(listener, info)
		end
	elseif kind == PitchNet.Messages.Abort then
		local laneId, pitchId, reason, atTime = ...
		if playbackPitchIds[laneId] == pitchId then
			if typeof(atTime) == "number" then
				-- Bat contact: the ball stays visible until the bat reaches it.
				playbacks[laneId]:cutAt(atTime)
			else
				stopPlayback(laneId)
			end
		end
		for _, listener in abortListeners do
			task.spawn(listener, laneId, pitchId, reason, atTime)
		end
	end
end

function PitchVisualController.start()
	visualsFolder = Instance.new("Folder")
	visualsFolder.Name = "PitchVisuals"
	visualsFolder.Parent = Workspace

	local runtime = ReplicatedStorage:WaitForChild(PitchNet.RuntimeFolderName)
	local lanesFolder = runtime:WaitForChild(PitchNet.LanesFolderName)
	local pitchEvent = runtime:WaitForChild(PitchNet.PitchEventName) :: RemoteEvent
	local getActive = runtime:WaitForChild(PitchNet.GetActivePitchesName) :: RemoteFunction

	local function watchLane(folder: Instance)
		readLane(folder)
		folder.AttributeChanged:Connect(function(name)
			if not PitchNet.RuntimeLaneAttributes[name] then
				readLane(folder)
			end
		end)
	end
	for _, folder in lanesFolder:GetChildren() do
		watchLane(folder)
	end
	lanesFolder.ChildAdded:Connect(watchLane)

	pitchEvent.OnClientEvent:Connect(onPitchEvent)
	RunService:BindToRenderStep(RENDER_BIND_NAME, Enum.RenderPriority.Camera.Value + 2, onRender)

	-- Late join: pick up pitches already in progress.
	task.spawn(function()
		local ok, packets = pcall(getActive.InvokeServer, getActive)
		if ok and typeof(packets) == "table" then
			for _, packet in packets do
				local data = Pitch.decode(packet)
				if data then
					startPitch(data)
				end
			end
		end
	end)
end

function PitchVisualController.getGeometry(laneId: string): LaneGeometry.Geometry?
	return geometries[laneId]
end

-- The flight currently rendered on a lane (batting prediction samples it).
function PitchVisualController.getActiveFlight(laneId: string): Pitch.Flight?
	local playback = playbacks[laneId]
	return playback and playback.flight
end

-- Hide the ball at `atTime` (server time); used by locally predicted contact.
function PitchVisualController.cutPitch(laneId: string, pitchId: number, atTime: number)
	local playback = playbacks[laneId]
	if playback and playbackPitchIds[laneId] == pitchId then
		playback:cutAt(atTime)
		for _, listener in cutListeners do
			listener(laneId, pitchId, atTime)
		end
	end
end

-- Undo a predicted cut, if the ball is still being rendered.
function PitchVisualController.uncutPitch(laneId: string, pitchId: number)
	local playback = playbacks[laneId]
	if playback and playbackPitchIds[laneId] == pitchId then
		playback:clearCut()
		for _, listener in cutListeners do
			listener(laneId, pitchId, nil)
		end
	end
end

function PitchVisualController.onGeometry(listener: Listener<string, LaneGeometry.Geometry>)
	table.insert(geometryListeners, listener)
	for laneId, geometry in geometries do
		task.spawn(listener, laneId, geometry)
	end
end

function PitchVisualController.onPitchStarted(listener: Listener<LaneGeometry.Geometry, Pitch.Flight>)
	table.insert(pitchListeners, listener)
end

function PitchVisualController.onPitchResult(listener: Listener<ResultInfo>)
	table.insert(resultListeners, listener)
end

function PitchVisualController.onPitchAborted(listener: Listener<string, number, string, number?>)
	table.insert(abortListeners, listener)
end
function PitchVisualController.onPitchCut(listener: Listener<string, number, number?>)
	table.insert(cutListeners, listener)
end

return PitchVisualController
