--!strict
-- One local procedural pitcher and catcher per lane (AthleteModel), animated
-- on the synchronized server clock from each pitch's windup/release times.
-- No asset IDs, physics or remotes: the pose is a pure function of the pitch
-- data every client already receives (PitcherMotion / CatcherMotion), so all
-- clients see the same delivery and the ball leaves the rendered hand at the
-- authoritative release point.
--
-- Lifecycle: a new pitch blends from whatever is on screen into its windup;
-- an aborted pitch (batter left, reset) blends back to the set position;
-- contact keeps the follow-through and relaxes the catcher. Rigs outside the
-- local player's current world are unparented and not animated.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Geometry = require(Shared.Pitching.LaneGeometry)
local Pitch = require(Shared.Pitching.Pitch)
local PitchNet = require(Shared.Pitching.PitchNet)
local PitchPhysics = require(Shared.Pitching.PitchPhysics)
local AthleteConfig = require(Shared.Presentation.AthleteConfig)
local CatcherMotion = require(Shared.Presentation.CatcherMotion)
local KeyTrack = require(Shared.Presentation.KeyTrack)
local Motion = require(Shared.Presentation.PitcherMotion)
local PitchVisual = require(script.Parent.PitchVisualController)
local AthleteModel = require(script.Parent.AthleteModel)
local Audio = require(script.Parent.GameAudio)

local Controller = {}

type Lane = {
	id: string,
	geo: Geometry.Geometry,
	worldId: string,
	pitcher: AthleteModel.AthleteModel,
	catcher: AthleteModel.AthleteModel,
	pitch: Pitch.PitchData?,
	catch: CatcherMotion.PitchInfo?,
	blendFrom: Motion.Channels?,
	blendStart: number,
	blendSeconds: number,
	last: Motion.Channels?,
	sounded: boolean,
}

local lanes: { [string]: Lane } = {}
local folder: Folder
local localPlayer = Players.LocalPlayer

local function serverNow(): number
	return workspace:GetServerTimeNow()
end

local function startBlend(lane: Lane, seconds: number)
	lane.blendFrom = lane.last
	lane.blendStart = serverNow()
	lane.blendSeconds = seconds
end

local function render(lane: Lane, now: number)
	local geo = lane.geo
	local data = lane.pitch
	local ch = if data
		then Motion.pitchChannels(geo, data.windupTime, data.releaseTime, data.releasePosition, now)
		else Motion.idleChannels(now)
	local from = lane.blendFrom
	if from then
		local alpha = KeyTrack.smooth((now - lane.blendStart) / lane.blendSeconds)
		if alpha >= 1 then
			lane.blendFrom = nil
		else
			ch = KeyTrack.blend(from, ch, alpha)
		end
	end
	lane.last = ch
	local _, solved = Motion.build(geo, ch)
	lane.pitcher:render(solved.cframes)
	lane.catcher:render(CatcherMotion.sample(geo, lane.catch, now).solved.cframes)

	local own = lane.id == localPlayer:GetAttribute(PitchNet.PlayerLaneAttribute)
		and localPlayer:GetAttribute("BattingMode") == "Batting"
	local cfg = AthleteConfig.Catcher
	lane.catcher:setTransparency(if own then cfg.OwnLaneTransparency else 0, if own then cfg.OwnLaneMittTransparency else 0)

	if data and not lane.sounded and now >= data.releaseTime then
		lane.sounded = true
		if own and now - data.releaseTime < 0.2 then
			Audio.play("Pitch")
		end
	end
end

local function createLane(id: string, geo: Geometry.Geometry)
	local runtime = ReplicatedStorage:FindFirstChild(PitchNet.RuntimeFolderName)
	local lanesFolder = runtime and runtime:FindFirstChild(PitchNet.LanesFolderName)
	local laneFolder = lanesFolder and lanesFolder:FindFirstChild(id)
	local worldId = laneFolder and laneFolder:GetAttribute("WorldId")
	local throw = Motion.throwSide()
	local lane: Lane = {
		id = id,
		geo = geo,
		worldId = if typeof(worldId) == "string" then worldId else "rookie",
		pitcher = AthleteModel.new("Pitcher", Motion.skeleton(geo), if throw == "Right" then "Left" else "Right", folder),
		catcher = AthleteModel.new("Catcher", CatcherMotion.skeleton(geo), "Left", folder),
		pitch = nil,
		catch = nil,
		blendFrom = nil,
		blendStart = 0,
		blendSeconds = 1,
		last = nil,
		sounded = false,
	}
	lane.pitcher.model.Name, lane.catcher.model.Name = id .. "_Pitcher", id .. "_Catcher"
	lanes[id] = lane
	render(lane, serverNow())
end

function Controller.start()
	folder = Instance.new("Folder")
	folder.Name, folder.Parent = "PitcherVisuals", workspace
	PitchVisual.onGeometry(function(id, geo)
		local lane = lanes[id]
		if lane then
			lane.geo = geo
			lane.blendFrom = nil
			return
		end
		createLane(id, geo)
	end)
	PitchVisual.onPitchStarted(function(_, flight)
		local lane = lanes[flight.data.laneId]
		if not lane then
			return
		end
		local data = flight.data
		startBlend(lane, AthleteConfig.Pitcher.BlendSeconds)
		lane.pitch, lane.sounded = data, false
		lane.catch = {
			windupTime = data.windupTime,
			releaseTime = data.releaseTime,
			endTime = data.releaseTime + flight.endTime,
			endPosition = PitchPhysics.sample(flight.trajectory, flight.endTime),
			endVelocity = PitchPhysics.sampleVelocity(flight.trajectory, flight.endTime),
			cutTime = nil,
		}
	end)
	PitchVisual.onPitchAborted(function(id, pitchId, _, atTime)
		local lane = lanes[id]
		if not lane or not lane.pitch or lane.pitch.id ~= pitchId then
			return
		end
		local catch = lane.catch
		if atTime then
			-- Contact keeps the follow-through; the catcher relaxes.
			if catch then
				catch.cutTime = math.min(catch.cutTime or math.huge, atTime)
			end
			return
		end
		startBlend(lane, AthleteConfig.Pitcher.AbortBlendSeconds)
		lane.pitch = nil
		if catch then
			catch.cutTime = math.min(catch.cutTime or math.huge, serverNow())
		end
	end)
	PitchVisual.onPitchCut(function(id, pitchId, atTime)
		local lane = lanes[id]
		local catch = lane and lane.catch
		if lane and catch and lane.pitch and lane.pitch.id == pitchId then
			catch.cutTime = atTime -- a predicted contact, or nil when the server did not confirm it
		end
	end)
	RunService.RenderStepped:Connect(function()
		local now = serverNow()
		local current = localPlayer:GetAttribute("CurrentWorld") or "rookie"
		for _, lane in lanes do
			local parent = if lane.worldId == current then folder else nil
			lane.pitcher:setParent(parent)
			lane.catcher:setParent(parent)
			if parent then
				render(lane, now)
			end
		end
	end)
end

return Controller
