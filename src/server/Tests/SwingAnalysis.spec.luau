--!strict
-- Stage 1 swing analysis: timing classes, placement calls and coaching tips
-- built from real resolver output (the same data the server sends), for
-- both batting hands, and that misses never carry exit velocity / launch.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Geometry = require(Shared.Pitching.LaneGeometry)
local Pitch = require(Shared.Pitching.Pitch)
local PitchPhysics = require(Shared.Pitching.PitchPhysics)
local BattingConfig = require(Shared.Batting.BattingConfig)
local SwingModel = require(Shared.Batting.SwingModel)
local SwingResolver = require(Shared.Batting.SwingResolver)
local PresentationConfig = require(Shared.Presentation.PresentationConfig)
local Analysis = require(Shared.Presentation.SwingAnalysis)
local Test = require(script.Parent.TestUtil)

local units = Test.units
local CM = units.toStuds(0.01)
local EPOCH = 1.7e9

type Setup = { geometry: Geometry.Geometry, flight: Pitch.Flight, ballX: number, ballY: number, ideal: number }

local function setup(geometry: Geometry.Geometry, seed: number): Setup
	local release = EPOCH + 1
	local data = Pitch.generate(geometry, Test.rng(seed), { id = seed, laneId = "Test", windupTime = release - 1, releaseTime = release })
	local flight = Pitch.buildFlight(geometry, data)
	local ideal = SwingResolver.idealContactTime(geometry, flight) :: number
	local offset = PitchPhysics.sample(flight.trajectory, ideal - release) - SwingModel.contactPlane(geometry).point
	return { geometry = geometry, flight = flight, ballX = offset:Dot(geometry.right), ballY = offset:Dot(geometry.up), ideal = ideal }
end

-- timing ms (- = early), vertical cm (+ = aimed high), lateral cm (+ = aim farther from the batter)
local function swing(s: Setup, timingMs: number, verticalCm: number, lateralCm: number): (SwingResolver.Resolution, number, number)
	local across = -SwingModel.batterSideSign(s.geometry)
	local aimX, aimY = s.ballX + across * lateralCm * CM, s.ballY + verticalCm * CM
	local sw = SwingModel.new(s.geometry, aimX, aimY, SwingModel.startTimeForSquareAt(s.ideal + timingMs / 1000))
	return SwingResolver.resolve(s.geometry, s.flight, sw), aimX, aimY
end

-- What the client builds from the server payload (same fields).
local function report(s: Setup, r: SwingResolver.Resolution, aimX: number, aimY: number, extra: { [string]: any }?): Analysis.Report
	local input: Analysis.Input = {
		batterSide = if s.geometry.inputs.batterSide == "Left" then "Left" else "Right",
		metersPerStud = units.metersPerStud,
		aimX = aimX,
		aimY = aimY,
		ballX = r.ballX,
		ballY = r.ballY,
		timingErrorSeconds = r.timingErrorSeconds,
		missReason = r.missReason,
		missAmount = r.missAmount,
		contact = r.contact :: any,
	}
	for key, value in (extra or {}) :: { [string]: any } do
		(input :: any)[key] = value
	end
	return Analysis.report(input)
end

local function hands(): { [string]: Geometry.Geometry }
	local out = {}
	for name, base in Test.geometries() do
		out[name .. "/Right"] = Geometry.forBatter(base, "Right")
		out[name .. "/Left"] = Geometry.forBatter(base, "Left")
	end
	return out
end

return function(t)
	t.test("timing classes follow the contact-quality timing tolerance", function()
		local tol = BattingConfig.Quality.TimingToleranceSeconds
		local cfg = PresentationConfig.SwingAnalysis
		Test.assertEqual(Analysis.timingClass(0), "Perfect")
		Test.assertEqual(Analysis.timingClass(tol * cfg.PerfectFraction * 0.99), "Perfect")
		Test.assertEqual(Analysis.timingClass(-tol * cfg.GoodFraction * 0.99), "Good")
		Test.assertEqual(Analysis.timingClass(-tol * 0.9), "Early")
		Test.assertEqual(Analysis.timingClass(tol * 0.9), "Late")
		Test.assertEqual(Analysis.timingClass(-tol * 1.2), "VeryEarly")
		Test.assertEqual(Analysis.timingClass(tol * 3), "VeryLate")
		Test.assertEqual(Analysis.timing(0.02).label, "JUST LATE")
		Test.assertEqual(Analysis.timing(-0.02).label, "JUST EARLY")
		Test.assertEqual(Analysis.timing(-1).position, -1)
		Test.assertEqual(Analysis.timing(1).position, 1)
	end)

	t.test("very early and very late misses get timing feedback, never aim advice or batted-ball numbers", function()
		for name, geo in hands() do
			local s = setup(geo, 7)
			for _, ms in { -140, -100, 90 } do
				local r, x, y = swing(s, ms, 0, 0)
				Test.assertTrue(r.contact == nil, `{name} {ms}: miss`)
				local rep = report(s, r, x, y, { exitSpeedMph = 99, launchAngleDegrees = 30 })
				Test.assertEqual(rep.kind, "Miss")
				Test.assertEqual(rep.primary, "Timing", `{name} {ms}`)
				local timing = rep.timing :: Analysis.Timing
				Test.assertEqual(timing.class, if ms < 0 then "VeryEarly" else "VeryLate", `{name} {ms}`)
				Test.assertTrue(string.find(rep.advice, if ms < 0 then "early" else "ooner") ~= nil, rep.advice)
				Test.assertEqual(#rep.stats, 0, "no fabricated exit velocity / launch angle on a miss")
			end
		end
	end)

	t.test("perfect and near-perfect contact are praised and graded from the server contact", function()
		for name, geo in hands() do
			local s = setup(geo, 3)
			local r, x, y = swing(s, 0, 0, 0)
			local contact = r.contact
			assert(contact, `{name}: ideal swing should connect`)
			local rep = report(s, r, x, y, { exitSpeedMph = 101.4, launchAngleDegrees = 27.6 })
			Test.assertEqual(rep.kind, "Contact")
			Test.assertEqual((rep.timing :: Analysis.Timing).class, "Perfect")
			Test.assertEqual(rep.stats[1].value, string.upper(contact.label))
			Test.assertEqual(rep.stats[2].value, "101 MPH")
			Test.assertEqual(rep.stats[3].value, "28°")
			if contact.label == "Perfect" then
				Test.assertEqual(rep.advice, "Perfect timing and excellent contact!")
			end
			local placement = rep.placement :: Analysis.Placement
			Test.assertTrue(placement.vertical == nil and placement.lateral == nil, "aimed on the ball")
			-- Slightly early but still contact: timing is called "Good / just early".
			local near, nx, ny = swing(s, -18, 0, 0)
			if near.contact then
				local nearRep = report(s, near, nx, ny)
				Test.assertEqual((nearRep.timing :: Analysis.Timing).label, "JUST EARLY")
			end
		end
	end)

	t.test("high and low misses call the aim and give the matching correction", function()
		for name, geo in hands() do
			local s = setup(geo, 11)
			local over, ox, oy = swing(s, 0, 25, 0)
			Test.assertEqual(over.missReason, "Over", name)
			local high = report(s, over, ox, oy)
			Test.assertEqual((high.placement :: Analysis.Placement).vertical, "High")
			Test.assertEqual(high.primary, "Vertical")
			Test.assertTrue(string.find(high.advice, "lower") ~= nil, high.advice)
			local under, ux, uy = swing(s, 0, -25, 0)
			Test.assertEqual(under.missReason, "Under", name)
			local low = report(s, under, ux, uy)
			Test.assertEqual((low.placement :: Analysis.Placement).vertical, "Low")
			Test.assertTrue(string.find(low.advice, "Raise") ~= nil, low.advice)
		end
	end)

	t.test("inside and outside misses are relative to the batter for both hands", function()
		for name, geo in hands() do
			local s = setup(geo, 5)
			-- Aim far from the batter: the ball was inside.
			local inside, ix, iy = swing(s, 0, 0, 80)
			Test.assertEqual(inside.missReason, "Inside", name)
			local rep = report(s, inside, ix, iy)
			Test.assertEqual((rep.placement :: Analysis.Placement).lateral, "Outside", "the aim sat outside the ball")
			Test.assertTrue(string.find(rep.advice, "closer to your body") ~= nil, rep.advice)
			local outside, ox, oy = swing(s, 0, 0, -45)
			Test.assertEqual(outside.missReason, "Outside", name)
			local rep2 = report(s, outside, ox, oy)
			Test.assertEqual((rep2.placement :: Analysis.Placement).lateral, "Inside")
			Test.assertTrue(string.find(rep2.advice, "farther from your body") ~= nil, rep2.advice)
			-- Diagram coordinates are the camera view: the aim is on the side away
			-- from the batter, which is screen right for a righty and left for a lefty.
			local p = rep.placement :: Analysis.Placement
			local screenRight = (p.aimX - (p.ballX :: number)) > 0
			Test.assertEqual(screenRight, geo.inputs.batterSide ~= "Left", name)
		end
	end)

	t.test("the reported ball crossing is the resolver's crossing of the contact plane", function()
		for name, geo in hands() do
			local s = setup(geo, 13)
			local r = swing(s, 40, 10, 0)
			Test.assertNear(r.ballX :: number, s.ballX, 1e-4, name)
			Test.assertNear(r.ballY :: number, s.ballY, 1e-4, name)
		end
	end)

	t.test("contact tips target the weakest measured factor; fouls from timing say so", function()
		local base: Analysis.Input = {
			batterSide = "Right",
			metersPerStud = units.metersPerStud,
			aimX = 0,
			aimY = 2.8,
			ballX = 0,
			ballY = 2.8,
		}
		local function contact(factors: { [string]: number }, sweet: number, vertical: number, timing: number): Analysis.ContactInput
			return {
				label = "Good",
				score = 0.5,
				factors = {
					timing = factors.timing or 1,
					sweetSpot = factors.sweetSpot or 1,
					vertical = factors.vertical or 1,
					efficiency = 0.9,
				},
				sweetSpotOffset = sweet,
				verticalOffset = vertical,
				timingErrorSeconds = timing,
			}
		end
		local function with(c: Analysis.ContactInput, extra: { [string]: any }?): Analysis.Report
			local input = table.clone(base)
			input.contact = c
			for key, value in (extra or {}) :: { [string]: any } do
				(input :: any)[key] = value
			end
			return Analysis.report(input)
		end
		Test.assertEqual(with(contact({ sweetSpot = 0.3 }, 0.5, 0, 0)).primary, "SweetSpot")
		Test.assertTrue(string.find(with(contact({ sweetSpot = 0.3 }, 0.5, 0, 0)).advice, "end of the bat") ~= nil)
		Test.assertTrue(string.find(with(contact({ sweetSpot = 0.3 }, -0.5, 0, 0)).advice, "handle") ~= nil)
		Test.assertTrue(string.find(with(contact({ vertical = 0.2 }, 0, 0.1, 0)).advice, "under") ~= nil)
		Test.assertTrue(string.find(with(contact({ vertical = 0.2 }, 0, -0.1, 0)).advice, "topped") ~= nil)
		Test.assertTrue(string.find(with(contact({ timing = 0.2 }, 0, 0, -0.05)).advice, "early") ~= nil)
		local foul = with(contact({ timing = 0.5 }, 0, 0, -0.05), { territory = "Foul", resultHeadline = "FOUL BALL" })
		Test.assertTrue(string.find(foul.advice, "Pulled foul") ~= nil, foul.advice)
		Test.assertEqual(foul.headline, "FOUL BALL")
		-- Distance only appears once the server outcome supplies it.
		local pending = with(contact({}, 0, 0, 0), { exitSpeedMph = 90 })
		for _, stat in pending.stats do
			Test.assertTrue(stat.label ~= "DISTANCE", "no distance before the outcome")
		end
		local landed = with(contact({}, 0, 0, 0), { exitSpeedMph = 90, distanceText = "402 FT" })
		Test.assertEqual(landed.stats[#landed.stats].value, "402 FT")
	end)

	t.test("over / under contact reads the same for both batting hands", function()
		for name, geo in hands() do
			local s = setup(geo, 3)
			-- Aimed above the ball's center: the bat tops it.
			local top, tx, ty = swing(s, 0, 3, 0)
			local topContact = top.contact
			assert(topContact, `{name}: +3 cm should still connect`)
			Test.assertTrue(topContact.verticalOffset < 0, `{name}: ball below the bat when aiming high`)
			Test.assertTrue(topContact.launchAngleHintDegrees < 0, `{name}: driven down`)
			-- Aimed below the center: the bat gets under it.
			local low, lx, ly = swing(s, 0, -3, 0)
			local lowContact = low.contact
			assert(lowContact, `{name}: -3 cm should still connect`)
			Test.assertTrue(lowContact.verticalOffset > 0, `{name}: ball above the bat when aiming low`)
			-- Unconfirmed (no launch yet): the tip follows the measured side.
			local forced = function(r: SwingResolver.Resolution, x: number, y: number): Analysis.Report
				local c = table.clone(r.contact :: any)
				c.label = "Good"
				c.factors = { timing = 1, sweetSpot = 1, vertical = 0.2, efficiency = 1 }
				local copy = table.clone(r) :: any
				copy.contact = c
				return report(s, copy :: SwingResolver.Resolution, x, y)
			end
			Test.assertTrue(string.find(forced(top, tx, ty).advice, "topped") ~= nil, name)
			Test.assertTrue(string.find(forced(low, lx, ly).advice, "under") ~= nil, name)
		end
	end)

	t.test("height tips follow the confirmed launch angle", function()
		local input: Analysis.Input = {
			batterSide = "Left",
			metersPerStud = units.metersPerStud,
			aimX = 0,
			aimY = 2.8,
			ballX = 0,
			ballY = 2.8,
			contact = {
				label = "Good",
				score = 0.5,
				factors = { timing = 1, sweetSpot = 1, vertical = 0.3, efficiency = 1 },
				sweetSpotOffset = 0,
				verticalOffset = 0.1,
				timingErrorSeconds = 0,
			},
		}
		input.launchAngleDegrees = 62
		Test.assertTrue(string.find(Analysis.report(input).advice, "popped it up") ~= nil)
		input.launchAngleDegrees = -12
		Test.assertTrue(string.find(Analysis.report(input).advice, "topped it") ~= nil)
		input.launchAngleDegrees = 24 -- a good fly ball: no height correction
		local good = Analysis.report(input)
		Test.assertTrue(good.primary ~= "Vertical", good.advice)
	end)

	t.test("stale, duplicate and out-of-order results never replace newer feedback", function()
		local current = { laneId = "Lane1", pitchId = 5, seq = 9 }
		Test.assertTrue(Analysis.supersedes(nil, current))
		Test.assertTrue(not Analysis.supersedes(current, { laneId = "Lane1", pitchId = 5, seq = 9 }), "duplicate")
		Test.assertTrue(not Analysis.supersedes(current, { laneId = "Lane1", pitchId = 4, seq = 12 }), "older pitch")
		Test.assertTrue(not Analysis.supersedes(current, { laneId = "Lane1", pitchId = 5, seq = 8 }), "older swing")
		Test.assertTrue(Analysis.supersedes(current, { laneId = "Lane1", pitchId = 6, seq = 10 }))
		Test.assertTrue(Analysis.supersedes(current, { laneId = "power/Lane2", pitchId = 1, seq = 10 }), "new lane")
	end)

	t.test("simultaneous swings on different lanes produce independent reports", function()
		local geos = hands()
		local a = setup(geos["straight/Right"], 21)
		local b = setup(geos["rotated/Left"], 21)
		local ra, ax, ay = swing(a, -100, 0, 0)
		local rb, bx, by = swing(b, 0, 25, 0)
		local first = report(a, ra, ax, ay)
		report(b, rb, bx, by)
		local again = report(a, ra, ax, ay)
		Test.assertEqual(first.advice, again.advice)
		Test.assertEqual(first.primary, "Timing")
		Test.assertEqual(report(b, rb, bx, by).primary, "Vertical")
	end)
end
