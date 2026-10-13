--!strict
-- Client batting: mouse aim, left-click swings, the local swing state machine,
-- and predicted presentation reconciled against the server's result.
--
-- Aim: every frame the mouse position is turned into a camera ray
-- (Camera:ViewportPointToRay) and intersected with the contact plane, so the
-- reticle sits on a real point in lane space at any resolution / aspect ratio.
-- The aim is only sent to the server with a swing, never per frame.
--
-- Swing: on click (if the previous swing has fully recovered) the client
-- stamps the click with the synchronized server clock, starts the bat swing
-- immediately, sends the intent, and runs the same deterministic resolver the
-- server runs to predict contact effects on time (including the batted ball,
-- through BattedBallController). The server's result decides the outcome; a
-- misprediction is corrected when it arrives.
--
-- While the hit camera is away from the batter (Stage 4) the aim HUD is
-- hidden and clicks are ignored; the camera's return re-enables both.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Pitching = Shared:WaitForChild("Pitching")
local LaneGeometry = require(Pitching.LaneGeometry)
local PitchNet = require(Pitching.PitchNet)
local Batting = Shared:WaitForChild("Batting")
local BattingConfig = require(Batting.BattingConfig)
local BattingNet = require(Batting.BattingNet)
local BatStance = require(Batting.BatStance)
local ContactQuality = require(Batting.ContactQuality)
local SwingModel = require(Batting.SwingModel)
local SwingResolver = require(Batting.SwingResolver)
local FieldFrame = require(Shared:WaitForChild("BattedBall"):WaitForChild("FieldFrame"))
local HitPresentation = require(Shared:WaitForChild("Presentation"):WaitForChild("HitPresentation"))

local BattedBallController = require(script.Parent.BattedBallController)
local BattingCamera = require(script.Parent.BattingCamera)
local BattingDebugView = require(script.Parent.BattingDebugView)
local BattingPresentation = require(script.Parent.BattingPresentation)
local CharacterGrip = require(script.Parent.CharacterGrip)
local PitchVisualController = require(script.Parent.PitchVisualController)
local Input = require(script.Parent.InputCoordinator)
local SwingAnalysisHud = require(script.Parent.SwingAnalysisHud)

local BattingController = {}

local RENDER_BIND_NAME = "BattingUpdate"
local MAX_PENDING = 8

type Pending = {
	seq: number,
	swing: SwingModel.Swing,
	laneId: string,
	pitchId: number?,
	predicted: SwingResolver.Resolution?,
	-- What is currently being shown (prediction, replaced by the server's).
	contact: ContactQuality.ContactResult?,
	contactShown: boolean,
	missSoundPlayed: boolean,
	server: BattingNet.SwingResultPayload?,
	labelShown: boolean,
}

local localPlayer = Players.LocalPlayer
local requestEvent: RemoteEvent
local laneId: string? = nil
local geometry: LaneGeometry.Geometry? = nil
local aimX, aimY = 0, 0
local aimClamped = false
local aimInitialized = false
local seq = 0
local currentSwing: SwingModel.Swing? = nil
local readyPose: SwingModel.Pose? = nil -- bat resting in the hands (smoothed toward the aim)
local swingFromPose: SwingModel.Pose? = nil -- what was on screen when the click happened
local pending: { Pending } = {}
local swungPitchId: number? = nil
local active = false
local readinessCheck: (() -> boolean)? = nil

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

local function findPending(sequence: number): Pending?
	for _, entry in pending do
		if entry.seq == sequence then
			return entry
		end
	end
	return nil
end

local function updateAim(dt: number)
	local geo = geometry
	local camera = Workspace.CurrentCamera
	if not geo or not camera then
		return
	end
	local mouse = UserInputService:GetMouseLocation()
	local ray = camera:ViewportPointToRay(mouse.X, mouse.Y)
	local rawX, rawY = SwingModel.aimFromRay(geo, ray.Origin, ray.Direction, BattingConfig.Aim.Sensitivity)
	if rawX == nil or rawY == nil then
		return
	end
	local x, y = SwingModel.clampAim(geo, rawX, rawY)
	aimClamped = x ~= rawX or y ~= rawY
	local tau = BattingConfig.Aim.SmoothingSeconds
	if tau > 0 and aimInitialized then
		local alpha = 1 - math.exp(-dt / tau) -- frame-rate independent
		aimX += (x - aimX) * alpha
		aimY += (y - aimY) * alpha
	else
		aimX, aimY = x, y
	end
	aimInitialized = true
	BattingPresentation.updateReticle(camera, geo, aimX, aimY, if aimClamped then mouse else nil)
	BattingPresentation.drawZone(camera, geo)
end

local function showContact(entry: Pending, contact: ContactQuality.ContactResult)
	local geo = geometry
	if not geo then
		return
	end
	entry.contactShown = true
	-- Intensity from the measured contact, plus the flight once one is known.
	local hit = BattingCamera.getHit()
	local flight = if hit and hit.pitchId == entry.pitchId then hit.flight else nil
	local intensity = HitPresentation.intensity({
		exitSpeedMph = flight and flight.exitSpeedMph,
		launchDegrees = flight and flight.launchAngleDegrees,
		score = contact.score,
		relativeSpeedMps = geo.units.toMeters(contact.relativeVelocity.Magnitude),
		sweetSpotOffsetMeters = geo.units.toMeters(contact.sweetSpotOffset),
	})
	local direction: Vector3? = nil
	if flight then
		local v = flight.launch.velocity
		local world = FieldFrame.vectorToWorld(flight.frame, v.X, v.Y, v.Z)
		direction = if world.Magnitude > 1e-6 then world.Unit else nil
	end
	BattingPresentation.playContact(contact, geo, intensity, direction)
	BattingCamera.addImpulse(intensity)
end

local function updatePending(now: number)
	local geo = geometry
	for i = #pending, 1, -1 do
		local entry = pending[i]
		local contact = entry.contact
		if contact and not entry.contactShown and now >= contact.contactTime then
			showContact(entry, contact)
		end
		local missTime = entry.swing.activeEnd
		if entry.pitchId and not contact and not entry.missSoundPlayed and now >= missTime then
			entry.missSoundPlayed = true
			BattingPresentation.playMiss()
		end
		-- The label appears once the server has answered and the moment has come.
		local server = entry.server
		if server and not entry.labelShown and geo then
			local labelTime = if contact then contact.contactTime else missTime
			if now >= labelTime then
				entry.labelShown = true
				local serverContact = server.contact
				if serverContact then
					BattingPresentation.showContactLabel(serverContact, geo)
				elseif server.pitchId then
					BattingPresentation.showMissLabel(server.missReason, server.missAmount, geo)
				end
				if server.pitchId and server.laneId == entry.laneId then
					SwingAnalysisHud.present(server, geo)
				end
			end
		end
		local done = entry.labelShown or (entry.server ~= nil and entry.server.pitchId == nil)
		if (done and now > entry.swing.startTime + entry.swing.timeline.total) or now > entry.swing.startTime + 5 then
			table.remove(pending, i)
		end
	end
end

local function onRender(dt: number)
	if not active then
		return
	end
	local geo = geometry
	if not geo then
		return
	end
	local now = serverNow()
	local aimVisible = BattingCamera.isAimVisible() and Input.canAim()
	BattingPresentation.setAimVisible(aimVisible)
	if aimVisible then
		updateAim(dt)
	end

	-- The resting bat lives in the character's hands and drifts toward the aim.
	-- The body follows the swing pivot (the swing's own while swinging, so it
	-- holds still mid-swing; the aimed one while waiting).
	CharacterGrip.ensureBound(localPlayer.Character)
	local activeSwing = currentSwing
	local swinging = activeSwing ~= nil and not SwingModel.isReadyAt(activeSwing, now)
	CharacterGrip.step(
		geo,
		if swinging and activeSwing then activeSwing.pivot else SwingModel.pivotFor(geo, aimX, aimY),
		dt
	)
	local anchor = CharacterGrip.getAnchor(geo) or BatStance.fallbackAnchor(geo)
	local length = SwingModel.dimensions(geo).length
	local restTarget = BatStance.readyPose(geo, anchor, aimX, aimY)
	local ready = if readyPose then BatStance.follow(readyPose, restTarget, dt, length) else restTarget
	readyPose = ready

	-- Active = the collision pose itself; the other phases blend to/from it.
	local swing = currentSwing
	local pose: SwingModel.Pose = ready
	local phase: string = "Ready"
	if swing and not SwingModel.isReadyAt(swing, now) then
		pose = BatStance.visualPoseAt(swing, now, swingFromPose or ready, ready)
		phase = (SwingModel.phaseAt(swing, now))
	end
	BattingPresentation.setBatPose(pose, SwingModel.dimensions(geo))
	CharacterGrip.apply(geo, pose)

	updatePending(now)
	BattingPresentation.update()
	BattingDebugView.updateLive(
		geo,
		phase,
		aimX,
		aimY,
		aimClamped,
		if BattingDebugView.isEnabled() then CharacterGrip.describe(geo) else nil
	)
end

local function trySwing()
	if not Input.canSwing() then
		return
	end
	local geo = geometry
	local lane = laneId
	if not active or not geo or not lane or not aimInitialized or not BattingCamera.isBattingView() then
		return
	end
	if readinessCheck and not readinessCheck() then
		return
	end
	local now = serverNow()
	-- Local state machine: no new swing until the previous one has recovered.
	if not SwingModel.isReadyAt(currentSwing, now) then
		return
	end

	seq += 1
	local swing = SwingModel.new(geo, aimX, aimY, now)
	currentSwing = swing
	swingFromPose = readyPose
	BattingPresentation.playSwing()

	local entry: Pending = {
		seq = seq,
		swing = swing,
		laneId = lane,
		pitchId = nil,
		predicted = nil,
		contact = nil,
		contactShown = false,
		missSoundPlayed = false,
		server = nil,
		labelShown = false,
	}

	-- Predict with the same deterministic code the server runs.
	local flight = PitchVisualController.getActiveFlight(lane)
	if flight and SwingResolver.overlapsFlight(swing, flight) and swungPitchId ~= flight.data.id then
		swungPitchId = flight.data.id
		entry.pitchId = flight.data.id
		local resolution = SwingResolver.resolve(geo, flight, swing)
		entry.predicted = resolution
		entry.contact = resolution.contact
		if resolution.contact then
			PitchVisualController.cutPitch(lane, flight.data.id, resolution.contact.contactTime)
			BattedBallController.predict(lane, flight.data.id, resolution.contact)
			BattingCamera.setContactLabel(lane, flight.data.id, resolution.contact.label)
		end
	end
	BattingDebugView.drawSwing(geo, swing, entry.predicted)

	table.insert(pending, entry)
	while #pending > MAX_PENDING do
		table.remove(pending, 1)
	end
	requestEvent:FireServer(seq, now, aimX, aimY, entry.pitchId, lane)
end

local function onSwingResult(payload: BattingNet.SwingResultPayload)
	if typeof(payload) ~= "table" or payload.userId ~= localPlayer.UserId then
		return
	end
	local entry = findPending(payload.seq)
	BattingDebugView.showResult(geometry, payload, entry and entry.predicted)
	if not entry then
		return
	end
	entry.server = payload
	local serverContact = payload.contact
	local predicted = entry.contact

	if serverContact and payload.pitchId then
		BattingCamera.setContactLabel(entry.laneId, payload.pitchId, serverContact.label)
	end
	if serverContact then
		if not entry.contactShown then
			-- Not shown yet: show the authoritative contact at its own time.
			entry.contact = serverContact
			if payload.pitchId then
				PitchVisualController.cutPitch(entry.laneId, payload.pitchId, serverContact.contactTime)
			end
		end
	elseif predicted then
		-- Predicted contact the server didn't grant: put the ball back if possible.
		entry.contact = nil
		if entry.pitchId then
			PitchVisualController.uncutPitch(entry.laneId, entry.pitchId)
		end
	end
	if entry.pitchId and (serverContact == nil or payload.hitId == nil) then
		-- No batted ball from the server for this swing: drop any predicted flight.
		BattedBallController.cancelPrediction(entry.laneId, entry.pitchId)
	end
	if payload.pitchId == nil then
		-- Practice swing or rejected: nothing to label.
		entry.pitchId = nil
	end
end

local function setActive(value: boolean)
	if active == value then
		return
	end
	active = value
	if not value then
		CharacterGrip.release()
	end
	BattingPresentation.setVisible(value)
end

local function refresh()
	local id = localPlayer:GetAttribute(PitchNet.PlayerLaneAttribute)
	local geo = if typeof(id) == "string" then PitchVisualController.getGeometry(id) else nil
	if typeof(id) == "string" and geo and localPlayer:GetAttribute("BattingMode") == "Batting" then
		local changed = geometry ~= geo
		laneId = id
		geometry = geo
		if changed then
			BattingPresentation.buildBat(SwingModel.dimensions(geo))
			table.clear(pending)
			currentSwing = nil
			readyPose = nil
			swingFromPose = nil
			aimInitialized = false
		end
		setActive(true)
	else
		laneId = nil
		geometry = nil
		table.clear(pending)
		currentSwing, readyPose, swingFromPose = nil, nil, nil
		aimInitialized, swungPitchId = false, nil
		setActive(false)
	end
end

function BattingController.isSwingReady(): boolean
	return currentSwing == nil or SwingModel.phaseAt(currentSwing, serverNow()) == "Ready"
end

function BattingController.setReadinessCheck(check: () -> boolean)
	readinessCheck = check
end

function BattingController.start()
	BattingPresentation.start()
	BattingPresentation.setVisible(false)

	local runtime = ReplicatedStorage:WaitForChild(BattingNet.RuntimeFolderName)
	requestEvent = runtime:WaitForChild(BattingNet.SwingRequestName) :: RemoteEvent
	local resultEvent = runtime:WaitForChild(BattingNet.SwingResultName) :: RemoteEvent
	resultEvent.OnClientEvent:Connect(onSwingResult)

	localPlayer:GetAttributeChangedSignal(PitchNet.PlayerLaneAttribute):Connect(refresh)
	localPlayer:GetAttributeChangedSignal("BattingMode"):Connect(refresh)
	PitchVisualController.onGeometry(function(changedLaneId)
		if changedLaneId == localPlayer:GetAttribute(PitchNet.PlayerLaneAttribute) then
			refresh()
		end
	end)
	refresh()

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			trySwing()
		end
	end)

	-- After the camera (Camera + 1) so rays use this frame's camera.
	RunService:BindToRenderStep(RENDER_BIND_NAME, Enum.RenderPriority.Camera.Value + 3, onRender)
end

return BattingController
