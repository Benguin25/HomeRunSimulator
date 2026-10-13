--!strict
-- Stage 1 pitcher / catcher presentation: release sync with the authoritative
-- release point, planted feet, recovery back to the set position, blends,
-- the catcher's late reach, and that nothing here touches pitch data.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Geometry = require(Shared.Pitching.LaneGeometry)
local Pitch = require(Shared.Pitching.Pitch)
local PitchConfig = require(Shared.Pitching.PitchConfig)
local PitchPhysics = require(Shared.Pitching.PitchPhysics)
local AthleteConfig = require(Shared.Presentation.AthleteConfig)
local AthleteRig = require(Shared.Presentation.AthleteRig)
local CatcherMotion = require(Shared.Presentation.CatcherMotion)
local KeyTrack = require(Shared.Presentation.KeyTrack)
local Motion = require(Shared.Presentation.PitcherMotion)
local PitchPlayback = require(Shared.Pitching.PitchPlayback)
local Test = require(script.Parent.TestUtil)

local MM = Test.units.toStuds(0.001)
local CM = Test.units.toStuds(0.01)
local EPOCH = 1.7e9

local function pitchFor(geo: Geometry.Geometry, seed: number, windup: number): (Pitch.PitchData, Pitch.Flight)
	local data = Pitch.generate(geo, Test.rng(seed), { id = seed, laneId = "Test", windupTime = EPOCH, releaseTime = EPOCH + windup })
	return data, Pitch.buildFlight(geo, data)
end

local function windups(): { number }
	local list = {}
	for _, tier in PitchConfig.Difficulty.Tiers do
		table.insert(list, tier.WindupSeconds)
	end
	return list
end

local function withHand(hand: "Right" | "Left", fn: () -> ())
	local saved = PitchConfig.Geometry.PitcherHand
	PitchConfig.Geometry.PitcherHand = hand
	local ok, err = pcall(fn :: any)
	PitchConfig.Geometry.PitcherHand = saved :: any
	if not ok then
		error(err, 0)
	end
end

local function lowestFootY(solved: AthleteRig.Solved, skel: AthleteRig.Skeleton, side: string): number
	local cf = solved.cframes[side .. "Foot"]
	local h = skel.parts[side .. "Foot"].size / 2
	local lowest = math.huge
	for _, x in { -1, 1 } do
		for _, y in { -1, 1 } do
			for _, z in { -1, 1 } do
				lowest = math.min(lowest, (cf * Vector3.new(h.X * x, h.Y * y, h.Z * z)).Y)
			end
		end
	end
	return lowest
end

return function(t)
	t.test("the held ball reaches the jittered release point exactly at release for every tier, lane and hand", function()
		for _, hand in { "Right", "Left" } do
			withHand(hand :: any, function()
				for name, base in Test.geometries() do
					local geo = Geometry.new(base.inputs) -- rebuilt so armSide follows the hand
					for _, windup in windups() do
						for seed = 1, 6 do
							local data = pitchFor(geo, seed, windup)
							local sample = Motion.sample(geo, data.windupTime, data.releaseTime, data.releasePosition, data.releaseTime)
							Test.assertNear((sample.hand - data.releasePosition).Magnitude, 0, MM, `{hand} {name} {windup}s seed {seed}`)
							Test.assertTrue(sample.released and sample.solved.reached[Motion.throwSide() .. "Arm"], "arm reaches the release point")
							-- Released by the hand on the throwing side of the body.
							local side = (sample.hand - sample.solved.cframes.UpperTorso.Position):Dot(geo.armSide)
							Test.assertTrue(side > 0, `{hand} release is on the arm side`)
						end
					end
				end
			end)
		end
	end)

	t.test("the hand moves continuously into release and toward the plate (no teleport)", function()
		for name, geo in Test.geometries() do
			for _, windup in windups() do
				local data = pitchFor(geo, 3, windup)
				local step = 1 / 240
				local previous = Motion.sample(geo, data.windupTime, data.releaseTime, data.releasePosition, data.releaseTime - 0.3).hand
				local maxJump = 0
				for i = 1, math.floor(0.3 / step) do
					local now = data.releaseTime - 0.3 + i * step
					local hand = Motion.sample(geo, data.windupTime, data.releaseTime, data.releasePosition, now).hand
					maxJump = math.max(maxJump, (hand - previous).Magnitude)
					previous = hand
				end
				-- 30 m/s at 240 Hz is 0.125 m per step; the arm whip is fast but continuous.
				Test.assertTrue(maxJump < Test.units.toStuds(0.13), `{name} {windup}s hand step {maxJump}`)
				local before = Motion.sample(geo, data.windupTime, data.releaseTime, data.releasePosition, data.releaseTime - 0.02).hand
				Test.assertTrue((data.releasePosition - before):Dot(-geo.toPitcher) > 0, `{name}: hand is moving toward the plate at release`)
			end
		end
	end)

	t.test("the ball stays hidden in the glove until the hands break; the trail starts with the arm whip", function()
		Test.assertEqual(Motion.ballAlpha(0), 0)
		Test.assertEqual(Motion.ballAlpha(0.45), 0)
		Test.assertNear(Motion.ballAlpha(0.6), 1, 1e-9)
		Test.assertTrue(not Motion.trailOn(0.6) and Motion.trailOn(0.95) and Motion.trailOn(1))
	end)

	t.test("feet stay on the ground and planted feet do not slide", function()
		for name, geo in Test.geometries() do
			local skel = Motion.skeleton(geo)
			local data = pitchFor(geo, 9, 1.6)
			local ground = geo.pitcherGround.Y
			local throw = Motion.throwSide()
			local glove = if throw == "Right" then "Left" else "Right"
			local function foot(side: string, now: number): Vector3
				local s = Motion.sample(geo, data.windupTime, data.releaseTime, data.releasePosition, now)
				return s.solved.cframes[side .. "Foot"].Position
			end
			for i = -20, 220 do
				local now = data.windupTime + i * 0.02
				local s = Motion.sample(geo, data.windupTime, data.releaseTime, data.releasePosition, now)
				for _, side in { "Right", "Left" } do
					Test.assertTrue(lowestFootY(s.solved, skel, side) >= ground - CM, `{name} {side} foot below ground at {i}`)
				end
			end
			-- Pivot foot on the rubber from the pivot until the drive; stride foot from foot strike.
			local pivot = foot(throw, data.windupTime + 0.26 * 1.6)
			for u = 0.3, 0.82, 0.04 do
				Test.assertNear((foot(throw, data.windupTime + u * 1.6) - pivot).Magnitude, 0, CM, `{name} pivot foot u={u}`)
			end
			local plant = foot(glove, data.windupTime + 0.87 * 1.6)
			for s = -0.15, 0.9, 0.05 do
				Test.assertNear((foot(glove, data.releaseTime + s) - plant).Magnitude, 0, CM, `{name} stride foot s={s}`)
			end
		end
	end)

	t.test("the delivery recovers to the set position so the next windup starts without a snap", function()
		for name, geo in Test.geometries() do
			for _, windup in windups() do
				local data = pitchFor(geo, 4, windup)
				local after = data.releaseTime + AthleteConfig.Pitcher.RecoverySeconds + 1
				local recovered = Motion.build(geo, Motion.pitchChannels(geo, data.windupTime, data.releaseTime, data.releasePosition, after))
				local idle = Motion.build(geo, Motion.idleChannels(after))
				Test.assertNear((recovered.pelvis.Position - idle.pelvis.Position).Magnitude, 0, CM, `{name} recovered pelvis`)
				-- A next pitch starting from the set position.
				local nextData = pitchFor(geo, 5, windup)
				local start = Motion.build(geo, Motion.pitchChannels(geo, nextData.windupTime, nextData.releaseTime, nextData.releasePosition, nextData.windupTime))
				local set = Motion.build(geo, Motion.idleChannels(nextData.windupTime))
				Test.assertNear((start.pelvis.Position - set.pelvis.Position).Magnitude, 0, CM, `{name} windup starts from the set`)
			end
		end
	end)

	t.test("aborted and replaced pitches blend from the pose on screen instead of snapping", function()
		local geo = Test.geometries().straight
		local data = pitchFor(geo, 2, 1.35)
		local mid = Motion.pitchChannels(geo, data.windupTime, data.releaseTime, data.releasePosition, data.windupTime + 1)
		local idle = Motion.idleChannels(data.windupTime + 1)
		Test.assertEqual(KeyTrack.blend(mid, idle, 0), mid)
		Test.assertEqual(KeyTrack.blend(mid, idle, 1), idle)
		local half = KeyTrack.blend(mid, idle, 0.5)
		Test.assertNear(half.pelvisYaw, (mid.pelvisYaw + idle.pelvisYaw) / 2, 1e-6)
		Test.assertNear(((half.pelvis :: Vector3) - (mid.pelvis :: Vector3):Lerp(idle.pelvis, 0.5)).Magnitude, 0, 1e-6)
		-- Every channel the rig needs survives a blend.
		local _, solved = Motion.build(geo, half)
		local parts = solved.cframes :: { [string]: any }
		Test.assertTrue(parts.Head ~= nil and parts.RightFoot ~= nil)
	end)

	t.test("keyframe tracks are smooth and never overshoot their keys", function()
		local track = { { u = 0, v = 0 }, { u = 0.5, v = 1 }, { u = 0.6, v = 1 }, { u = 1, v = 0 } }
		local compiled = KeyTrack.compile(track, 2)
		for i = 0, 200 do
			local value = KeyTrack.eval(compiled, i / 100)
			Test.assertTrue(value >= -1e-9 and value <= 1 + 1e-9, "within the key range")
		end
		for i = 0, 20 do
			Test.assertNear(KeyTrack.eval(compiled, 1 + i * 0.01), 1, 1e-9, "held between equal keys")
		end
		Test.assertNear(KeyTrack.eval(compiled, -5), 0, 1e-9)
		Test.assertNear(KeyTrack.eval(compiled, 50), 0, 1e-9)
	end)

	t.test("presentation is deterministic, per lane, and never modifies the pitch", function()
		local geos = Test.geometries()
		local a, flightA = pitchFor(geos.straight, 8, 1.6)
		local before = Pitch.encode(a)
		local first = Motion.sample(geos.straight, a.windupTime, a.releaseTime, a.releasePosition, a.releaseTime - 0.4)
		-- Another lane in between must not disturb the first lane's alignment.
		local b = pitchFor(geos.rotated, 8, 1.6)
		Motion.sample(geos.rotated, b.windupTime, b.releaseTime, b.releasePosition, b.releaseTime - 0.4)
		local again = Motion.sample(geos.straight, a.windupTime, a.releaseTime, a.releasePosition, a.releaseTime - 0.4)
		Test.assertNear((first.hand - again.hand).Magnitude, 0, 1e-6)
		local after = Pitch.encode(a)
		for i, value in before do
			Test.assertEqual(after[i], value, "pitch data unchanged")
		end
		local rebuilt = Pitch.buildFlight(geos.straight, a)
		Test.assertNear(rebuilt.endTime, flightA.endTime, 1e-9, "trajectory unchanged")
	end)

	t.test("catcher holds a neutral target until late in the flight, catches the ball and relaxes", function()
		for name, base in Test.geometries() do
			for _, side in { "Right", "Left" } do
				local geo = Geometry.forBatter(base, side :: any)
				local mitts = {}
				for seed = 1, 3 do
					local data, flight = pitchFor(geo, seed * 11, 1.6)
					local endTime = data.releaseTime + flight.endTime
					local info: CatcherMotion.PitchInfo = {
						windupTime = data.windupTime,
						releaseTime = data.releaseTime,
						endTime = endTime,
						endPosition = PitchPhysics.sample(flight.trajectory, flight.endTime),
						endVelocity = PitchPhysics.sampleVelocity(flight.trajectory, flight.endTime),
					}
					-- No tip-off: the same mitt position at release for every pitch.
					table.insert(mitts, CatcherMotion.sample(geo, info, data.releaseTime).mitt)
					local react = data.releaseTime + flight.endTime * AthleteConfig.Catcher.ReactFraction
					Test.assertNear((CatcherMotion.sample(geo, info, react - 0.01).mitt - mitts[1]).Magnitude, 0, CM, "neutral until react")
					local catch = CatcherMotion.sample(geo, info, endTime)
					Test.assertTrue(catch.caught, "caught at the end of the flight")
					Test.assertNear((catch.mitt - info.endPosition).Magnitude, 0, CM, `{name} {side} mitt on the ball`)
					local relaxed = CatcherMotion.sample(geo, info, endTime + 3)
					local idle = CatcherMotion.sample(geo, nil, endTime + 3)
					Test.assertNear((relaxed.mitt - idle.mitt).Magnitude, 0, CM, "relaxed")
					-- Contact: never reaches for a ball that was hit.
					local hitInfo = table.clone(info)
					hitInfo.cutTime = data.releaseTime + flight.endTime * 0.5
					Test.assertTrue(not CatcherMotion.sample(geo, hitInfo, endTime).caught, "no catch after contact")
				end
				for i = 2, #mitts do
					Test.assertNear((mitts[i] - mitts[1]).Magnitude, 0, 1e-6, "same setup for every pitch")
				end
			end
		end
	end)

	t.test("the catcher is behind the plate, clear of the strike zone plane, the same for both batter sides", function()
		for _, base in Test.geometries() do
			local right = CatcherMotion.sample(Geometry.forBatter(base, "Right"), nil, 0)
			local left = CatcherMotion.sample(Geometry.forBatter(base, "Left"), nil, 0)
			for part, cf in right.solved.cframes do
				Test.assertNear((cf.Position - left.solved.cframes[part].Position).Magnitude, 0, 1e-4, part)
				-- Everything stays behind the zone plane (toward the backstop).
				local depth = (cf.Position - base.zonePlane.point):Dot(base.toPitcher)
				Test.assertTrue(depth < 0, `{part} is behind the zone plane`)
			end
		end
	end)

	t.robloxTest("the rendered ball sits in the pitcher's hand before release and leaves from the release point", function()
		local geo = Test.geometries().rotated
		local folder = Instance.new("Folder")
		folder.Name = "PitcherReleaseTest"
		folder.Parent = workspace
		local ok, err = pcall(function()
			local data, flight = pitchFor(geo, 6, 1.35)
			local playback = PitchPlayback.new(geo, flight, folder)
			local ball = (folder:FindFirstChild("Baseball") :: Model).PrimaryPart :: BasePart
			for _, u in { 0.6, 0.8, 0.95, 0.999 } do
				local now = data.windupTime + u * 1.35
				playback:update(now)
				local hand = Motion.sample(geo, data.windupTime, data.releaseTime, data.releasePosition, now).hand
				Test.assertNear((ball.Position - hand).Magnitude, 0, MM * 2, `ball in hand at u={u}`)
				Test.assertTrue(ball.Transparency < 0.01, "visible once the hands break")
			end
			playback:update(data.releaseTime)
			Test.assertNear((ball.Position - data.releasePosition).Magnitude, 0, MM * 2, "leaves from the release point")
			playback:destroy()
			Test.assertEqual(#folder:GetChildren(), 0, "cleaned up")
		end)
		folder:Destroy()
		if not ok then
			error(err, 0)
		end
	end)
end
