--!strict
local Service = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")
local Config = require(script.Parent.PersistenceConfig)
local ProfileStore = require(script.Parent.ProfileStore)
local Mock = require(script.Parent.MockStore)
local Schema = require(game:GetService("ReplicatedStorage").Shared.Progression.PlayerData)
local Adapter = {}
function Adapter.new(): (ProfileStore.Adapter, boolean)
	if RunService:IsStudio() and Config.StudioMode == "Mock" then
		local state, mock = Mock.new()
		local loaded: { [string]: boolean } = {}
		return {
			budget = mock.budget,
			update = function(key, transform)
				if
					Config.StudioMockScenario == "LoadFailure"
					or (Config.StudioMockScenario == "SaveFailure" and loaded[key])
				then
					state.failures = 100
				end
				if Config.StudioMockScenario == "Returning" and state.records[key] == nil then
					local seed = Schema.defaults()
					seed.coins, seed.powerLevel, seed.bestMeters = 1000, 8, 600
					seed.selectedWorld, seed.unlockedWorlds = "sky", { rookie = true, power = true, sky = true }
					state.records[key] = seed
				end
				local result = mock.update(key, transform)
				loaded[key] = true
				return result
			end,
		},
			true
	end
	local available, store = pcall(function()
		return Service:GetDataStore(if RunService:IsStudio() then Config.DevelopmentStore else Config.ProductionStore)
	end)
	return {
		budget = function()
			-- UpdateAsync consumes both read and write budgets.
			return math.min(
				Service:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.GetAsync),
				Service:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.SetIncrementAsync)
			)
		end,
		update = function(key, transform)
			if not available then
				error("Storage unavailable")
			end
			return store:UpdateAsync(key, transform)
		end,
	},
		false
end
return Adapter
