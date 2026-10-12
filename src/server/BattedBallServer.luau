--!strict
-- Authoritative batted balls. On a validated contact (BattingServer) it:
--   1. runs the impact model on the server's own contact measurements,
--   2. builds the deterministic flight from the resulting launch record,
--   3. sweeps that flight against the stadium (Workspace:Spherecast) to find
--      the first impact and measure the outcome,
--   4. broadcasts the launch record once, pauses the lane's pitching,
--   5. broadcasts the outcome at the impact's server time, holds briefly,
--      then lets the lane pitch again.
--
-- The server never creates a ball Part and never trusts client positions.
-- The stadium is static, so the whole outcome is known at launch; it is
-- revealed on schedule by HitLifecycle (exactly once, robust to frame hitches).

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PitchNet = require(Shared:WaitForChild("Pitching"):WaitForChild("PitchNet"))
local ContactQuality = require(Shared:WaitForChild("Batting"):WaitForChild("ContactQuality"))
local BattedBallFolder = Shared:WaitForChild("BattedBall")
local BattedBall = require(BattedBallFolder.BattedBall)
local BattedBallConfig = require(BattedBallFolder.BattedBallConfig)
local BattedBallNet = require(BattedBallFolder.BattedBallNet)
local FieldFrame = require(BattedBallFolder.FieldFrame)
local HitLifecycle = require(BattedBallFolder.HitLifecycle)
local ImpactModel = require(BattedBallFolder.ImpactModel)
local LandingDetector = require(BattedBallFolder.LandingDetector)

local PitchServer = require(script.Parent.PitchServer)

local BattedBallServer = {}

type LaneHits = {
	lifecycle: HitLifecycle.HitLifecycle,
	frame: FieldFrame.Frame,
}

export type HitStats = {
	impact: ImpactModel.Result,
	contactType: ImpactModel.ContactType,
	simulateMs: number,
	sweepMs: number,
	steps: number,
	casts: number,
}

local lanes: { [string]: LaneHits } = {}
local stats: { [number]: HitStats } = {}
local event: RemoteEvent
local nextHitId = 0
local heartbeat: RBXScriptConnection? = nil

local debugLogging = RunService:IsStudio() and BattedBallConfig.Debug.LogHitsToOutput

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function setHitState(laneId: string, state: string)
	local folder = PitchServer.getLaneFolder(laneId)
	if folder then
		folder:SetAttribute(PitchNet.LaneAttributes.HitState, state)
	end
end

-- Everything the ball must not hit: players, markers, client-only visuals,
-- tagged parts. Non-collidable parts are skipped through RespectCanCollide.
local function raycastParams(): RaycastParams
	local cfg = BattedBallConfig.Collision
	local exclude: { Instance } = {}
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(exclude, player.Character)
		end
	end
	for _, name in cfg.IgnoreWorkspaceChildren do
		local child = Workspace:FindFirstChild(name)
		if child then
			table.insert(exclude, child)
		end
	end
	for _, tagged in CollectionService:GetTagged(cfg.IgnoreTag) do
		table.insert(exclude, tagged)
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = exclude
	params.RespectCanCollide = cfg.RespectCanCollide
	return params
end

local function workspaceCaster(params: RaycastParams): LandingDetector.Caster
	return function(origin: Vector3, displacement: Vector3, radius: number): LandingDetector.CastHit?
		local result = Workspace:Spherecast(origin, radius, displacement, params)
		if result == nil then
			return nil
		end
		return {
			distance = result.Distance,
			point = result.Position,
			normal = result.Normal,
			name = result.Instance:GetFullName(),
		}
	end
end

local function log(hit: HitLifecycle.ActiveHit)
	if not debugLogging then
		return
	end
	local flight = hit.flight
	local s = stats[hit.launch.hitId]
	local impact = s and s.impact
	print(
		string.format(
			"[BattedBall] %s hit #%d: %.1f mph, launch %+.1f deg, spray %+.1f deg (pull %+.1f), backspin %.0f rpm, sidespin %+.0f rpm"
				.. " | apex %.1f m, end %.2f s | %s"
				.. " | %s contact: e %.3f, M_eff %.3f kg, q %.3f%s | sim %.2f ms (%d steps), sweep %.2f ms (%d casts)",
			hit.launch.laneId,
			hit.launch.hitId,
			flight.exitSpeedMph,
			flight.launchAngleDegrees,
			flight.sprayAngleDegrees,
			flight.pullAngleDegrees,
			flight.backspinRpm,
			flight.sidespinRpm,
			flight.apexHeightMeters,
			hit.outcome.endTime,
			LandingDetector.describe(LandingDetector.toPayload(hit.outcome)),
			s and s.contactType or "?",
			impact and impact.restitution or 0,
			impact and impact.effectiveBatMass or 0,
			impact and impact.collisionEfficiency or 0,
			if impact and impact.sliding then ", sliding" else "",
			s and s.simulateMs or 0,
			s and s.steps or 0,
			s and s.sweepMs or 0,
			s and s.casts or 0
		)
	)
end

local function getLane(laneId: string): LaneHits?
	local existing = lanes[laneId]
	if existing then
		return existing
	end
	local geometry = PitchServer.getGeometry(laneId)
	if not geometry then
		return nil
	end
	local frame = FieldFrame.new(geometry)
	local lifecycle = HitLifecycle.new(laneId, {
		onLaunched = function(_, hit)
			PitchServer.setLanePaused(laneId, true)
			setHitState(laneId, "Flying")
			event:FireAllClients(BattedBallNet.Messages.Launch, BattedBall.encode(hit.launch, hit.outcome.endTime))
		end,
		onResolved = function(_, hit)
			setHitState(laneId, "Resolved")
			event:FireAllClients(BattedBallNet.Messages.Resolved, hit.launch.hitId, laneId, LandingDetector.toPayload(hit.outcome))
			log(hit)
		end,
		onFinished = function(_, hit)
			stats[hit.launch.hitId] = nil
			setHitState(laneId, "Idle")
			PitchServer.setLanePaused(laneId, false)
		end,
		onCancelled = function(_, hit, reason)
			stats[hit.launch.hitId] = nil
			setHitState(laneId, "Idle")
			PitchServer.setLanePaused(laneId, false)
			event:FireAllClients(BattedBallNet.Messages.Cancelled, hit.launch.hitId, laneId, reason)
			if debugLogging then
				print(`[BattedBall] {laneId} hit #{hit.launch.hitId} cancelled ({reason})`)
			end
		end,
	})
	local record = { lifecycle = lifecycle, frame = frame }
	lanes[laneId] = record
	if debugLogging then
		print(`[BattedBall] {laneId} field frame: foul lines from {frame.foulLineSource}`)
	end
	return record
end

-- Starts the authoritative flight for a validated contact. Returns the hit
-- id, or nil if the lane is unknown or already has a ball in the air.
function BattedBallServer.launch(laneId: string, pitchId: number, player: Player, contact: ContactQuality.ContactResult): number?
	local lane = getLane(laneId)
	if not lane then
		return nil
	end
	if lane.lifecycle:isBusy() then
		warn(`[BattedBall] {laneId}: contact on pitch #{pitchId} while a hit is still active; ignored.`)
		return nil
	end
	nextHitId += 1
	local hitId = nextHitId

	local launch, impact = BattedBall.computeLaunch(lane.frame, contact, {
		hitId = hitId,
		laneId = laneId,
		pitchId = pitchId,
		userId = player.UserId,
	})
	local t0 = os.clock()
	local flight = BattedBall.buildFlight(lane.frame, launch)
	local t1 = os.clock()
	local outcome = LandingDetector.evaluate(flight, workspaceCaster(raycastParams()))
	local t2 = os.clock()
	stats[hitId] = {
		impact = impact,
		contactType = BattedBall.describeContact(lane.frame, contact, impact),
		simulateMs = (t1 - t0) * 1000,
		sweepMs = (t2 - t1) * 1000,
		steps = flight.trajectory.count - 1,
		casts = outcome.casts,
	}

	if not lane.lifecycle:launch(now(), { launch = launch, flight = flight, outcome = outcome }) then
		stats[hitId] = nil
		return nil
	end
	return hitId
end

-- Abandons the lane's active hit (batter left). Clients remove the ball.
function BattedBallServer.cancelLane(laneId: string, reason: string)
	local lane = lanes[laneId]
	if lane then
		lane.lifecycle:cancel(reason)
	end
end

function BattedBallServer.getActiveHit(laneId: string): HitLifecycle.ActiveHit?
	local lane = lanes[laneId]
	return lane and lane.lifecycle.hit
end

function BattedBallServer.start()
	assert(heartbeat == nil, "BattedBallServer already started")
	local existing = ReplicatedStorage:FindFirstChild(BattedBallNet.RuntimeFolderName)
	if existing then
		existing:Destroy()
	end
	local runtime = Instance.new("Folder")
	runtime.Name = BattedBallNet.RuntimeFolderName
	event = Instance.new("RemoteEvent")
	event.Name = BattedBallNet.EventName
	event.Parent = runtime
	runtime.Parent = ReplicatedStorage

	heartbeat = RunService.Heartbeat:Connect(function()
		local t = now()
		for _, lane in lanes do
			lane.lifecycle:update(t)
		end
	end)
end

return BattedBallServer
