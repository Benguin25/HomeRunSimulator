--!strict
-- Collects every `*.spec` module in this folder and runs it.

local TestRunner = require(script.TestRunner)

local Tests = {}

function Tests.run(isRoblox: boolean, log: ((string) -> ())?): TestRunner.Summary
	local specs = {}
	for _, child in script:GetChildren() do
		if child:IsA("ModuleScript") and string.sub(child.Name, -5) == ".spec" then
			specs[child.Name] = (require :: any)(child)
		end
	end
	return TestRunner.run(specs, isRoblox, log)
end

return Tests
