--!strict
-- Conservative render settling, not a GPU-completion API. Replication/preload
-- remain separate gates. Time advances only on fresh, responsive render frames.
local Settler = {}
export type State = { elapsed: number, samples: { { time: number, triangles: number } }, stable: number }
function Settler.new(): State
	return { elapsed = 0, samples = {}, stable = 0 }
end
function Settler.update(
	s: State,
	dt: number,
	triangles: number,
	minimum: number,
	window: number,
	tolerance: number
): boolean
	s.elapsed += math.clamp(dt, 0, 0.1)
	if triangles <= 0 then
		table.clear(s.samples)
		s.stable = 0
		return false
	end
	table.insert(s.samples, { time = s.elapsed, triangles = triangles })
	while #s.samples > 1 and s.samples[2].time <= s.elapsed - window do
		table.remove(s.samples, 1)
	end
	local low, high = math.huge, 0
	for _, sample in s.samples do
		low, high = math.min(low, sample.triangles), math.max(high, sample.triangles)
	end
	s.stable = if high - low <= math.max(64, high * tolerance) then s.elapsed - s.samples[1].time else 0
	return s.elapsed >= minimum and s.stable >= window
end
return Settler
