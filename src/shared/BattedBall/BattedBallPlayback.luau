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

local Pitching = script.Parent.Parent.Pitching
local BallVisual = require(Pitching.BallVisual)
local PitchConfig = require(Pitching.PitchConfig)

local BattedBall = require(script.Parent.BattedBall)
local BattedBallConfig = require(script.Parent.BattedBallConfig)
local FieldFrame = require(script.Parent.FieldFrame)

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
	return setmetatable({
		flight = flight,
		ball = ball,
		endTime = endTime,
		spinAxis = if worldSpin.Magnitude > 1e-6 then worldSpin.Unit else flight.frame.right,
		spinRate = worldSpin.Magnitude * BattedBallConfig.Display.VisualSpinScale,
		finished = false,
	}, BattedBallPlayback)
end

function BattedBallPlayback.setEndTime(self: BattedBallPlayback, endTime: number)
	self.endTime = endTime
end

-- Returns false once the playback has finished and destroyed itself.
function BattedBallPlayback.update(self: BattedBallPlayback, serverNow: number): boolean
	local ball = self.ball
	if self.finished or ball == nil then
		return false
	end
	local t = serverNow - self.flight.launch.launchTime
	if t < 0 then
		ball:setTransparency(1)
		ball:setTrailEnabled(false)
		return true
	end

	local endTime = math.min(self.endTime or self.flight.trajectory.duration, self.flight.trajectory.duration)
	local flightTime = math.min(t, endTime)
	local position = BattedBall.positionAt(self.flight, flightTime)
	ball:setCFrame(CFrame.new(position) * CFrame.fromAxisAngle(self.spinAxis, self.spinRate * flightTime))

	if t <= endTime then
		ball:setTransparency(0)
		ball:setTrailEnabled(true)
		return true
	end

	local display = BattedBallConfig.Display
	ball:setTrailEnabled(false)
	local after = t - endTime - display.LandedHoldSeconds
	if after < display.LandedFadeSeconds then
		ball:setTransparency(math.clamp(after / display.LandedFadeSeconds, 0, 1))
		return true
	end
	self:destroy()
	return false
end

function BattedBallPlayback.destroy(self: BattedBallPlayback)
	self.finished = true
	if self.ball then
		self.ball:destroy()
		self.ball = nil
	end
end

return BattedBallPlayback
