--!strict
local Config = require(script.Parent.GameplayConfig)
local LandingDetector = require(script.Parent.Parent.BattedBall.LandingDetector)
local Rules = {}

export type Award = {
	hitId: number,
	distanceMeters: number,
	previousMeters: number,
	improvementMeters: number,
	baseline: boolean,
	newRecord: boolean,
	milestonesFeet: { number },
	intensity: number,
}

function Rules.finite(value: number): boolean
	return value == value and math.abs(value) < math.huge
end

function Rules.eligible(outcome: LandingDetector.OutcomePayload): boolean
	local carry = outcome.carryMeters
	return outcome.kind == "Landed"
		and outcome.territory == "Fair"
		and not outcome.territoryProvisional
		and carry ~= nil
		and Rules.finite(carry)
		and carry >= 0
end

function Rules.award(hitId: number, distance: number, previous: number, reached: { [number]: boolean }): Award
	local newRecord = distance > previous + Config.Records.TieToleranceMeters
	local baseline = previous == 0 and newRecord
	local milestones = {}
	for _, feet in Config.Records.MilestonesFeet do
		if distance >= feet * 0.3048 and not reached[feet] then
			reached[feet] = true
			table.insert(milestones, feet)
		end
	end
	local improvement = if newRecord then distance - previous else 0
	return {
		hitId = hitId,
		distanceMeters = distance,
		previousMeters = previous,
		improvementMeters = improvement,
		baseline = baseline,
		newRecord = newRecord,
		milestonesFeet = milestones,
		intensity = if baseline
			then 0.25
			else math.clamp(improvement / (Config.Records.ImprovementForFullCelebrationFeet * 0.3048), 0, 1),
	}
end

return Rules
