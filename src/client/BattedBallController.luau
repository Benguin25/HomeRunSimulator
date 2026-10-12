--!strict
-- Client side of batted balls: renders the authoritative flight from one
-- launch record per hit, sampled against the synchronized server clock.
--
-- The swinging client also predicts its own hit: when its local swing
-- resolution predicts contact, it runs the same impact model and flight
-- solver on the same contact data, so the ball leaves the bat at the contact
-- instant even before the server's launch arrives. When the launch arrives:
--   * same launch record (the normal case) -> the prediction is adopted and
--     just learns the server's first-impact time;
--   * different record (rewind clamping, a different contact) -> replaced by
--     the server's flight at the current server time;
--   * the server reports no contact, or nothing arrives in time -> removed.
-- One flight per lane. Clients never report positions, impacts or distances.
--
-- Stage 4: the local batter's own hits are also reported to BattingCamera
-- (cinematic follow, HUD) and HitEffects (landing feedback). Other lanes'
-- hits are only drawn.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ContactQuality = require(Shared:WaitForChild("Batting"):WaitForChild("ContactQuality"))
local PitchNet = require(Shared:WaitForChild("Pitching"):WaitForChild("PitchNet"))
local BattedBallFolder = Shared:WaitForChild("BattedBall")
local BattedBall = require(BattedBallFolder.BattedBall)
local BattedBallConfig = require(BattedBallFolder.BattedBallConfig)
local BattedBallNet = require(BattedBallFolder.BattedBallNet)
local BattedBallPlayback = require(BattedBallFolder.BattedBallPlayback)
local FieldFrame = require(BattedBallFolder.FieldFrame)
local ImpactModel = require(BattedBallFolder.ImpactModel)
local LandingDetector = require(BattedBallFolder.LandingDetector)

local BattedBallDebugView = require(script.Parent.BattedBallDebugView)
local BattingCamera = require(script.Parent.BattingCamera)
local HitEffects = require(script.Parent.HitEffects)
local PitchVisualController = require(script.Parent.PitchVisualController)
local ProgressionController = require(script.Parent.ProgressionController)
local ProgressionRules = require(Shared.Progression.ProgressionRules)

local BattedBallController = {}

export type Entry = {
	laneId: string,
	pitchId: number,
	hitId: number?, -- nil while it is an unconfirmed prediction
	predicted: boolean, -- created locally (may since have been confirmed)
	createdClock: number,
	launch: BattedBall.LaunchData,
	flight: BattedBall.Flight,
	endTime: number?, -- server flight end (s after launch), once known
	playback: BattedBallPlayback.BattedBallPlayback,
	outcome: LandingDetector.OutcomePayload?,
	-- Only for this client's own predicted hits (debug).
	impact: ImpactModel.Result?,
	contactType: ImpactModel.ContactType?,
}

type Effect = { untilClock: number, instance: Instance }

local RENDER_BIND_NAME = "BattedBallRender"

local localPlayer = Players.LocalPlayer
local visualsFolder: Folder
local frames: { [string]: FieldFrame.Frame } = {}
local entries: { [string]: Entry } = {}
local effects: { Effect } = {}

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

-- The local batter's own hit on the lane they are batting in.
local function isOwn(launch: BattedBall.LaunchData): boolean
	return launch.userId == localPlayer.UserId and launch.laneId == localPlayer:GetAttribute(PitchNet.PlayerLaneAttribute)
end

local function frameFor(laneId: string): FieldFrame.Frame?
	local existing = frames[laneId]
	if existing then
		return existing
	end
	local geometry = PitchVisualController.getGeometry(laneId)
	if not geometry then
		return nil
	end
	local frame = FieldFrame.new(geometry)
	frames[laneId] = frame
	BattedBallDebugView.drawField(laneId, frame)
	return frame
end

local function removeEntry(laneId: string)
	local entry = entries[laneId]
	if entry then
		entry.playback:destroy()
		entries[laneId] = nil
	end
end

local function addEntry(entry: Entry)
	removeEntry(entry.laneId)
	entries[entry.laneId] = entry
	BattedBallDebugView.showFlight(entry)
end

local function newEntry(launch: BattedBall.LaunchData, frame: FieldFrame.Frame, predicted: boolean, endTime: number?): Entry
	local flight = BattedBall.buildFlight(frame, launch)
	return {
		laneId = launch.laneId,
		pitchId = launch.pitchId,
		hitId = if predicted then nil else launch.hitId,
		predicted = predicted,
		createdClock = os.clock(),
		launch = launch,
		flight = flight,
		endTime = endTime,
		playback = BattedBallPlayback.new(flight, visualsFolder, endTime),
		outcome = nil,
		impact = nil,
		contactType = nil,
	}
end

-- Called by BattingController when its local resolution predicts contact.
function BattedBallController.predict(laneId: string, pitchId: number, contact: ContactQuality.ContactResult)
	local frame = frameFor(laneId)
	if not frame then
		return
	end
	local powerLevel, powerVersion = ProgressionController.power()
	local launch, impact = BattedBall.computeLaunch(frame, contact, {
		hitId = 0,
		laneId = laneId,
		pitchId = pitchId,
		userId = localPlayer.UserId,
	}, ProgressionRules.impactConfig(powerLevel))
	launch.powerLevel, launch.powerVersion = powerLevel, powerVersion
	local entry = newEntry(launch, frame, true, nil)
	entry.impact = impact
	entry.contactType = BattedBall.describeContact(frame, contact, impact)
	addEntry(entry)
	BattingCamera.beginHit({ pitchId = pitchId, flight = entry.flight, endTime = nil, confirmed = false })
	HitEffects.attachWhoosh(entry.playback.ball and entry.playback.ball.model.PrimaryPart)
end

-- The server did not grant the predicted contact.
function BattedBallController.cancelPrediction(laneId: string, pitchId: number)
	local entry = entries[laneId]
	if entry and entry.hitId == nil and entry.pitchId == pitchId then
		removeEntry(laneId)
		BattingCamera.cancelHit(laneId, pitchId, "prediction rejected")
	end
end

local function addEffect(instance: Instance, seconds: number)
	instance.Parent = visualsFolder
	table.insert(effects, { untilClock = os.clock() + seconds, instance = instance })
end

local function spawnLandingMarker(entry: Entry, payload: LandingDetector.OutcomePayload)
	local display = BattedBallConfig.Display
	local point = payload.impactPoint
	if not display.ShowLandingMarker or point == nil then
		return
	end
	local frame = entry.flight.frame
	local normal = frame.up
	local text: string
	if payload.kind == "Landed" then
		text = BattedBall.formatDistance(payload.carryMeters or 0)
	else
		text = BattedBall.formatDistance(payload.impactDistanceMeters or 0) .. " (wall)"
	end

	local ring = Instance.new("Part")
	ring.Name = "LandingMarker"
	ring.Shape = Enum.PartType.Cylinder
	local diameter = display.LandingMarkerDiameterMeters * frame.studsPerMeter
	ring.Size = Vector3.new(0.05, diameter, diameter)
	-- Cylinder axis is the part's X axis: lay it along the surface normal.
	if payload.kind == "Landed" then
		ring.CFrame = CFrame.fromMatrix(point + normal * 0.03, normal, frame.forward:Cross(normal).Unit)
	else
		ring.CFrame = CFrame.new(point)
		ring.Size = Vector3.one * diameter * 0.4
		ring.Shape = Enum.PartType.Ball
	end
	ring.Color = if payload.territory == "Fair" then Color3.fromRGB(255, 214, 64) else Color3.fromRGB(200, 200, 200)
	ring.Material = Enum.Material.Neon
	ring.Transparency = 0.25
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanTouch = false
	ring.CanQuery = false
	ring.CastShadow = false

	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromOffset(160, 36)
	billboard.StudsOffsetWorldSpace = normal * 3
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBlack
	label.TextScaled = true
	label.TextColor3 = ring.Color
	label.TextStrokeTransparency = 0.3
	label.Text = text
	label.Parent = billboard
	billboard.Parent = ring

	addEffect(ring, display.LandingMarkerSeconds)
end

local function onLaunch(packet: any)
	local launch, endTime = BattedBall.decode(packet)
	if not launch or not endTime then
		return
	end
	local frame = frameFor(launch.laneId)
	if not frame then
		return
	end
	local display = BattedBallConfig.Display
	if serverNow() > launch.launchTime + endTime + display.LandedHoldSeconds + display.LandedFadeSeconds then
		return -- already over
	end
	local entry = entries[launch.laneId]
	if entry and entry.hitId == launch.hitId then
		return -- duplicate
	end
	if entry and entry.hitId == nil and entry.pitchId == launch.pitchId and BattedBall.sameLaunch(entry.launch, launch) then
		-- Prediction confirmed: keep the ball that is already flying.
		entry.hitId = launch.hitId
		entry.launch = launch
		entry.endTime = endTime
		entry.playback:setEndTime(endTime)
		BattedBallDebugView.showFlight(entry)
		if isOwn(launch) then
			BattingCamera.confirmHit(launch.laneId, launch.pitchId, endTime)
		end
		return
	end
	local fresh = newEntry(launch, frame, false, endTime)
	addEntry(fresh)
	if isOwn(launch) then
		-- Either a corrected prediction (same pitch: the camera swaps flights
		-- under its smoothing) or a hit this client did not predict.
		BattingCamera.beginHit({ pitchId = launch.pitchId, flight = fresh.flight, endTime = endTime, confirmed = true })
		HitEffects.attachWhoosh(fresh.playback.ball and fresh.playback.ball.model.PrimaryPart)
	end
end

local function onResolved(hitId: any, laneId: any, payload: any)
	if typeof(laneId) ~= "string" or typeof(payload) ~= "table" then
		return
	end
	local entry = entries[laneId]
	if not entry or entry.hitId ~= hitId or entry.outcome ~= nil then
		return
	end
	local outcome = payload :: LandingDetector.OutcomePayload
	entry.outcome = outcome
	entry.endTime = outcome.endTime
	entry.playback:setEndTime(outcome.endTime)
	spawnLandingMarker(entry, outcome)
	if isOwn(entry.launch) then
		BattingCamera.resolveHit(laneId, entry.pitchId, outcome)
		local point = outcome.impactPoint
		if point then
			HitEffects.playLanding(point, outcome.kind, outcome.surface)
		end
	end
	BattedBallDebugView.showOutcome(entry)
end

local function onEvent(kind: string, ...: any)
	if kind == BattedBallNet.Messages.Launch then
		onLaunch(...)
	elseif kind == BattedBallNet.Messages.Resolved then
		onResolved(...)
	elseif kind == BattedBallNet.Messages.Cancelled then
		local hitId, laneId = ...
		local entry = if typeof(laneId) == "string" then entries[laneId] else nil
		if entry and entry.hitId == hitId then
			removeEntry(laneId)
			if isOwn(entry.launch) then
				BattingCamera.cancelHit(laneId, entry.pitchId, "hit cancelled by server")
			end
		end
	end
end

local function onRender()
	local now = serverNow()
	local clock = os.clock()
	local timeout = BattedBallConfig.Lifecycle.PredictionTimeoutSeconds
	local camera = Workspace.CurrentCamera
	local cameraPosition = camera and camera.CFrame.Position
	for laneId, entry in entries do
		if entry.hitId == nil and clock - entry.createdClock > timeout then
			removeEntry(laneId) -- the server never confirmed this prediction
			BattingCamera.cancelHit(laneId, entry.pitchId, "prediction timed out")
		elseif not entry.playback:update(now, cameraPosition) then
			entries[laneId] = nil
		end
	end
	for i = #effects, 1, -1 do
		if clock >= effects[i].untilClock then
			effects[i].instance:Destroy()
			table.remove(effects, i)
		end
	end
	local ownLane = localPlayer:GetAttribute(PitchNet.PlayerLaneAttribute)
	local shown = if typeof(ownLane) == "string" then entries[ownLane] else nil
	if shown == nil then
		for _, entry in entries do
			shown = entry
			break
		end
	end
	BattedBallDebugView.updateLive(shown, now)
end

function BattedBallController.start()
	visualsFolder = Instance.new("Folder")
	visualsFolder.Name = "BattedBallVisuals"
	visualsFolder.Parent = Workspace

	PitchVisualController.onGeometry(function(laneId)
		frames[laneId] = nil
		frameFor(laneId)
	end)

	local runtime = ReplicatedStorage:WaitForChild(BattedBallNet.RuntimeFolderName)
	local event = runtime:WaitForChild(BattedBallNet.EventName) :: RemoteEvent
	event.OnClientEvent:Connect(onEvent)
	-- Same priority band as the pitch ball, so both are placed before the frame renders.
	RunService:BindToRenderStep(RENDER_BIND_NAME, Enum.RenderPriority.Camera.Value + 2, onRender)
end

return BattedBallController
