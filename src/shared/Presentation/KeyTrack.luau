--!strict
-- Keyframe tracks for the procedural athletes (pitcher, catcher). Pure.
--
-- A track is a list of keys { u = fraction-of-windup | s = seconds-after-release, v = number | Vector3 }.
-- `compile` places every key on one absolute timeline (seconds from the windup
-- start) for a given windup duration, so the motion across the release is a
-- single smooth curve. Values are interpolated with monotone cubic Hermite
-- splines (Fritsch-Butland tangents): C1-smooth, and never overshoot between
-- two keys, so a planted foot (two equal keys) stays planted and a value never
-- swings past the poses that were authored. End tangents are zero (ease in/out).

local KeyTrack = {}

export type Key = { u: number?, s: number?, v: any }
export type Track = { Key }
type Channel = { times: { number }, values: { number }, tangents: { number } }
export type Compiled = { kind: "number" | "Vector3", channels: { Channel } }
export type CompiledSet = { [string]: Compiled }

local function timeOf(key: Key, windupSeconds: number): number
	if key.u ~= nil then
		return key.u * windupSeconds
	end
	return windupSeconds + (key.s or 0)
end

local function tangents(times: { number }, values: { number }): { number }
	local n = #values
	local m = table.create(n, 0)
	for i = 2, n - 1 do
		local h0, h1 = times[i] - times[i - 1], times[i + 1] - times[i]
		local d0 = if h0 > 1e-9 then (values[i] - values[i - 1]) / h0 else 0
		local d1 = if h1 > 1e-9 then (values[i + 1] - values[i]) / h1 else 0
		if d0 * d1 > 0 then
			local w0, w1 = 2 * h1 + h0, h1 + 2 * h0
			m[i] = (w0 + w1) / (w0 / d0 + w1 / d1)
		end
	end
	return m
end

local function channel(times: { number }, values: { number }): Channel
	return { times = times, values = values, tangents = tangents(times, values) }
end

function KeyTrack.compile(track: Track, windupSeconds: number): Compiled
	assert(#track > 0, "empty track")
	local times = {}
	for i, key in track do
		times[i] = timeOf(key, windupSeconds)
		assert(i == 1 or times[i] >= times[i - 1], "track keys must be in time order")
	end
	local first = track[1].v
	if typeof(first) == "Vector3" then
		local xs, ys, zs = {}, {}, {}
		for i, key in track do
			local v = key.v :: Vector3
			xs[i], ys[i], zs[i] = v.X, v.Y, v.Z
		end
		return { kind = "Vector3", channels = { channel(times, xs), channel(times, ys), channel(times, zs) } }
	end
	local values = {}
	for i, key in track do
		values[i] = key.v :: number
	end
	return { kind = "number", channels = { channel(times, values) } }
end

function KeyTrack.compileSet(tracks: { [string]: Track }, windupSeconds: number): CompiledSet
	local set: CompiledSet = {}
	for name, track in tracks do
		set[name] = KeyTrack.compile(track, windupSeconds)
	end
	return set
end

local function evalChannel(c: Channel, t: number): number
	local times, values = c.times, c.values
	local n = #times
	if n == 1 or t <= times[1] then
		return values[1]
	elseif t >= times[n] then
		return values[n]
	end
	local i = 1
	while times[i + 1] < t do
		i += 1
	end
	local h = times[i + 1] - times[i]
	if h <= 1e-9 then
		return values[i + 1]
	end
	local u = (t - times[i]) / h
	local u2, u3 = u * u, u * u * u
	return (2 * u3 - 3 * u2 + 1) * values[i]
		+ (u3 - 2 * u2 + u) * h * c.tangents[i]
		+ (-2 * u3 + 3 * u2) * values[i + 1]
		+ (u3 - u2) * h * c.tangents[i + 1]
end

function KeyTrack.eval(compiled: Compiled, t: number): any
	local c = compiled.channels
	if compiled.kind == "Vector3" then
		return Vector3.new(evalChannel(c[1], t), evalChannel(c[2], t), evalChannel(c[3], t))
	end
	return evalChannel(c[1], t)
end

function KeyTrack.evalSet(set: CompiledSet, t: number): { [string]: any }
	local out = {}
	for name, compiled in set do
		out[name] = KeyTrack.eval(compiled, t)
	end
	return out
end

-- Linear blend of two evaluated channel tables (numbers and Vector3s).
function KeyTrack.blend(a: { [string]: any }, b: { [string]: any }, alpha: number): { [string]: any }
	if alpha <= 0 then
		return a
	elseif alpha >= 1 then
		return b
	end
	local out = {}
	for name, value in b do
		local from = a[name]
		if from == nil then
			out[name] = value
		elseif typeof(value) == "Vector3" then
			out[name] = (from :: Vector3):Lerp(value, alpha)
		else
			out[name] = from + (value - from) * alpha
		end
	end
	return out
end

function KeyTrack.smooth(x: number): number
	local u = math.clamp(x, 0, 1)
	return u * u * (3 - 2 * u)
end

return KeyTrack
