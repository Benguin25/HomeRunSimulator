--!strict
-- Pure presentation data for a hit (no services, no Instances): contact
-- intensity, the live distance counter, the result summary and the
-- speed-dependent flight styling. The client's HitHud / HitEffects only
-- render what these functions return, so the numbers are testable.
--
-- Honesty rules for distances:
--   * the live counter is the ball's horizontal distance from home plate
--     (BattedBall.distanceAt), never path length or an estimate;
--   * a "final" number only ever comes from the server's outcome:
--     Landed -> carry; Obstacle -> where it hit (labelled, no carry);
--     NoImpact -> the last tracked distance (labelled, no landing);
--   * between the ball stopping and the server's answer the counter says so.

local Shared = script.Parent.Parent
local Units = require(Shared.Pitching.Units)
local BattedBall = require(Shared.BattedBall.BattedBall)
local BattedBallConfig = require(Shared.BattedBall.BattedBallConfig)
local LandingDetector = require(Shared.BattedBall.LandingDetector)

local PresentationConfig = require(script.Parent.PresentationConfig)

local HitPresentation = {}

---------------------------------------------------------------------------
-- Contact intensity
---------------------------------------------------------------------------

export type Tier = "Weak" | "Solid" | "Crushed"

export type IntensityInput = {
	exitSpeedMph: number?, -- nil when no flight is known yet
	launchDegrees: number?,
	score: number, -- ContactQuality score 0..1
	relativeSpeedMps: number, -- |bat velocity - ball velocity| at contact
	sweetSpotOffsetMeters: number,
}

local function ramp(value: number, low: number, high: number): number
	if high <= low then
		return if value >= high then 1 else 0
	end
	return math.clamp((value - low) / (high - low), 0, 1)
end

-- 0..1 from measured contact properties (no randomness).
function HitPresentation.intensity(input: IntensityInput): number
	local cfg = PresentationConfig.Intensity
	local w = cfg.Weights
	local quality = math.clamp(input.score, 0, 1)
	local ev = if input.exitSpeedMph then ramp(input.exitSpeedMph, cfg.ExitVelocityLowMph, cfg.ExitVelocityHighMph) else quality
	local relative = ramp(input.relativeSpeedMps, cfg.RelativeSpeedLowMps, cfg.RelativeSpeedHighMps)
	local sweet = 1 - ramp(math.abs(input.sweetSpotOffsetMeters), 0, cfg.SweetSpotToleranceMeters)
	local total = w.ExitVelocity + w.Quality + w.RelativeSpeed + w.SweetSpot
	local base = (w.ExitVelocity * ev + w.Quality * quality + w.RelativeSpeed * relative + w.SweetSpot * sweet) / total
	local launchFactor = 1
	if input.launchDegrees then
		local d = (input.launchDegrees - cfg.IdealLaunchDegrees) / cfg.LaunchSpreadDegrees
		launchFactor = cfg.LaunchMinFactor + (1 - cfg.LaunchMinFactor) * math.exp(-0.5 * d * d)
	end
	return math.clamp(base * launchFactor, 0, 1)
end

function HitPresentation.tier(intensity: number): Tier
	local cfg = PresentationConfig.Intensity
	if intensity >= cfg.CrushedAt then
		return "Crushed"
	elseif intensity >= cfg.SolidAt then
		return "Solid"
	end
	return "Weak"
end

---------------------------------------------------------------------------
-- Distance formatting
---------------------------------------------------------------------------

-- (number text, unit text) in the configured unit, e.g. ("187", "FT").
function HitPresentation.distanceParts(meters: number): (string, string)
	if BattedBallConfig.Display.DistanceUnit == "Meters" then
		return string.format("%.1f", meters), "M"
	end
	return tostring(math.floor(meters / Units.METERS_PER_FOOT + 0.5)), "FT"
end

local function distanceText(meters: number): string
	local value, unit = HitPresentation.distanceParts(meters)
	return `{value} {unit}`
end

---------------------------------------------------------------------------
-- Live counter
---------------------------------------------------------------------------

export type CounterKind = "Hidden" | "Live" | "Confirming" | "Final" | "Wall" | "Tracked"

export type Counter = {
	kind: CounterKind,
	label: string, -- small caption above the number
	meters: number, -- what the number shows
	tag: string, -- status pill ("LIVE", "FINAL", ...)
	fair: boolean?, -- for Final / Wall: territory
}

export type CounterInput = {
	flight: BattedBall.Flight,
	endTime: number, -- s after launch when the ball stops (server's when known)
	outcome: LandingDetector.OutcomePayload?,
	elapsed: number, -- now - launchTime
}

local HIDDEN: Counter = { kind = "Hidden", label = "", meters = 0, tag = "" }

function HitPresentation.counter(input: CounterInput): Counter
	local hud = PresentationConfig.Hud
	local flight = input.flight
	local endTime = math.min(input.endTime, flight.trajectory.duration)
	if input.elapsed < hud.CounterDelaySeconds then
		return HIDDEN
	end
	if BattedBall.distanceAt(flight, endTime) < hud.CounterMinMeters then
		return HIDDEN -- a dribbler: nothing worth counting
	end
	if input.elapsed < endTime then
		return { kind = "Live", label = "DISTANCE", meters = BattedBall.distanceAt(flight, input.elapsed), tag = "LIVE" }
	end
	local outcome = input.outcome
	if outcome == nil then
		return { kind = "Confirming", label = "DISTANCE", meters = BattedBall.distanceAt(flight, endTime), tag = "CONFIRMING" }
	end
	local fair = outcome.territory == "Fair"
	if outcome.kind == "Landed" and outcome.carryMeters then
		return { kind = "Final", label = "CARRY", meters = outcome.carryMeters, tag = if fair then "FINAL" else "FOUL", fair = fair }
	elseif outcome.kind == "Obstacle" and outcome.impactDistanceMeters then
		return {
			kind = "Wall",
			label = if outcome.surface == "Ceiling" then "HIT THE ROOF AT" else "HIT THE WALL AT",
			meters = outcome.impactDistanceMeters,
			tag = "NO CARRY",
			fair = fair,
		}
	end
	return {
		kind = "Tracked",
		label = "TRACKED TO",
		meters = BattedBall.distanceAt(flight, math.min(outcome.endTime, flight.trajectory.duration)),
		tag = "NO LANDING",
		fair = fair,
	}
end

---------------------------------------------------------------------------
-- Result summary
---------------------------------------------------------------------------

export type Tone = "Fair" | "Foul" | "Neutral"

export type SummaryRow = { label: string, value: string }

export type Summary = {
	headline: string,
	tone: Tone,
	note: string?, -- one short qualifier line, when needed
	distanceLabel: string?,
	distanceValue: string?, -- number only
	distanceUnit: string?,
	rows: { SummaryRow },
}

export type SummaryInput = {
	flight: BattedBall.Flight,
	outcome: LandingDetector.OutcomePayload?, -- nil = the server never answered
	contactLabel: string?,
}

function HitPresentation.summary(input: SummaryInput): Summary
	local flight = input.flight
	local rows: { SummaryRow } = {
		{ label = "EXIT VELO", value = `{math.floor(flight.exitSpeedMph + 0.5)} MPH` },
		{ label = "LAUNCH", value = `{math.floor(flight.launchAngleDegrees + 0.5)}°` },
	}
	if input.contactLabel then
		table.insert(rows, { label = "CONTACT", value = string.upper(input.contactLabel) })
	end

	local outcome = input.outcome
	if outcome == nil then
		return { headline = "RESULT UNAVAILABLE", tone = "Neutral", note = "the server did not report a landing", rows = rows }
	end

	local tone: Tone = if outcome.territory == "Fair" then "Fair" else "Foul"
	local summary: Summary = { headline = "", tone = tone, rows = rows }
	local function setDistance(label: string, meters: number)
		local value, unit = HitPresentation.distanceParts(meters)
		summary.distanceLabel, summary.distanceValue, summary.distanceUnit = label, value, unit
	end

	if outcome.kind == "Landed" and outcome.carryMeters then
		summary.headline = if tone == "Fair" then "FAIR BALL" else "FOUL BALL"
		setDistance("DISTANCE", outcome.carryMeters)
		if outcome.territoryProvisional then
			summary.note = "short of the bases: could still roll " .. (if tone == "Fair" then "foul" else "fair")
		end
	elseif outcome.kind == "Obstacle" and outcome.impactDistanceMeters then
		summary.headline = if outcome.surface == "Ceiling" then "OFF THE ROOF" else "OFF THE WALL"
		setDistance("HIT AT", outcome.impactDistanceMeters)
		summary.note = string.format("%s up - no carry measured", distanceText(math.max(0, outcome.impactHeightMeters or 0)))
	else
		summary.headline = "OUT OF RANGE"
		summary.tone = "Neutral"
		setDistance("TRACKED TO", BattedBall.distanceAt(flight, math.min(outcome.endTime, flight.trajectory.duration)))
		summary.note = "left the tracked area before landing"
	end
	return summary
end

---------------------------------------------------------------------------
-- Flight visuals
---------------------------------------------------------------------------

export type TrailStyle = { level: number, lifetime: number, transparency: number }

-- Speed-dependent trail, quantized to TrailSteps levels so it only changes
-- when the speed crosses a level.
function HitPresentation.trailStyle(speedMps: number): TrailStyle
	local cfg = PresentationConfig.Flight
	local steps = math.max(1, cfg.TrailSteps)
	local level = math.floor(ramp(speedMps, cfg.TrailSlowMps, cfg.TrailFastMps) * steps + 0.5)
	local f = level / steps
	return {
		level = level,
		lifetime = cfg.TrailLifetimeSlow + (cfg.TrailLifetimeFast - cfg.TrailLifetimeSlow) * f,
		transparency = cfg.TrailTransparencySlow + (cfg.TrailTransparencyFast - cfg.TrailTransparencySlow) * f,
	}
end

-- Halo opacity (0..1) for a ball this far from the camera.
function HitPresentation.haloOpacity(cameraDistanceMeters: number): number
	local cfg = PresentationConfig.Flight
	if not cfg.HaloEnabled then
		return 0
	end
	return cfg.HaloMaxOpacity * ramp(cameraDistanceMeters, cfg.HaloFadeStartMeters, cfg.HaloFadeEndMeters)
end

return HitPresentation
