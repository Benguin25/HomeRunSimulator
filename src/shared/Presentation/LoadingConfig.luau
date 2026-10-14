--!strict
-- Also mapped into ReplicatedFirst so the first frame never waits for Shared.
return {
	Enabled = true,
	GuiName = "HRSLoadingScreen",
	ActiveAttribute = "LoadingScreenActive",
	EnteredAttribute = "LoadingScreenEntered",
	ClientReadyAttribute = "LoadingClientReady",
	RuntimeName = "LoadingRuntime",
	LoadedEvent = "OpeningLoaded",
	Artwork = "rbxassetid://120160465320703",
	Title = "Home Run Simulator",
	OpeningRadiusStuds = 1600,
	OpeningHalfAngleDegrees = 80, -- wide desktop view plus both batter-side margins
	VisualBatchInstances = 256,
	RenderReadyFrames = 3,
	RenderWarmupSeconds = { rookie = 8, power = 3, sky = 3 },
	MaxVisualSeconds = 30, -- join enables Play at the cap; travel includes its automatic reveal
	RenderStableSeconds = 8,
	RenderTriangleTolerance = 0.0015,
	ScanBudgetSeconds = 0.002,
	ProgressPointsPerSecond = 12,
	ProgressCurveExponent = 1.15, -- modest slowing near the end, without the old 80% plateau
	SpinnerSecondsPerTurn = 1.2,
	PollSeconds = 0.15,
	TimeoutSeconds = 180,
	ArtworkTimeoutSeconds = 12,
	CoverSeconds = 0.18,
	RevealSeconds = 0.45,
	ReadySettleSeconds = 0.35,
	StreamTimeoutSeconds = 2,
	Colors = { Navy = { 5, 18, 36 }, Cream = { 255, 245, 220 }, Gold = { 255, 200, 61 }, Red = { 215, 65, 57 } },
}
