--!strict
-- The only script that writes Workspace.CurrentCamera while batting.
--
-- Base framing: behind and slightly above the plate, looking out at the
-- pitcher so the whole pitch (release -> zone) stays in frame. Placement is
-- relative to the lane geometry (markers), never to world coordinates.
--
-- Hits (Stage 4): a CameraDirector (shared, pure) runs the
-- Batting -> ContactTransition -> BallFollow -> Landing -> Returning cycle
-- from the deterministic flight; this module feeds it the batting framing,
-- applies its pose, and keeps the follow camera out of walls with one
-- raycast per frame. BattedBallController reports hit events here; nothing
-- camera-related is ever networked.
--
-- `setOffset` is the extension point for small effects (nudges) on top of
-- whatever pose is shown.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Pitching = Shared:WaitForChild("Pitching")
local LaneGeometry = require(Pitching.LaneGeometry)
local PitchConfig = require(Pitching.PitchConfig)
local PitchNet = require(Pitching.PitchNet)
local BattedBallConfig = require(Shared:WaitForChild("BattedBall"):WaitForChild("BattedBallConfig"))
local LandingDetector = require(Shared.BattedBall.LandingDetector)
local Presentation = Shared:WaitForChild("Presentation")
local CameraDirector = require(Presentation.CameraDirector)
local CameraMath = require(Presentation.CameraMath)
local PresentationConfig = require(Presentation.PresentationConfig)

local PitchVisualController = require(script.Parent.PitchVisualController)

local BattingCamera = {}

local BIND_NAME = "PitchingBattingCamera"

local localPlayer = Players.LocalPlayer
local director = CameraDirector.new()
local activeLaneId: string? = nil
local baseCFrame: CFrame? = nil
local blendFrom: CFrame? = nil
local blendStart = 0
local offset = CFrame.identity
local savedFieldOfView: number? = nil
local bound = false
local occlusionDistance = math.huge
local occlusionParams: RaycastParams? = nil
local lastFocus: Vector3? = nil

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

function BattingCamera.computeCFrame(geometry: LaneGeometry.Geometry): CFrame
	local cfg = PitchConfig.Camera
	local units = geometry.units
	-- Right-handed batters stand on the catcher's left (-right).
	local batterSign = if PitchConfig.Geometry.BatterSide == "Left" then 1 else -1
	local position = geometry.plateGround
		- geometry.toPitcher * units.toStuds(cfg.BackMeters)
		+ geometry.up * units.toStuds(cfg.HeightMeters)
		+ geometry.right * (batterSign * units.toStuds(cfg.SideMeters))
	local lookAt = geometry.zoneCenter:Lerp(geometry.releasePoint, cfg.LookFraction)
		+ geometry.up * units.toStuds(cfg.LookRaiseMeters)
	return CFrame.lookAt(position, lookAt)
end

-- Everything the follow camera may look through: characters and our own visuals.
local function buildOcclusionParams(): RaycastParams
	local exclude: { Instance } = {}
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(exclude, player.Character)
		end
	end
	for _, name in BattedBallConfig.Collision.IgnoreWorkspaceChildren do
		local child = Workspace:FindFirstChild(name)
		if child then
			table.insert(exclude, child)
		end
	end
	for _, name in { "HitEffects" } do
		local child = Workspace:FindFirstChild(name)
		if child then
			table.insert(exclude, child)
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = exclude
	params.RespectCanCollide = true
	return params
end

-- Pulls the camera toward the ball when stadium geometry is in between.
local function avoidOcclusion(pose: CameraMath.Pose, focus: Vector3?, dt: number): CameraMath.Pose
	local cfg = PresentationConfig.Camera
	if not cfg.AvoidOcclusion or focus == nil then
		occlusionDistance = math.huge
		return pose
	end
	local toCamera = pose.position - focus
	local desired = toCamera.Magnitude
	if desired < 1e-3 then
		return pose
	end
	local params = occlusionParams or buildOcclusionParams()
	occlusionParams = params
	local result = Workspace:Raycast(focus, toCamera, params)
	local blocked: number? = nil
	if result then
		local units = PitchConfig.Units
		blocked = math.max(0, result.Distance - cfg.OcclusionPaddingMeters / units.MetersPerStud)
	end
	if occlusionDistance == math.huge then
		occlusionDistance = desired
	end
	occlusionDistance = CameraMath.stepOcclusion(occlusionDistance, desired, blocked, dt)
	if occlusionDistance >= desired - 1e-4 then
		return pose
	end
	return {
		position = focus + toCamera.Unit * occlusionDistance,
		yaw = pose.yaw,
		pitch = pose.pitch,
		fov = pose.fov,
	}
end

local function battingCFrame(target: CFrame): CFrame
	local from = blendFrom
	if from == nil then
		return target
	end
	local alpha = math.clamp((os.clock() - blendStart) / PitchConfig.Camera.BlendInSeconds, 0, 1)
	if alpha >= 1 then
		blendFrom = nil
	end
	return from:Lerp(target, CameraMath.easeOutCubic(alpha))
end

local function onRender(dt: number)
	local camera = Workspace.CurrentCamera
	local target = baseCFrame
	if not camera or not target then
		return
	end
	if camera.CameraType ~= Enum.CameraType.Scriptable then
		camera.CameraType = Enum.CameraType.Scriptable
	end
	local batting = CameraMath.poseFromCFrame(battingCFrame(target), PitchConfig.Camera.FieldOfView)
	local wasBatting = director:isBattingView()
	local pose = director:update(serverNow(), dt, batting)
	if wasBatting and not director:isBattingView() then
		-- A hit just started: refresh the exclusion list and start unoccluded.
		occlusionParams = buildOcclusionParams()
		occlusionDistance = math.huge
	end
	local focus = director.debug.focus
	lastFocus = focus
	pose = avoidOcclusion(pose, focus, dt)
	camera.CFrame = CameraMath.toCFrame(pose) * offset
	camera.FieldOfView = pose.fov
end

local function activate(laneId: string)
	local geometry = PitchVisualController.getGeometry(laneId)
	local camera = Workspace.CurrentCamera
	if not geometry or not camera then
		return
	end
	if activeLaneId ~= laneId then
		director:reset("lane assigned")
	end
	activeLaneId = laneId
	director:setLane(laneId)
	baseCFrame = BattingCamera.computeCFrame(geometry)
	if not bound then
		savedFieldOfView = camera.FieldOfView
		blendFrom = camera.CFrame
		blendStart = os.clock()
		RunService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Camera.Value + 1, onRender)
		bound = true
	end
end

local function deactivate()
	activeLaneId = nil
	baseCFrame = nil
	director:reset("left the lane")
	director:setLane(nil)
	if bound then
		RunService:UnbindFromRenderStep(BIND_NAME)
		bound = false
		local camera = Workspace.CurrentCamera
		if camera then
			camera.CameraType = Enum.CameraType.Custom
			camera.FieldOfView = savedFieldOfView or 70
		end
	end
end

local function refresh()
	local laneId = localPlayer:GetAttribute(PitchNet.PlayerLaneAttribute)
	if typeof(laneId) == "string" then
		activate(laneId)
	else
		deactivate()
	end
end

function BattingCamera.start()
	localPlayer:GetAttributeChangedSignal(PitchNet.PlayerLaneAttribute):Connect(refresh)
	PitchVisualController.onGeometry(function(laneId)
		if laneId == localPlayer:GetAttribute(PitchNet.PlayerLaneAttribute) then
			activate(laneId)
		end
	end)
	-- A respawn mid-flight must not strand the camera away from the batter.
	localPlayer.CharacterAdded:Connect(function()
		director:cancel(serverNow(), nil, nil, "respawned")
		occlusionParams = nil
	end)
	refresh()
end

-- Additional transform applied on top of the shown pose (nudges).
function BattingCamera.setOffset(newOffset: CFrame)
	offset = newOffset
end

function BattingCamera.getActiveLaneId(): string?
	return activeLaneId
end

---------------------------------------------------------------------------
-- Hit events (from BattedBallController / BattingController, own lane only)
---------------------------------------------------------------------------

-- Ignored unless the hit is on the lane this client is batting in.
function BattingCamera.beginHit(input: CameraDirector.HitInput)
	director:begin(serverNow(), input)
end

function BattingCamera.confirmHit(laneId: string, pitchId: number, endTime: number)
	director:confirm(laneId, pitchId, endTime)
end

function BattingCamera.resolveHit(laneId: string, pitchId: number, outcome: LandingDetector.OutcomePayload)
	director:resolve(laneId, pitchId, outcome)
end

function BattingCamera.cancelHit(laneId: string, pitchId: number, reason: string)
	director:cancel(serverNow(), laneId, pitchId, reason)
end

function BattingCamera.setContactLabel(laneId: string, pitchId: number, label: string)
	director:setContactLabel(laneId, pitchId, label)
end

function BattingCamera.addImpulse(intensity: number)
	director:addImpulse(serverNow(), intensity)
end

---------------------------------------------------------------------------
-- Queries (HUD, batting input, debug)
---------------------------------------------------------------------------

function BattingCamera.getDirector(): CameraDirector.CameraDirector
	return director
end

function BattingCamera.getHit(): CameraDirector.Hit?
	return director:getHit()
end

-- Swings are only accepted while the camera shows the batting framing.
function BattingCamera.isBattingView(): boolean
	return director:isBattingView()
end

-- The aim HUD is shown while batting and over the last part of the return.
function BattingCamera.isAimVisible(): boolean
	if director:isBattingView() then
		return true
	end
	return director:getState() == "Returning"
		and director:returnProgress(serverNow()) >= PresentationConfig.Hud.AimHudReturnFraction
end

function BattingCamera.getFocus(): Vector3?
	return lastFocus
end

function BattingCamera.getOcclusionDistance(): number
	return occlusionDistance
end

return BattingCamera
