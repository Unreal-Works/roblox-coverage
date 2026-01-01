local fs = require("@lune/fs")
local framework = require("./framework")

local testFiles = {}

for _, file in ipairs(fs.readDir("test")) do
    if file:sub(-10) == ".test.luau" then
        testFiles[#testFiles + 1] = "./" .. file:sub(1, -6)
    end
end

for _, testFile in ipairs(testFiles) do
    require(testFile)
end

framework.run()