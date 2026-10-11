--!strict
-- Pitch lifecycle state machine for one batting lane.
--
--   Idle -> Ready -> Windup -> Released -> Approaching -> Crossed
--        -> Finished -> Resetting -> Ready -> ...
--
-- Pure and clock-driven: the owner calls `update(now)` with the server clock
-- (any frequency, any frame time). Transitions after the windup happen at
-- their scheduled times computed from the pitch's trajectory, and several
-- transitions can be processed in one update if a frame was long, so a hitch
-- can never skip the crossing or start overlapping pitches. A lane holds at
-- most one pitch at a time; a new one is only created from Ready.

local PitchConfig = require(script.Parent.PitchConfig)
local Pitch = require(script.Parent.Pitch)

local PitchLane = {}
PitchLane.__index = PitchLane

export type State = "Idle" | "Ready" | "Windup" | "Released" | "Approaching" | "Crossed" | "Finished" | "Resetting"

export type ActivePitch = {
	data: Pitch.PitchData,
	flight: Pitch.Flight,
}

export type Hooks = {
	-- Must return the pitch to throw (windup starts at `windupTime`), or nil to skip this cycle.
	createPitch: (lane: PitchLane, id: number, windupTime: number, releaseTime: number) -> ActivePitch?,
	onStateChanged: ((lane: PitchLane, state: State, now: number) -> ())?,
	onPitchStarted: ((lane: PitchLane, pitch: ActivePitch) -> ())?,
	onPitchCrossed: ((lane: PitchLane, pitch: ActivePitch) -> ())?,
	onPitchFinished: ((lane: PitchLane, pitch: ActivePitch) -> ())?,
	onPitchAborted: ((lane: PitchLane, pitch: ActivePitch, reason: string) -> ())?,
}

export type Timing = PitchConfig.Timing

export type PitchLane = typeof(setmetatable(
	{} :: {
		id: string,
		state: State,
		hooks: Hooks,
		timing: Timing,
		paused: boolean,
		pitch: ActivePitch?,
		nextTransitionTime: number,
		nextPitchId: number,
		pitchesStarted: number,
		pitchesFinished: number,
		pitchesAborted: number,
	},
	PitchLane
))

local MAX_TRANSITIONS_PER_UPDATE = 32

function PitchLane.new(id: string, hooks: Hooks, timing: Timing?): PitchLane
	local self = setmetatable({
		id = id,
		state = "Idle" :: State,
		hooks = hooks,
		timing = timing or PitchConfig.Timing,
		paused = false,
		pitch = nil :: ActivePitch?,
		nextTransitionTime = math.huge,
		nextPitchId = 1,
		pitchesStarted = 0,
		pitchesFinished = 0,
		pitchesAborted = 0,
	}, PitchLane)
	return self
end

function PitchLane._setState(self: PitchLane, state: State, now: number)
	self.state = state
	local hook = self.hooks.onStateChanged
	if hook then
		hook(self, state, now)
	end
end

-- Begin pitching (e.g. a batter was assigned). The first windup starts after `delay`.
function PitchLane.start(self: PitchLane, now: number, delay: number?)
	if self.state ~= "Idle" then
		return
	end
	self.nextTransitionTime = now + (delay or self.timing.FirstPitchDelaySeconds)
	self:_setState("Ready", now)
end

-- Stop pitching entirely (batter left/died). Any in-flight pitch is aborted.
function PitchLane.stop(self: PitchLane, now: number, reason: string)
	self:abortPitch(now, reason)
	self.nextTransitionTime = math.huge
	if self.state ~= "Idle" then
		self:_setState("Idle", now)
	end
end

-- While paused no new windup begins; a pitch already in progress completes
-- normally. On resume, the windup starts as soon as the Ready time has elapsed.
function PitchLane.setPaused(self: PitchLane, paused: boolean)
	self.paused = paused
end

-- Ends the current pitch immediately (player reset, future batting contact).
-- Returns true if a pitch was aborted.
function PitchLane.abortPitch(self: PitchLane, now: number, reason: string): boolean
	local pitch = self.pitch
	if pitch == nil then
		return false
	end
	self.pitch = nil
	self.pitchesAborted += 1
	local hook = self.hooks.onPitchAborted
	if hook then
		hook(self, pitch, reason)
	end
	if self.state ~= "Idle" then
		self.nextTransitionTime = now + self.timing.ResetSeconds
		self:_setState("Resetting", now)
	end
	return true
end

function PitchLane.hasActivePitch(self: PitchLane): boolean
	return self.pitch ~= nil
end

-- Server time at which the active pitch crosses the zone plane, if it does.
function PitchLane.getCrossServerTime(self: PitchLane): number?
	local pitch = self.pitch
	if pitch and pitch.flight.crossTime then
		return pitch.data.releaseTime + pitch.flight.crossTime
	end
	return nil
end

-- Performs one due transition. Returns false when nothing is due.
function PitchLane._advance(self: PitchLane, now: number): boolean
	local state = self.state
	if state == "Idle" or now < self.nextTransitionTime then
		return false
	end
	local due = self.nextTransitionTime

	if state == "Ready" then
		if self.paused or self.pitch ~= nil then
			return false
		end
		-- Use the actual decision time so a late update never back-dates a windup.
		local windupTime = now
		local releaseTime = windupTime + self.timing.WindupSeconds
		local id = self.nextPitchId
		self.nextPitchId += 1
		local pitch = self.hooks.createPitch(self, id, windupTime, releaseTime)
		if pitch == nil then
			self.nextTransitionTime = now + self.timing.ResetSeconds
			return false
		end
		self.pitch = pitch
		self.pitchesStarted += 1
		self.nextTransitionTime = releaseTime
		self:_setState("Windup", now)
		local hook = self.hooks.onPitchStarted
		if hook then
			hook(self, pitch)
		end
	elseif state == "Windup" then
		self:_setState("Released", due)
		-- Released is instantaneous; the ball is now approaching the plate.
		local pitch = self.pitch :: ActivePitch
		local crossTime = self:getCrossServerTime()
		self.nextTransitionTime = crossTime or (pitch.data.releaseTime + pitch.flight.endTime)
		self:_setState("Approaching", due)
	elseif state == "Approaching" then
		local pitch = self.pitch :: ActivePitch
		if pitch.flight.crossTime then
			self.nextTransitionTime = pitch.data.releaseTime + pitch.flight.endTime
			self:_setState("Crossed", due)
			local hook = self.hooks.onPitchCrossed
			if hook then
				hook(self, pitch)
			end
		else
			-- Never reached the plate (e.g. bounced); finish without a crossing.
			self.nextTransitionTime = due
			self:_setState("Crossed", due)
		end
	elseif state == "Crossed" then
		local pitch = self.pitch :: ActivePitch
		self.pitch = nil
		self.pitchesFinished += 1
		self:_setState("Finished", due)
		local hook = self.hooks.onPitchFinished
		if hook then
			hook(self, pitch)
		end
		self.nextTransitionTime = due + self.timing.ResetSeconds
		self:_setState("Resetting", due)
	elseif state == "Resetting" then
		self.nextTransitionTime = due + self.timing.ReadySeconds
		self:_setState("Ready", due)
	else
		return false
	end
	return true
end

function PitchLane.update(self: PitchLane, now: number)
	for _ = 1, MAX_TRANSITIONS_PER_UPDATE do
		if not self:_advance(now) then
			return
		end
	end
end

return PitchLane
