--!strict
return {
	ProductionStore = "HomeRunProfiles_v1",
	DevelopmentStore = "HomeRunProfiles_DEV_v1",
	StudioMode = "Mock", -- "DataStore" requires Studio API access; always uses DEV.
	StudioMockScenario = "New", -- New / Returning / LoadFailure / SaveFailure; mock only.
	LeaseSeconds = 180,
	SafetySeconds = 15,
	AutosaveSeconds = 60,
	MaxAttempts = 4,
	RetryBaseSeconds = 0.5,
	RetryMaxSeconds = 4,
	LoadTimeoutSeconds = 20,
	SaveTimeoutSeconds = 12,
	CloseTimeoutSeconds = 25,
}
