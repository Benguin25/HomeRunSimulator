--!strict
-- Client presentation of one batted ball: follows the deterministic flight
-- against the synchronized server clock, then rests at the first impact and
-- fades out.
--
-- Lives in Shared so the Studio test runner can exercise it; the client's
-- BattedBallController owns it and calls `update(serverNow)` from one render
-- binding (no per-ball connections).
--
-- Timeline (server time, t = serverNow - launchTime):
--   t < 0            : hidden (a predicted hit created at the click, before contact)
--   0 .. endTime     : exactly BattedBall.positionAt(flight, t). At t = 0 that is
--                      the ball center at contact, where the pitch playback was
--                      cut, so the ball continues without a snap.
--   after endTime    : held at the impact point, then faded and destroyed.
-- endTime is the server's first-impact time; until it is known (an
-- unconfirmed prediction) the ball flies to the end of the simulated flight.
--
-- Stage 4 visuals (cosmetic only): the trail grows with the ball's speed
-- (quantized, so properties change only a few times per flight), and a small
-- screen-space halo keeps the ball findable far from the camera.

local Pitching = script.Parent.Parent.Pitching
local BallVisual = require(Pitching.BallVisual)
local PitchConfig = require(Pitching.PitchConfig)

local HitPresentation = require(script.Parent.Parent.Presentation.HitPresentation)
local PresentationConfig = require(script.Parent.Parent.Presentation.PresentationConfig)

local BattedBall = require(script.Parent.BattedBall)
local BattedBallConfig = require(script.Parent.BattedBallConfig)
local FieldFrame = require(script.Parent.FieldFrame)
local FlightPhysics = require(script.Parent.FlightPhysics)

local BattedBallPlayback = {}
BattedBallPlayback.__index = BattedBallPlayback

export type BattedBallPlayback = typeof(setmetatable(
	{} :: {
		flight: BattedBall.Flight,
		ball: BallVisual.BallVisual?,
		endTime: number?, -- seconds after launch; nil = not known yet
		spinAxis: Vector3,
		spinRate: number, -- visual rad/s
		finished: boolean,
		trailLevel: number,
		halo: Frame?,
	},
	BattedBallPlayback
))

function BattedBallPlayback.new(flight: BattedBall.Flight, parent: Instance, endTime: number?): BattedBallPlayback
	local ballConfig = PitchConfig.Ball
	local diameter = ballConfig.RadiusMeters * 2 * flight.frame.studsPerMeter * ballConfig.VisualScale
	local spin = flight.launch.spin
	local worldSpin = FieldFrame.vectorToWorld(flight.frame, spin.X, spin.Y, spin.Z)
	local ball = BallVisual.new(diameter, parent)
	ball.model.Name = "BattedBall"
	ball.trail.Lifetime = BattedBallConfig.Display.TrailLifetime
	ball:setTransparency(1)

	local halo: Frame? = nil
	local flightCfg = PresentationConfig.Flight
	if flightCfg.HaloEnabled then
		local billboard = Instance.new("BillboardGui")
		billboard.Name = "Halo"
		billboard.Size = UDim2.fromOffset(flightCfg.HaloPixels, flightCfg.HaloPixels)
		billboard.LightInfluence = 0
		billboard.AlwaysOnTop = false
		local dot = Instance.new("Frame")
		dot.Size = UDim2.fromScale(1, 1)
		dot.BackgroundColor3 = Color3.new(1, 1, 1)
		dot.BackgroundTransparency = 1
		dot.BorderSizePixel = 0
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0.5, 0)
		corner.Parent = dot
		local stroke = Instance.new("UIStroke")
		stroke.Color = Color3.fromRGB(40, 40, 40)
		stroke.Transparency = 1
		stroke.Parent = dot
		dot.Parent = billboard
		billboard.Parent = ball.model.PrimaryPart
		halo = dot
	end

	return setmetatable({
		flight = flight,
		ball = ball,
		endTime = endTime,
		spinAxis = if worldSpin.Magnitude > 1e-6 then worldSpin.Unit else flight.frame.right,
		spinRate = worldSpin.Magnitude * BattedBallConfig.Display.VisualSpinScale,
		finished = false,
		trailLevel = -1,
		halo = halo,
	}, BattedBallPlayback)
end

local function setHalo(self: BattedBallPlayback, opacity: number)
	local halo = self.halo
	if halo then
		halo.BackgroundTransparency = 1 - opacity
		local stroke = halo:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Transparency = 1 - opacity * 0.6
		end
	end
end

-- Trail lifetime / opacity from the current speed (only when the level changes).
local function updateTrail(self: BattedBallPlayback, ball: BallVisual.BallVisual, t: number)
	local vx, vy, vz = FlightPhysics.sampleVelocity(self.flight.trajectory, t)
	local style = HitPresentation.trailStyle(math.sqrt(vx * vx + vy * vy + vz * vz))
	if style.level ~= self.trailLevel then
		self.trailLevel = style.level
		ball.trail.Lifetime = style.lifetime
		ball.trail.Transparency = NumberSequence.new(style.transparency, 1)
	end
end

function BattedBallPlayback.setEndTime(self: BattedBallPlayback, endTime: number)
	self.endTime = endTime
end

-- Returns false once the playback has finished and destroyed itself.
-- `cameraPosition` (optional) drives the distance halo.
function BattedBallPlayback.update(self: BattedBallPlayback, serverNow: number, cameraPosition: Vector3?): boolean
	local ball = self.ball
	if self.finished or ball == nil then
		return false
	end
	local t = serverNow - self.flight.launch.launchTime
	if t < 0 then
		ball:setTransparency(1)
		ball:setTrailEnabled(false)
		setHalo(self, 0)
		return true
	end

	local endTime = math.min(self.endTime or self.flight.trajectory.duration, self.flight.trajectory.duration)
	local flightTime = math.min(t, endTime)
	local position = BattedBall.positionAt(self.flight, flightTime)
	ball:setCFrame(CFrame.new(position) * CFrame.fromAxisAngle(self.spinAxis, self.spinRate * flightTime))
	local haloOpacity = if cameraPosition
		then HitPresentation.haloOpacity((cameraPosition - position).Magnitude * self.flight.frame.metersPerStud)
		else 0

	if t <= endTime then
		ball:setTransparency(0)
		updateTrail(self, ball, flightTime)
		ball:setTrailEnabled(true)
		setHalo(self, haloOpacity)
		return true
	end

	local display = BattedBallConfig.Display
	ball:setTrailEnabled(false)
	local after = t - endTime - display.LandedHoldSeconds
	if after < display.LandedFadeSeconds then
		local fade = math.clamp(after / display.LandedFadeSeconds, 0, 1)
		ball:setTransparency(fade)
		setHalo(self, haloOpacity * (1 - fade))
		return true
	end
	self:destroy()
	return false
end

function BattedBallPlayback.destroy(self: BattedBallPlayback)
	self.finished = true
	self.halo = nil
	if self.ball then
		self.ball:destroy()
		self.ball = nil
	end
end

return BattedBallPlayback
