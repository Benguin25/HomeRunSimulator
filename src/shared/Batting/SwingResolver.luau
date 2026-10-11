--!strict
-- Resolves one swing against one pitch: runs the swept collision over the
-- overlap of the swing's Active window and the ball's flight, then grades any
-- contact. Pure and deterministic: the server uses it authoritatively, the
-- client uses the same call to predict visuals.

local Pitching = script.Parent.Parent.Pitching
local LaneGeometry = require(Pitching.LaneGeometry)
local Pitch = require(Pitching.Pitch)
local PitchPhysics = require(Pitching.PitchPhysics)

local BatCollision = require(script.Parent.BatCollision)
local BattingConfig = require(script.Parent.BattingConfig)
local ContactQuality = require(script.Parent.ContactQuality)
local MissClassifier = require(script.Parent.MissClassifier)
local SwingModel = require(script.Parent.SwingModel)

local SwingResolver = {}

export type MissReason = MissClassifier.Reason | "NoOverlap"

export type Resolution = {
	contact: ContactQuality.ContactResult?,
	missReason: MissReason?,
	missAmount: number?, -- seconds for Early/Late, studs for the others
	missAnalysis: MissClassifier.Analysis?,
	idealContactTime: number?, -- server time the ball crosses the contact plane
	timingErrorSeconds: number?, -- - = early, + = late
	minGap: number, -- studs (math.huge if the windows never overlapped)
	iterations: number,
}

-- Does the swing's Active window overlap the ball's flight at all?
function SwingResolver.overlapsFlight(swing: SwingModel.Swing, flight: Pitch.Flight): boolean
	local releaseTime = flight.data.releaseTime
	return swing.activeEnd >= releaseTime and swing.activeStart <= releaseTime + flight.endTime
end

-- Server time the ball reaches the contact plane (the "ideal" contact time).
function SwingResolver.idealContactTime(geometry: LaneGeometry.Geometry, flight: Pitch.Flight): number?
	local crossing = PitchPhysics.findPlaneCrossing(flight.trajectory, SwingModel.contactPlane(geometry))
	return crossing and (flight.data.releaseTime + crossing.time)
end

-- Fastest the ball moves during its flight (with a little Hermite headroom).
local function maxBallSpeed(flight: Pitch.Flight): number
	local maxSpeed = 0
	for _, velocity in flight.trajectory.velocities do
		maxSpeed = math.max(maxSpeed, velocity.Magnitude)
	end
	return maxSpeed * 1.02
end

-- Runs the swept collision for a swing against a flight (no grading).
function SwingResolver.findContact(geometry: LaneGeometry.Geometry, flight: Pitch.Flight, swing: SwingModel.Swing): BatCollision.Result
	local releaseTime = flight.data.releaseTime
	local trajectory = flight.trajectory
	return BatCollision.findEarliest(swing, function(t: number): Vector3
		return PitchPhysics.sample(trajectory, t - releaseTime)
	end, flight.params.radius, releaseTime, releaseTime + flight.endTime, maxBallSpeed(flight), geometry.units.toStuds(
		BattingConfig.Collision.ToleranceMeters
	))
end

function SwingResolver.resolve(geometry: LaneGeometry.Geometry, flight: Pitch.Flight, swing: SwingModel.Swing): Resolution
	local releaseTime = flight.data.releaseTime
	local ideal = SwingResolver.idealContactTime(geometry, flight)
	local timingError = if ideal then swing.squareTime - ideal else nil

	local resolution: Resolution = {
		contact = nil,
		missReason = nil,
		missAmount = nil,
		missAnalysis = nil,
		idealContactTime = ideal,
		timingErrorSeconds = timingError,
		minGap = math.huge,
		iterations = 0,
	}

	if not SwingResolver.overlapsFlight(swing, flight) then
		resolution.missReason = "NoOverlap"
		return resolution
	end

	local search = SwingResolver.findContact(geometry, flight, swing)
	resolution.minGap = search.minGap
	resolution.iterations = search.iterations

	local hit = search.hit
	if hit then
		local ballVelocity = PitchPhysics.sampleVelocity(flight.trajectory, hit.time - releaseTime)
		resolution.contact =
			ContactQuality.evaluate(geometry, swing, hit, ballVelocity, flight.params.radius, releaseTime, ideal)
		return resolution
	end

	if ideal then
		local analysis = MissClassifier.classify(geometry, flight, swing, ideal, function(candidate)
			return SwingResolver.findContact(geometry, flight, candidate).hit ~= nil
		end)
		resolution.missReason = analysis.reason
		resolution.missAmount = analysis.amount
		resolution.missAnalysis = analysis
	else
		-- The ball never reaches the contact plane: all we can say is when the swing was.
		resolution.missReason = if swing.squareTime < releaseTime + flight.endTime / 2 then "Early" else "Late"
	end
	return resolution
end

return SwingResolver
