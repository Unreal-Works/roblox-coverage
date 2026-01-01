local process = require("@lune/process")
local framework = {}

framework.passed = {}
framework.failed = {}

function framework.expect(actual)
	local expectations
	expectations = {
		toBe = function(expected)
			if actual ~= expected then
				error("\nExpected:\n" .. tostring(expected) .. "\nReceived:\n" .. tostring(actual), 2)
			end
		end,
		toBeGreaterThan = function(expected)
			if actual <= expected then
				error("\nExpected greater than:\n" .. tostring(expected) .. "\nReceived:\n" .. tostring(actual), 2)
			end
		end,
		toBeUndefined = function()
			return expectations.toBe(nil)
		end,
	}
	return expectations
end

function framework.describe(name: string, fn: () -> ())
	_G.__COVERAGE__ = nil -- Reset coverage between tests

	local ok, err = pcall(fn)
	if ok then
		table.insert(framework.passed, {
			name = name,
		})
	else
		table.insert(framework.failed, {
			name = name,
			error = err,
		})
	end
end

function framework.run()
	for _, test in ipairs(framework.passed) do
		if table.find(process.args, "--verbose") then
			print("[PASS] " .. test.name)
		end
	end

	for _, test in ipairs(framework.failed) do
		print("[FAIL] " .. test.name)
		print(test.error)
	end

	print("Tests finished. Passed:", #framework.passed, "Failed:", #framework.failed)
	if #framework.failed > 0 then
		process.exit(1)
	else
		process.exit(0)
	end
end

return framework
