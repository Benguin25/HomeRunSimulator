--!strict
-- Session-only gameplay loop. No currency, persistence or power progression.
return {
	Pacing = {
		LandingHoldSeconds = 0.65,
		ReturnSeconds = 0.85, -- keep the existing smooth camera return
		RequestMinGapSeconds = 0.15,
		ReadyRetrySeconds = 0.5,
		RecoveryAfterSeconds = 8, -- request a camera recovery; never auto-release a lane
	},
	Records = {
		TieToleranceMeters = 0.01,
		MilestonesFeet = { 200, 250, 300, 350, 400, 450, 500 },
		ImprovementForFullCelebrationFeet = 100,
	},
	Hud = {
		StatsKey = "G",
		SkipKey = "Space",
		NumberSmoothSeconds = 0.16,
		NoticeSeconds = 2.2,
		BaselineNoticeSeconds = 1.4,
		MinScale = 0.6,
		MaxScale = 1.15,
		CompactWidth = 960,
	},
}
