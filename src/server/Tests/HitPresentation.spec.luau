--!strict
-- Presentation data (Stage 4): contact intensity, the live distance counter,
-- the landing summary and flight styling, against real flights and outcomes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Units = require(Shared.Pitching.Units)
local SwingModel = require(Shared.Batting.SwingModel)
local BattedBall = require(Shared.BattedBall.BattedBall)
local FieldFrame = require(Shared.BattedBall.FieldFrame)
local FlightPhysics = require(Shared.BattedBall.FlightPhysics)
local LandingDetector = require(Shared.BattedBall.LandingDetector)
local HitPresentation = require(Shared.Presentation.HitPresentation)
local PresentationConfig = require(Shared.Presentation.PresentationConfig)

local BattedBallTestUtil = require(script.Parent.BattedBallTestUtil)
local TestUtil = require(script.Parent.TestUtil)

local function frame(): FieldFrame.Frame
	return FieldFrame.new(TestUtil.geometries().rotated)
end

local function outcomeFor(f: FieldFrame.Frame, flight: BattedBall.Flight, shapes: { BattedBallTestUtil.Shape }): LandingDetector.OutcomePayload
	return LandingDetector.toPayload(LandingDetector.evaluate(flight, BattedBallTestUtil.scene(f, shapes).caster))
end

local function feet(meters: number): string
	return tostring(math.floor(meters / Units.METERS_PER_FOOT + 0.5))
end

return function(t)
	t.test("live counter = horizontal distance from home plate (not path length), shown after a short delay", function()
		local f = frame()
		local flight = BattedBallTestUtil.flight(f, { speedMph = 78, launchDegrees = 30, backspinRpm = 2000 })
		local outcome = outcomeFor(f, flight, { BattedBallTestUtil.ground() })
		local hud = PresentationConfig.Hud
		local hidden = HitPresentation.counter({ flight = flight, endTime = outcome.endTime, outcome = nil, elapsed = hud.CounterDelaySeconds * 0.5 })
		TestUtil.assertEqual(hidden.kind, "Hidden", "before the delay")

		local previous = -1
		local path = 0
		local last = BattedBall.positionAt(flight, 0)
		for tt = hud.CounterDelaySeconds, outcome.endTime - 0.01, 0.05 do
			local c = HitPresentation.counter({ flight = flight, endTime = outcome.endTime, outcome = nil, elapsed = tt })
			TestUtil.assertEqual(c.kind, "Live")
			TestUtil.assertEqual(c.tag, "LIVE")
			local x, _, z = FlightPhysics.sample(flight.trajectory, tt)
			TestUtil.assertNear(c.meters, math.sqrt(x * x + z * z), 1e-9, "horizontal distance")
			TestUtil.assertTrue(c.meters >= previous, "a normal fly ball's distance never decreases")
			previous = c.meters
			local p = BattedBall.positionAt(flight, tt)
			path += (p - last).Magnitude * f.metersPerStud
			last = p
		end
		TestUtil.assertTrue(path > previous + 1, "path length is longer than what is displayed")
	end)

	t.test("after the ball stops: CONFIRMING until the server answers, then the server's carry", function()
		local f = frame()
		local flight = BattedBallTestUtil.flight(f, { speedMph = 78, launchDegrees = 25, backspinRpm = 1800 })
		local outcome = outcomeFor(f, flight, { BattedBallTestUtil.ground() })
		local after = outcome.endTime + 0.2
		local confirming = HitPresentation.counter({ flight = flight, endTime = outcome.endTime, outcome = nil, elapsed = after })
		TestUtil.assertEqual(confirming.kind, "Confirming")
		TestUtil.assertTrue(confirming.tag ~= "FINAL", "never claims a final distance without the server")

		-- The final number is the server's, even if it differed from the client's flight.
		local server = table.clone(outcome)
		server.carryMeters = (outcome.carryMeters :: number) + 3
		local final = HitPresentation.counter({ flight = flight, endTime = outcome.endTime, outcome = server, elapsed = after })
		TestUtil.assertEqual(final.kind, "Final")
		TestUtil.assertEqual(final.label, "CARRY")
		TestUtil.assertEqual(final.meters, server.carryMeters, "server carry")
		TestUtil.assertEqual(final.tag, "FINAL")

		local foul = table.clone(outcome)
		foul.territory = "Foul"
		TestUtil.assertEqual(HitPresentation.counter({ flight = flight, endTime = outcome.endTime, outcome = foul, elapsed = after }).tag, "FOUL")
	end)

	t.test("a wall hit never shows a carry; an unresolved flight is labelled as tracked", function()
		local f = frame()
		local flight = BattedBallTestUtil.flight(f, { speedMph = 85, launchDegrees = 18, backspinRpm = 1500 })
		local wall = BattedBallTestUtil.plane("Wall", Vector3.new(45, 0, 0), Vector3.new(-1, 0, 0), function(p)
			return p.Y < 12
		end)
		local hitWall = outcomeFor(f, flight, { BattedBallTestUtil.ground(), wall })
		TestUtil.assertEqual(hitWall.kind, "Obstacle", "scenario")
		local c = HitPresentation.counter({ flight = flight, endTime = hitWall.endTime, outcome = hitWall, elapsed = hitWall.endTime + 0.1 })
		TestUtil.assertEqual(c.kind, "Wall")
		TestUtil.assertTrue(string.find(c.label, "CARRY") == nil, "no carry label")
		TestUtil.assertEqual(c.meters, hitWall.impactDistanceMeters, "impact distance")
		local summary = HitPresentation.summary({ flight = flight, outcome = hitWall, contactLabel = "Great" })
		TestUtil.assertEqual(summary.headline, "OFF THE WALL")
		TestUtil.assertEqual(summary.distanceLabel, "HIT AT")
		TestUtil.assertTrue(summary.note ~= nil and string.find(summary.note :: string, "no carry") ~= nil, "says no carry")

		-- No surfaces at all: the flight leaves the simulated volume.
		local none = outcomeFor(f, flight, {})
		TestUtil.assertEqual(none.kind, "NoImpact", "scenario")
		local tracked = HitPresentation.counter({ flight = flight, endTime = none.endTime, outcome = none, elapsed = none.endTime + 1 })
		TestUtil.assertEqual(tracked.kind, "Tracked")
		TestUtil.assertEqual(tracked.tag, "NO LANDING")
		TestUtil.assertNear(tracked.meters, BattedBall.distanceAt(flight, none.endTime), 1e-9, "last tracked distance")
		local s2 = HitPresentation.summary({ flight = flight, outcome = none })
		TestUtil.assertEqual(s2.headline, "OUT OF RANGE")
		TestUtil.assertEqual(s2.tone, "Neutral")
	end)

	t.test("landing summary uses the measured values", function()
		local f = frame()
		local flight = BattedBallTestUtil.flight(f, { speedMph = 79, launchDegrees = 28, backspinRpm = 2000, sprayDegrees = 5 })
		local outcome = outcomeFor(f, flight, { BattedBallTestUtil.ground() })
		local summary = HitPresentation.summary({ flight = flight, outcome = outcome, contactLabel = "Perfect" })
		TestUtil.assertEqual(summary.headline, "FAIR BALL")
		TestUtil.assertEqual(summary.tone, "Fair")
		TestUtil.assertEqual(summary.distanceLabel, "DISTANCE")
		TestUtil.assertEqual(summary.distanceValue, feet(outcome.carryMeters :: number))
		TestUtil.assertEqual(summary.distanceUnit, "FT")
		TestUtil.assertEqual(#summary.rows, 3)
		TestUtil.assertEqual(summary.rows[1].value, `{math.floor(flight.exitSpeedMph + 0.5)} MPH`)
		TestUtil.assertEqual(summary.rows[2].value, `{math.floor(flight.launchAngleDegrees + 0.5)}°`)
		TestUtil.assertEqual(summary.rows[3].value, "PERFECT")
		TestUtil.assertTrue(summary.note == nil, "no qualifier for a clean fair landing")

		local foul = table.clone(outcome)
		foul.territory = "Foul"
		TestUtil.assertEqual(HitPresentation.summary({ flight = flight, outcome = foul }).headline, "FOUL BALL")
		TestUtil.assertEqual(#HitPresentation.summary({ flight = flight, outcome = foul }).rows, 2, "no contact row without a label")

		local short = table.clone(outcome)
		short.territoryProvisional = true
		TestUtil.assertTrue(HitPresentation.summary({ flight = flight, outcome = short }).note ~= nil, "provisional call is flagged")

		local missing = HitPresentation.summary({ flight = flight, outcome = nil })
		TestUtil.assertEqual(missing.headline, "RESULT UNAVAILABLE")
		TestUtil.assertTrue(missing.distanceValue == nil, "no invented distance")
	end)

	t.test("distance formatting: feet by default, rounded", function()
		local value, unit = HitPresentation.distanceParts(80)
		TestUtil.assertEqual(value, "262")
		TestUtil.assertEqual(unit, "FT")
	end)

	t.test("intensity grows with exit velocity, quality, closing speed and sweet spot, and is bounded", function()
		local base: HitPresentation.IntensityInput = {
			exitSpeedMph = 60,
			launchDegrees = 25,
			score = 0.6,
			relativeSpeedMps = 35,
			sweetSpotOffsetMeters = 0.04,
		}
		local i0 = HitPresentation.intensity(base)
		local function with(key: string, value: any): number
			local copy = table.clone(base) :: any
			copy[key] = value
			return HitPresentation.intensity(copy)
		end
		TestUtil.assertTrue(with("exitSpeedMph", 80) > i0, "exit velocity")
		TestUtil.assertTrue(with("score", 0.9) > i0, "quality")
		TestUtil.assertTrue(with("relativeSpeedMps", 48) > i0, "closing speed")
		TestUtil.assertTrue(with("sweetSpotOffsetMeters", 0) > i0, "sweet spot")
		TestUtil.assertTrue(with("launchDegrees", -20) < i0, "topped ball is weaker")
		TestUtil.assertTrue(with("exitSpeedMph", 400) <= 1, "future power stays bounded")
		TestUtil.assertTrue(HitPresentation.intensity({ score = 0, relativeSpeedMps = 0, sweetSpotOffsetMeters = 1 }) >= 0, "lower bound")

		TestUtil.assertEqual(HitPresentation.tier(0.1), "Weak")
		TestUtil.assertEqual(HitPresentation.tier(PresentationConfig.Intensity.SolidAt), "Solid")
		TestUtil.assertEqual(HitPresentation.tier(0.99), "Crushed")
	end)

	t.test("real swings: a squared-up barrel hit is more intense than a jammed one", function()
		local geometry = TestUtil.geometries().straight
		local pitch = BattedBallTestUtil.pitch(geometry, 8)
		local across = -SwingModel.batterSideSign()
		local function intensityOf(dx: number, dy: number): number
			local flight, contact = BattedBallTestUtil.hit(geometry, pitch, dx, dy, 0)
			return HitPresentation.intensity({
				exitSpeedMph = flight.exitSpeedMph,
				launchDegrees = flight.launchAngleDegrees,
				score = contact.score,
				relativeSpeedMps = geometry.units.toMeters(contact.relativeVelocity.Magnitude),
				sweetSpotOffsetMeters = geometry.units.toMeters(contact.sweetSpotOffset),
			})
		end
		local squared = intensityOf(0, -0.03)
		local jammed = intensityOf(across * 0.3, -0.02) -- on the handle
		TestUtil.assertTrue(squared > jammed + 0.1, `squared {squared} vs jammed {jammed}`)
		TestUtil.assertEqual(HitPresentation.tier(squared), "Crushed", `squared tier ({squared})`)
	end)

	t.test("trail style grows with speed in a few discrete steps; halo only far away", function()
		local cfg = PresentationConfig.Flight
		local slow = HitPresentation.trailStyle(cfg.TrailSlowMps - 5)
		local fast = HitPresentation.trailStyle(cfg.TrailFastMps + 50)
		TestUtil.assertEqual(slow.level, 0)
		TestUtil.assertEqual(fast.level, cfg.TrailSteps)
		TestUtil.assertTrue(fast.lifetime > slow.lifetime and fast.transparency < slow.transparency, "faster = longer, stronger trail")
		local levels = {}
		for speed = 0, 120, 0.5 do
			levels[HitPresentation.trailStyle(speed).level] = true
		end
		local count = 0
		for _ in levels do
			count += 1
		end
		TestUtil.assertEqual(count, cfg.TrailSteps + 1, "quantized")
		TestUtil.assertEqual(HitPresentation.haloOpacity(cfg.HaloFadeStartMeters - 1), 0)
		TestUtil.assertNear(HitPresentation.haloOpacity(cfg.HaloFadeEndMeters + 50), cfg.HaloMaxOpacity, 1e-9, "far")
	end)
end
