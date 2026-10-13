--!strict
-- Turns a geometric bat-ball contact into measured quantities, a quality score
-- and a label. The label summarizes the measurements; it never replaces them.
-- `ContactResult` is the hand-off structure for the Phase 3 ball-flight solver.
--
-- All vectors are world space, lengths in studs, speeds in studs/s, times in
-- server seconds unless the field name says otherwise.

local Pitching = script.Parent.Parent.Pitching
local LaneGeometry = require(Pitching.LaneGeometry)

local BatCollision = require(script.Parent.BatCollision)
local BattingConfig = require(script.Parent.BattingConfig)
local SwingModel = require(script.Parent.SwingModel)

local ContactQuality = {}

export type Label = "Perfect" | "Great" | "Good" | "Weak" | "Miss"

export type Factors = {
	timing: number,
	sweetSpot: number,
	vertical: number,
	efficiency: number,
}

export type ContactResult = {
	contactTime: number, -- server time of first touch
	timeAfterRelease: number,
	contactPoint: Vector3, -- point on the ball's surface touching the bat
	ballCenter: Vector3,
	batAxisPoint: Vector3,
	impactNormal: Vector3, -- unit, bat -> ball; direction of the collision impulse
	ballVelocity: Vector3,
	ballSpin: Vector3, -- incoming pitch spin (rad/s, world); Phase 3A impact model input
	batVelocity: Vector3, -- of the bat surface at the contact point
	relativeVelocity: Vector3, -- batVelocity - ballVelocity
	closingSpeed: number, -- relativeVelocity . impactNormal (> 0 = approaching)
	segment: BatCollision.SegmentName,
	distanceFromKnob: number,
	sweetSpotOffset: number, -- along the bat; + toward the tip
	verticalOffset: number, -- ball center above (+) / below (-) the bat axis, along the swing-plane normal
	batDirection: Vector3,
	swingDirection: Vector3, -- unit bat velocity at the contact point
	batAngleDegrees: number, -- 0 = square, + = out front (early), - = behind (late)
	idealContactTime: number?, -- ball reaches the aim point's plane
	timingErrorSeconds: number?, -- bat square time - idealContactTime; - = early, + = late
	-- Direction hints derived from the impact normal (not a flight solution).
	sprayAngleDegrees: number, -- horizontal; 0 = straightaway, + = pull side
	launchAngleHintDegrees: number,
	factors: Factors,
	score: number, -- 0..1
	label: Label,
}

local function falloff(error: number, tolerance: number): number
	if tolerance <= 0 then
		return if error == 0 then 1 else 0
	end
	local r = error / tolerance
	return math.max(0, 1 - r * r)
end

function ContactQuality.labelFor(score: number): Label
	local thresholds = BattingConfig.Quality.Thresholds
	if score >= thresholds.Perfect then
		return "Perfect"
	elseif score >= thresholds.Great then
		return "Great"
	elseif score >= thresholds.Good then
		return "Good"
	end
	return "Weak"
end

function ContactQuality.score(factors: Factors): number
	local weights = BattingConfig.Quality.Weights
	return (factors.timing ^ weights.Timing)
		* (factors.sweetSpot ^ weights.SweetSpot)
		* (factors.vertical ^ weights.Vertical)
		* (factors.efficiency ^ weights.Efficiency)
end

function ContactQuality.evaluate(
	geometry: LaneGeometry.Geometry,
	swing: SwingModel.Swing,
	hit: BatCollision.Hit,
	ballVelocity: Vector3,
	ballRadius: number,
	releaseTime: number,
	idealContactTime: number?,
	ballSpin: Vector3?
): ContactResult
	local units = geometry.units
	local quality = BattingConfig.Quality
	local normal = hit.normal
	local pose = hit.pose

	local surfacePoint = hit.axisPoint + normal * hit.segmentRadius
	local batVelocity = SwingModel.pointVelocity(swing, surfacePoint)
	local relative = batVelocity - ballVelocity
	local closing = relative:Dot(normal)
	local efficiency = if relative.Magnitude > 1e-6 then math.clamp(closing / relative.Magnitude, 0, 1) else 0

	local sweetSpotOffset = hit.alongBat - swing.dims.sweetSpot
	local offset = hit.ballCenter - hit.axisPoint
	-- The swing axis points up for a right-handed batter and down for a
	-- left-handed one; measure along the upward side of the swing plane so
	-- "+ = ball above the bat" holds for both hands. Only the magnitude feeds
	-- the quality score.
	local planeUp = if pose.planeNormal:Dot(geometry.up) < 0 then -pose.planeNormal else pose.planeNormal
	local verticalOffset = offset:Dot(planeUp)

	local timingError = if idealContactTime then swing.squareTime - idealContactTime else nil

	local factors: Factors = {
		timing = if timingError then falloff(math.abs(timingError), quality.TimingToleranceSeconds) else 0,
		sweetSpot = falloff(math.abs(units.toMeters(sweetSpotOffset)), quality.SweetSpotToleranceMeters),
		vertical = falloff(math.abs(verticalOffset), (hit.segmentRadius + ballRadius) * quality.VerticalToleranceScale),
		efficiency = efficiency,
	}
	local score = ContactQuality.score(factors)

	-- Pull side is the batter's side of the field (third base for a righty).
	local pull = -swing.across
	local horizontal = normal - geometry.up * normal:Dot(geometry.up)
	local spray = if horizontal.Magnitude > 1e-6
		then math.deg(math.atan2(horizontal:Dot(pull), horizontal:Dot(geometry.toPitcher)))
		else 0

	return {
		contactTime = hit.time,
		timeAfterRelease = hit.time - releaseTime,
		contactPoint = hit.ballCenter - normal * ballRadius,
		ballCenter = hit.ballCenter,
		batAxisPoint = hit.axisPoint,
		impactNormal = normal,
		ballVelocity = ballVelocity,
		ballSpin = ballSpin or Vector3.zero,
		batVelocity = batVelocity,
		relativeVelocity = relative,
		closingSpeed = closing,
		segment = hit.segment,
		distanceFromKnob = hit.alongBat,
		sweetSpotOffset = sweetSpotOffset,
		verticalOffset = verticalOffset,
		batDirection = pose.direction,
		swingDirection = if batVelocity.Magnitude > 1e-6 then batVelocity.Unit else swing.tangent,
		batAngleDegrees = math.deg(pose.angle),
		idealContactTime = idealContactTime,
		timingErrorSeconds = timingError,
		sprayAngleDegrees = spray,
		launchAngleHintDegrees = math.deg(math.asin(math.clamp(normal:Dot(geometry.up), -1, 1))),
		factors = factors,
		score = score,
		label = ContactQuality.labelFor(score),
	}
end

return ContactQuality
