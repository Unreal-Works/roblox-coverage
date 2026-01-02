--!strict
--- AST-based instrumentation module
--- Transforms AST nodes to inject coverage tracking calls

local ast = require("./ast")
local lexer = require("./lexer")

local instrument = {}

-- Coverage context for tracking IDs and metadata
export type CoverageContext = {
	filePath: string,
	coverage: any,
	tokens: { lexer.Token },
	lines: { string },
	firstTokenPerLine: { [number]: lexer.Token },
	tokensByLine: { [number]: { index: number, token: lexer.Token } },

	-- Tracking tables
	lineHitIds: { [number]: number },
	functionInstrumentedLines: {
		[number]: { { allocatedId: number?, isEmpty: boolean, isDefinition: boolean, tokenIdx: number? } },
	},
	functionDeclarationLines: { [number]: { { id: number, tokenIdx: number, isDefinition: boolean } } },
	branchInstrumentedLines: { [number]: { { branchId: number, pathIndex: number, isTernary: boolean } } },
	linesInCondition: { [number]: boolean },
	loopDoLines: { [number]: boolean },
}

-- Create instrumentation context
function instrument.createContext(program: ast.Program, filePath: string, coverage: any): CoverageContext
	local ctx = ast.createContext(program.tokens, program.lines)

	return {
		filePath = filePath,
		coverage = coverage,
		tokens = program.tokens,
		lines = program.lines,
		firstTokenPerLine = ctx.firstTokenPerLine,
		tokensByLine = ctx.tokensByLine,

		lineHitIds = {},
		functionInstrumentedLines = {},
		functionDeclarationLines = {},
		branchInstrumentedLines = {},
		linesInCondition = {},
		loopDoLines = {},
	}
end

-- Forward declarations
local visitStatement: (stmt: ast.Statement, ctx: CoverageContext) -> ()
local visitBlock: (block: ast.Block, ctx: CoverageContext) -> ()
local visitExpression: (expr: ast.Expression, ctx: CoverageContext) -> ()

-- Check if a statement should be instrumented based on first token
local STATEMENT_KEYWORDS = {
	["break"] = true,
	["continue"] = true,
	["do"] = true,
	["for"] = true,
	["local"] = true,
	["repeat"] = true,
	["return"] = true,
	["while"] = true,
}

local CLOSING_KEYWORDS = {
	["end"] = true,
	["else"] = true,
	["elseif"] = true,
	["until"] = true,
}

local function shouldInstrumentToken(token: lexer.Token?): boolean
	if not token then
		return false
	end
	if CLOSING_KEYWORDS[token.value] then
		return false
	end
	if token.kind == "identifier" then
		return true
	end
	if token.kind == "keyword" then
		return STATEMENT_KEYWORDS[token.value] == true
	end
	if token.kind == "symbol" then
		return token.value == "(" or token.value == "{" or token.value == "["
	end
	return false
end

-- Check if a line is a continuation of the previous line
local function isContinuationLine(ctx: CoverageContext, lineNo: number): boolean
	local token = ctx.firstTokenPerLine[lineNo]
	if not token then
		return false
	end

	local tokenInfoList = ctx.tokensByLine[lineNo]
	if not tokenInfoList or #tokenInfoList == 0 then
		return false
	end

	local firstTokenInfo = tokenInfoList[1]
	if firstTokenInfo.index <= 1 then
		return false
	end

	local prev = ctx.tokens[firstTokenInfo.index - 1]
	if not prev then
		return false
	end

	if prev.kind == "symbol" then
		local v = prev.value
		if
			v == "("
			or v == "["
			or v == "{"
			or v == ","
			or v == "="
			or v == "+"
			or v == "-"
			or v == "*"
			or v == "/"
			or v == "//"
			or v == "%"
			or v == "^"
			or v == ".."
			or v == "=="
			or v == "~="
			or v == "<"
			or v == ">"
			or v == "<="
			or v == ">="
			or v == "."
			or v == ":"
			or v == "::"
			or v == "->"
		then
			return true
		end
	elseif prev.kind == "keyword" then
		local v = prev.value
		if v == "and" or v == "or" or v == "not" or v == "in" then
			return true
		elseif (v == "if" or v == "elseif") and prev.line < token.line then
			return true
		end
	end

	return false
end

-- Check if a line is a type declaration
local function isTypeDeclarationLine(ctx: CoverageContext, lineNo: number): boolean
	local token = ctx.firstTokenPerLine[lineNo]
	if not token then
		return false
	end

	local lineTokens = ctx.tokensByLine[lineNo]
	if not lineTokens then
		return false
	end

	if token.value == "type" then
		if #lineTokens >= 2 and lineTokens[2].token.kind == "identifier" then
			return true
		end
	elseif token.value == "export" then
		if #lineTokens >= 2 and lineTokens[2].token.value == "type" then
			return true
		end
	end

	return false
end

-- Pass 1: Identify loop headers whose 'do' is on a separate line
local function identifyLoopDoLines(ctx: CoverageContext)
	for idx, token in ipairs(ctx.tokens) do
		if token.kind == "keyword" and (token.value == "for" or token.value == "while") then
			local nestedFunctionDepth = 0
			local j = idx + 1
			while j <= #ctx.tokens do
				local t = ctx.tokens[j]
				if t.kind == "keyword" then
					if t.value == "function" then
						nestedFunctionDepth += 1
					elseif t.value == "end" then
						if nestedFunctionDepth > 0 then
							nestedFunctionDepth -= 1
						end
					elseif t.value == "do" and nestedFunctionDepth == 0 then
						if t.line ~= token.line then
							ctx.loopDoLines[t.line] = true
						end
						break
					end
				end
				j += 1
			end
		end
	end
end

-- Visit function statement to collect function metadata
local function visitFunctionStatement(stmt: ast.FunctionStatement, ctx: CoverageContext)
	local funcName = stmt.name
	local funcTokenIdx = stmt.functionTokenIdx
	local funcToken = ctx.tokens[funcTokenIdx]
	local signatureEndLine = stmt.signatureEndLine
	local signatureEndTokenIdx = stmt.signatureEndTokenIdx or funcTokenIdx
	local bodyStartTokenIdx = stmt.bodyStartTokenIdx
	local isEmpty = stmt.isEmpty

	-- Determine if this is a function definition (not an expression)
	local isDefinition = false
	if funcName ~= "<anonymous>" then
		local firstOnLine = ctx.firstTokenPerLine[funcToken.line]
		if firstOnLine == funcToken then
			isDefinition = true
		else
			local lineTokens = ctx.tokensByLine[funcToken.line]
			if
				lineTokens
				and lineTokens[1]
				and lineTokens[1].token.kind == "keyword"
				and lineTokens[1].token.value == "local"
				and lineTokens[2]
				and lineTokens[2].index == funcTokenIdx
			then
				isDefinition = true
			end
		end
	end

	-- Register function in coverage map
	local fnId = ctx.coverage.nextFnId
	ctx.coverage.nextFnId += 1
	ctx.coverage.fnMap[fnId] = {
		name = funcName,
		line = funcToken.line,
		file = ctx.filePath,
		loc = { start = { line = funcToken.line, column = 0 }, ["end"] = { line = funcToken.line, column = 0 } },
	}

	-- Mark this line for function declaration instrumentation
	if not ctx.functionDeclarationLines[signatureEndLine] then
		ctx.functionDeclarationLines[signatureEndLine] = {}
	end
	table.insert(
		ctx.functionDeclarationLines[signatureEndLine],
		{ id = fnId, tokenIdx = signatureEndTokenIdx, isDefinition = isDefinition }
	)

	-- Find body start line
	local bodyLineNo = funcToken.line + 1
	if bodyStartTokenIdx and bodyStartTokenIdx <= #ctx.tokens then
		bodyLineNo = ctx.tokens[bodyStartTokenIdx].line
	end

	-- Check if we should skip body hit due to multi-line if condition
	local skipBodyHit = false
	if bodyStartTokenIdx and bodyStartTokenIdx > 1 then
		local prevTok = ctx.tokens[bodyStartTokenIdx - 1]
		if prevTok and prevTok.kind == "keyword" and (prevTok.value == "if" or prevTok.value == "elseif") then
			local firstOnPrevLine = ctx.firstTokenPerLine[prevTok.line]
			if prevTok.line < ctx.tokens[bodyStartTokenIdx].line and firstOnPrevLine == prevTok then
				skipBodyHit = true
			end
		end
	end

	if not skipBodyHit then
		if not ctx.functionInstrumentedLines[bodyLineNo] then
			ctx.functionInstrumentedLines[bodyLineNo] = {}
		end

		if bodyLineNo == signatureEndLine then
			table.insert(
				ctx.functionInstrumentedLines[bodyLineNo],
				{ tokenIdx = signatureEndTokenIdx, isEmpty = isEmpty, isDefinition = isDefinition }
			)
		else
			table.insert(
				ctx.functionInstrumentedLines[bodyLineNo],
				{ id = nil, isEmpty = isEmpty, isDefinition = isDefinition }
			)
		end
	end

	-- Visit function body
	visitBlock(stmt.body, ctx)
end

-- Visit if statement to collect branch metadata
local function visitIfStatement(stmt: ast.IfStatement, ctx: CoverageContext)
	local ifTokenIdx = stmt.ifTokenIdx
	local thenTokenIdx = stmt.thenTokenIdx
	local ifToken = ctx.tokens[ifTokenIdx]

	-- Register branch
	local branchId = ctx.coverage.nextBranchId
	ctx.coverage.nextBranchId += 1

	local branchLocations = {}
	local branchLines = {}

	-- Mark condition lines (between if and then)
	local ifLine = ifToken.line
	local thenLine = ctx.tokens[thenTokenIdx].line
	if ifLine ~= thenLine then
		for lineNum = ifLine, thenLine do
			ctx.linesInCondition[lineNum] = true
		end
	end

	-- First branch (then block)
	local firstBranchLine = nil
	if thenTokenIdx + 1 <= #ctx.tokens then
		local candidateLine = ctx.tokens[thenTokenIdx + 1].line
		if candidateLine == ctx.tokens[thenTokenIdx].line then
			firstBranchLine = ifToken.line
		else
			firstBranchLine = candidateLine
		end
	end

	if firstBranchLine then
		table.insert(branchLines, { line = firstBranchLine, pathIndex = 0 })
		table.insert(
			branchLocations,
			{ start = { line = firstBranchLine, column = 0 }, ["end"] = { line = firstBranchLine, column = 0 } }
		)
	end

	-- Process elseif branches
	local elseIdx = nil
	if stmt.elseifBranches then
		for idx, branch in ipairs(stmt.elseifBranches) do
			local elseifLine = branch.startLine
			local elseifThenLine = ctx.tokens[branch.thenTokenIdx].line

			-- Mark elseif condition lines
			if elseifLine ~= elseifThenLine then
				for lineNum = elseifLine, elseifThenLine do
					ctx.linesInCondition[lineNum] = true
				end
			end

			-- Find branch start line
			local elseifBranchLine = nil
			if branch.thenTokenIdx + 1 <= #ctx.tokens then
				local candidateLine = ctx.tokens[branch.thenTokenIdx + 1].line
				if candidateLine == ctx.tokens[branch.thenTokenIdx].line then
					elseifBranchLine = elseifLine
				else
					elseifBranchLine = candidateLine
				end
			end

			if elseifBranchLine then
				table.insert(branchLines, { line = elseifBranchLine, pathIndex = #branchLocations })
				table.insert(
					branchLocations,
					{
						start = { line = elseifBranchLine, column = 0 },
						["end"] = { line = elseifBranchLine, column = 0 },
					}
				)
			end

			-- Visit elseif block
			visitBlock(branch.block, ctx)
		end
	end

	-- Process else block
	if stmt.elseBlock then
		-- Find else token by looking after the last elseif/then block
		for j = thenTokenIdx + 1, #ctx.tokens do
			local t = ctx.tokens[j]
			if t.kind == "keyword" and t.value == "else" then
				elseIdx = j
				break
			elseif t.kind == "keyword" and t.value == "end" then
				break
			end
		end

		if elseIdx then
			local elseBranchLine = nil
			if elseIdx + 1 <= #ctx.tokens then
				local candidateLine = ctx.tokens[elseIdx + 1].line
				if candidateLine == ctx.tokens[elseIdx].line then
					elseBranchLine = ifToken.line
				else
					elseBranchLine = candidateLine
				end
			end

			if elseBranchLine then
				table.insert(branchLines, { line = elseBranchLine, pathIndex = #branchLocations })
				table.insert(
					branchLocations,
					{ start = { line = elseBranchLine, column = 0 }, ["end"] = { line = elseBranchLine, column = 0 } }
				)
			end
		end

		visitBlock(stmt.elseBlock, ctx)
	else
		-- Implicit else (no else block)
		local endLine = stmt.loc.endLine
		table.insert(
			branchLocations,
			{ start = { line = endLine, column = 0 }, ["end"] = { line = endLine, column = 0 } }
		)
	end

	-- Register branch in coverage map
	if #branchLocations >= 2 then
		ctx.coverage.branchMap[branchId] = {
			type = "if",
			line = ifToken.line,
			file = ctx.filePath,
			locations = branchLocations,
			isTernary = false,
			endLine = stmt.loc.endLine,
			ifTokenIdx = ifTokenIdx,
			thenTokenIdx = thenTokenIdx,
			elseIdx = elseIdx,
			endTokenIdx = stmt.loc.endTokenIdx,
		}

		-- Mark lines for branch instrumentation
		for _, branchInfo in ipairs(branchLines) do
			if not ctx.branchInstrumentedLines[branchInfo.line] then
				ctx.branchInstrumentedLines[branchInfo.line] = {}
			end
			table.insert(
				ctx.branchInstrumentedLines[branchInfo.line],
				{ branchId = branchId, pathIndex = branchInfo.pathIndex, isTernary = false }
			)
		end
	end

	-- Visit then block
	visitBlock(stmt.thenBlock, ctx)
end

-- Visit if expression (ternary) to collect branch metadata
local function visitIfExpression(expr: ast.IfExpression, ctx: CoverageContext)
	local ifTokenIdx = expr.ifTokenIdx
	local thenTokenIdx = expr.thenTokenIdx
	local elseIdx = expr.elseIdx
	local endTokenIdx = expr.endTokenIdx
	local ifToken = ctx.tokens[ifTokenIdx]

	-- Register branch
	local branchId = ctx.coverage.nextBranchId
	ctx.coverage.nextBranchId += 1

	local branchLocations = {}

	-- For ternary expressions, all branches are on the same line (the if line)
	local ifLine = ifToken.line
	table.insert(branchLocations, { start = { line = ifLine, column = 0 }, ["end"] = { line = ifLine, column = 0 } })

	-- Check for elseif branches
	if expr.elseifBranches then
		for _, branch in ipairs(expr.elseifBranches) do
			table.insert(
				branchLocations,
				{ start = { line = ifLine, column = 0 }, ["end"] = { line = ifLine, column = 0 } }
			)
		end
	end

	-- Else branch
	table.insert(branchLocations, { start = { line = ifLine, column = 0 }, ["end"] = { line = ifLine, column = 0 } })

	-- Find end line
	local endLine = ctx.tokens[endTokenIdx].line

	-- Register branch in coverage map
	ctx.coverage.branchMap[branchId] = {
		type = "if",
		line = ifLine,
		file = ctx.filePath,
		locations = branchLocations,
		isTernary = true,
		endLine = endLine,
		ifTokenIdx = ifTokenIdx,
		thenTokenIdx = thenTokenIdx,
		elseIdx = elseIdx,
		endTokenIdx = endTokenIdx,
	}

	-- Mark for ternary branch instrumentation
	if not ctx.branchInstrumentedLines[ifLine] then
		ctx.branchInstrumentedLines[ifLine] = {}
	end
	table.insert(ctx.branchInstrumentedLines[ifLine], { branchId = branchId, pathIndex = 0, isTernary = true })
	table.insert(ctx.branchInstrumentedLines[ifLine], { branchId = branchId, pathIndex = 1, isTernary = true })
end

-- Visit expression to find nested ternaries and functions
visitExpression = function(expr: ast.Expression, ctx: CoverageContext)
	if expr.type == "IfExpression" then
		visitIfExpression(expr :: ast.IfExpression, ctx)
	elseif expr.type == "FunctionExpression" then
		local funcExpr = expr :: ast.FunctionExpression
		-- Register anonymous function
		local fnId = ctx.coverage.nextFnId
		ctx.coverage.nextFnId += 1
		ctx.coverage.fnMap[fnId] = {
			name = funcExpr.name or "<anonymous>",
			line = funcExpr.loc.startLine,
			file = ctx.filePath,
			loc = {
				start = { line = funcExpr.loc.startLine, column = 0 },
				["end"] = { line = funcExpr.loc.startLine, column = 0 },
			},
		}

		local signatureEndLine = funcExpr.signatureEndLine
		local signatureEndTokenIdx = funcExpr.signatureEndTokenIdx

		if not ctx.functionDeclarationLines[signatureEndLine] then
			ctx.functionDeclarationLines[signatureEndLine] = {}
		end
		table.insert(
			ctx.functionDeclarationLines[signatureEndLine],
			{ id = fnId :: number, tokenIdx = signatureEndTokenIdx or 0, isDefinition = false }
		)

		-- Visit function body
		visitBlock(funcExpr.body, ctx)
	elseif expr.type == "RawExpression" then
		-- Scan raw expression for nested functions and ternaries
		local rawExpr = expr :: ast.RawExpression
		for i, token in ipairs(rawExpr.tokens) do
			if token.kind == "keyword" then
				if token.value == "function" then
					-- Found function expression in raw tokens - need to process it
					-- For now, we'll handle this in the second scan pass
				elseif token.value == "if" then
					-- Could be a ternary - check context
					local firstOnLine = ctx.firstTokenPerLine[token.line]
					if firstOnLine ~= token then
						-- Likely a ternary
					end
				end
			end
		end
	end
end

-- Visit statement
visitStatement = function(stmt: ast.Statement, ctx: CoverageContext)
	if stmt.type == "FunctionStatement" then
		visitFunctionStatement(stmt :: ast.FunctionStatement, ctx)
	elseif stmt.type == "LocalStatement" then
		local localStmt = stmt :: ast.LocalStatement
		if localStmt.isFunction and localStmt.functionExpr then
			visitExpression(localStmt.functionExpr :: ast.Expression, ctx)
		elseif localStmt.values then
			for _, val in ipairs(localStmt.values) do
				visitExpression(val, ctx)
			end
		end
	elseif stmt.type == "IfStatement" then
		visitIfStatement(stmt :: ast.IfStatement, ctx)
	elseif stmt.type == "ExpressionStatement" then
		local exprStmt = stmt :: ast.ExpressionStatement
		visitExpression(exprStmt.expression, ctx)
	elseif stmt.type == "ForNumericStatement" then
		visitBlock((stmt :: ast.ForNumericStatement).body, ctx)
	elseif stmt.type == "ForGenericStatement" then
		visitBlock((stmt :: ast.ForGenericStatement).body, ctx)
	elseif stmt.type == "WhileStatement" then
		visitBlock((stmt :: ast.WhileStatement).body, ctx)
	elseif stmt.type == "RepeatStatement" then
		visitBlock((stmt :: ast.RepeatStatement).body, ctx)
	elseif stmt.type == "DoStatement" then
		visitBlock((stmt :: ast.DoStatement).body, ctx)
	elseif stmt.type == "ReturnStatement" then
		local retStmt = stmt :: ast.ReturnStatement
		if retStmt.values then
			for _, val in ipairs(retStmt.values) do
				visitExpression(val, ctx)
			end
		end
	end
end

-- Visit block of statements
visitBlock = function(block: ast.Block, ctx: CoverageContext)
	for _, stmt in ipairs(block.statements) do
		visitStatement(stmt, ctx)
	end
end

-- Allocate line hit IDs after collecting all function/branch info
local function allocateLineHitIds(ctx: CoverageContext)
	for lineNo = 1, #ctx.lines do
		local token = ctx.firstTokenPerLine[lineNo]
		local trimmed = ctx.lines[lineNo]:match("^%s*(.-)$") or ""

		-- Check if this is a function definition line
		local isFunctionDefinition = false
		if ctx.functionDeclarationLines[lineNo] then
			for _, decl in ipairs(ctx.functionDeclarationLines[lineNo]) do
				if decl.isDefinition then
					isFunctionDefinition = true
					break
				end
			end
		end

		-- Check for continuation
		local isContinuation = isContinuationLine(ctx, lineNo)

		-- Check for loop do lines
		if ctx.loopDoLines[lineNo] then
			isContinuation = true
		end

		-- Allocate body hit IDs first
		if ctx.functionInstrumentedLines[lineNo] then
			for _, marker in ipairs(ctx.functionInstrumentedLines[lineNo]) do
				if not marker.isEmpty or marker.isDefinition then
					local id = ctx.coverage.nextId
					ctx.coverage.nextId += 1
					ctx.coverage.map[id] = { file = ctx.filePath, line = lineNo }
					marker.allocatedId = id
				end
			end
		end

		-- Check for type declaration
		local isTypeDeclaration = isTypeDeclarationLine(ctx, lineNo)

		-- Allocate statement hit ID
		if
			not isTypeDeclaration
			and shouldInstrumentToken(token)
			and trimmed ~= ""
			and not ctx.linesInCondition[lineNo]
			and not isFunctionDefinition
			and not isContinuation
			and not ctx.functionInstrumentedLines[lineNo]
			and not ctx.functionDeclarationLines[lineNo]
		then
			local id = ctx.coverage.nextId
			ctx.coverage.nextId += 1
			ctx.coverage.map[id] = { file = ctx.filePath, line = lineNo }
			ctx.lineHitIds[lineNo] = id
		end
	end
end

-- Main instrumentation function - collects all metadata without generating code yet
function instrument.collectMetadata(program: ast.Program, filePath: string, coverage: any): CoverageContext
	local ctx = instrument.createContext(program, filePath, coverage)

	-- Pass 1: Identify loop do lines
	identifyLoopDoLines(ctx)

	-- Pass 2: Visit AST to collect function and branch info
	visitBlock(program.body, ctx)

	-- Pass 3: Allocate hit IDs
	allocateLineHitIds(ctx)

	return ctx
end

return instrument
