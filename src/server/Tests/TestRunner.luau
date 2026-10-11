--!strict
-- Minimal test runner shared by Roblox Studio and the Lune CLI harness
-- (tools/run-tests.luau). Specs are ModuleScripts returning
-- `function(t: TestContext)`.

local TestRunner = {}

export type TestContext = {
	test: (name: string, fn: () -> ()) -> (),
	-- Registered only when running inside Roblox (needs Instances/workspace).
	robloxTest: (name: string, fn: () -> ()) -> (),
	isRoblox: boolean,
}

export type Summary = {
	passed: number,
	failed: number,
	skipped: number,
	failures: { string },
}

function TestRunner.run(specs: { [string]: (TestContext) -> () }, isRoblox: boolean, log: ((string) -> ())?): Summary
	local out: (string) -> () = log or print :: any
	local summary: Summary = { passed = 0, failed = 0, skipped = 0, failures = {} }

	local names = {}
	for name in specs do
		table.insert(names, name)
	end
	table.sort(names)

	for _, specName in names do
		local tests: { { name: string, fn: () -> (), roblox: boolean } } = {}
		local context: TestContext = {
			test = function(name, fn)
				table.insert(tests, { name = name, fn = fn, roblox = false })
			end,
			robloxTest = function(name, fn)
				table.insert(tests, { name = name, fn = fn, roblox = true })
			end,
			isRoblox = isRoblox,
		}
		specs[specName](context)

		for _, case in tests do
			local label = `{specName} > {case.name}`
			if case.roblox and not isRoblox then
				summary.skipped += 1
				out(`  SKIP  {label} (requires Roblox)`)
				continue
			end
			local ok, err = xpcall(case.fn :: any, debug.traceback)
			if ok then
				summary.passed += 1
				out(`  PASS  {label}`)
			else
				summary.failed += 1
				table.insert(summary.failures, `{label}\n{err}`)
				out(`  FAIL  {label}\n{err}`)
			end
		end
	end

	out(string.format("Tests: %d passed, %d failed, %d skipped", summary.passed, summary.failed, summary.skipped))
	return summary
end

return TestRunner
