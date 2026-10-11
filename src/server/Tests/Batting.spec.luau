--!strict
-- Batting tests: swing state machine, aim projection, swept bat-ball
-- collision, contact quality and pitch cleanup (pure Luau; Studio + CLI).
--
-- "Perfect" swings are constructed from the authoritative trajectory: aim at
-- the point where the ball crosses the contact plane, and time the click so
-- the bat is square exactly when the ball gets there.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Pitching = Shared:WaitForChild("Pitching")
local LaneGeometry = require(Pitching.LaneGeometry)
local Pitch = require(Pitching.Pitch)
local PitchLane = require(Pitching.PitchLane)
local PitchPhysics = require(Pitching.PitchPhysics)
local Batting = Shared:WaitForChild("Batting")
local BatCollision = require(Batting.BatCollision)
local BattingConfig = require(Batting.BattingConfig)
local SwingModel = require(Batting.SwingModel)
local SwingResolver = require(Batting.SwingResolver)
local SwingValidator = require(Batting.SwingValidator)

local TestUtil = require(script.Parent.TestUtil)

local units = TestUtil.units
local CM = units.toStuds(0.01)
-- Server clock values are ~1.7e9 s; use a realistic epoch so precision issues show up.
local EPOCH = 1.7e9

local function makeFlight(geometry: LaneGeometry.Geometry, seed: number, releaseTime: number?): Pitch.Flight
	local release = releaseTime or (EPOCH + 1)
	local data = Pitch.generate(geometry, TestUtil.rng(seed), {
		id = seed,
		laneId = "Test",
		windupTime = release - 1,
		releaseTime = release,
	})
	return Pitch.buildFlight(geometry, data)
end

-- Aim coordinates of the ball at the contact plane, and the server time it gets there.
local function perfectAim(geometry: LaneGeometry.Geometry, flight: Pitch.Flight): (number, number, number)
	local ideal = SwingResolver.idealContactTime(geometry, flight)
	assert(ideal, "ball never reaches the contact plane")
	local ball = PitchPhysics.sample(flight.trajectory, ideal - flight.data.releaseTime)
	local offset = ball - SwingModel.contactPlane(geometry).point
	return offset:Dot(geometry.right), offset:Dot(geometry.up), ideal
end

local function swingSquareAt(geometry: LaneGeometry.Geometry, aimX: number, aimY: number, squareTime: number): SwingModel.Swing
	return SwingModel.new(geometry, aimX, aimY, SwingModel.startTimeForSquareAt(squareTime))
end

local function tolerance(): number
	return units.toStuds(BattingConfig.Collision.ToleranceMeters)
end

return function(t)
	t.test("swing phases run Ready -> Windup -> Active -> FollowThrough -> Recovery -> Ready", function()
		local geometry = TestUtil.geometries().straight
		local swing = SwingModel.new(geometry, 0, units.toStuds(0.8), EPOCH)
		local seen = {}
		local now = EPOCH - 0.05
		while now < EPOCH + swing.timeline.total + 0.05 do
			local phase = SwingModel.phaseAt(swing, now)
			if seen[#seen] ~= phase then
				table.insert(seen, phase)
			end
			now += 1 / 240
		end
		local expected = { "Ready", "Windup", "Active", "FollowThrough", "Recovery", "Ready" }
		TestUtil.assertEqual(#seen, #expected, "phase count")
		for i, phase in expected do
			TestUtil.assertEqual(seen[i], phase, `phase {i}`)
		end
		TestUtil.assertTrue(not SwingModel.isReadyAt(swing, EPOCH + swing.timeline.total - 1e-3), "ready before recovery ended")
		TestUtil.assertTrue(SwingModel.isReadyAt(swing, EPOCH + swing.timeline.total + 1e-3), "not ready after recovery")
		-- Only the Active window can collide.
		TestUtil.assertTrue(SwingModel.poseAt(swing, swing.activeStart + 0.01).collidable, "active pose not collidable")
		TestUtil.assertTrue(not SwingModel.poseAt(swing, EPOCH + 0.01).collidable, "windup pose collidable")
	end)

	t.test("phase timing and bat pose are frame-rate independent", function()
		local geometry = TestUtil.geometries().rotated
		local swing = SwingModel.new(geometry, CM * 5, units.toStuds(0.9), EPOCH)
		local tl = swing.timeline
		local boundaries = {
			Windup = EPOCH,
			Active = EPOCH + tl.windup,
			FollowThrough = EPOCH + tl.windup + tl.active,
			Recovery = EPOCH + tl.windup + tl.active + tl.followThrough,
		}
		local rng = TestUtil.rng(77)
		for _, fps in { 24, 30, 60, 144, 240, 0 } do
			local now = EPOCH - 0.1
			local previous = "Ready"
			local entered: { [string]: number } = {}
			while now < EPOCH + tl.total + 0.1 do
				local dt = if fps == 0 then rng:NextNumber(0.001, 0.05) else 1 / fps
				now += dt
				local phase = SwingModel.phaseAt(swing, now)
				if phase ~= previous and entered[phase] == nil then
					entered[phase] = now
					-- The frame that first sees a phase is never more than one frame late.
					local boundary = boundaries[phase]
					if boundary then
						TestUtil.assertTrue(now >= boundary and now - boundary <= dt + 1e-9, `{fps} fps: {phase} seen at wrong time`)
					end
				end
				previous = phase
			end
		end
		-- Pose is a pure function of time: same answer in any query order.
		local times = {}
		for i = 0, 40 do
			times[i + 1] = EPOCH + tl.total * i / 40
		end
		local forward = {}
		for i, time in times do
			forward[i] = SwingModel.poseAt(swing, time).tip
		end
		for i = #times, 1, -1 do
			TestUtil.assertTrue((SwingModel.poseAt(swing, times[i]).tip - forward[i]).Magnitude < 1e-6, "pose depends on query history")
		end
	end)

	t.test("camera rays map to the contact-plane point they pass through", function()
		for laneName, geometry in TestUtil.geometries() do
			local camera = geometry.plateGround - geometry.toPitcher * units.toStuds(3.4) + geometry.up * units.toStuds(1.6)
			for _, aim in { { 0, 0.8 }, { 0.2, 0.5 }, { -0.35, 1.2 }, { 0.45, 0.35 } } do
				local x, y = units.toStuds(aim[1]), units.toStuds(aim[2])
				local world = SwingModel.aimToWorld(geometry, x, y)
				local rx, ry = SwingModel.aimFromRay(geometry, camera, (world - camera).Unit)
				assert(rx and ry, `{laneName}: ray missed the plane`)
				TestUtil.assertNear(rx, x, 1e-3, `{laneName} aim x`)
				TestUtil.assertNear(ry, y, 1e-3, `{laneName} aim y`)
			end
			-- Rays pointing away from the plane give no aim.
			local rx = SwingModel.aimFromRay(geometry, camera, -geometry.toPitcher)
			TestUtil.assertTrue(rx == nil, `{laneName}: backward ray produced an aim`)
			-- Clamping keeps aim inside the configured region.
			local cx, cy = SwingModel.clampAim(geometry, units.toStuds(5), units.toStuds(-5))
			local minX, maxX, minY, maxY = SwingModel.aimBounds(geometry)
			TestUtil.assertTrue(cx == maxX and cy == minY, `{laneName}: clamp failed`)
			TestUtil.assertTrue(minX < 0 and maxY > geometry.zoneTop, "aim region should cover the zone")
		end
	end)

	t.test("perfectly aligned swings connect on the sweet spot and grade Perfect", function()
		for laneName, geometry in TestUtil.geometries() do
			for seed = 1, 12 do
				local flight = makeFlight(geometry, seed * 31)
				local x, y, ideal = perfectAim(geometry, flight)
				local resolution = SwingResolver.resolve(geometry, flight, swingSquareAt(geometry, x, y, ideal))
				local contact = resolution.contact
				assert(contact, `{laneName} seed {seed}: perfect swing missed ({resolution.missReason})`)
				TestUtil.assertEqual(contact.label, "Perfect", `{laneName} seed {seed} label (score {contact.score})`)
				TestUtil.assertEqual(contact.segment, "Barrel", `{laneName} seed {seed} segment`)
				TestUtil.assertTrue(math.abs(contact.sweetSpotOffset) < CM, `{laneName} seed {seed}: sweet spot offset`)
				TestUtil.assertTrue(math.abs(contact.verticalOffset) < 1.5 * CM, `{laneName} seed {seed}: vertical offset`)
				TestUtil.assertNear(contact.timingErrorSeconds :: number, 0, 1e-6, `{laneName} seed {seed}: timing error`)
				-- First touch happens just before the centers align (both have thickness).
				TestUtil.assertTrue(contact.contactTime <= ideal and contact.contactTime > ideal - 0.01, `{laneName} seed {seed}: contact time`)
				TestUtil.assertTrue(math.abs(contact.sprayAngleDegrees) < 8, `{laneName} seed {seed}: spray {contact.sprayAngleDegrees}`)
			end
		end
	end)

	t.test("contact output carries consistent physical quantities for Phase 3", function()
		local geometry = TestUtil.geometries().straight
		local flight = makeFlight(geometry, 5)
		local x, y, ideal = perfectAim(geometry, flight)
		local contact = SwingResolver.resolve(geometry, flight, swingSquareAt(geometry, x, y, ideal)).contact
		assert(contact, "no contact")
		local ballRadius = flight.params.radius
		TestUtil.assertNear((contact.ballCenter - contact.contactPoint).Magnitude, ballRadius, 1e-3, "contact point on ball surface")
		TestUtil.assertNear((contact.batAxisPoint - contact.ballCenter).Magnitude, ballRadius + units.toStuds(BattingConfig.Bat.BarrelRadiusMeters), tolerance() + 1e-3, "touching distance")
		TestUtil.assertTrue((contact.relativeVelocity - (contact.batVelocity - contact.ballVelocity)).Magnitude < 1e-3, "relative velocity")
		TestUtil.assertTrue(contact.closingSpeed > contact.ballVelocity.Magnitude, "closing speed should exceed ball speed on a square hit")
		TestUtil.assertTrue(contact.impactNormal:Dot(geometry.toPitcher) > 0.95, "square hit should drive the ball back up the middle")
		TestUtil.assertNear(contact.timeAfterRelease, contact.contactTime - flight.data.releaseTime, 1e-9, "time after release")
		local batMph = units.studsPerSecondToMph(contact.batVelocity.Magnitude)
		TestUtil.assertTrue(batMph > 30 and batMph < 100, `implausible bat speed {batMph}`)
	end)

	t.test("early swings pull the ball, late swings push it, extreme timing misses", function()
		for laneName, geometry in TestUtil.geometries() do
			local flight = makeFlight(geometry, 11)
			local x, y, ideal = perfectAim(geometry, flight)
			local function at(offset: number)
				return SwingResolver.resolve(geometry, flight, swingSquareAt(geometry, x, y, ideal + offset))
			end
			local early, perfect, late = at(-0.03).contact, at(0).contact, at(0.03).contact
			assert(early and perfect and late, `{laneName}: moderately mistimed swings should still connect`)
			TestUtil.assertTrue((early.timingErrorSeconds :: number) < 0 and (late.timingErrorSeconds :: number) > 0, "timing sign")
			TestUtil.assertTrue(early.sprayAngleDegrees > perfect.sprayAngleDegrees + 5, `{laneName}: early not pulled`)
			TestUtil.assertTrue(late.sprayAngleDegrees < perfect.sprayAngleDegrees - 5, `{laneName}: late not pushed`)
			TestUtil.assertTrue(early.score < perfect.score and late.score < perfect.score, "mistimed contact should grade lower")
			TestUtil.assertTrue(early.batAngleDegrees > 0 and late.batAngleDegrees < 0, "bat angle at contact")

			-- 100 ms off: the Active window still overlaps the flight, but the bat
			-- passes the ball's path before / after the ball is there.
			local wayEarly, wayLate = at(-0.1), at(0.1)
			TestUtil.assertTrue(wayEarly.contact == nil and wayEarly.missReason == "Early", `{laneName}: way early should miss Early`)
			TestUtil.assertTrue(wayLate.contact == nil and wayLate.missReason == "Late", `{laneName}: way late should miss Late`)
		end
	end)

	t.test("incorrect aim misses; slightly off aim connects with lower quality", function()
		for laneName, geometry in TestUtil.geometries() do
			local flight = makeFlight(geometry, 23)
			local x, y, ideal = perfectAim(geometry, flight)
			local function aimed(dx: number, dy: number)
				return SwingResolver.resolve(geometry, flight, swingSquareAt(geometry, x + dx, y + dy, ideal))
			end
			local over, under = aimed(0, 20 * CM), aimed(0, -20 * CM)
			TestUtil.assertTrue(over.contact == nil and over.missReason == "Over", `{laneName}: high aim`)
			TestUtil.assertTrue(under.contact == nil and under.missReason == "Under", `{laneName}: low aim`)
			-- Bat tip ends ~18 cm past the sweet spot: aiming 45 cm toward the batter misses outside.
			local across = -SwingModel.batterSideSign()
			local outside = aimed(-across * 45 * CM, 0)
			TestUtil.assertTrue(outside.contact == nil and outside.missReason == "Outside", `{laneName}: outside ({outside.missReason})`)

			local slightly = aimed(0, 5 * CM).contact
			assert(slightly, `{laneName}: 5 cm high should still connect`)
			TestUtil.assertTrue(slightly.label ~= "Perfect" and slightly.verticalOffset < 0, `{laneName}: off-center hit graded Perfect`)
			local endOfBat = aimed(-across * 15 * CM, 0).contact
			assert(endOfBat, `{laneName}: 15 cm toward the tip should connect`)
			TestUtil.assertTrue(endOfBat.sweetSpotOffset > 10 * CM and endOfBat.score < 0.9, `{laneName}: end-of-bat contact`)
		end
	end)

	t.test("swings that do not overlap the flight never make contact", function()
		local geometry = TestUtil.geometries().straight
		local flight = makeFlight(geometry, 3)
		local x, y = perfectAim(geometry, flight)
		local release = flight.data.releaseTime
		local beforeRelease = SwingModel.new(geometry, x, y, release - 1)
		local afterCatch = SwingModel.new(geometry, x, y, release + flight.endTime + 0.5)
		for _, swing in { beforeRelease, afterCatch } do
			local resolution = SwingResolver.resolve(geometry, flight, swing)
			TestUtil.assertTrue(resolution.contact == nil, "contact without overlap")
			TestUtil.assertEqual(resolution.missReason, "NoOverlap", "miss reason")
		end
	end)

	t.test("contact at the boundary of the bat is exact to the millimeter", function()
		local geometry = TestUtil.geometries().rotated
		local swing = SwingModel.new(geometry, 0, units.toStuds(0.8), EPOCH)
		local dims = swing.dims
		local ballRadius = units.toStuds(0.0366)
		local margin = units.toStuds(0.002)
		local function sweep(point: Vector3)
			return BatCollision.findEarliest(swing, function()
				return point
			end, ballRadius, swing.activeStart, swing.activeEnd, 0, tolerance())
		end
		local function at(alongFromKnob: number, height: number): Vector3
			return swing.pivot + swing.across * (dims.pivotRadius + alongFromKnob) + swing.axis * height
		end
		-- Above the barrel (height measured from the swing plane).
		local reach = dims.barrelRadius + ballRadius
		local inside = sweep(at(dims.sweetSpot, reach - margin)).hit
		TestUtil.assertTrue(inside ~= nil and inside.segment == "Barrel", "ball just inside the barrel radius missed")
		TestUtil.assertTrue(sweep(at(dims.sweetSpot, reach + margin)).hit == nil, "ball just outside the barrel radius hit")
		-- Beyond the tip (capsule end cap), in the swing plane.
		TestUtil.assertTrue(sweep(at(dims.length + reach - margin, 0)).hit ~= nil, "ball just inside the tip missed")
		TestUtil.assertTrue(sweep(at(dims.length + reach + margin, 0)).hit == nil, "ball just beyond the tip hit")
		-- Over the thinner handle.
		local handleReach = dims.handleRadius + ballRadius
		local handle = sweep(at(units.toStuds(0.1), handleReach - margin)).hit
		TestUtil.assertTrue(handle ~= nil and handle.segment == "Handle", "ball just inside the handle radius missed")
		TestUtil.assertTrue(sweep(at(units.toStuds(0.1), handleReach + margin)).hit == nil, "ball just outside the handle radius hit")
	end)

	t.test("high-speed balls cannot tunnel through the bat", function()
		local geometry = TestUtil.geometries().straight
		local swing = SwingModel.new(geometry, 0, units.toStuds(0.8), EPOCH)
		local ballRadius = units.toStuds(0.0366)
		local speed = units.mphToStudsPerSecond(300)
		local travel = -geometry.toPitcher
		-- Ball passes exactly through the sweet spot at the square time.
		local function ballAt(time: number): Vector3
			return swing.aimPoint + travel * (speed * (time - swing.squareTime))
		end
		-- A naive per-frame overlap check at 60 Hz sees nothing...
		local naiveHit = false
		local frame = swing.squareTime - 0.5 / 60
		while frame < swing.activeEnd do
			if frame >= swing.activeStart then
				local m = BatCollision.measure(SwingModel.activePoseAt(swing, frame), swing.dims, ballAt(frame), ballRadius)
				naiveHit = naiveHit or m.gap <= 0
			end
			frame += 1 / 60
		end
		TestUtil.assertTrue(not naiveHit, "test setup: the 60 Hz check should have tunneled")
		-- ...but the swept test finds the contact.
		local result = BatCollision.findEarliest(swing, ballAt, ballRadius, swing.activeStart, swing.activeEnd, speed, tolerance())
		local hit = result.hit
		assert(hit, "swept test tunneled at 300 mph")
		TestUtil.assertTrue(hit.time <= swing.squareTime and hit.time > swing.squareTime - 0.005, "contact time")
		TestUtil.assertTrue(result.iterations < 500, `too many iterations ({result.iterations})`)
	end)

	t.test("swept detection matches a dense brute-force scan", function()
		local geometry = TestUtil.geometries().straight
		local flight = makeFlight(geometry, 17)
		local x, y, ideal = perfectAim(geometry, flight)
		local release = flight.data.releaseTime
		local ballRadius = flight.params.radius
		local agreeContact, agreeMiss = 0, 0
		for _, case in { { 0, 0 }, { -0.04, 0 }, { 0.05, 0 }, { 0, 8 }, { 0, -9.5 }, { -0.07, 0 }, { 0.02, 6 } } do
			local swing = swingSquareAt(geometry, x, y + case[2] * CM, ideal + case[1])
			local resolution = SwingResolver.resolve(geometry, flight, swing)
			-- Brute force: first sample within the contact tolerance, and first
			-- sample where the surfaces actually overlap.
			local withinTolerance: number? = nil
			local overlapping: number? = nil
			local step = 1e-5
			local time = swing.activeStart
			while time <= swing.activeEnd and overlapping == nil do
				local ball = PitchPhysics.sample(flight.trajectory, time - release)
				local gap = BatCollision.measure(SwingModel.activePoseAt(swing, time), swing.dims, ball, ballRadius).gap
				if gap <= tolerance() and withinTolerance == nil then
					withinTolerance = time
				end
				if gap <= 0 then
					overlapping = time
				end
				time += step
			end
			local contact = resolution.contact
			local label = `case {case[1]}, {case[2]}`
			-- Any real overlap must be found; no contact may be reported where the
			-- surfaces never came within tolerance.
			if overlapping then
				assert(contact, `{label}: sweep missed a real overlap`)
			end
			if withinTolerance == nil then
				TestUtil.assertTrue(contact == nil, `{label}: sweep reported a phantom contact`)
			end
			if contact and withinTolerance then
				-- Earliest touch within tolerance <= sweep contact <= earliest overlap.
				TestUtil.assertTrue(contact.contactTime >= withinTolerance - step, `{label}: sweep contact before the surfaces met`)
				if overlapping then
					TestUtil.assertTrue(contact.contactTime <= overlapping + 1e-9, `{label}: sweep contact later than the first overlap`)
				end
				agreeContact += 1
			else
				agreeMiss += 1
			end
		end
		TestUtil.assertTrue(agreeContact >= 4 and agreeMiss >= 1, "cases should cover both contact and misses")
	end)

	t.test("a pitch is cleaned up after contact and cannot be hit twice", function()
		local geometry = TestUtil.geometries().straight
		local rng = TestUtil.rng(41)
		local crossings: { [number]: boolean } = {}
		local aborted: { [number]: string } = {}
		local lane = PitchLane.new("Test", {
			createPitch = function(_lane, id, windupTime, releaseTime)
				local data = Pitch.generate(geometry, rng, { id = id, laneId = "Test", windupTime = windupTime, releaseTime = releaseTime })
				return { data = data, flight = Pitch.buildFlight(geometry, data) }
			end,
			onPitchCrossed = function(_lane, pitch)
				crossings[pitch.data.id] = true
			end,
			onPitchAborted = function(_lane, pitch, reason)
				aborted[pitch.data.id] = reason
			end,
		})
		local now = EPOCH
		lane:start(now, 0)
		while lane.state ~= "Approaching" do
			now += 1 / 60
			lane:update(now)
		end
		local active = lane.pitch
		assert(active, "no active pitch")
		local x, y, ideal = perfectAim(geometry, active.flight)
		local swing = swingSquareAt(geometry, x, y, ideal)

		local state = SwingValidator.newState()
		local window = { id = active.data.id, releaseTime = active.data.releaseTime, endTime = active.data.releaseTime + active.flight.endTime }
		local validation = SwingValidator.validate(state, { seq = 1, clientTime = swing.startTime, aimX = x, aimY = y }, {
			receiveTime = swing.startTime + 0.03,
			ping = 0.06,
			geometry = geometry,
			pitch = window,
		})
		TestUtil.assertTrue(validation.accepted and validation.pitchId == active.data.id, `swing rejected ({validation.reason})`)
		local contact = SwingResolver.resolve(geometry, active.flight, swing).contact
		assert(contact, "perfect swing missed")

		-- Server behaviour on contact: end the pitch immediately.
		TestUtil.assertTrue(lane:abortPitch(now, "Contact"), "abort failed")
		TestUtil.assertTrue(lane.pitch == nil, "pitch still active after contact")
		TestUtil.assertEqual(aborted[active.data.id], "Contact", "abort reason")
		-- A second swing at the same pitch is refused (window stretched so the
		-- second swing would overlap it after the cooldown).
		local stretched = { id = window.id, releaseTime = window.releaseTime, endTime = window.endTime + 10 }
		local again = SwingValidator.validate(state, { seq = 2, clientTime = swing.startTime + 1, aimX = x, aimY = y }, {
			receiveTime = swing.startTime + 1.01,
			ping = 0.06,
			geometry = geometry,
			pitch = stretched,
		})
		TestUtil.assertEqual(again.reason, "AlreadySwung", "second swing at the same pitch")

		-- The hit pitch never registers a crossing, and pitching continues.
		local target = now + 6
		while now < target do
			now += 1 / 60
			lane:update(now)
		end
		TestUtil.assertTrue(crossings[active.data.id] == nil, "hit pitch was still called at the plate")
		TestUtil.assertTrue(lane.pitchesStarted >= 2, "lane did not continue after contact")
		TestUtil.assertEqual(lane.pitchesStarted, lane.pitchesFinished + lane.pitchesAborted + (if lane.pitch then 1 else 0), "pitch balance")
	end)
end
