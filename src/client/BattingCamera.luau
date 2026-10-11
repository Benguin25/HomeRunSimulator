--!strict
-- Fixed batting camera: behind and slightly above the plate, looking out at
-- the pitcher so the whole flight (release -> zone) stays in frame. Placement
-- is relative to the lane geometry (markers), never to world coordinates.
--
-- `setOffset` is the extension point for later effects (swing shake, aim
-- nudges) without touching the base framing.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Pitching = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Pitching")
local LaneGeometry = require(Pitching.LaneGeometry)
local PitchConfig = require(Pitching.PitchConfig)
local PitchNet = require(Pitching.PitchNet)

local PitchVisualController = require(script.Parent.PitchVisualController)

local BattingCamera = {}

local BIND_NAME = "PitchingBattingCamera"

local activeLaneId: string? = nil
local baseCFrame: CFrame? = nil
local blendFrom: CFrame? = nil
local blendStart = 0
local offset = CFrame.identity
local savedFieldOfView: number? = nil
local bound = false

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

local function onRender()
	local camera = Workspace.CurrentCamera
	local target = baseCFrame
	if not camera or not target then
		return
	end
	if camera.CameraType ~= Enum.CameraType.Scriptable then
		camera.CameraType = Enum.CameraType.Scriptable
	end
	local cframe = target
	local from = blendFrom
	if from then
		local alpha = math.clamp((os.clock() - blendStart) / PitchConfig.Camera.BlendInSeconds, 0, 1)
		alpha = 1 - (1 - alpha) ^ 3 -- ease out
		cframe = from:Lerp(target, alpha)
		if alpha >= 1 then
			blendFrom = nil
		end
	end
	camera.CFrame = cframe * offset
	camera.FieldOfView = PitchConfig.Camera.FieldOfView
end

local function activate(laneId: string)
	local geometry = PitchVisualController.getGeometry(laneId)
	local camera = Workspace.CurrentCamera
	if not geometry or not camera then
		return
	end
	activeLaneId = laneId
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
	local laneId = Players.LocalPlayer:GetAttribute(PitchNet.PlayerLaneAttribute)
	if typeof(laneId) == "string" then
		activate(laneId)
	else
		deactivate()
	end
end

function BattingCamera.start()
	Players.LocalPlayer:GetAttributeChangedSignal(PitchNet.PlayerLaneAttribute):Connect(refresh)
	PitchVisualController.onGeometry(function(laneId)
		if laneId == Players.LocalPlayer:GetAttribute(PitchNet.PlayerLaneAttribute) then
			activate(laneId)
		end
	end)
	refresh()
end

-- Additional transform applied on top of the base framing (shake, nudges).
function BattingCamera.setOffset(newOffset: CFrame)
	offset = newOffset
end

function BattingCamera.getActiveLaneId(): string?
	return activeLaneId
end

return BattingCamera
