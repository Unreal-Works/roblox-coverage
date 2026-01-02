local framework = require("../framework")
local expect = framework.expect
local describe = framework.describe
local parser = require("../../src/parser")

describe("extractFunctionName", function()
	local tokens = parser.tokenize("function test() end")
	local name = parser.extractFunctionName(tokens, 2)
	expect(name).toBe("test")

	tokens = parser.tokenize("function obj.method() end")
	name = parser.extractFunctionName(tokens, 2)
	expect(name).toBe("obj.method")

	tokens = parser.tokenize("function obj:method() end")
	name = parser.extractFunctionName(tokens, 2)
	expect(name).toBe("obj:method")

	tokens = parser.tokenize("function() end")
	name = parser.extractFunctionName(tokens, 2)
	expect(name).toBe("<anonymous>")
end)

describe("extractFunctionName with nested dots", function()
	local tokens = parser.tokenize("function obj.sub.method() end")
	local name = parser.extractFunctionName(tokens, 2)
	expect(name).toBe("obj.sub.method")
end)

describe("extractFunctionName with colon", function()
	local tokens = parser.tokenize("function a:b:c() end")
	local name = parser.extractFunctionName(tokens, 2)
	expect(name).toBe("a:b:c")
end)

describe("extractFunctionName with mixed separators", function()
	local tokens = parser.tokenize("function obj.method:other() end")
	local name = parser.extractFunctionName(tokens, 2)
	expect(name).toBe("obj.method:other")
end)

describe("extractFunctionName out of bounds", function()
	local tokens = parser.tokenize("function")
	local name = parser.extractFunctionName(tokens, 100)
	expect(name).toBe("<anonymous>")
end)

describe("extractFunctionName no identifier", function()
	local tokens = parser.tokenize("function (x) end")
	local name = parser.extractFunctionName(tokens, 2)
	expect(name).toBe("<anonymous>")
end)