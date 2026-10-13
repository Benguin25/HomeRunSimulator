--!strict
local Config = require(script.Parent.ProgressionConfig)
local BallConfig = require(script.Parent.Parent.BattedBall.BattedBallConfig)
local Impact = require(script.Parent.Parent.BattedBall.ImpactModel)
local PitchConfig = require(script.Parent.Parent.Pitching.PitchConfig)
local Landing = require(script.Parent.Parent.BattedBall.LandingDetector)
local Rules = {}

function Rules.finite(value: any): boolean
	return typeof(value) == "number" and value == value and math.abs(value) < math.huge
end
function Rules.level(value: any): boolean
	return Rules.finite(value) and value >= 0 and value <= Config.Power.MaxLevel and value % 1 == 0
end
function Rules.rebirthCount(value: any): boolean
	return Rules.finite(value) and value % 1 == 0 and value >= 0 and value <= Config.Rebirth.MaxRebirths
end
function Rules.permanentMultiplier(rebirths: number): number
	assert(Rules.rebirthCount(rebirths), "invalid rebirth count")
	return 1 + Config.Rebirth.BonusPerRebirth * rebirths
end
function Rules.rebirthRequirement(rebirths: number): number?
	assert(Rules.rebirthCount(rebirths), "invalid rebirth count")
	return if rebirths < Config.Rebirth.MaxRebirths
		then Config.Rebirth.FirstLevel + Config.Rebirth.LevelsPerRebirth * rebirths
		else nil
end
function Rules.multiplier(level: number, rebirths: number?): number
	assert(Rules.level(level), "invalid power level")
	return Config.Power.Growth ^ level * Rules.permanentMultiplier(rebirths or 0)
end
function Rules.cost(level: number): number?
	assert(Rules.level(level), "invalid power level")
	return if level < Config.Power.MaxLevel
		then math.ceil(Config.Power.BaseCost * Config.Power.CostGrowth ^ level)
		else nil
end
function Rules.nextBenefit(level: number): number?
	return if level < Config.Power.MaxLevel then Rules.multiplier(level + 1) - Rules.multiplier(level) else nil
end
function Rules.impactConfig(level: number, rebirths: number?): Impact.Config
	local multiplier = Rules.multiplier(level, rebirths)
	local power = table.clone(BallConfig.Power)
	-- Extend the existing post-impulse velocity multiplier, preserving direction,
	-- measured contact and spin. Level 0 is exactly the Stage 5A configuration.
	power.ArcadePowerMultiplier *= multiplier
	power.MaxLaunchEnergyJoules = math.min(
		power.MaxLaunchEnergyJoules * multiplier ^ 2,
		0.5 * PitchConfig.Ball.MassKg * Config.Limits.MaxExitSpeedMps ^ 2
	)
	return { Impact = BallConfig.Impact, Power = power, ArcadeContact = BallConfig.ArcadeContact }
end

-- Only server-confirmed first impacts may reach this function. Short/provisional
-- grounders, fouls and walls get a flat contact reward, never projected distance.
function Rules.reward(outcome: Landing.OutcomePayload): (number, string)
	if
		not Rules.finite(outcome.endTime)
		or outcome.endTime < 0
		or typeof(outcome.territoryProvisional) ~= "boolean"
		or (outcome.territory ~= "Fair" and outcome.territory ~= "Foul")
	then
		return 0, "Invalid"
	end
	if outcome.kind == "NoImpact" then
		return 0, "Unresolved"
	end
	local distance = if outcome.kind == "Landed" then outcome.carryMeters else outcome.impactDistanceMeters
	if
		(outcome.kind ~= "Landed" and outcome.kind ~= "Obstacle")
		or not Rules.finite(distance)
		or (distance :: number) < 0
		or (distance :: number) > Config.Reward.MaxDistanceMeters
	then
		return 0, "Invalid"
	end
	if outcome.kind == "Landed" then
		if outcome.surface ~= "Ground" then
			return 0, "Invalid"
		end
	elseif outcome.surface ~= "Wall" and outcome.surface ~= "Ceiling" then
		return 0, "Invalid"
	end
	if outcome.territory == "Foul" then
		return Config.Reward.ContactCoins, "Foul contact"
	end
	if outcome.kind == "Obstacle" then
		return Config.Reward.ContactCoins, "Obstacle contact"
	end
	if outcome.territoryProvisional then
		return Config.Reward.ContactCoins, "Provisional contact"
	end
	return Config.Reward.ContactCoins + math.floor((distance :: number) / 0.3048 * Config.Reward.CoinsPerFoot),
		"Fair carry"
end
return Rules
