--!strict
-- Lifecycle of the batted ball on one lane.
--
--   Idle -> Flying -> Resolved (holding the result) -> Idle
--             \----------------> Idle (cancel)
--
-- Pure and clock-driven like PitchLane: the owner calls `update(now)` with
-- the server clock at any rate. The first impact is known when the hit is
-- launched (the trajectory and the stadium are deterministic), so the
-- resolution fires at exactly launchTime + outcome.endTime, however long a
-- frame is, and exactly once. A lane holds at most one hit; a second launch
-- while one is active is refused, so a duplicate contact can never produce
-- two balls or two results.

local BattedBall = require(script.Parent.BattedBall)
local BattedBallConfig = require(script.Parent.BattedBallConfig)
local LandingDetector = require(script.Parent.LandingDetector)

local HitLifecycle = {}
HitLifecycle.__index = HitLifecycle

export type State = "Idle" | "Flying" | "Resolved"

export type ActiveHit = {
	launch: BattedBall.LaunchData,
	flight: BattedBall.Flight,
	outcome: LandingDetector.Outcome,
}

export type Hooks = {
	onLaunched: ((lifecycle: HitLifecycle, hit: ActiveHit) -> ())?,
	onResolved: ((lifecycle: HitLifecycle, hit: ActiveHit) -> ())?,
	onFinished: ((lifecycle: HitLifecycle, hit: ActiveHit) -> ())?,
	onCancelled: ((lifecycle: HitLifecycle, hit: ActiveHit, reason: string) -> ())?,
}

export type HitLifecycle = typeof(setmetatable(
	{} :: {
		laneId: string,
		hooks: Hooks,
		holdSeconds: number,
		state: State,
		hit: ActiveHit?,
		resolveTime: number,
		finishTime: number,
		launched: number,
		resolved: number,
		finished: number,
		cancelled: number,
	},
	HitLifecycle
))

function HitLifecycle.new(laneId: string, hooks: Hooks, holdSeconds: number?): HitLifecycle
	return setmetatable({
		laneId = laneId,
		hooks = hooks,
		holdSeconds = holdSeconds or BattedBallConfig.Lifecycle.ResultHoldSeconds,
		state = "Idle" :: State,
		hit = nil :: ActiveHit?,
		resolveTime = math.huge,
		finishTime = math.huge,
		launched = 0,
		resolved = 0,
		finished = 0,
		cancelled = 0,
	}, HitLifecycle)
end

function HitLifecycle.isBusy(self: HitLifecycle): boolean
	return self.state ~= "Idle"
end

-- Starts a hit. Returns false (and does nothing) if one is already active.
function HitLifecycle.launch(self: HitLifecycle, now: number, hit: ActiveHit): boolean
	if self.state ~= "Idle" then
		return false
	end
	self.hit = hit
	self.state = "Flying"
	self.resolveTime = hit.launch.launchTime + hit.outcome.endTime
	self.finishTime = self.resolveTime + self.holdSeconds
	self.launched += 1
	local hook = self.hooks.onLaunched
	if hook then
		hook(self, hit)
	end
	self:update(now)
	return true
end

function HitLifecycle.update(self: HitLifecycle, now: number)
	local hit = self.hit
	if hit == nil then
		return
	end
	if self.state == "Flying" and now >= self.resolveTime then
		self.state = "Resolved"
		self.resolved += 1
		local hook = self.hooks.onResolved
		if hook then
			hook(self, hit)
		end
	end
	if self.state == "Resolved" and now >= self.finishTime and self.hit == hit then
		self.hit = nil
		self.state = "Idle"
		self.finished += 1
		local hook = self.hooks.onFinished
		if hook then
			hook(self, hit)
		end
	end
end

-- Ends the active hit early (batter left, lane shut down). Returns true if
-- there was one. A cancelled hit never resolves.
function HitLifecycle.cancel(self: HitLifecycle, reason: string): boolean
	local hit = self.hit
	if hit == nil then
		return false
	end
	self.hit = nil
	self.state = "Idle"
	self.cancelled += 1
	local hook = self.hooks.onCancelled
	if hook then
		hook(self, hit, reason)
	end
	return true
end

return HitLifecycle
