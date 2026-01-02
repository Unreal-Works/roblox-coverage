local framework = require("../framework")
local expect = framework.expect
local describe = framework.describe
local parser = require("../../src/parser")

describe("firstTokenPerLine", function()
	local tokens = parser.tokenize("local x = 1\nlocal y = 2")
	local firstTokens = parser.firstTokenPerLine(tokens)
	expect(firstTokens[1].value).toBe("local")
	expect(firstTokens[2].value).toBe("local")
end)