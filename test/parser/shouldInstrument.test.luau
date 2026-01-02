local framework = require("../framework")
local expect = framework.expect
local describe = framework.describe
local parser = require("../../src/parser")

describe("shouldInstrument", function()
	local token = { kind = "keyword", value = "if" }
	expect(parser.shouldInstrument(token :: any)).toBe(false)

	token = { kind = "keyword", value = "local" }
	expect(parser.shouldInstrument(token :: any)).toBe(true)

	token = { kind = "keyword", value = "end" }
	expect(parser.shouldInstrument(token :: any)).toBe(false)

	token = { kind = "identifier", value = "x" }
	expect(parser.shouldInstrument(token :: any)).toBe(true)

	expect(parser.shouldInstrument(nil)).toBe(false)
end)