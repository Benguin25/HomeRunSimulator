--!strict
-- Explains WHY a swing missed, from the simulated swing and ball geometry.
--
-- A miss can come from three independent mistakes:
--   timing   : the bat was square earlier/later than the ball arrived
--   vertical : the bat plane passed above/below the ball
--   lateral  : the ball was closer to the batter / farther out than the aim
--
-- For each one we measure the error against where the ball really crossed
-- the contact plane, and we test it with the real collision sweep: "if only
-- this one thing had been perfect, would the bat have hit the ball?". The
-- reported reason is the largest error (relative to the same tolerances the
-- contact-quality score uses) among the mistakes that would have fixed the
-- miss; if no single fix works, among all three. So:
--   * timing wins when the swing was far enough off in time that the bat was
--     not at the ball while it was reachable (Early / Late);
--   * a directional reason wins when the timing was reasonable but the swing
--     path went over/under or inside/outside the ball.
-- Nothing here looks at the screen.

local Pitching = script.Parent.Parent.Pitching
local LaneGeometry = require(Pitching.LaneGeometry)
local Pitch = require(Pitching.Pitch)
local PitchPhysics = require(Pitching.PitchPhysics)

local BattingConfig = require(script.Parent.BattingConfig)
local SwingModel = require(script.Parent.SwingModel)

local MissClassifier = {}

export type Reason = "Early" | "Late" | "Over" | "Under" | "Inside" | "Outside"

export type Analysis = {
	reason: Reason,
	amount: number, -- seconds for Early/Late, studs for the others
	-- Signed errors in units of their tolerance (1 = where contact quality hits zero).
	timing: number, -- - = swing early
	vertical: number, -- + = ball above the aim (bat went under)
	lateral: number, -- + = ball farther out than the aim
	-- Would contact have happened if only this one thing were corrected?
	fixes: { timing: boolean, vertical: boolean, lateral: boolean },
}

-- `hits(swing)` must run the real collision sweep for a candidate swing
-- against this same pitch and report whether it makes contact.
function MissClassifier.classify(
	geometry: LaneGeometry.Geometry,
	flight: Pitch.Flight,
	swing: SwingModel.Swing,
	idealTime: number,
	hits: (SwingModel.Swing) -> boolean
): Analysis
	local quality = BattingConfig.Quality
	local units = geometry.units
	local ball = PitchPhysics.sample(flight.trajectory, idealTime - flight.data.releaseTime)
	local offset = ball - SwingModel.contactPlane(geometry).point
	local ballX, ballY = offset:Dot(geometry.right), offset:Dot(geometry.up)

	local timingError = swing.squareTime - idealTime
	local verticalError = ballY - swing.aimY
	local lateralError = (ball - swing.aimPoint):Dot(swing.across)

	local reach = swing.dims.barrelRadius + flight.params.radius
	local timing = timingError / quality.TimingToleranceSeconds
	local vertical = verticalError / (reach * quality.VerticalToleranceScale)
	local lateral = lateralError / units.toStuds(quality.SweetSpotToleranceMeters)

	local fixes = {
		timing = hits(SwingModel.new(geometry, swing.aimX, swing.aimY, SwingModel.startTimeForSquareAt(idealTime))),
		vertical = hits(SwingModel.new(geometry, swing.aimX, ballY, swing.startTime)),
		lateral = hits(SwingModel.new(geometry, ballX, swing.aimY, swing.startTime)),
	}

	local anyFix = fixes.timing or fixes.vertical or fixes.lateral
	local best: string? = nil
	local bestSize = -1
	-- Fixed order so ties are deterministic.
	for _, axis in { "timing", "vertical", "lateral" } do
		local size = math.abs((if axis == "timing" then timing elseif axis == "vertical" then vertical else lateral))
		if (not anyFix or (fixes :: any)[axis]) and size > bestSize then
			best, bestSize = axis, size
		end
	end

	local reason: Reason
	local amount: number
	if best == "timing" then
		reason = if timingError < 0 then "Early" else "Late"
		amount = math.abs(timingError)
	elseif best == "vertical" then
		-- Ball above the aim: the bat plane went under it.
		reason = if verticalError > 0 then "Under" else "Over"
		amount = math.abs(verticalError)
	else
		-- Ball farther from the batter than the aim: the bat fell short.
		reason = if lateralError > 0 then "Outside" else "Inside"
		amount = math.abs(lateralError)
	end

	return {
		reason = reason,
		amount = amount,
		timing = timing,
		vertical = vertical,
		lateral = lateral,
		fixes = fixes,
	}
end

return MissClassifier
