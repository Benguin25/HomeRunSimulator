--!strict
-- UI readiness only. It cannot authorize batting, progression or travel.
local State = {}
export type State = {
	token: number,
	mode: string,
	world: string,
	phase: string,
	percent: number,
	entered: boolean,
	capped: boolean,
}
export type Readiness = {
	boot: boolean,
	profile: boolean,
	character: boolean,
	world: boolean,
	loaded: number,
	total: number,
	assets: boolean,
	scene: boolean,
	warmup: number?,
	failure: string?,
}
function State.new(): State
	return {
		token = 0,
		mode = "Join",
		world = "rookie",
		phase = "Loading",
		percent = 0,
		entered = false,
		capped = false,
	}
end
function State.begin(s: State, mode: string, world: string): number
	s.token += 1
	s.mode, s.world, s.phase, s.percent = mode, world, "Loading", 0
	s.capped = false
	return s.token
end
function State.cap(s: State, token: number, elapsed: number, limit: number, r: Readiness): boolean
	if
		token ~= s.token
		or s.phase ~= "Loading"
		or elapsed < limit
		or r.failure
		or not r.boot
		or not r.profile
		or not r.character
		or not r.world
	then
		return false
	end
	s.capped, s.phase, s.percent = true, "Ready", 100
	return true
end
function State.displayProgress(elapsed: number, limit: number, exponent: number): number
	local fraction = math.clamp(elapsed / limit, 0, 1)
	return math.min(99, math.floor(100 * (1 - (1 - fraction) ^ exponent)))
end
function State.update(s: State, token: number, r: Readiness): boolean
	if token ~= s.token or s.phase == "Leaving" or s.phase == "Hidden" then
		return false
	end
	if r.failure then
		s.phase = "Error"
		return false
	end
	local fraction = if r.total > 0 then math.clamp(r.loaded / r.total, 0, 1) else 0
	local ready = r.boot
		and r.profile
		and r.character
		and r.world
		and (s.capped or (r.assets and r.scene and r.total > 0 and r.loaded >= r.total))
	local progress = (if r.boot then 8 else 0)
		+ (if r.profile then 17 else 0)
		+ (if r.character then 10 else 0)
		+ (if r.world then 10 else 0)
		+ fraction * 30
		+ (if r.assets then 5 else 0)
		+ math.clamp(r.warmup or (if r.scene then 1 else 0), 0, 1) * 20
	s.percent = if ready then 100 else math.min(99, math.max(s.percent, math.floor(progress)))
	s.phase = if ready then "Ready" else "Loading"
	return ready
end
function State.leave(s: State, token: number): boolean
	if s.token ~= token or s.phase ~= "Ready" then
		return false
	end
	s.phase = "Leaving"
	return true
end
function State.finish(s: State, token: number): boolean
	if s.token ~= token or s.phase ~= "Leaving" then
		return false
	end
	s.phase, s.entered = "Hidden", true
	return true
end
return State
