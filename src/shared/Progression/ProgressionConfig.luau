--!strict
-- Authoritative economy, rebirth and safety tuning.
return {
	SchemaVersion = 3,
	Rebirth = { FirstLevel = 8, LevelsPerRebirth = 1, MaxRebirths = 12, BonusPerRebirth = 0.25, RequestGapSeconds = 1 },
	RebirthBalance = { BaselineLevelsPerRebirth = 2, AttemptsPerCycle = 20000 },
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
	Hud = {
		NoticeSeconds = 2,
		RebirthNoticeSeconds = 3,
		RebirthFlashSeconds = 0.45,
		RebirthPulseScale = 0.06,
		MinScale = 0.65,
		MaxScale = 1.1,
		CompactWidth = 960,
	},
	Balance = {
		Attempts = 150,
		MilestoneAttemptBudget = 3000,
		TypicalSessionSeconds = 600,
		BaseAttemptSeconds = 3.5,
		MilestonesFeet = { 400, 500, 750, 1000 },
		Levels = { 0, 1, 5, 10, 20, 30, 40 },
	},
}
