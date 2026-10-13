--!strict
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Schema = require(Shared.Progression.PlayerData)
local Data = require(Shared.Progression.PlayerProgression)
local Rules = require(Shared.Progression.ProgressionRules)
local Landing = require(Shared.BattedBall.LandingDetector)
local Config = require(script.Parent.Parent.Persistence.PersistenceConfig)
local Store = require(script.Parent.Parent.Persistence.ProfileStore)
local Mock = require(script.Parent.Parent.Persistence.MockStore)
local Test = require(script.Parent.TestUtil)
local function fixture()
	local mock, adapter = Mock.new()
	local clock = { time = 1000, waits = {} :: { number } }
	local manager = Store.new(adapter, {
		now = function()
			return clock.time
		end,
		wait = function(seconds)
			clock.time += seconds
			table.insert(clock.waits, seconds)
		end,
		random = function()
			return 0.5
		end,
	})
	return mock, clock, manager, Store.profile("player", "serverA")
end
local function outcome(feet: number): Landing.OutcomePayload
	return {
		kind = "Landed",
		surface = "Ground",
		territory = "Fair",
		territoryProvisional = false,
		carryMeters = feet * 0.3048,
		endTime = 4,
		sprayAngleDegrees = 0,
	}
end
return function(t)
	t.test("late load acknowledgement cannot activate an expired session", function()
		local mock, clock, manager, p = fixture()
		mock.afterUpdate = function()
			clock.time += Config.LeaseSeconds + 1
		end
		Test.assertTrue(not Store.load(manager, p))
		Test.assertEqual(p.state, nil)
		Test.assertEqual(p.lastError, "LeaseExpired")
		Test.assertTrue(not Store.writable(manager, p))
	end)
	t.test("late save acknowledgement cannot renew authority or flush queued rewards", function()
		local mock, clock, manager, p = fixture()
		Store.load(manager, p)
		local s = assert(p.state, "profile loaded")
		Data.launch(s, 1)
		p.status = "SaveDelayed"
		Store.resolve(manager, p, 1, outcome(400))
		mock.afterUpdate = function()
			clock.time += Config.LeaseSeconds + 1
		end
		Test.assertTrue(not Store.save(manager, p))
		Test.assertEqual(p.status, "Lost")
		Test.assertEqual(s.coins, 0)
		Test.assertTrue(not Store.writable(manager, p))
	end)
	t.test("rebirth and request deduplication persist one atomic reset", function()
		local mock, clock, manager, p = fixture()
		Store.load(manager, p)
		local s = assert(p.state, "profile loaded")
		s.coins, s.powerLevel = 1000, 8
		local _, result = Store.mutate(manager, p, function(state)
			return Data.rebirth(state, 1, 0, 0, clock.time)
		end)
		Test.assertTrue(result.ok)
		Test.assertTrue(not Data.rebirth(s, 1, 0, 0, clock.time + 2).ok)
		Test.assertTrue(Store.close(manager, p, clock.time + 25))
		local loaded = Store.profile("player", "new-session")
		Test.assertTrue(Store.load(manager, loaded))
		Test.assertEqual(assert(loaded.state, "reloaded").rebirths, 1)
		Test.assertEqual(mock.records.player.data.coins, 0)
		Test.assertEqual(mock.records.player.data.powerLevel, 0)
	end)
	t.test("duplicate purchases debit once and old rebirth epochs reject", function()
		local _, _, manager, p = fixture()
		Store.load(manager, p)
		local s = assert(p.state, "profile loaded")
		s.coins = 2000
		Test.assertTrue(Data.purchase(s, "Power", 1, 0, 1, 0).ok)
		Test.assertEqual(Data.purchase(s, "Power", 1, 1, 2, 0).reason, "DuplicateRequest")
		Test.assertEqual(s.coins, 1600)
		s.rebirths = 1
		Test.assertEqual(Data.purchase(s, "Power", 2, 1, 3, 0).reason, "StaleProgression")
		Test.assertEqual(s.coins, 1600)
	end)
	t.test("resolved hits during a saving outage credit once on renewal and close", function()
		local mock, clock, manager, p = fixture()
		Store.load(manager, p)
		local s = assert(p.state, "profile loaded")
		Data.launch(s, 1)
		mock.failures = 4
		Store.save(manager, p)
		Test.assertTrue(Store.resolve(manager, p, 1, outcome(400)))
		Test.assertTrue(not Store.resolve(manager, p, 1, outcome(999)))
		Test.assertEqual(s.coins, 0)
		Test.assertTrue(Store.close(manager, p, clock.time + 25))
		Test.assertEqual(mock.records.player.data.coins, 200)
		Test.assertEqual(mock.records.player.data.lifetime.fairHits, 1)
	end)
	t.test("new players acquire a lease and detached defaults", function()
		local mock, _, manager, p = fixture()
		Test.assertTrue(Store.load(manager, p))
		Test.assertTrue(Store.writable(manager, p))
		local s = assert(p.state, "profile loaded")
		Test.assertEqual(s.coins, 0)
		Test.assertEqual(s.rebirths, 0)
		Test.assertEqual(Rules.multiplier(s.powerLevel, s.rebirths), 1)
		s.worlds.unlockedWorlds.sky = true
		Test.assertTrue(not mock.records.player.data.unlockedWorlds.sky)
	end)
	t.test("reward purchase worlds best and lifetime survive save release reload", function()
		local mock, clock, manager, p = fixture()
		Store.load(manager, p)
		Store.mutate(manager, p, function(s)
			Data.launch(s, 1)
			Data.resolve(s, 1, outcome(1800))
			Test.assertTrue(Data.purchase(s, "Power", 1, 0, 1).ok)
			s.worlds.currentWorld = "sky"
			return true
		end)
		local original = Data.export((assert(p.state, "profile loaded")))
		Test.assertTrue(Store.close(manager, p, clock.time + 25))
		Test.assertEqual(mock.records.player.lock, nil)
		local returned = Store.profile("player", "serverB")
		Test.assertTrue(Store.load(manager, returned))
		local s = assert(returned.state, "returning profile loaded")
		Test.assertEqual(s.coins, original.coins)
		Test.assertEqual(s.powerLevel, 1)
		Test.assertEqual(s.worlds.currentWorld, "sky")
		Test.assertNear(s.worlds.qualifyingBestMeters, 1800 * 0.3048, 1e-9)
		Test.assertTrue(s.milestones["500"])
		Test.assertEqual(s.lifetime.fairHits, 1)
		Test.assertEqual(s.lastHit, 0)
		Test.assertEqual(s.lastSequence, 0)
		Test.assertEqual(next(s.pending), nil)
	end)
	t.test("legacy migration missing fields and stable IDs restore safely", function()
		local data, reason = Schema.decode({ coins = 12, currentWorld = "sky", qualifyingBestMeters = 600 })
		Test.assertEqual(reason, "Migrated")
		local d = assert(data, "decoded data")
		Test.assertEqual(d.schemaVersion, 1)
		Test.assertEqual(d.selectedWorld, "sky")
		Test.assertEqual(d.rebirths, 0)
		Test.assertTrue(d.unlockedWorlds.rookie and d.unlockedWorlds.power)
		Test.assertTrue(d.milestones["500"])
		local partial = assert(
			Schema.decode({ schemaVersion = 1, unlockedWorlds = { bogus = true, sky = false }, selectedWorld = "sky" })
		)
		Test.assertEqual(partial.selectedWorld, "rookie")
		Test.assertEqual(partial.unlockedWorlds.bogus, nil)
	end)
	t.test("invalid stored numbers and fields are finite bounded and sanitized", function()
		local d = assert(Schema.decode({
			schemaVersion = 1,
			coins = math.huge,
			earnedCoins = -12,
			powerLevel = 900,
			rebirths = 0 / 0,
			bestMeters = "forged",
			milestones = "bad",
			lifetime = { fairHits = -1, over400 = 900 },
		}))
		Test.assertEqual(d.coins, 0)
		Test.assertEqual(d.powerLevel, 40)
		Test.assertEqual(d.rebirths, 0)
		Test.assertEqual(d.bestMeters, 0)
		Test.assertEqual(d.lifetime.over400, 0)
		Test.assertEqual(Schema.decode("corrupt"), nil)
		Test.assertEqual(Schema.decode({ schemaVersion = 999 }), nil)
	end)
	t.test("failed load never installs defaults or overwrites stored data", function()
		local mock, _, manager, p = fixture()
		mock.records.player = { schemaVersion = 1, coins = 777 }
		mock.failures = 10
		Test.assertTrue(not Store.load(manager, p))
		Test.assertEqual(p.state, nil)
		Test.assertEqual(p.status, "LoadFailed")
		Test.assertTrue(not Store.save(manager, p))
		Test.assertTrue(not Store.mutate(manager, p, function()
			error("must not mutate")
		end))
		Test.assertEqual(mock.records.player.coins, 777)
	end)
	t.test("future malformed envelopes and malformed leases fail closed", function()
		for _, record in
			{
				{ format = 2, data = {} },
				{ format = 1 },
				{ data = { coins = 1000 }, lock = { owner = "old", expires = 2000 } },
				{ format = 1, data = { schemaVersion = 9 } },
				{ format = 1, data = {}, lock = { owner = "a", expires = "bad" } },
			} :: { any }
		do
			local mock, _, manager, p = fixture()
			mock.records.player = record
			Test.assertTrue(not Store.load(manager, p))
			Test.assertEqual(p.state, nil)
			Test.assertTrue(not Store.save(manager, p))
			Test.assertEqual(mock.records.player, record)
		end
	end)
	t.test("bounded exponential retries recover transient errors", function()
		local mock, clock, manager, p = fixture()
		mock.failures = 2
		Test.assertTrue(Store.load(manager, p))
		Test.assertEqual(mock.calls, 3)
		Test.assertNear(clock.waits[1], 0.5, 1e-9)
		Test.assertNear(clock.waits[2], 1, 1e-9)
	end)
	t.test("budget exhaustion makes zero requests and respects deadlines", function()
		local mock, clock, manager, p = fixture()
		mock.budget = 0
		Test.assertTrue(not Store.load(manager, p))
		Test.assertEqual(mock.calls, 0)
		Test.assertNear(clock.time, 1000 + Config.LoadTimeoutSeconds, 1e-9)
	end)
	t.test("save failures retain dirty state and pause purchases until renewal", function()
		local mock, _, manager, p = fixture()
		Store.load(manager, p)
		local s = assert(p.state, "profile loaded")
		s.coins, s.version = 1000, 1
		mock.failures = 4
		Test.assertTrue(not Store.save(manager, p))
		Test.assertEqual(p.savedVersion, 0)
		Test.assertEqual(p.status, "SaveDelayed")
		Test.assertTrue(not Store.mutate(manager, p, function(state)
			return Data.purchase(state, "Power", 1, 0, 1)
		end))
		Test.assertEqual(s.coins, 1000)
		Test.assertTrue(Store.save(manager, p))
		Test.assertEqual(p.savedVersion, 1)
		Test.assertTrue(Store.writable(manager, p))
	end)
	t.test("two sessions cannot acquire or mutate the same live key", function()
		local mock, _, manager, p = fixture()
		Store.load(manager, p)
		local other = Store.profile("player", "serverB")
		Test.assertTrue(not Store.load(manager, other))
		Test.assertEqual(other.lastError, "Locked")
		Test.assertTrue(not Store.writable(manager, other))
		Test.assertEqual(mock.records.player.lock.owner, "serverA")
	end)
	t.test("lease expiry recovery rejects stale writers and local mutations", function()
		local mock, clock, manager, p = fixture()
		Store.load(manager, p)
		clock.time += Config.LeaseSeconds + 1
		Test.assertTrue(not Store.writable(manager, p))
		local newer = Store.profile("player", "serverB")
		Test.assertTrue(Store.load(manager, newer))
		local s = assert(newer.state, "new owner loaded")
		s.coins, s.version = 900, 1
		Store.save(manager, newer)
		Test.assertTrue(not Store.save(manager, p))
		Test.assertEqual(p.status, "Lost")
		Test.assertEqual(mock.records.player.data.coins, 900)
		Test.assertEqual(mock.records.player.lock.owner, "serverB")
	end)
	t.test("ownership loss before expiry is fenced inside UpdateAsync", function()
		local mock, _, manager, p = fixture()
		Store.load(manager, p)
		mock.records.player.lock.owner = "serverB"
		Test.assertTrue(not Store.save(manager, p))
		Test.assertEqual(p.status, "Lost")
	end)
	t.test("concurrent mutation during save remains dirty without lost updates", function()
		local mock, _, manager, p = fixture()
		Store.load(manager, p)
		mock.beforeUpdate = function()
			mock.beforeUpdate = nil
			Store.mutate(manager, p, function(s)
				Data.launch(s, 1)
				Data.resolve(s, 1, outcome(400))
				return true
			end)
		end
		Test.assertTrue(Store.save(manager, p))
		Test.assertEqual(p.savedVersion, 0)
		Test.assertEqual(assert(p.state, "profile loaded").version, 1)
		Test.assertTrue(Store.save(manager, p))
		Test.assertEqual(mock.records.player.data.coins, 200)
	end)
	t.test("callback replay and lost acknowledgements do not duplicate writes", function()
		local mock, _, manager, p = fixture()
		mock.replay, mock.commitError = true, true
		Test.assertTrue(Store.load(manager, p))
		local s = assert(p.state, "profile loaded")
		s.coins, s.version = 700, 1
		mock.commitError = true
		Test.assertTrue(Store.save(manager, p))
		Test.assertEqual(mock.records.player.data.coins, 700)
		mock.commitError = true
		Test.assertTrue(Store.save(manager, p, true))
		Test.assertEqual(mock.records.player.lock, nil)
	end)
	t.test("busy saves serialize and closing immediately blocks mutations", function()
		local mock, clock, manager, p = fixture()
		Store.load(manager, p)
		mock.beforeUpdate = function()
			Test.assertTrue(not Store.save(manager, p))
			Test.assertTrue(not Store.mutate(manager, p, function()
				error("closing must block")
			end))
		end
		Test.assertTrue(Store.close(manager, p, clock.time + 25))
		Test.assertEqual(p.status, "Closed")
		Test.assertTrue(not Store.save(manager, p))
	end)
	t.test("disconnect releases latest state and shutdown exhaustion is bounded", function()
		local mock, clock, manager, p = fixture()
		Store.load(manager, p)
		mock.budget = 0
		Test.assertTrue(not Store.close(manager, p, clock.time + 2))
		Test.assertNear(clock.time, 1002, 1e-9)
		Test.assertTrue(p.closing)
		Test.assertEqual(mock.calls, 1)
		mock.budget = 100
		Test.assertTrue(Store.close(manager, p, clock.time + 2))
	end)
	t.test("independent player profiles never share progression", function()
		local mock, _, manager, p = fixture()
		local other = Store.profile("otherPlayer", "otherOwner")
		Store.load(manager, p)
		Store.load(manager, other)
		assert(p.state, "profile loaded").coins = 500
		Store.save(manager, p)
		Test.assertEqual(mock.records.otherPlayer.data.coins, 0)
	end)
end
