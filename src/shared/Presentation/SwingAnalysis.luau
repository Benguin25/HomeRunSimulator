--!strict
-- Post-swing analysis: turns one authoritative swing result (plus the
-- confirmed batted ball, when there is one) into what the analysis panel
-- shows. Pure: no services or Instances, so every rule is testable.
--
-- Honesty rules:
--   * timing is the server's measured error (bat square time - ball arrival at
--     the aim plane), never a client animation estimate;
--   * placement compares the server's aim with where the ball actually crossed
--     the contact plane (both lane-local, the same plane the swing uses);
--   * the primary correction for a miss is MissClassifier's reason, which
--     already tests "would fixing only this have made contact?" with the real
--     collision sweep, so aim advice is never given for a timing miss;
--   * exit velocity / launch angle only exist for confirmed contact; misses
--     never show them, and a missing measurement is omitted, not invented.
--
-- Diagram coordinates are seen from the batting camera behind the plate:
-- +x = screen right (the catcher's right) for both batting hands.

local Shared = script.Parent.Parent
local BattingConfig = require(Shared.Batting.BattingConfig)
local PresentationConfig = require(script.Parent.PresentationConfig)

local SwingAnalysis = {}

export type TimingClass = "VeryEarly" | "Early" | "Good" | "Perfect" | "Late" | "VeryLate"
export type Tone = "Perfect" | "Good" | "Fair" | "Poor"

export type ContactInput = {
	label: string,
	score: number,
	factors: { timing: number, sweetSpot: number, vertical: number, efficiency: number },
	sweetSpotOffset: number, -- studs, + toward the tip
	verticalOffset: number, -- studs, + = ball above the bat axis
	timingErrorSeconds: number?,
}

export type Input = {
	batterSide: "Right" | "Left",
	metersPerStud: number,
	aimX: number?, -- studs, lane-local contact plane
	aimY: number?,
	ballX: number?,
	ballY: number?,
	timingErrorSeconds: number?,
	missReason: string?, -- MissClassifier reason or "NoOverlap"
	missAmount: number?, -- seconds for Early/Late, studs otherwise
	contact: ContactInput?,
	-- Confirmed batted ball (server launch record) and result, when known.
	exitSpeedMph: number?,
	launchAngleDegrees: number?,
	territory: ("Fair" | "Foul")?,
	distanceText: string?, -- e.g. "412 FT", from HitPresentation (server outcome only)
	resultHeadline: string?,
	personalBest: boolean?,
}

export type Timing = {
	class: TimingClass,
	label: string,
	detail: string, -- "18 ms late"
	errorSeconds: number,
	position: number, -- -1 (very early) .. +1 (very late) on the meter
	tone: Tone,
}

export type Placement = {
	aimX: number, -- meters, catcher's view (+ = screen right)
	aimY: number, -- meters above plate ground
	ballX: number?,
	ballY: number?,
	vertical: ("High" | "Low")?, -- where the AIM was relative to the ball
	lateral: ("Inside" | "Outside")?, -- where the AIM was relative to the ball (toward / away from the batter)
	offsetCm: number?,
	batterSide: "Right" | "Left",
}

export type Stat = { label: string, value: string }

export type Report = {
	kind: "Contact" | "Miss",
	headline: string,
	tone: Tone,
	timing: Timing?,
	placement: Placement?,
	primary: string, -- "Perfect" | "Timing" | "Vertical" | "Lateral" | "SweetSpot" | "Efficiency" | "Unknown"
	advice: string,
	stats: { Stat },
}

local cfg = PresentationConfig.SwingAnalysis

local CLASS_LABEL: { [string]: string } = {
	VeryEarly = "VERY EARLY",
	Early = "EARLY",
	Good = "GOOD",
	Perfect = "PERFECT",
	Late = "LATE",
	VeryLate = "VERY LATE",
}

local CLASS_TONE: { [string]: Tone } = {
	VeryEarly = "Poor",
	Early = "Fair",
	Good = "Good",
	Perfect = "Perfect",
	Late = "Fair",
	VeryLate = "Poor",
}

local function tolerance(): number
	return BattingConfig.Quality.TimingToleranceSeconds
end

function SwingAnalysis.timingClass(errorSeconds: number): TimingClass
	local tol = tolerance()
	local size = math.abs(errorSeconds)
	local early = errorSeconds < 0
	local class: TimingClass
	if size <= tol * cfg.PerfectFraction then
		class = "Perfect"
	elseif size <= tol * cfg.GoodFraction then
		class = "Good"
	elseif size <= tol then
		class = if early then "Early" else "Late"
	else
		class = if early then "VeryEarly" else "VeryLate"
	end
	return class
end

function SwingAnalysis.timing(errorSeconds: number): Timing
	local class: string = SwingAnalysis.timingClass(errorSeconds)
	local ms = math.floor(math.abs(errorSeconds) * 1000 + 0.5)
	local label = CLASS_LABEL[class]
	if class == "Good" then
		label = if errorSeconds < 0 then "JUST EARLY" else "JUST LATE"
	end
	return {
		class = (class :: any) :: TimingClass,
		label = label,
		detail = if ms == 0 then "dead on" else `{ms} ms {if errorSeconds < 0 then "early" else "late"}`,
		errorSeconds = errorSeconds,
		position = math.clamp(errorSeconds / (tolerance() * cfg.MeterRangeFraction), -1, 1),
		tone = CLASS_TONE[class],
	}
end

-- +1 when +x (screen right) points away from the batter.
local function awaySign(side: "Right" | "Left"): number
	return if side == "Left" then -1 else 1
end

function SwingAnalysis.placement(input: Input): Placement?
	if input.aimX == nil or input.aimY == nil then
		return nil
	end
	local m = input.metersPerStud
	local placement: Placement = {
		aimX = input.aimX * m,
		aimY = input.aimY * m,
		ballX = if input.ballX then input.ballX * m else nil,
		ballY = if input.ballY then input.ballY * m else nil,
		vertical = nil,
		lateral = nil,
		offsetCm = nil,
		batterSide = input.batterSide,
	}
	local bx, by = placement.ballX, placement.ballY
	if bx and by then
		local dy = placement.aimY - by
		-- + = the aim sat farther from the batter than the ball.
		local away = (placement.aimX - bx) * awaySign(input.batterSide)
		local call = cfg.PlacementCallMeters
		if math.abs(dy) > call then
			placement.vertical = if dy > 0 then "High" else "Low"
		end
		if math.abs(away) > call then
			placement.lateral = if away > 0 then "Outside" else "Inside"
		end
		placement.offsetCm = math.floor(math.sqrt(dy * dy + away * away) * 100 + 0.5)
	end
	return placement
end

local function cm(studs: number?, metersPerStud: number): string
	if studs == nil then
		return ""
	end
	return string.format(" (~%d cm)", math.floor(math.abs(studs) * metersPerStud * 100 + 0.5))
end

local function timingAdvice(timing: Timing?): string
	if timing == nil then
		return "Watch the pitch all the way in and time your click to its arrival."
	end
	local class = timing.class
	if class == "VeryEarly" then
		return "You're swinging too early. Wait longer before clicking."
	elseif class == "Early" then
		return "A bit early. Let the pitch travel a little deeper before you swing."
	elseif class == "Good" and timing.errorSeconds < 0 then
		return "Close! Try waiting just a little longer."
	elseif class == "Good" then
		return "Close! Start your swing just a touch sooner."
	elseif class == "Late" then
		return "A bit late. Start your swing a little sooner."
	elseif class == "VeryLate" then
		return "Swing sooner to catch up to the pitch."
	end
	return "Timing was right on."
end

local function missReport(input: Input, timing: Timing?): (string, string)
	local reason = input.missReason
	local m = input.metersPerStud
	if reason == "Over" then
		return "Vertical", "You swung over the ball. Aim lower" .. cm(input.missAmount, m) .. "."
	elseif reason == "Under" then
		return "Vertical", "You swung under the ball. Raise your aim" .. cm(input.missAmount, m) .. "."
	elseif reason == "Inside" then
		return "Lateral", "The pitch was inside. Move your aim closer to your body" .. cm(input.missAmount, m) .. "."
	elseif reason == "Outside" then
		return "Lateral", "The pitch was away. Reach out: aim farther from your body" .. cm(input.missAmount, m) .. "."
	elseif reason == "Early" or reason == "Late" or reason == "NoOverlap" then
		return "Timing", timingAdvice(timing)
	end
	return "Unknown", "Keep your eye on the ball and adjust your aim to its path."
end

local function contactReport(input: Input, contact: ContactInput, timing: Timing?): (string, string)
	local f = contact.factors
	local timingOff = timing ~= nil and timing.class ~= "Perfect" and timing.class ~= "Good"
	if contact.label == "Perfect" then
		return "Perfect", if timing and timing.class == "Perfect"
			then "Perfect timing and excellent contact!"
			else "Crushed it! Square contact on the sweet spot."
	end
	if input.territory == "Foul" and timingOff and timing then
		if timing.errorSeconds < 0 then
			return "Timing", "Pulled foul: you were early. Wait a little longer to keep it fair."
		end
		return "Timing", "Fouled off late. Start your swing a little sooner."
	end
	-- The weakest measured contact factor is the most useful single fix.
	-- (Efficiency, how head-on the collision was, follows from these and is
	-- only mentioned when the three correctable factors are all good.) The
	-- vertical tip follows the confirmed launch angle when it is known: a ball
	-- that already flew at a good angle needs no height correction.
	local launch = input.launchAngleDegrees
	local function verticalTip(): string?
		local under = if launch then launch >= cfg.PopUpDegrees else contact.verticalOffset > 0
		local topped = if launch then launch <= cfg.GroundBallDegrees else contact.verticalOffset <= 0
		if under then
			return "You got under it and popped it up. Aim a little higher, closer to the ball's center."
		elseif topped then
			return "You topped it into the ground. Aim a little lower, closer to the ball's center."
		end
		return nil
	end
	local order: { { name: string, value: number } } = {
		{ name = "timing", value = f.timing },
		{ name = "sweetSpot", value = f.sweetSpot },
		{ name = "vertical", value = f.vertical },
	}
	table.sort(order, function(a, b)
		return a.value < b.value
	end)
	for _, item in order do
		local name, value = item.name, item.value
		if value >= cfg.TipFactorBelow then
			break
		end
		if name == "timing" then
			if timing and timing.errorSeconds < 0 then
				return "Timing", "Contact was early. Wait a touch longer to square it up."
			end
			return "Timing", "Contact was late. Start your swing a touch sooner."
		elseif name == "sweetSpot" then
			if contact.sweetSpotOffset > 0 then
				return "SweetSpot", "Off the end of the bat. Aim a little farther out toward the pitch."
			end
			return "SweetSpot", "Jammed near the handle. Aim a little closer to your body."
		else
			local tip = verticalTip()
			if tip then
				return "Vertical", tip
			end
		end
	end
	if contact.label == "Great" then
		return "Efficiency", "Great contact! Keep that timing and aim."
	end
	return "Efficiency", "Solid swing. Meet the ball more squarely for extra power."
end

local CONTACT_TONE: { [string]: Tone } = { Perfect = "Perfect", Great = "Good", Good = "Fair", Weak = "Poor" }

function SwingAnalysis.report(input: Input): Report
	local contact = input.contact
	local timingError = if contact and contact.timingErrorSeconds then contact.timingErrorSeconds else input.timingErrorSeconds
	local timing = if timingError and timingError == timingError then SwingAnalysis.timing(timingError) else nil
	local placement = SwingAnalysis.placement(input)
	local stats: { Stat } = {}
	if contact then
		local primary, advice = contactReport(input, contact, timing)
		table.insert(stats, { label = "CONTACT", value = string.upper(contact.label) })
		if input.exitSpeedMph then
			table.insert(stats, { label = "EXIT VELO", value = `{math.floor(input.exitSpeedMph + 0.5)} MPH` })
		end
		if input.launchAngleDegrees then
			table.insert(stats, { label = "LAUNCH", value = `{math.floor(input.launchAngleDegrees + 0.5)}°` })
		end
		if input.distanceText then
			table.insert(stats, { label = "DISTANCE", value = input.distanceText })
		end
		return {
			kind = "Contact",
			headline = input.resultHeadline or `{string.upper(contact.label)} CONTACT`,
			tone = CONTACT_TONE[contact.label] or "Fair",
			timing = timing,
			placement = placement,
			primary = primary,
			advice = advice,
			stats = stats,
		}
	end
	local primary, advice = missReport(input, timing)
	return {
		kind = "Miss",
		headline = "SWING & MISS",
		tone = "Poor",
		timing = timing,
		placement = placement,
		primary = primary,
		advice = advice,
		stats = stats,
	}
end

export type Key = { laneId: string, pitchId: number, seq: number }

-- Whether a result should replace the one on screen: a different lane always
-- does; on the same lane only a later pitch, or a later swing at the same
-- pitch, does (stale, duplicate and out-of-order packets are ignored).
function SwingAnalysis.supersedes(current: Key?, incoming: Key): boolean
	if current == nil or current.laneId ~= incoming.laneId then
		return true
	end
	if incoming.pitchId ~= current.pitchId then
		return incoming.pitchId > current.pitchId
	end
	return incoming.seq > current.seq
end

return SwingAnalysis
