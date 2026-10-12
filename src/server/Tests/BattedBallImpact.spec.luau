--!strict
-- Bat-ball impact model tests (pure Luau). Checks are analytic: the
-- batted-ball-speed formula, the definition of restitution, the rolling
-- condition, Coulomb's limit and energy bookkeeping, rather than comparing the
-- model with itself.
--
-- Axes in these tests: X = toward the pitcher (the bat's motion), Y = up,
-- Z = X x Y (right). For a ball moving +X, backspin is +Z.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PitchConfig = require(Shared.Pitching.PitchConfig)
local BattedBallConfig = require(Shared.BattedBall.BattedBallConfig)
local ImpactModel = require(Shared.BattedBall.ImpactModel)

local BBTU = require(script.Parent.BattedBallTestUtil)
local TestUtil = require(script.Parent.TestUtil)

local m = PitchConfig.Ball.MassKg
local R = PitchConfig.Ball.RadiusMeters
local SWEET = 0.68

local function input(normal: Vector3, ball: Vector3, bat: Vector3, spin: Vector3?, along: number?): ImpactModel.Input
	return {
		normal = normal.Unit,
		ballVelocity = ball,
		ballSpin = spin or Vector3.zero,
		batVelocity = bat,
		distanceFromKnob = along or SWEET,
		sweetSpotFromKnob = SWEET,
	}
end

local function finite(v: Vector3): boolean
	return v.X == v.X and v.Y == v.Y and v.Z == v.Z and math.abs(v.Magnitude) < math.huge
end

-- Total kinetic energy of ball (translation + spin) and the bat's effective mass.
local function energy(v: Vector3, w: Vector3, batV: Vector3, invMass: number, config: ImpactModel.Config): number
	local inertia = config.Impact.BallInertiaFactor * m * R * R
	return 0.5 * m * v:Dot(v) + 0.5 * inertia * w:Dot(w) + 0.5 * batV:Dot(batV) / invMass
end

return function(t)
	t.test("head-on hit matches the batted-ball-speed formula q*v_pitch + (1+q)*v_bat", function()
		local config = BBTU.physicalConfig()
		for _, case in { { 20, 25 }, { 40, 31 }, { 0, 30 }, { 25, 0 } } do
			local vp, vb = case[1], case[2]
			local result = ImpactModel.resolve(input(Vector3.xAxis, Vector3.new(-vp, 0, 0), Vector3.new(vb, 0, 0)), config)
			local e = config.Impact.SweetSpotRestitution
			local r = m * ImpactModel.inverseEffectiveMass(SWEET, config.Impact)
			local q = (e - r) / (1 + r)
			TestUtil.assertNear(result.velocity.X, q * vp + (1 + q) * vb, 1e-4, `v_out for vp {vp}, vb {vb}`)
			TestUtil.assertNear(result.velocity.Y, 0, 1e-5, "no vertical velocity")
			TestUtil.assertNear(result.spin.Magnitude, 0, 1e-4, "no spin from a head-on hit")
			TestUtil.assertNear(result.collisionEfficiency, q, 1e-9, "reported q")
		end
		-- Wood bats measure q ~ 0.2 at the sweet spot (Nathan 2003; Cross 2011).
		local q = ImpactModel.collisionEfficiency(BattedBallConfig.Impact.SweetSpotRestitution, ImpactModel.inverseEffectiveMass(SWEET))
		TestUtil.assertTrue(q > 0.15 and q < 0.3, `sweet-spot q {q} outside the wood-bat range`)
	end)

	t.test("restitution holds along the normal and energy is never created", function()
		local config = BBTU.physicalConfig({ FrictionCoefficient = 0.5 })
		local rng = TestUtil.rng(41)
		local checked = 0
		for _ = 1, 400 do
			local function rv(scale: number): Vector3
				return Vector3.new(rng:NextNumber(-1, 1), rng:NextNumber(-1, 1), rng:NextNumber(-1, 1)) * scale
			end
			local normal = rv(1)
			if normal.Magnitude < 0.2 then
				continue
			end
			local along = rng:NextNumber(0.1, 0.86)
			local ball, bat, spin = rv(45), rv(35), rv(300)
			local data = input(normal, ball, bat, spin, along)
			local result = ImpactModel.resolve(data, config)
			if result.separated then
				continue
			end
			checked += 1
			local n = data.normal
			local invMass = ImpactModel.inverseEffectiveMass(along, config.Impact)
			-- Bat recoil from the impulse the ball received.
			local impulse = (result.velocity - ball) * m
			local batAfter = bat - impulse * invMass
			local before = (ball - bat):Dot(n)
			local after = (result.velocity - batAfter):Dot(n)
			TestUtil.assertNear(after, -result.restitution * before, 2e-3, "normal relative velocity after = -e * before")
			local e0 = energy(ball, spin, bat, invMass, config)
			local e1 = energy(result.velocity, result.spin, batAfter, invMass, config)
			TestUtil.assertTrue(e1 <= e0 * (1 + 1e-5) + 1e-6, string.format("energy grew: %.4f -> %.4f J", e0, e1))
		end
		TestUtil.assertTrue(checked > 150, `only {checked} approaching cases`)
	end)

	t.test("a ball dropped on a very heavy bat rebounds at e times its speed", function()
		local config = BBTU.physicalConfig({ Bat = { MassKg = 1e9, CenterOfMassFromKnobMeters = SWEET, MomentOfInertiaKgM2 = 1e9 } })
		local result = ImpactModel.resolve(input(Vector3.yAxis, Vector3.new(0, -10, 0), Vector3.zero), config)
		TestUtil.assertNear(result.velocity.Y, 10 * config.Impact.SweetSpotRestitution, 1e-4, "rebound speed")
		TestUtil.assertNear(result.effectiveBatMass, 1e9, 1, "effective mass")
	end)

	t.test("with enough friction the contact point leaves the bat rolling (no slip)", function()
		local config = BBTU.physicalConfig({ FrictionCoefficient = 10, TangentialRestitution = 0 })
		for _, degrees in { 10, 25, 40, -15 } do
			local a = math.rad(degrees)
			local n = Vector3.new(math.cos(a), math.sin(a), 0)
			local ball, bat = Vector3.new(-22, -1.5, 0.3), Vector3.new(26, 2.7, 0)
			local spin = Vector3.new(0, 30, -215)
			local result = ImpactModel.resolve(input(n, ball, bat, spin), config)
			TestUtil.assertTrue(not result.sliding, `{degrees} deg: should not slide`)
			local invMass = ImpactModel.inverseEffectiveMass(SWEET, config.Impact)
			local batAfter = bat - (result.velocity - ball) * m * invMass
			local slip = result.velocity + result.spin:Cross(-n * R) - batAfter
			local tangential = slip - n * slip:Dot(n)
			TestUtil.assertTrue(tangential.Magnitude < 2e-3, string.format("%d deg: residual slip %.4f m/s", degrees, tangential.Magnitude))
		end
	end)

	t.test("friction is capped by Coulomb's law", function()
		local config = BBTU.physicalConfig({ FrictionCoefficient = 0.05 })
		local a = math.rad(35)
		local result = ImpactModel.resolve(input(Vector3.new(math.cos(a), math.sin(a), 0), Vector3.new(-30, 0, 0), Vector3.new(30, 0, 0)), config)
		TestUtil.assertTrue(result.sliding, "should slide")
		TestUtil.assertNear(result.tangentialImpulse, 0.05 * result.normalImpulse, 1e-5, "|J_t| = mu J_n")
	end)

	t.test("sweet spot beats the tip and the handle (restitution and effective mass)", function()
		local config = BBTU.physicalConfig()
		local function exitSpeed(along: number): number
			return ImpactModel.resolve(input(Vector3.xAxis, Vector3.new(-23, 0, 0), Vector3.new(27, 0, 0), nil, along), config).velocity.X
		end
		local sweet, tip, handle = exitSpeed(SWEET), exitSpeed(0.85), exitSpeed(0.15)
		TestUtil.assertTrue(sweet > tip + 3, string.format("sweet %.1f vs tip %.1f m/s", sweet, tip))
		TestUtil.assertTrue(sweet > handle + 10, string.format("sweet %.1f vs handle %.1f m/s", sweet, handle))
		TestUtil.assertTrue(handle > 0 and handle < 0.5 * sweet, string.format("handle (jammed) %.1f m/s should be weak", handle))
		-- Effective mass is largest at the balance point and falls toward both ends.
		local mid = ImpactModel.inverseEffectiveMass(0.56)
		TestUtil.assertTrue(mid < ImpactModel.inverseEffectiveMass(SWEET) and mid < ImpactModel.inverseEffectiveMass(0.15), "M_eff peak")
		TestUtil.assertTrue(ImpactModel.restitution(0) > ImpactModel.restitution(0.2), "restitution falls off")
	end)

	t.test("under the ball lifts it with backspin, over the ball drives it down with topspin", function()
		local config = BBTU.physicalConfig()
		local ball, bat = Vector3.new(-23, -1.2, 0), Vector3.new(27, 2.8, 0)
		local function at(degrees: number)
			local a = math.rad(degrees)
			return ImpactModel.resolve(input(Vector3.new(math.cos(a), math.sin(a), 0), ball, bat), config)
		end
		local under, square, over = at(22), at(0), at(-22)
		TestUtil.assertTrue(under.velocity.Y > square.velocity.Y + 5 and under.velocity.Y > 0, "under: higher launch")
		TestUtil.assertTrue(over.velocity.Y < 0, "over: downward launch")
		TestUtil.assertTrue(under.spin.Z > 50, string.format("under: backspin (+Z) expected, got %.1f rad/s", under.spin.Z))
		TestUtil.assertTrue(over.spin.Z < -50, string.format("over: topspin (-Z) expected, got %.1f rad/s", over.spin.Z))
		TestUtil.assertTrue(square.velocity.Magnitude > under.velocity.Magnitude, "squared up is the hardest hit")
	end)

	t.test("incoming pitch backspin is partly retained and reduces batted backspin", function()
		local config = BBTU.physicalConfig()
		local a = math.rad(20)
		local n = Vector3.new(math.cos(a), math.sin(a), 0)
		local ball, bat = Vector3.new(-23, -1.2, 0), Vector3.new(27, 2.8, 0)
		-- A fastball moving -X with backspin spins about (v x up) = -Z.
		local without = ImpactModel.resolve(input(n, ball, bat, Vector3.zero), config)
		local with = ImpactModel.resolve(input(n, ball, bat, Vector3.new(0, 0, -220)), config)
		TestUtil.assertTrue(with.spin.Z < without.spin.Z - 20, string.format("%.1f vs %.1f rad/s", with.spin.Z, without.spin.Z))
	end)

	t.test("early contact sends the ball one way, late contact the other", function()
		local config = BBTU.physicalConfig()
		for _, degrees in { 15, -15, 30, -30 } do
			local a = math.rad(degrees)
			local result = ImpactModel.resolve(input(Vector3.new(math.cos(a), 0, math.sin(a)), Vector3.new(-23, 0, 0), Vector3.new(27, 0, 0)), config)
			TestUtil.assertTrue(result.velocity.Z * degrees > 0, `{degrees} deg: lateral direction follows the normal`)
		end
	end)

	t.test("glancing, zero-speed and degenerate contacts stay finite", function()
		local config = BBTU.physicalConfig()
		-- Normal perpendicular to the relative velocity: no approach, ball unchanged.
		local grazing = ImpactModel.resolve(input(Vector3.yAxis, Vector3.new(-30, 0, 0), Vector3.new(30, 0, 0)), config)
		TestUtil.assertTrue(grazing.separated, "grazing contact should not exchange an impulse")
		TestUtil.assertTrue((grazing.velocity - Vector3.new(-30, 0, 0)).Magnitude < 1e-6, "grazing ball keeps its velocity")
		-- Nearly grazing: small impulse, small change.
		local a = math.rad(88)
		local near = ImpactModel.resolve(input(Vector3.new(math.cos(a), math.sin(a), 0), Vector3.new(-30, 0, 0), Vector3.new(30, 0, 0)), config)
		TestUtil.assertTrue(not near.separated and near.normalImpulse < 1, "nearly grazing impulse")
		-- Separating surfaces (ball already moving away).
		local separating = ImpactModel.resolve(input(Vector3.xAxis, Vector3.new(40, 0, 0), Vector3.new(30, 0, 0)), config)
		TestUtil.assertTrue(separating.separated, "separating contact")
		-- Zeros and a degenerate normal.
		for _, case in {
			input(Vector3.xAxis, Vector3.zero, Vector3.zero),
			input(Vector3.xAxis, Vector3.new(-1e-7, 0, 0), Vector3.new(1e-7, 0, 0)),
			{ normal = Vector3.zero, ballVelocity = Vector3.new(-20, 0, 0), ballSpin = Vector3.zero, batVelocity = Vector3.new(20, 0, 0), distanceFromKnob = SWEET, sweetSpotFromKnob = SWEET },
		} do
			local result = ImpactModel.resolve(case, config)
			TestUtil.assertTrue(finite(result.velocity) and finite(result.spin), "non-finite output")
		end
	end)

	t.test("power knobs: bat speed raises exit speed, arcade power scales it, energy is capped", function()
		local base = ImpactModel.resolve(input(Vector3.xAxis, Vector3.new(-23, 0, 0), Vector3.new(21, 0, 0)), BBTU.physicalConfig())
		local faster = ImpactModel.resolve(
			input(Vector3.xAxis, Vector3.new(-23, 0, 0), Vector3.new(21, 0, 0)),
			BBTU.impactConfig({ BatSpeedMultiplier = 1.5, ArcadePowerMultiplier = 1, MaxLaunchEnergyJoules = math.huge })
		)
		TestUtil.assertTrue(faster.velocity.X > base.velocity.X * 1.3, "bat speed multiplier")
		local arcade = ImpactModel.resolve(
			input(Vector3.xAxis, Vector3.new(-23, 0, 0), Vector3.new(21, 0, 0)),
			BBTU.impactConfig({ BatSpeedMultiplier = 1, ArcadePowerMultiplier = 3, MaxLaunchEnergyJoules = math.huge })
		)
		TestUtil.assertNear(arcade.velocity.X, base.velocity.X * 3, 1e-3, "arcade multiplier")
		local capped = ImpactModel.resolve(
			input(Vector3.xAxis, Vector3.new(-23, 0, 0), Vector3.new(21, 0, 0)),
			BBTU.impactConfig({ BatSpeedMultiplier = 1, ArcadePowerMultiplier = 10, MaxLaunchEnergyJoules = 250 })
		)
		TestUtil.assertTrue(capped.energyCapped, "energy cap flag")
		TestUtil.assertNear(0.5 * m * capped.velocity:Dot(capped.velocity), 250, 0.05, "capped energy")
	end)

	t.test("contact descriptions follow the measured geometry", function()
		local function describe(vertical: number, offset: number, closing: number, ratio: number)
			return ImpactModel.describe({ verticalAngleDegrees = vertical, sweetSpotOffsetMeters = offset, closingFraction = closing, exitSpeedRatio = ratio })
		end
		TestUtil.assertEqual(describe(5, 0, 0.98, 0.95), "Squared", "squared")
		TestUtil.assertEqual(describe(35, 0, 0.9, 0.7), "Under", "under")
		TestUtil.assertEqual(describe(-20, 0, 0.9, 0.8), "Topped", "topped")
		TestUtil.assertEqual(describe(0, -0.25, 0.95, 0.4), "Inside", "inside")
		TestUtil.assertEqual(describe(0, 0.15, 0.95, 0.7), "Outside", "outside")
		TestUtil.assertEqual(describe(0, 0, 0.3, 0.5), "Glancing", "glancing")
		TestUtil.assertEqual(describe(0, 0.05, 0.9, 0.5), "Weak", "weak")
	end)
end
