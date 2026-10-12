--!strict
-- Hit lifecycle tests driven by a fake clock, including a full pitching loop
-- where every pitch is hit (pure Luau), plus an Instance cleanup test for the
-- client playback (Studio only).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Pitch = require(Shared.Pitching.Pitch)
local PitchLane = require(Shared.Pitching.PitchLane)
local BattedBall = require(Shared.BattedBall.BattedBall)
local BattedBallPlayback = require(Shared.BattedBall.BattedBallPlayback)
local FieldFrame = require(Shared.BattedBall.FieldFrame)
local HitLifecycle = require(Shared.BattedBall.HitLifecycle)
local LandingDetector = require(Shared.BattedBall.LandingDetector)

local BBTU = require(script.Parent.BattedBallTestUtil)
local TestUtil = require(script.Parent.TestUtil)

type Log = { events: { string }, resolved: { [number]: number }, finished: { [number]: number }, cancelled: { [number]: number } }

local function newLog(): Log
	return { events = {}, resolved = {}, finished = {}, cancelled = {} }
end

local function hooks(log: Log): HitLifecycle.Hooks
	local function bump(map: { [number]: number }, id: number)
		map[id] = (map[id] or 0) + 1
	end
	return {
		onLaunched = function(_, hit)
			table.insert(log.events, `launch {hit.launch.hitId}`)
		end,
		onResolved = function(_, hit)
			table.insert(log.events, `resolve {hit.launch.hitId}`)
			bump(log.resolved, hit.launch.hitId)
		end,
		onFinished = function(_, hit)
			table.insert(log.events, `finish {hit.launch.hitId}`)
			bump(log.finished, hit.launch.hitId)
		end,
		onCancelled = function(_, hit, _reason)
			table.insert(log.events, `cancel {hit.launch.hitId}`)
			bump(log.cancelled, hit.launch.hitId)
		end,
	}
end

-- A real hit (launch + flight + outcome on flat ground) at a given launch time.
local function makeHit(hitId: number, launchTime: number): HitLifecycle.ActiveHit
	local frame = FieldFrame.new(TestUtil.geometries().straight)
	local launch = BBTU.launchData(frame, { speedMph = 85, launchDegrees = 25, backspinRpm = 2000 })
	launch.hitId = hitId
	launch.launchTime = launchTime
	local flight = BattedBall.buildFlight(frame, launch)
	local outcome = LandingDetector.evaluate(flight, BBTU.scene(frame, { BBTU.ground() }).caster)
	return { launch = launch, flight = flight, outcome = outcome }
end

return function(t)
	t.test("a hit resolves exactly once at its impact time, then finishes after the hold", function()
		local rng = TestUtil.rng(3)
		for _, frameKind in { "60fps", "hitches" } do
			local log = newLog()
			local lifecycle = HitLifecycle.new("Test", hooks(log), 1.5)
			local hit = makeHit(1, 100)
			local impactTime = 100 + hit.outcome.endTime
			TestUtil.assertTrue(lifecycle:launch(100, hit), "launch refused")
			local now = 100
			while now < impactTime + 5 do
				now += if frameKind == "60fps" then 1 / 60 else rng:NextNumber(0.001, 2.5)
				if now < impactTime then
					TestUtil.assertEqual(lifecycle.state, "Flying", `{frameKind}: resolved early`)
				end
				lifecycle:update(now)
			end
			TestUtil.assertEqual(log.resolved[1], 1, `{frameKind}: resolve count`)
			TestUtil.assertEqual(log.finished[1], 1, `{frameKind}: finish count`)
			TestUtil.assertEqual(lifecycle.state, "Idle", `{frameKind}: idle afterwards`)
			TestUtil.assertTrue(lifecycle.hit == nil, `{frameKind}: hit released`)
			TestUtil.assertEqual(table.concat(log.events, ","), "launch 1,resolve 1,finish 1", `{frameKind}: order`)
		end
	end)

	t.test("a second launch while a hit is active is refused (no duplicate balls or results)", function()
		local log = newLog()
		local lifecycle = HitLifecycle.new("Test", hooks(log), 1)
		TestUtil.assertTrue(lifecycle:launch(0, makeHit(1, 0)), "first launch")
		TestUtil.assertTrue(not lifecycle:launch(0.1, makeHit(2, 0.1)), "duplicate launch accepted")
		local now = 0
		while now < 20 do
			now += 1 / 30
			lifecycle:update(now)
			lifecycle:update(now) -- repeated updates in one frame
		end
		TestUtil.assertEqual(log.resolved[1], 1, "resolved once")
		TestUtil.assertTrue(log.resolved[2] == nil, "refused hit never resolves")
		TestUtil.assertTrue(lifecycle:launch(now, makeHit(3, now)), "a new hit is accepted once idle")
	end)

	t.test("cancelling ends the hit without a result and only once", function()
		local log = newLog()
		local lifecycle = HitLifecycle.new("Test", hooks(log), 1)
		lifecycle:launch(0, makeHit(1, 0))
		lifecycle:update(0.5)
		TestUtil.assertTrue(lifecycle:cancel("BatterLeft"), "cancel")
		TestUtil.assertTrue(not lifecycle:cancel("Again"), "double cancel")
		lifecycle:update(30)
		TestUtil.assertEqual(log.cancelled[1], 1, "cancelled once")
		TestUtil.assertTrue(log.resolved[1] == nil and log.finished[1] == nil, "a cancelled hit never resolves")
		TestUtil.assertEqual(lifecycle.state, "Idle", "idle")
		-- A ball launched in the past (latency rewind) that has already landed resolves immediately.
		local late = makeHit(2, 0)
		lifecycle:launch(late.outcome.endTime + 0.01, late)
		TestUtil.assertEqual(log.resolved[2], 1, "past impact resolves on launch")
	end)

	t.test("consecutive hits never overlap the next pitch, and the pitching loop keeps going", function()
		local geometry = TestUtil.geometries().straight
		local frame = FieldFrame.new(geometry)
		local ground = BBTU.scene(frame, { BBTU.ground() })
		local rng = TestUtil.rng(17)
		local lane: PitchLane.PitchLane
		local log = newLog()
		local lifecycle = HitLifecycle.new("Test", hooks(log))
		local hitsPaused = 0
		lifecycle.hooks.onLaunched = function(_, hit)
			lane:setPaused(true)
			hitsPaused += 1
			table.insert(log.events, `launch {hit.launch.hitId}`)
		end
		local previousFinished = lifecycle.hooks.onFinished :: any
		lifecycle.hooks.onFinished = function(l, hit)
			previousFinished(l, hit)
			lane:setPaused(false)
		end
		local windupsDuringHit = 0
		lane = PitchLane.new("Test", {
			createPitch = function(_, id, windupTime, releaseTime)
				local data = Pitch.generate(geometry, rng, { id = id, laneId = "Test", windupTime = windupTime, releaseTime = releaseTime })
				return { data = data, flight = Pitch.buildFlight(geometry, data) }
			end,
			onStateChanged = function(_, state)
				if state == "Windup" and lifecycle:isBusy() then
					windupsDuringHit += 1
				end
			end,
		})

		local swungPitch: number? = nil
		local pendingContact: { time: number, hit: HitLifecycle.ActiveHit, pitchId: number }? = nil
		local nextHitId = 0
		lane:start(0, 0)
		local now = 0
		while now < 240 do
			now += rng:NextNumber(1 / 120, 1 / 20)
			local active = lane.pitch
			-- Swing at each pitch once, slightly under and a little early/late, like a player would.
			if active and swungPitch ~= active.data.id and lane.state == "Approaching" then
				swungPitch = active.data.id
				local resolution = BBTU.swing(geometry, active.flight, 0, rng:NextNumber(-0.04, 0), rng:NextNumber(-0.015, 0.015))
				local contact = resolution.contact
				if contact then
					nextHitId += 1
					local launch = BattedBall.computeLaunch(frame, contact, { hitId = nextHitId, laneId = "Test", pitchId = active.data.id, userId = 1 })
					local flight = BattedBall.buildFlight(frame, launch)
					pendingContact = {
						time = contact.contactTime,
						pitchId = active.data.id,
						hit = { launch = launch, flight = flight, outcome = LandingDetector.evaluate(flight, ground.caster) },
					}
				end
			end
			-- The server learns about the contact a little later (latency): rewind is handled by launchTime.
			local contactInfo = pendingContact
			if contactInfo and now >= contactInfo.time + 0.05 then
				pendingContact = nil
				local current = lane.pitch
				if current and current.data.id == contactInfo.pitchId and lane:abortPitch(now, "Contact") then
					TestUtil.assertTrue(lifecycle:launch(now, contactInfo.hit), "launch refused while idle")
				end
			end
			lane:update(now)
			lifecycle:update(now)
		end
		TestUtil.assertTrue(lifecycle.launched >= 12, `only {lifecycle.launched} hits in the loop`)
		TestUtil.assertEqual(windupsDuringHit, 0, "a pitch started while a ball was in the air")
		TestUtil.assertTrue(lane.pitchesStarted >= lifecycle.launched, "pitching stopped")
		for id = 1, lifecycle.launched - 1 do
			TestUtil.assertEqual(log.resolved[id], 1, `hit {id} resolved`)
			TestUtil.assertEqual(log.finished[id], 1, `hit {id} finished`)
		end
		TestUtil.assertEqual(hitsPaused, lifecycle.launched, "every hit paused the lane")
	end)

	t.test("a batter reset mid-flight keeps the lane paused until the ball comes down", function()
		local geometry = TestUtil.geometries().straight
		local rng = TestUtil.rng(5)
		local lane = PitchLane.new("Test", {
			createPitch = function(_, id, windupTime, releaseTime)
				local data = Pitch.generate(geometry, rng, { id = id, laneId = "Test", windupTime = windupTime, releaseTime = releaseTime })
				return { data = data, flight = Pitch.buildFlight(geometry, data) }
			end,
		})
		local lifecycle = HitLifecycle.new("Test", {
			onLaunched = function()
				lane:setPaused(true)
			end,
			onFinished = function()
				lane:setPaused(false)
			end,
			onCancelled = function()
				lane:setPaused(false)
			end,
		})
		lane:start(0, 0)
		local now = 0
		while lane.state ~= "Approaching" do
			now += 1 / 60
			lane:update(now)
		end
		lane:abortPitch(now, "Contact")
		local hit = makeHit(1, now)
		lifecycle:launch(now, hit)
		-- The batter resets: the lane stops and restarts right away.
		lane:stop(now + 0.2, "CharacterRemoved")
		lane:start(now + 0.5, 0)
		local started = lane.pitchesStarted
		local clock = now + 0.5
		while clock < now + hit.outcome.endTime + lifecycle.holdSeconds - 0.05 do
			clock += 1 / 60
			lane:update(clock)
			lifecycle:update(clock)
		end
		TestUtil.assertEqual(lane.pitchesStarted, started, "pitched during the flight after a reset")
		while clock < now + hit.outcome.endTime + lifecycle.holdSeconds + 3 do
			clock += 1 / 60
			lane:update(clock)
			lifecycle:update(clock)
		end
		TestUtil.assertTrue(lane.pitchesStarted > started, "pitching did not resume after the hit")
		-- Leaving cancels and unpauses.
		lane:abortPitch(clock, "Contact")
		lifecycle:launch(clock, makeHit(2, clock))
		lifecycle:cancel("BatterLeft")
		TestUtil.assertTrue(not lane.paused, "cancel must unpause the lane")
	end)

	t.robloxTest("batted-ball playbacks leave no orphaned instances", function()
		local folder = Instance.new("Folder")
		folder.Name = "BattedBallVisualTest"
		folder.Parent = workspace
		local ok, err = pcall(function()
			for id = 1, 10 do
				local hit = makeHit(id, 50)
				local playback = BattedBallPlayback.new(hit.flight, folder, if id % 2 == 0 then hit.outcome.endTime else nil)
				local now = 49.5
				local alive = true
				while alive do
					now += 1 / 60
					alive = playback:update(now)
					TestUtil.assertTrue(#folder:GetChildren() <= 1, "too many visual instances")
					TestUtil.assertTrue(now < 80, "playback never finished")
				end
				TestUtil.assertEqual(#folder:GetChildren(), 0, `instances left after hit {id}`)
			end
			local hit = makeHit(99, 0)
			local playback = BattedBallPlayback.new(hit.flight, folder, nil)
			playback:update(0.5)
			playback:destroy()
			TestUtil.assertEqual(#folder:GetChildren(), 0, "instances left after an early destroy")
			TestUtil.assertTrue(not playback:update(0.6), "destroyed playback reports finished")
		end)
		folder:Destroy()
		if not ok then
			error(err, 0)
		end
	end)
end
