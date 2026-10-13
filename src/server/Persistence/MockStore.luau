--!strict
-- Deterministic storage for tests and Studio mock mode. Supports contention,
-- callback replay, commit-then-error and injected clock/budget faults.
local ProfileStore = require(script.Parent.ProfileStore)
local Mock = {}
export type State = {
	records: { [string]: any },
	failures: number,
	calls: number,
	budget: number,
	commitError: boolean,
	replay: boolean,
	beforeUpdate: (() -> ())?,
	afterUpdate: (() -> ())?,
}
local function copy(value: any): any
	if typeof(value) ~= "table" then
		return value
	end
	local result = {}
	for k, v in value do
		result[k] = copy(v)
	end
	return result
end
function Mock.new(): (State, ProfileStore.Adapter)
	local state: State = { records = {}, failures = 0, calls = 0, budget = 100, commitError = false, replay = false }
	return state,
		{
			budget = function()
				return state.budget
			end,
			update = function(key, transform)
				state.calls += 1
				if state.beforeUpdate then
					state.beforeUpdate()
				end
				if state.failures > 0 then
					state.failures -= 1
					error("mock transport failure")
				end
				if state.replay then
					transform(copy(state.records[key]))
				end
				local result = transform(copy(state.records[key]))
				if result == nil then
					return nil
				end
				state.records[key] = copy(result)
				if state.afterUpdate then
					state.afterUpdate()
				end
				if state.commitError then
					state.commitError = false
					error("mock lost acknowledgement")
				end
				return copy(result)
			end,
		}
end
return Mock
