--!strict
-- Authoritative pitching: owns one PitchLane per batting lane, generates and
-- solves pitches, and replicates each pitch once (at windup start) with its
-- server-time release timestamp. Outcomes (crossing point, strike/ball) are
-- computed here from the same deterministic trajectory the clients render.
--
-- The server never creates a ball Part: the ball is pure math on the server
-- and a cosmetic object on clients. Phase 2 batting validation can sample
-- PitchServer.getActivePitch(laneId).flight at any server time.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Pitching = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Pitching")
local Pitch = require(Pitching.Pitch)
local PitchConfig = require(Pitching.PitchConfig)
local PitchLane = require(Pitching.PitchLane)
local PitchNet = require(Pitching.PitchNet)

local MarkerResolver = require(script.Parent.MarkerResolver)

local PitchServer = {}

type LaneRecord = {
	id: string,
	resolved: MarkerResolver.ResolvedLane,
	lane: PitchLane.PitchLane,
	folder: Folder,
}

local lanes: { [string]: LaneRecord } = {}
local laneOrder: { string } = {}
local pitchEvent: RemoteEvent
local rng = Random.new()
local heartbeatConnection: RBXScriptConnection? = nil

local debugLogging = RunService:IsStudio() and PitchConfig.Debug.Enabled and PitchConfig.Debug.LogPitchesToOutput

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function createRuntime(): (Folder, Folder)
	local existing = ReplicatedStorage:FindFirstChild(PitchNet.RuntimeFolderName)
	if existing then
		existing:Destroy()
	end
	local runtime = Instance.new("Folder")
	runtime.Name = PitchNet.RuntimeFolderName

	local lanesFolder = Instance.new("Folder")
	lanesFolder.Name = PitchNet.LanesFolderName
	lanesFolder.Parent = runtime

	pitchEvent = Instance.new("RemoteEvent")
	pitchEvent.Name = PitchNet.PitchEventName
	pitchEvent.Parent = runtime

	local getActive = Instance.new("RemoteFunction")
	getActive.Name = PitchNet.GetActivePitchesName
	getActive.OnServerInvoke = function(_player: Player)
		local packets = {}
		for _, record in lanes do
			local active = record.lane.pitch
			if active then
				table.insert(packets, Pitch.encode(active.data))
			end
		end
		return packets
	end
	getActive.Parent = runtime

	return runtime, lanesFolder
end

local function logPitch(record: LaneRecord, active: PitchLane.ActivePitch, solveIterations: number)
	if not debugLogging then
		return
	end
	local flight = active.flight
	local units = record.resolved.geometry.units
	print(
		string.format(
			"[Pitching] %s #%d %s %.1f mph -> %.1f mph at plate | flight %.3f s | target error %.2f mm | %s | solver iters %d",
			record.id,
			active.data.id,
			active.data.pitchType,
			flight.releaseSpeedMph,
			flight.plateSpeedMph or 0,
			flight.crossTime or -1,
			flight.targetError and units.toMeters(flight.targetError) * 1000 or -1,
			if flight.isStrike then "STRIKE" else "BALL",
			solveIterations
		)
	)
end

local function createLane(resolved: MarkerResolver.ResolvedLane, lanesFolder: Folder): LaneRecord
	local folder = Instance.new("Folder")
	folder.Name = resolved.id
	local attrs = PitchNet.LaneAttributes
	folder:SetAttribute(attrs.PlateGround, resolved.inputs.plateGround)
	folder:SetAttribute(attrs.PitcherGround, resolved.inputs.pitcherGround)
	folder:SetAttribute(attrs.ReleasePoint, resolved.inputs.releasePoint)
	folder:SetAttribute(attrs.BatterGround, resolved.inputs.batterGround)
	folder:SetAttribute(attrs.State, "Idle")
	folder.Parent = lanesFolder

	local record: LaneRecord
	local geometry = resolved.geometry

	local lane = PitchLane.new(resolved.id, {
		createPitch = function(_lane, id, windupTime, releaseTime)
			local data, result = Pitch.generate(geometry, rng :: any, {
				id = id,
				laneId = resolved.id,
				windupTime = windupTime,
				releaseTime = releaseTime,
			})
			local flight = Pitch.buildFlight(geometry, data)
			if flight.crossing == nil then
				warn(`[Pitching] {resolved.id}: generated pitch #{id} never reaches the plate; skipping.`)
				return nil
			end
			if not result.ok then
				warn(
					string.format(
						"[Pitching] %s: solver did not converge for pitch #%d (error %.4f studs).",
						resolved.id,
						id,
						result.error
					)
				)
			end
			local active = { data = data, flight = flight }
			logPitch(record, active, result.iterations)
			return active
		end,
		onStateChanged = function(_lane, state, _now)
			folder:SetAttribute(attrs.State, state)
		end,
		onPitchStarted = function(_lane, active)
			pitchEvent:FireAllClients(PitchNet.Messages.Start, Pitch.encode(active.data))
		end,
		onPitchCrossed = function(_lane, active)
			local crossing = active.flight.crossing
			pitchEvent:FireAllClients(
				PitchNet.Messages.Result,
				resolved.id,
				active.data.id,
				active.flight.isStrike,
				crossing and crossing.position
			)
		end,
		onPitchAborted = function(_lane, active, reason)
			pitchEvent:FireAllClients(PitchNet.Messages.Abort, resolved.id, active.data.id, reason)
		end,
	})

	record = { id = resolved.id, resolved = resolved, lane = lane, folder = folder }
	return record
end

function PitchServer.start()
	assert(heartbeatConnection == nil, "PitchServer already started")
	local runtime, lanesFolder = createRuntime()

	for _, resolved in MarkerResolver.resolveLanes() do
		local record = createLane(resolved, lanesFolder)
		lanes[record.id] = record
		table.insert(laneOrder, record.id)
		if debugLogging then
			print(`[Pitching] {record.id} markers:`)
			for role, source in resolved.sources do
				print(`    {role}: {source}`)
			end
		end
	end

	-- Lanes must exist before clients look for them.
	runtime.Parent = ReplicatedStorage

	heartbeatConnection = RunService.Heartbeat:Connect(function()
		local t = now()
		for _, id in laneOrder do
			lanes[id].lane:update(t)
		end
	end)
end

function PitchServer.getLaneIds(): { string }
	return table.clone(laneOrder)
end

function PitchServer.getGeometry(laneId: string)
	local record = lanes[laneId]
	return record and record.resolved.geometry
end

function PitchServer.setBatter(laneId: string, userId: number?)
	local record = lanes[laneId]
	if record then
		record.folder:SetAttribute(PitchNet.LaneAttributes.BatterUserId, userId)
	end
end

-- Starts pitching on a lane (no-op if already running).
function PitchServer.startLane(laneId: string, delay: number?)
	local record = lanes[laneId]
	if record then
		record.lane:start(now(), delay)
	end
end

-- Stops pitching on a lane and aborts any pitch in flight.
function PitchServer.stopLane(laneId: string, reason: string)
	local record = lanes[laneId]
	if record then
		record.lane:stop(now(), reason)
	end
end

-- Hook for Phase 2 (e.g. pause while a swing resolves).
function PitchServer.setLanePaused(laneId: string, paused: boolean)
	local record = lanes[laneId]
	if record then
		record.lane:setPaused(paused)
	end
end

function PitchServer.getActivePitch(laneId: string): PitchLane.ActivePitch?
	local record = lanes[laneId]
	return record and record.lane.pitch
end

return PitchServer
