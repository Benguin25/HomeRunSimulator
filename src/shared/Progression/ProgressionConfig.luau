--!strict
-- Stage 6A is session-only. All economy, power and safety tuning lives here.
return {
	SchemaVersion = 1,
	Reward = { ContactCoins = 20, CoinsPerFoot = 0.45, MaxDistanceMeters = 10000 },
	Power = { Growth = 1.12, MaxLevel = 40, BaseCost = 400, CostGrowth = 1.22 },
	Limits = {
		MaxCoins = 1e12,
		MaxSequence = 2147483647,
		PurchaseGapSeconds = 0.35,
		MaxExitSpeedMps = 5000,
		MaxFlightSeconds = 30,
		MaxDistanceMeters = 10000,
		MaxCastStuds = 900,
		CameraWatchdogGraceSeconds = 4,
	},
	Hud = { NoticeSeconds = 2, MinScale = 0.65, MaxScale = 1.1, CompactWidth = 960 },
	Balance = {
		Attempts = 150,
		MilestoneAttemptBudget = 3000,
		TypicalSessionSeconds = 600,
		BaseAttemptSeconds = 3.5,
		MilestonesFeet = { 400, 500, 750, 1000 },
		Levels = { 0, 1, 5, 10, 20, 30, 40 },
	},
}
