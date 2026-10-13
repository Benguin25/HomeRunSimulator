--!strict
-- Client presentation of one pitch: windup cue, flight and catch.
--
-- Lives in Shared only so the Studio test runner can exercise it; it is used
-- by the client's PitchVisualController. It owns no connections: the
-- controller calls `update(serverNow)` from a single RenderStepped binding,
-- so the number of connections never grows with the number of pitches.
--
-- Timeline (server time):
--   windupTime .. releaseTime : hidden in the glove until the hands break,
--                               then held in the pitcher's throwing hand
--                               (PitcherMotion), which reaches the exact
--                               release point at the release time
--   releaseTime .. +endTime   : ball follows the simulated trajectory exactly
--   afterwards                : brief hold + fade in the catcher's mitt

local BallVisual = require(script.Parent.BallVisual)
local LaneGeometry = require(script.Parent.LaneGeometry)
local Pitch = require(script.Parent.Pitch)
local PitchConfig = require(script.Parent.PitchConfig)
local PitchPhysics = require(script.Parent.PitchPhysics)
local PitcherMotion = require(script.Parent.Parent.Presentation.PitcherMotion)

local PitchPlayback = {}
PitchPlayback.__index = PitchPlayback

local CATCH_HOLD_SECONDS = 0.18
local CATCH_FADE_SECONDS = 0.22

export type PitchPlayback = typeof(setmetatable(
	{} :: {
		flight: Pitch.Flight,
		geometry: LaneGeometry.Geometry,
		ball: BallVisual.BallVisual?,
		spinAxis: Vector3,
		spinRate: number, -- visual rad/s
		finished: boolean,
		cutTime: number, -- server time the ball disappears early (bat contact); math.huge = never
	},
	PitchPlayback
))

function PitchPlayback.new(geometry: LaneGeometry.Geometry, flight: Pitch.Flight, parent: Instance): PitchPlayback
	local units = geometry.units
	local ballConfig = PitchConfig.Ball
	local diameter = units.toStuds(ballConfig.RadiusMeters * 2) * ballConfig.VisualScale
	local spin = flight.data.spin

	local self = setmetatable({
		flight = flight,
		geometry = geometry,
		ball = BallVisual.new(diameter, parent),
		spinAxis = if spin.Magnitude > 1e-6 then spin.Unit else geometry.right,
		spinRate = spin.Magnitude * ballConfig.VisualSpinRpmScale,
		finished = false,
		cutTime = math.huge,
	}, PitchPlayback);
	(self.ball :: BallVisual.BallVisual):setTransparency(1)
	return self
end

-- Where the ball is held before release: the same pose the pitcher rig renders.
function PitchPlayback.heldPosition(self: PitchPlayback, serverNow: number): Vector3
	local data = self.flight.data
	return PitcherMotion.sample(self.geometry, data.windupTime, data.releaseTime, data.releasePosition, serverNow).hand
end

-- Soft ground shadow that fades in as the ball approaches the plate.
local function updateShadow(self: PitchPlayback, ball: BallVisual.BallVisual, position: Vector3)
	local geometry = self.geometry
	local cfg = PitchConfig.Ball
	local total = (geometry.releasePoint - geometry.plateGround):Dot(-geometry.toPitcher)
	local progress = if total > 1e-3 then 1 - (position - geometry.plateGround):Dot(geometry.toPitcher) / total else 0
	local start = cfg.ShadowStartFraction
	local opacity = cfg.ShadowMaxOpacity * math.clamp((progress - start) / math.max(1 - start, 1e-3) * 2, 0, 1)
	local ground = position - geometry.up * ((position - geometry.plateGround):Dot(geometry.up) - geometry.units.toStuds(0.01))
	ball:setShadow(ground, opacity)
end

-- Returns false once the playback has finished and destroyed itself.
function PitchPlayback.update(self: PitchPlayback, serverNow: number): boolean
	local ball = self.ball
	if self.finished or ball == nil then
		return false
	end
	if serverNow >= self.cutTime then
		self:destroy()
		return false
	end
	local data = self.flight.data
	local t = serverNow - data.releaseTime

	if t < 0 then
		local duration = math.max(data.releaseTime - data.windupTime, 1e-3)
		local u = math.clamp((serverNow - data.windupTime) / duration, 0, 1)
		ball:setTransparency(1 - PitcherMotion.ballAlpha(u))
		-- A short streak once the arm whips forward is the "here it comes" cue.
		ball:setTrailEnabled(PitcherMotion.trailOn(u))
		ball:setCFrame(CFrame.new(self:heldPosition(serverNow)))
		ball:setShadow(nil, 0)
		return true
	end

	local endTime = self.flight.endTime
	local trajectory = self.flight.trajectory
	local flightTime = math.min(t, endTime)
	local position = PitchPhysics.sample(trajectory, flightTime)
	local rotation = CFrame.fromAxisAngle(self.spinAxis, self.spinRate * flightTime)
	ball:setCFrame(CFrame.new(position) * rotation)

	if t <= endTime then
		updateShadow(self, ball, position)
		ball:setTransparency(0)
		ball:setTrailEnabled(true)
		return true
	end

	-- Caught: hold, then fade out.
	ball:setTrailEnabled(false)
	ball:setShadow(nil, 0)
	local after = t - endTime - CATCH_HOLD_SECONDS
	if after < CATCH_FADE_SECONDS then
		ball:setTransparency(math.clamp(after / CATCH_FADE_SECONDS, 0, 1))
		return true
	end

	self:destroy()
	return false
end

-- Ends the playback at a server time (the bat hit the ball). Earlier cuts win.
function PitchPlayback.cutAt(self: PitchPlayback, serverTime: number)
	self.cutTime = math.min(self.cutTime, serverTime)
end

-- Cancels a pending cut (a predicted contact the server did not confirm).
function PitchPlayback.clearCut(self: PitchPlayback)
	self.cutTime = math.huge
end

function PitchPlayback.destroy(self: PitchPlayback)
	self.finished = true
	if self.ball then
		self.ball:destroy()
		self.ball = nil
	end
end

return PitchPlayback
