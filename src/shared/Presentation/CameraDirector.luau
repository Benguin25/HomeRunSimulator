--!strict
-- The hit camera's state machine (pure: no services, no Instances).
--
--   Batting -> ContactTransition -> BallFollow -> Landing -> Returning -> Batting
--      ^              |                  |            |
--      +--------------+------------------+------------+-- cancel: Returning from wherever it is
--
-- The client's BattingCamera owns one director and feeds it the batting
-- framing every frame; the director returns the pose to render. It is driven
-- by the synchronized server clock (`now`) for its timeline, so the flight,
-- landing and return line up with the server's lifecycle, and by the render
-- `dt` only for smoothing.
--
-- The camera target is the deterministic flight itself (BattedBall.positionAt
-- at the same server time the ball is drawn), never a Part, so it cannot lose
-- its target: rejected predictions return to the batter, server corrections
-- swap the flight under the smoothed offsets, and a watchdog ends any hit
-- presentation that runs too long.
--
-- Lane isolation: the director only accepts hits launched on its lane
-- (`setLane`), and every later event is keyed by (laneId, pitchId), since
-- pitch ids are per-lane counters.

local Shared = script.Parent.Parent
local BattedBall = require(Shared.BattedBall.BattedBall)
local FieldFrame = require(Shared.BattedBall.FieldFrame)
local FlightPhysics = require(Shared.BattedBall.FlightPhysics)
local LandingDetector = require(Shared.BattedBall.LandingDetector)

local CameraMath = require(script.Parent.CameraMath)
local PresentationConfig = require(script.Parent.PresentationConfig)

local CameraDirector = {}
CameraDirector.__index = CameraDirector

export type State = "Batting" | "ContactTransition" | "BallFollow" | "Landing" | "Returning"

export type Hit = {
	laneId: string,
	pitchId: number,
	flight: BattedBall.Flight,
	endTime: number?, -- s after launch when the flight stops; nil = not known yet (prediction)
	confirmed: boolean, -- the server launched this record
	outcome: LandingDetector.OutcomePayload?,
	contactLabel: string?,
	profile: CameraMath.Profile,
	power: number,
}

export type HitInput = {
	pitchId: number,
	flight: BattedBall.Flight,
	endTime: number?,
	confirmed: boolean,
}

export type Debug = {
	focus: Vector3?,
	desiredOffset: Vector3?,
	smoothingErrorMeters: number,
	ballTime: number,
}

export type CameraDirector = typeof(setmetatable(
	{} :: {
		laneId: string?, -- the only lane whose hits are presented
		state: State,
		stateStart: number, -- server time the current state began
		hit: Hit?,
		returningHit: Hit?,
		fromPose: CameraMath.Pose?,
		lastPose: CameraMath.Pose?,
		heading: Vector3,
		offset: CameraMath.Spring,
		look: CameraMath.Spring,
		fov: CameraMath.ScalarSpring,
		landedAt: number?,
		impulseStart: number,
		impulseIntensity: number,
		corrections: number,
		transitions: number,
		lastEvent: string,
		debug: Debug,
	},
	CameraDirector
))

function CameraDirector.new(): CameraDirector
	return setmetatable({
		laneId = nil :: string?,
		state = "Batting" :: State,
		stateStart = 0,
		hit = nil :: Hit?,
		returningHit = nil :: Hit?,
		fromPose = nil :: CameraMath.Pose?,
		lastPose = nil :: CameraMath.Pose?,
		heading = Vector3.new(0, 0, -1),
		offset = { value = Vector3.zero, velocity = Vector3.zero },
		look = { value = Vector3.zero, velocity = Vector3.zero },
		fov = { value = 70, velocity = 0 },
		landedAt = nil :: number?,
		impulseStart = -math.huge,
		impulseIntensity = 0,
		corrections = 0,
		transitions = 0,
		lastEvent = "none",
		debug = { focus = nil, desiredOffset = nil, smoothingErrorMeters = 0, ballTime = 0 },
	}, CameraDirector)
end

local function makeHit(input: HitInput): Hit
	local flight = input.flight
	return {
		laneId = flight.launch.laneId,
		pitchId = input.pitchId,
		flight = flight,
		endTime = input.endTime,
		confirmed = input.confirmed,
		outcome = nil,
		contactLabel = nil,
		profile = CameraMath.profileFor(flight.launchAngleDegrees),
		power = CameraMath.powerFactor(flight.exitSpeedMph),
	}
end

-- Seconds after launch at which the ball stops (first impact, or end of simulation).
function CameraDirector.endTimeOf(hit: Hit): number
	local duration = hit.flight.trajectory.duration
	return math.min(hit.endTime or duration, duration)
end

local function setState(self: CameraDirector, state: State, at: number, event: string)
	self.state = state
	self.stateStart = at
	self.transitions += 1
	self.lastEvent = event
end

local function matches(hit: Hit?, laneId: string, pitchId: number?): boolean
	return hit ~= nil and hit.laneId == laneId and (pitchId == nil or hit.pitchId == pitchId)
end

-- Sets the lane whose hits this director presents (nil = none).
function CameraDirector.setLane(self: CameraDirector, laneId: string?)
	self.laneId = laneId
end

function CameraDirector.getState(self: CameraDirector): State
	return self.state
end

-- True while the camera shows the batting framing (aim and swings make sense).
function CameraDirector.isBattingView(self: CameraDirector): boolean
	return self.state == "Batting"
end

-- The hit being presented (or about to be), if any.
function CameraDirector.getHit(self: CameraDirector): Hit?
	return self.hit or self.returningHit
end

-- Starts presenting a hit, or swaps the flight of the one being presented
-- (server correction of a prediction). The camera only leaves the batter at
-- the contact time (launchTime), not when the click is predicted. Returns false if the hit is
-- not on this director's lane.
function CameraDirector.begin(self: CameraDirector, now: number, input: HitInput): boolean
	local laneId = input.flight.launch.laneId
	if self.laneId == nil or laneId ~= self.laneId then
		return false
	end
	local current = self.hit
	if current and matches(current, laneId, input.pitchId) and self.state ~= "Returning" then
		local changed = not BattedBall.sameLaunch(current.flight.launch, input.flight.launch)
		local replacement = makeHit(input)
		replacement.outcome = current.outcome
		replacement.contactLabel = current.contactLabel
		self.hit = replacement
		if changed then
			self.corrections += 1
			self.lastEvent = "corrected by server"
		end
		return true
	end
	local state: State = self.state
	self.hit = makeHit(input)
	self.lastEvent = if state == "Returning" then "new hit while returning" else "hit pending contact"
	if state == "ContactTransition" or state == "BallFollow" or state == "Landing" then
		-- A different pitch while a hit is still on screen: restart from here.
		self.fromPose = self.lastPose
		setState(self, "Returning", now, "new hit replaced the old one")
		self.returningHit = nil
	end
	return true
end

-- The server launched the predicted record unchanged.
function CameraDirector.confirm(self: CameraDirector, laneId: string, pitchId: number, endTime: number)
	local hit = self.hit
	if hit and matches(hit, laneId, pitchId) then
		hit.endTime = endTime
		hit.confirmed = true
	end
end

-- The server's measured outcome (first impact).
function CameraDirector.resolve(self: CameraDirector, laneId: string, pitchId: number, outcome: LandingDetector.OutcomePayload)
	local hit = self.hit
	if hit and matches(hit, laneId, pitchId) then
		hit.outcome = outcome
		hit.endTime = outcome.endTime
		hit.confirmed = true
	end
end

function CameraDirector.setContactLabel(self: CameraDirector, laneId: string, pitchId: number, label: string)
	local hit = self.hit
	if hit and matches(hit, laneId, pitchId) then
		hit.contactLabel = label
	end
end

local function startReturn(self: CameraDirector, at: number, event: string)
	self.fromPose = self.lastPose
	self.returningHit = self.hit
	self.hit = nil
	setState(self, "Returning", at, event)
end

-- Presentation-only skip. Requires a confirmed result; never changes a flight
-- or outcome. Duplicate approvals during a return do not restart its blend.
function CameraDirector.skipResult(self: CameraDirector, now: number, laneId: string, pitchId: number): boolean
	local hit = self.hit
	if not hit or not matches(hit, laneId, pitchId) or not hit.confirmed or hit.outcome == nil
		or self.state ~= "Landing" then return false end
	startReturn(self, now, "result skipped")
	return true
end

-- Drops the hit (prediction rejected, hit cancelled). `laneId` nil = whatever
-- is presented (respawn). Before contact nothing visible happens; after it
-- the camera returns.
function CameraDirector.cancel(self: CameraDirector, now: number, laneId: string?, pitchId: number?, reason: string)
	local hit = self.hit
	if hit == nil or (laneId ~= nil and not matches(hit, laneId, pitchId)) then
		return
	end
	if self.state == "Batting" or self.state == "Returning" then
		self.hit = nil
		self.lastEvent = `cancelled before contact ({reason})`
		return
	end
	startReturn(self, now, `cancelled ({reason})`)
end

-- Hard reset (session ended, lane changed): back to batting immediately.
function CameraDirector.reset(self: CameraDirector, reason: string)
	self.hit = nil
	self.returningHit = nil
	self.fromPose = nil
	self.landedAt = nil
	self.impulseStart = -math.huge
	setState(self, "Batting", 0, `reset ({reason})`)
end

-- Camera impulse for strong contact (see CameraMath.impulse).
function CameraDirector.addImpulse(self: CameraDirector, now: number, intensity: number)
	self.impulseStart = now
	self.impulseIntensity = intensity
end

local function sampleVelocity(flight: BattedBall.Flight, t: number): Vector3
	local vx, vy, vz = FlightPhysics.sampleVelocity(flight.trajectory, t)
	return FieldFrame.vectorToWorld(flight.frame, vx, vy, vz) * flight.frame.studsPerMeter
end

local function sideSign(frame: FieldFrame.Frame): number
	-- Same side as the batting camera (catcher's left for a right-handed batter).
	return if frame.batterSide == "Left" then 1 else -1
end

local function followInput(hit: Hit, now: number, heading: Vector3): (CameraMath.FollowInput, number)
	local flight = hit.flight
	local frame = flight.frame
	local launch = flight.launch
	local endTime = CameraDirector.endTimeOf(hit)
	local elapsed = now - launch.launchTime
	local t = math.clamp(elapsed, 0, endTime)
	local ball = BattedBall.positionAt(flight, t)
	local lagged = BattedBall.positionAt(flight, math.clamp(elapsed - hit.profile.LagSeconds, 0, endTime))
	local maxLag = PresentationConfig.Camera.MaxLagMeters * frame.studsPerMeter
	if (lagged - ball).Magnitude > maxLag then
		lagged = ball + (lagged - ball).Unit * maxLag
	end
	local landing = elapsed >= endTime
	return {
		ball = ball,
		lagged = lagged,
		velocity = if landing then Vector3.zero else sampleVelocity(flight, t),
		heading = heading,
		launchHeight = launch.position.Y,
		fieldHeight = frame.origin.Y,
		studsPerMeter = frame.studsPerMeter,
		sideSign = sideSign(frame),
		profile = hit.profile,
		power = hit.power,
		landing = landing,
	},
		t
end

local function initialHeading(hit: Hit): Vector3
	local flight = hit.flight
	local v = sampleVelocity(flight, 0)
	local horizontal = Vector3.new(v.X, 0, v.Z)
	if horizontal.Magnitude * flight.frame.metersPerStud >= PresentationConfig.Camera.MinHeadingSpeedMps then
		return horizontal.Unit
	end
	local forward = flight.frame.forward
	return Vector3.new(forward.X, 0, forward.Z).Unit
end

-- Places the follow springs on their targets so the follow pose starts settled.
local function initFollow(self: CameraDirector, hit: Hit, now: number)
	self.heading = initialHeading(hit)
	local input = followInput(hit, now, self.heading)
	local target = CameraMath.followTarget(input)
	self.offset.value, self.offset.velocity = target.offset, Vector3.zero
	self.look.value, self.look.velocity = target.lookOffset, Vector3.zero
	self.fov.value, self.fov.velocity = target.fov, 0
end

local function stepFollow(self: CameraDirector, hit: Hit, now: number, dt: number): CameraMath.Pose
	local cfg = PresentationConfig.Camera
	local mps = hit.flight.frame.metersPerStud
	local input, t = followInput(hit, now, self.heading)
	self.heading = CameraMath.stepHeading(self.heading, input.velocity, mps, dt)
	input.heading = self.heading
	local target = CameraMath.followTarget(input)
	CameraMath.springStep(self.offset, target.offset, cfg.OffsetSmoothSeconds, dt)
	CameraMath.springStep(self.look, target.lookOffset, cfg.LookSmoothSeconds, dt)
	CameraMath.scalarSpringStep(self.fov, target.fov, cfg.FovSmoothSeconds, dt)

	local ball = input.ball
	local position = ball + self.offset.value
	local debug = self.debug
	debug.focus = ball
	debug.desiredOffset = target.offset
	debug.smoothingErrorMeters = (target.offset - self.offset.value).Magnitude * mps
	debug.ballTime = t
	return CameraMath.lookPose(position, ball + self.look.value, self.fov.value)
end

local function withImpulse(self: CameraDirector, pose: CameraMath.Pose, now: number): CameraMath.Pose
	local dp, dy, dfov = CameraMath.impulse(self.impulseIntensity, now - self.impulseStart)
	if dp == 0 and dy == 0 and dfov == 0 then
		return pose
	end
	return { position = pose.position, yaw = pose.yaw + dy, pitch = pose.pitch + dp, fov = pose.fov + dfov }
end

-- Advances the camera and returns the pose to render this frame.
function CameraDirector.update(self: CameraDirector, now: number, dt: number, batting: CameraMath.Pose): CameraMath.Pose
	local timing = PresentationConfig.Timing
	dt = math.clamp(dt, 0, 0.1) -- a long hitch must not fling the springs
	local pose = batting
	self.debug.focus = nil

	local hit = self.hit
	if self.state == "Batting" and hit and now >= hit.flight.launch.launchTime then
		self.fromPose = self.lastPose or batting
		initFollow(self, hit, now)
		setState(self, "ContactTransition", hit.flight.launch.launchTime, "contact")
	end

	hit = self.hit
	if hit and (self.state == "ContactTransition" or self.state == "BallFollow" or self.state == "Landing") then
		local launchTime = hit.flight.launch.launchTime
		if now - launchTime > timing.MaxHitSeconds then
			startReturn(self, now, "watchdog")
		else
			local follow = stepFollow(self, hit, now, dt)
			-- The blend out of the batting framing runs on its own clock, so a
			-- ball that lands during it (a short grounder) never cuts it short.
			local blendStart = launchTime + timing.ContactHoldSeconds
			local a = (now - blendStart) / math.max(timing.ContactTransitionSeconds, 1e-6)
			pose = if a >= 1 then follow else CameraMath.blendPoses(self.fromPose or batting, follow, CameraMath.easeInOutCubic(a))

			local landTime = launchTime + CameraDirector.endTimeOf(hit)
			if self.state ~= "Landing" and now >= landTime then
				self.landedAt = landTime
				setState(self, "Landing", landTime, "first impact")
			elseif self.state == "ContactTransition" and a >= 1 then
				setState(self, "BallFollow", blendStart + timing.ContactTransitionSeconds, "following")
			end

			if self.state == "Landing" and a >= 1 then
				local holdEnd = (self.landedAt or now) + timing.LandingHoldSeconds
				if now >= holdEnd and (hit.outcome ~= nil or now >= holdEnd + timing.OutcomeGraceSeconds) then
					self.lastPose = pose
					startReturn(self, math.max(holdEnd, now - dt), "landing hold over")
				end
			end
		end
	end

	if self.state == "Returning" then
		local from = self.fromPose or batting
		local a = (now - self.stateStart) / math.max(timing.ReturnSeconds, 1e-6)
		if a >= 1 then
			self.returningHit = nil
			self.fromPose = nil
			setState(self, "Batting", now, "back at the plate")
			pose = batting
			-- A hit that began during the return starts its transition next frame.
		else
			local distanceMeters = (from.position - batting.position).Magnitude
			local scale = 1
			local presented = self.returningHit
			if presented then
				scale = presented.flight.frame.metersPerStud
			end
			local meters = distanceMeters * scale
			local arcMeters = math.min(timing.ReturnArcMaxMeters, meters / 100 * timing.ReturnArcMetersPer100)
			pose = CameraMath.blendPoses(from, batting, CameraMath.easeInOutSine(a), arcMeters / scale)
		end
	end

	self.lastPose = pose
	return withImpulse(self, pose, now)
end

-- Coarse phase for the HUD.
export type Phase = "Idle" | "Contact" | "Flight" | "Landed" | "Returning"

function CameraDirector.getPhase(self: CameraDirector): Phase
	local state = self.state
	if state == "ContactTransition" then
		return "Contact"
	elseif state == "BallFollow" then
		return "Flight"
	elseif state == "Landing" then
		return "Landed"
	elseif state == "Returning" then
		return "Returning"
	end
	return "Idle"
end

-- Fraction (0..1) of the return completed; 0 outside Returning.
function CameraDirector.returnProgress(self: CameraDirector, now: number): number
	if self.state ~= "Returning" then
		return 0
	end
	return math.clamp((now - self.stateStart) / math.max(PresentationConfig.Timing.ReturnSeconds, 1e-6), 0, 1)
end

-- Ball time (s after launch, clamped to the flight) for the presented hit.
function CameraDirector.ballTime(hit: Hit, now: number): number
	return math.clamp(now - hit.flight.launch.launchTime, 0, CameraDirector.endTimeOf(hit))
end

return CameraDirector
