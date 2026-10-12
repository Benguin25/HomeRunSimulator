--!strict
-- Bat-ball collision: turns the measured contact (normal, velocities, where
-- on the bat, incoming spin) into the ball's outgoing velocity and spin.
--
-- Model: an instantaneous impulse between the ball (a sphere) and a free bat
-- represented by its effective mass at the impact point (the hands barely
-- matter during the ~1 ms collision; Nathan 2000, Cross 2011).
--
--   Effective bat mass at distance b from the bat's center of mass:
--     1/M_eff = 1/M + b^2 / I_cm
--   Normal impulse (n = unit normal from bat to ball, u_n = (v - V).n < 0):
--     J_n = -(1 + e) u_n / (1/m + 1/M_eff)
--   For a head-on hit this is the familiar batted-ball-speed formula
--     v_out = q v_pitch + (1 + q) v_bat,  q = (e - m/M_eff) / (1 + m/M_eff).
--   Tangential impulse (friction), applied at the ball's contact point
--   r_c = -R n. The impulse needed to stop the contact point slipping
--   relative to the bat (rolling) is
--     J_t = -(1 + e_t) s_t / (1/m + R^2/I_ball + 1/M_eff),
--   with s_t the tangential slip velocity (including the incoming spin),
--   capped by Coulomb friction |J_t| <= mu J_n (then the ball slides).
--   Spin change: dw = (r_c x J_t) / I_ball. The normal impulse passes
--   through the ball's center and adds no spin.
--
-- What this produces, without any quality labels:
--   * squared up: normal along the bat's motion, sweet-spot e and M_eff -> max speed
--   * under the ball: normal tilted up -> higher launch, friction adds backspin
--   * topped: normal tilted down -> grounder with topspin
--   * inside / outside (handle / tip): lower restitution and lower M_eff -> weaker
--   * glancing: small normal approach speed -> little impulse
--   * early / late: the normal turns with the bat -> pull / opposite field
--
-- Simplifications (documented): constant e (no speed dependence), the bat's
-- effective mass is used for the tangential direction too, no bat vibration
-- or bending model, and the swing itself is not slowed by the collision.
-- All quantities SI, world-oriented Vector3s (directions only; no studs).

local PitchConfig = require(script.Parent.Parent.Pitching.PitchConfig)

local BattedBallConfig = require(script.Parent.BattedBallConfig)

local ImpactModel = {}

export type Config = {
	Impact: typeof(BattedBallConfig.Impact),
	Power: typeof(BattedBallConfig.Power),
	ArcadeContact: typeof(BattedBallConfig.ArcadeContact)?,
}

export type Input = {
	normal: Vector3, -- unit, bat axis -> ball center
	up: Vector3?, -- swing-plane up; omitted for raw/analytic physical impact tests
	ballVelocity: Vector3, -- m/s
	ballSpin: Vector3, -- rad/s (incoming pitch spin)
	batVelocity: Vector3, -- m/s, bat surface at the contact point (before power scaling)
	distanceFromKnob: number, -- m along the bat
	sweetSpotFromKnob: number, -- m
}

export type Result = {
	velocity: Vector3, -- m/s, outgoing
	spin: Vector3, -- rad/s, outgoing
	batVelocity: Vector3, -- m/s, after BatSpeedMultiplier
	approachSpeed: number, -- m/s along the normal (> 0 = approaching)
	restitution: number,
	effectiveBatMass: number, -- kg
	collisionEfficiency: number, -- q at this point on the bat
	normalImpulse: number, -- N s
	tangentialImpulse: number, -- N s
	sliding: boolean, -- friction limit reached (contact point still slipping)
	separated: boolean, -- no impulse: the surfaces were not approaching
	energyCapped: boolean,
	-- Speed a head-on hit at the sweet spot would give with the same ball and
	-- bat speeds (q v_ball + (1 + q) v_bat). Used to describe contact.
	idealExitSpeed: number,
}

export type ContactType = "Squared" | "Under" | "Topped" | "Inside" | "Outside" | "Glancing" | "Weak"

local function finite(v: Vector3): boolean
	return v.X == v.X and v.Y == v.Y and v.Z == v.Z and math.abs(v.X) < math.huge and math.abs(v.Y) < math.huge and math.abs(v.Z) < math.huge
end

-- Normal restitution at `offset` meters from the sweet spot (before power scaling).
function ImpactModel.restitution(offset: number, impact: typeof(BattedBallConfig.Impact)?): number
	local cfg = impact or BattedBallConfig.Impact
	local w = cfg.RestitutionFalloffMeters
	local falloff = if w > 0 then math.exp(-(offset / w) ^ 2) else (if offset == 0 then 1 else 0)
	return cfg.MinRestitution + (cfg.SweetSpotRestitution - cfg.MinRestitution) * falloff
end

-- 1 / M_eff at `distanceFromKnob` meters (kg^-1).
function ImpactModel.inverseEffectiveMass(distanceFromKnob: number, impact: typeof(BattedBallConfig.Impact)?): number
	local bat = (impact or BattedBallConfig.Impact).Bat
	local b = distanceFromKnob - bat.CenterOfMassFromKnobMeters
	return 1 / bat.MassKg + b * b / bat.MomentOfInertiaKgM2
end

-- Collision efficiency q = (e - r) / (1 + r), r = m / M_eff.
function ImpactModel.collisionEfficiency(restitution: number, inverseMass: number): number
	local r = PitchConfig.Ball.MassKg * inverseMass
	return (restitution - r) / (1 + r)
end

-- Virtual impact surface: preserve in-plane direction, soften vertical tilt.
-- The actual swept contact/time/position and measured quality are untouched.
-- f(u)=k*u+(1-k)*sign(u)*((max(|u|-s,0)/(1-s))^3).
-- Monotonic for 0<k<=1, C2 at the shoulder, odd, with f(0)=0/f(±1)=±1.
function ImpactModel.contactNormal(normal: Vector3, up: Vector3, config: typeof(BattedBallConfig.ArcadeContact)): Vector3
	if not config.Enabled or config.CenterSlope == 1 then
		return normal
	end
	local u = math.clamp(normal:Dot(up), -1, 1)
	local horizontal = normal - up * u
	if horizontal.Magnitude < 1e-6 then
		return normal
	end
	local k = math.clamp(config.CenterSlope, 0.01, 1)
	local s = math.clamp(config.ShoulderStart, 0, 0.99)
	local shoulder = math.max(0, (math.abs(u) - s) / (1 - s))
	local mapped = k * u + (1 - k) * math.sign(u) * shoulder ^ 3
	return horizontal.Unit * math.sqrt(math.max(0, 1 - mapped * mapped)) + up * mapped
end

function ImpactModel.resolve(input: Input, config: Config?): Result
	local cfg = config or BattedBallConfig
	local impact, power = cfg.Impact, cfg.Power
	local ball = PitchConfig.Ball
	local m, radius = ball.MassKg, ball.RadiusMeters
	local ballInertia = impact.BallInertiaFactor * m * radius * radius

	local n = input.normal
	-- Check real approach first: the adjustment must not turn a separating
	-- contact into an impact. Bad/degenerate normals retain the existing guard.
	if input.up and cfg.ArcadeContact and finite(n) and n.Magnitude >= 0.5
		and -(input.ballVelocity - input.batVelocity * power.BatSpeedMultiplier):Dot(n) > impact.MinApproachSpeedMps then
		n = ImpactModel.contactNormal(n, input.up, cfg.ArcadeContact)
	end
	local v = input.ballVelocity
	local w = input.ballSpin
	local batVelocity = input.batVelocity * power.BatSpeedMultiplier

	local offset = input.distanceFromKnob - input.sweetSpotFromKnob
	local invMass = ImpactModel.inverseEffectiveMass(input.distanceFromKnob, impact)
	local e = math.clamp(ImpactModel.restitution(offset, impact) * power.RestitutionScale, 0, 1)
	local q = ImpactModel.collisionEfficiency(e, invMass)

	local sweetE = math.clamp(ImpactModel.restitution(0, impact) * power.RestitutionScale, 0, 1)
	local sweetQ = ImpactModel.collisionEfficiency(sweetE, ImpactModel.inverseEffectiveMass(input.sweetSpotFromKnob, impact))
	local idealExitSpeed = math.max(0, sweetQ * v.Magnitude + (1 + sweetQ) * batVelocity.Magnitude)

	local approach = -(v - batVelocity):Dot(n)
	local result: Result = {
		velocity = v,
		spin = w,
		batVelocity = batVelocity,
		approachSpeed = approach,
		restitution = e,
		effectiveBatMass = 1 / invMass,
		collisionEfficiency = q,
		normalImpulse = 0,
		tangentialImpulse = 0,
		sliding = false,
		separated = true,
		energyCapped = false,
		idealExitSpeed = idealExitSpeed,
	}
	if not (approach > impact.MinApproachSpeedMps) or not finite(n) or n.Magnitude < 0.5 then
		-- Already separating (or degenerate): the ball keeps its path, like a foul tip.
		return result
	end
	result.separated = false

	local normalImpulse = (1 + e) * approach / (1 / m + invMass)

	-- Tangential slip of the ball's contact point relative to the bat surface.
	local contactArm = -n * radius
	local slip = v + w:Cross(contactArm) - batVelocity
	local tangentialSlip = slip - n * slip:Dot(n)
	local tangentialImpulse = Vector3.zero
	if tangentialSlip.Magnitude > 1e-9 then
		local stiffness = 1 / m + radius * radius / ballInertia + invMass
		local required = tangentialSlip * (-(1 + impact.TangentialRestitution) / stiffness)
		local limit = impact.FrictionCoefficient * normalImpulse
		if required.Magnitude > limit then
			tangentialImpulse = required.Unit * limit
			result.sliding = true
		else
			tangentialImpulse = required
		end
	end

	local velocity = v + (n * normalImpulse + tangentialImpulse) / m
	local spin = (w + contactArm:Cross(tangentialImpulse) / ballInertia) * power.SpinEffectiveness
	velocity *= power.ArcadePowerMultiplier

	local energy = 0.5 * m * velocity:Dot(velocity)
	if energy > power.MaxLaunchEnergyJoules and energy > 0 then
		velocity *= math.sqrt(power.MaxLaunchEnergyJoules / energy)
		result.energyCapped = true
	end

	if finite(velocity) and finite(spin) then
		result.velocity = velocity
		result.spin = spin
		result.normalImpulse = normalImpulse
		result.tangentialImpulse = tangentialImpulse.Magnitude
	end
	return result
end

export type DescribeInput = {
	verticalAngleDegrees: number, -- angle of the impact normal above (+) / below (-) the swing plane
	sweetSpotOffsetMeters: number, -- + toward the tip
	closingFraction: number, -- approach speed / relative speed (1 = head-on)
	exitSpeedRatio: number, -- exit speed / idealExitSpeed
}

-- Descriptive contact type for HUD/debug, derived from the measured contact
-- geometry. Never used by the physics.
function ImpactModel.describe(d: DescribeInput): ContactType
	if d.closingFraction < 0.5 then
		return "Glancing"
	elseif d.sweetSpotOffsetMeters < -0.15 then
		return "Inside"
	elseif d.sweetSpotOffsetMeters > 0.1 then
		return "Outside"
	elseif d.verticalAngleDegrees > 25 then
		return "Under"
	elseif d.verticalAngleDegrees < -12 then
		return "Topped"
	elseif d.exitSpeedRatio < 0.6 then
		return "Weak"
	end
	return "Squared"
end

return ImpactModel
