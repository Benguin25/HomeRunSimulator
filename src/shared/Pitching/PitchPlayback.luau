--!strict
-- Client presentation of one pitch: windup cue, flight and catch.
--
-- Lives in Shared only so the Studio test runner can exercise it; it is used
-- by the client's PitchVisualController. It owns no connections: the
-- controller calls `update(serverNow)` from a single RenderStepped binding,
-- so the number of connections never grows with the number of pitches.
--
-- Timeline (server time):
--   windupTime .. releaseTime : ball appears in the pitcher's glove, then
--                               sweeps back and over the top into the release
--                               point (authored cue, not physics)
--   releaseTime .. +endTime   : ball follows the simulated trajectory exactly
--   afterwards                : brief hold + fade in the catcher's mitt

local BallVisual = require(script.Parent.BallVisual)
local LaneGeometry = require(script.Parent.LaneGeometry)
local Pitch = require(script.Parent.Pitch)
local PitchConfig = require(script.Parent.PitchConfig)
local PitchPhysics = require(script.Parent.PitchPhysics)

local PitchPlayback = {}
PitchPlayback.__index = PitchPlayback

local FADE_IN_START = 0.12 -- fraction of the windup
local FADE_IN_END = 0.3
local ARM_SWING_START = 0.55
local CATCH_HOLD_SECONDS = 0.18
local CATCH_FADE_SECONDS = 0.22
local RELEASE_FLASH_SECONDS = 0.14

export type PitchPlayback = typeof(setmetatable(
	{} :: {
		flight: Pitch.Flight,
		geometry: LaneGeometry.Geometry,
		ball: BallVisual.BallVisual?,
		flash: Part?,
		glovePoint: Vector3,
		cockedPoint: Vector3,
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
	local toPlate = -geometry.toPitcher
	local spin = flight.data.spin

	local self = setmetatable({
		flight = flight,
		geometry = geometry,
		ball = BallVisual.new(diameter, parent),
		flash = nil :: Part?,
		glovePoint = geometry.pitcherGround
			+ geometry.up * units.toStuds(1.3)
			+ toPlate * units.toStuds(0.35)
			- geometry.armSide * units.toStuds(0.1),
		cockedPoint = geometry.pitcherGround
			+ geometry.toPitcher * units.toStuds(0.6)
			+ geometry.up * units.toStuds(2.1)
			+ geometry.armSide * units.toStuds(0.8),
		spinAxis = if spin.Magnitude > 1e-6 then spin.Unit else geometry.right,
		spinRate = spin.Magnitude * ballConfig.VisualSpinRpmScale,
		finished = false,
		cutTime = math.huge,
	}, PitchPlayback)
	;(self.ball :: BallVisual.BallVisual):setTransparency(1)
	return self
end

local function windupPosition(self: PitchPlayback, u: number): Vector3
	local release = self.flight.data.releasePosition
	if u < ARM_SWING_START then
		-- Small settle/bob while "set" in the glove.
		return self.glovePoint + Vector3.new(0, math.sin(u * math.pi * 2) * 0.04, 0)
	end
	-- Quadratic Bezier glove -> over the shoulder -> release, accelerating
	-- into release so it hands off smoothly to the (fast) flight.
	local s = (u - ARM_SWING_START) / (1 - ARM_SWING_START)
	s = s * s
	local a = self.glovePoint:Lerp(self.cockedPoint, s)
	local b = self.cockedPoint:Lerp(release, s)
	return a:Lerp(b, s)
end

local function spawnFlash(self: PitchPlayback, parent: Instance)
	local flash = Instance.new("Part")
	flash.Name = "ReleaseFlash"
	flash.Shape = Enum.PartType.Ball
	flash.Material = Enum.Material.Neon
	flash.Color = Color3.new(1, 1, 1)
	flash.Anchored = true
	flash.CanCollide = false
	flash.CanTouch = false
	flash.CanQuery = false
	flash.CastShadow = false
	flash.Size = Vector3.one * 0.2
	flash.CFrame = CFrame.new(self.flight.data.releasePosition)
	flash.Parent = parent
	self.flash = flash
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
		local alpha = math.clamp((u - FADE_IN_START) / (FADE_IN_END - FADE_IN_START), 0, 1)
		ball:setTransparency(1 - alpha)
		-- The streak behind the ball during the arm swing is the "it's coming" cue.
		ball:setTrailEnabled(u >= ARM_SWING_START)
		ball:setCFrame(CFrame.new(windupPosition(self, u)))
		return true
	end

	-- Release cue: a quick expanding flash at the release point.
	local flash = self.flash
	if flash == nil and t < RELEASE_FLASH_SECONDS then
		spawnFlash(self, ball.model.Parent :: Instance)
		flash = self.flash
	end
	if flash then
		local f = t / RELEASE_FLASH_SECONDS
		if f >= 1 then
			flash:Destroy()
			self.flash = nil
		else
			flash.Size = Vector3.one * (0.2 + f * 1.4)
			flash.Transparency = 0.3 + 0.7 * f
		end
	end

	local endTime = self.flight.endTime
	local trajectory = self.flight.trajectory
	local flightTime = math.min(t, endTime)
	local position = PitchPhysics.sample(trajectory, flightTime)
	local rotation = CFrame.fromAxisAngle(self.spinAxis, self.spinRate * flightTime)
	ball:setCFrame(CFrame.new(position) * rotation)

	if t <= endTime then
		ball:setTransparency(0)
		ball:setTrailEnabled(true)
		return true
	end

	-- Caught: hold, then fade out.
	ball:setTrailEnabled(false)
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
	if self.flash then
		self.flash:Destroy()
		self.flash = nil
	end
end

return PitchPlayback
