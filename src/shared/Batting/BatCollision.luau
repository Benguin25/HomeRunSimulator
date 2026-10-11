--!strict
-- Continuous bat-ball intersection.
--
-- The bat is two capsules along its axis (handle, barrel) that rotate with the
-- swing; the ball is a sphere moving along the authoritative pitch trajectory.
-- We need the earliest time in [t0, t1] at which they touch.
--
-- Method: conservative advancement. Let gap(t) = min over capsules of
-- (distance from ball center to capsule axis segment) - (capsule radius + ball
-- radius). gap can change no faster than the maximum relative speed between
-- any bat point and the ball, vmax. So from time t no contact is possible
-- before t + gap(t)/vmax, and stepping by exactly that amount can never jump
-- over a contact, regardless of how fast either object moves. The loop stops
-- when the gap falls below a small tolerance (contact) or the interval ends.
--
-- This replaces Touched events and fixed-step overlap checks, which tunnel at
-- these speeds (the ball moves ~37 cm per 60 Hz frame).

local SwingModel = require(script.Parent.SwingModel)
local BattingConfig = require(script.Parent.BattingConfig)

local BatCollision = {}

export type SegmentName = "Handle" | "Barrel"

export type Hit = {
	time: number, -- server time of first touch
	ballCenter: Vector3,
	axisPoint: Vector3, -- closest point on the bat axis to the ball center
	alongBat: number, -- studs from the knob to axisPoint
	segment: SegmentName,
	segmentRadius: number,
	normal: Vector3, -- unit, from the bat axis toward the ball center
	gap: number, -- remaining surface gap (<= tolerance)
	pose: SwingModel.Pose,
}

export type Result = {
	hit: Hit?,
	iterations: number,
	minGap: number, -- smallest gap seen (studs); useful for "just missed" feedback
	minGapTime: number,
}

export type BallPositionFn = (t: number) -> Vector3

-- Closest point on segment [a, b] to p, and its parameter in [0, 1].
local function closestOnSegment(a: Vector3, b: Vector3, p: Vector3): (Vector3, number)
	local ab = b - a
	local lengthSq = ab:Dot(ab)
	if lengthSq < 1e-12 then
		return a, 0
	end
	local u = math.clamp((p - a):Dot(ab) / lengthSq, 0, 1)
	return a + ab * u, u
end

type Measure = {
	gap: number,
	axisPoint: Vector3,
	alongBat: number,
	segment: SegmentName,
	radius: number,
}

-- Surface gap between the ball and the bat at a pose.
function BatCollision.measure(pose: SwingModel.Pose, dims: SwingModel.BatDimensions, ballCenter: Vector3, ballRadius: number): Measure
	local knob = pose.knob
	local direction = pose.direction
	local split = knob + direction * dims.barrelStart

	local handlePoint, handleU = closestOnSegment(knob, split, ballCenter)
	local handleGap = (ballCenter - handlePoint).Magnitude - (dims.handleRadius + ballRadius)

	local barrelPoint, barrelU = closestOnSegment(split, pose.tip, ballCenter)
	local barrelGap = (ballCenter - barrelPoint).Magnitude - (dims.barrelRadius + ballRadius)

	if barrelGap <= handleGap then
		return {
			gap = barrelGap,
			axisPoint = barrelPoint,
			alongBat = dims.barrelStart + barrelU * (dims.length - dims.barrelStart),
			segment = "Barrel",
			radius = dims.barrelRadius,
		}
	end
	return {
		gap = handleGap,
		axisPoint = handlePoint,
		alongBat = handleU * dims.barrelStart,
		segment = "Handle",
		radius = dims.handleRadius,
	}
end

-- Earliest contact between the swing's Active window and the ball within
-- [t0, t1] (server times; clipped to the Active window).
--   maxBallSpeed : upper bound on the ball's speed over the interval (studs/s)
--   tolerance    : studs; surfaces closer than this count as touching
function BatCollision.findEarliest(
	swing: SwingModel.Swing,
	ballPositionAt: BallPositionFn,
	ballRadius: number,
	t0: number,
	t1: number,
	maxBallSpeed: number,
	tolerance: number
): Result
	local cfg = BattingConfig.Collision
	local startTime = math.max(t0, swing.activeStart)
	local endTime = math.min(t1, swing.activeEnd)
	local result: Result = { hit = nil, iterations = 0, minGap = math.huge, minGapTime = startTime }
	if endTime < startTime then
		return result
	end

	local vmax = (maxBallSpeed + SwingModel.maxPointSpeed(swing)) * cfg.SpeedBoundMargin
	assert(vmax > 0, "relative speed bound must be positive")

	local t = startTime
	local final = false
	for iteration = 1, cfg.MaxIterations do
		result.iterations = iteration
		local pose = SwingModel.activePoseAt(swing, t)
		local ballCenter = ballPositionAt(t)
		local m = BatCollision.measure(pose, swing.dims, ballCenter, ballRadius)
		if m.gap < result.minGap then
			result.minGap = m.gap
			result.minGapTime = t
		end
		if m.gap <= tolerance then
			local offset = ballCenter - m.axisPoint
			local normal = if offset.Magnitude > 1e-6 then offset.Unit else pose.planeNormal
			result.hit = {
				time = t,
				ballCenter = ballCenter,
				axisPoint = m.axisPoint,
				alongBat = m.alongBat,
				segment = m.segment,
				segmentRadius = m.radius,
				normal = normal,
				gap = m.gap,
				pose = pose,
			}
			return result
		end
		if final then
			return result
		end
		t += m.gap / vmax
		if t >= endTime then
			-- Always evaluate the window's last instant exactly once.
			t = endTime
			final = true
		end
	end
	warn("[Batting] collision search hit the iteration cap; treating as a miss")
	return result
end

return BatCollision
