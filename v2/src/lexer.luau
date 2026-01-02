local tryScanLong = require("./string/tryScanLong")

local lexer = {}

--- A token in Luau code
export type Token = {
	--- The kind of token (e.g., "identifier", "number", "string", "keyword", "symbol").
	kind: string,
	--- The raw text value of the token.
	value: string,
	--- The line number where the token appears (1-based).
	line: number,
	--- The column number where the token starts (0-based).
	column: number,
	--- The index of the token in the token list (1-based).
	index: number,
}

local KEYWORDS = {
	["and"] = true,
	["break"] = true,
	["continue"] = true,
	["do"] = true,
	["else"] = true,
	["elseif"] = true,
	["end"] = true,
	["false"] = true,
	["for"] = true,
	["function"] = true,
	["if"] = true,
	["in"] = true,
	["local"] = true,
	["nil"] = true,
	["not"] = true,
	["or"] = true,
	["repeat"] = true,
	["return"] = true,
	["then"] = true,
	["true"] = true,
	["until"] = true,
	["while"] = true,
}

--- Tokenize source code into a list of tokens
function lexer.tokenize(src: string): { Token }
	local tokens = {}
	local i = 1
	local line = 1
	local len = #src

	local column = 0
	local function push(kind: string, value: string, startCol: number)
		table.insert(tokens, {
			kind = kind,
			value = value,
			line = line,
			column = startCol,
			index = #tokens + 1,
		})
	end

	while i <= len do
		local ch = string.sub(src, i, i)
		local startCol = column

		if ch == " " or ch == "\t" then
			i += 1
			column += 1
		elseif ch == "\n" then
			line += 1
			column = 0
			i += 1
		elseif ch == "-" and string.sub(src, i + 1, i + 1) == "-" then
			local startI = i
			-- Comment: line or block
			if string.sub(src, i + 2, i + 2) == "[" then
				local nextIndex, nl = tryScanLong(src, i + 2)
				if nextIndex then
					local commentVal = string.sub(src, i, nextIndex - 1)
					if nl > 0 then
						line += nl
						-- Find column of last line of comment
						local lastNl = commentVal:find("\n[^\n]*$")
						if lastNl then
							column = #commentVal - lastNl
						else
							column += #commentVal
						end
					else
						column += #commentVal
					end
					i = nextIndex
				else
					i = i + 2
					column += 2
				end
			else
				while i <= len and string.sub(src, i, i) ~= "\n" do
					i += 1
				end
				-- We don't advance column here because it will stop at \n or EOF
				-- If it stops at \n, the \n case will handle it.
				-- However, we need to advance i and column for the text we skipped
				column += (i - startI)
			end
		elseif ch == "'" or ch == '"' or ch == "`" then
			local startI = i
			local quote = ch
			i += 1
			column += 1
			while i <= len do
				local c = string.sub(src, i, i)
				if c == "\\" then
					i += 2
					column += 2
				elseif c == quote then
					i += 1
					column += 1
					break
				else
					if c == "\n" then
						line += 1
						column = 0
					else
						column += 1
					end
					i += 1
				end
			end
			push("string", string.sub(src, startI, i - 1), startCol)
		elseif ch == "[" then
			local startI = i
			local nextIndex, nl = tryScanLong(src, i)
			if nextIndex then
				local strVal = string.sub(src, startI, nextIndex - 1)
				if nl > 0 then
					line += nl
					local lastNl = strVal:find("\n[^\n]*$")
					if lastNl then
						column = #strVal - lastNl
					else
						column += #strVal
					end
				else
					column += #strVal
				end
				i = nextIndex
				push("string", strVal, startCol)
			else
				push("symbol", ch, startCol)
				i += 1
				column += 1
			end
		elseif string.match(ch, "%d") then
			local start = i
			i += 1
			while i <= len and string.match(string.sub(src, i, i), "[%d%.eE+-]") do
				i += 1
			end
			local val = string.sub(src, start, i - 1)
			push("number", val, startCol)
			column += #val
		elseif string.match(ch, "[A-Za-z_]") then
			local start = i
			i += 1
			while i <= len and string.match(string.sub(src, i, i), "[A-Za-z0-9_]") do
				i += 1
			end
			local word = string.sub(src, start, i - 1)
			if KEYWORDS[word] then
				push("keyword", word, startCol)
			else
				push("identifier", word, startCol)
			end
			column += #word
		else
			-- Prefer the longest match to stay close to Luau's lexer rules.
			if string.sub(src, i, i + 2) == "..." then
				push("symbol", "...", startCol)
				i += 3
				column += 3
			else
				local two = string.sub(src, i, i + 1)
				if
					two == "=="
					or two == "~="
					or two == "<="
					or two == ">="
					or two == "//"
					or two == ".."
					or two == "::"
					or two == "->"
				then
					push("symbol", two, startCol)
					i += 2
					column += 2
				else
					push("symbol", ch, startCol)
					i += 1
					column += 1
				end
			end
		end
	end

	return tokens
end

--- Calculate the first token on each line
function lexer.firstTokenPerLine(tokens: { Token }): { [number]: Token }
	local lookup = {}
	for _, token in ipairs(tokens) do
		if not lookup[token.line] then
			lookup[token.line] = token
		end
	end
	return lookup
end

return lexer
