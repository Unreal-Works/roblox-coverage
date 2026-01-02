--!strict
--- Code generator for instrumented Luau source
--- Takes instrumentation metadata and generates instrumented source code

local ast = require("./ast")
local lexer = require("./lexer")

local codegen = {}

export type GeneratorContext = {
	tokens: { lexer.Token },
	lines: { string },
	filePath: string,
	coverage: any,
	firstTokenPerLine: { [number]: lexer.Token },
	tokensByLine: { [number]: { { index: number, token: lexer.Token } } },

	-- From instrumentation pass
	lineHitIds: { [number]: number },
	functionInstrumentedLines: {
		[number]: { { allocatedId: number?, isEmpty: boolean, isDefinition: boolean, tokenIdx: number? } },
	},
	functionDeclarationLines: { [number]: { { id: number, tokenIdx: number, isDefinition: boolean } } },
	branchInstrumentedLines: { [number]: { { branchId: number, pathIndex: number, isTernary: boolean } } },
	linesInCondition: { [number]: boolean },
}

-- Forward declaration for recursive ternary replacement
local replaceTernaryExpression: (
	ctx: GeneratorContext,
	lines: { string },
	startLine: number,
	endLine: number,
	branchId: number,
	branchData: any,
	processedBranchIds: { [number]: boolean }?
) -> (string, number, number, number?, number?, { [number]: boolean }?, string?)

-- Instrument internal expressions within a ternary part
local function instrumentInternalExpressions(
	ctx: GeneratorContext,
	partText: string,
	partStartLine: number,
	colOffset: number?,
	firstTokens: { [number]: lexer.Token },
	processedBranchIds: { [number]: boolean }
): (string, number)
	local partLines = {}
	local current = partText
	local startIdx = 1
	while true do
		local nl = current:find("\n", startIdx, true)
		if not nl then
			table.insert(partLines, current:sub(startIdx))
			break
		end
		table.insert(partLines, current:sub(startIdx, nl - 1))
		startIdx = nl + 1
	end

	local addedCount = 0
	local result = {}

	for i, lineText in ipairs(partLines) do
		local currentLineNo = partStartLine + i - 1
		local modifications = {}
		local trimmed = lineText:match("^%s*(.-)%s*$") or ""
		local indent = lineText:match("^(%s*)") or ""
		local currentColOffset = (i == 1 and colOffset or 0)

		local combinedLineInsertions = {}

		-- Function declarations
		if ctx.functionDeclarationLines[currentLineNo] then
			local decls = ctx.functionDeclarationLines[currentLineNo]
			for _, decl in ipairs(decls) do
				local targetToken = nil
				local tokensOnLine = ctx.tokensByLine[currentLineNo]
				if tokensOnLine then
					for _, ti in ipairs(tokensOnLine) do
						if ti.index == decl.tokenIdx then
							targetToken = ti.token
							break
						end
					end
				end

				if targetToken then
					local relCol = targetToken.column - currentColOffset
					if relCol >= 0 and relCol < #lineText then
						local modStr = "_G.__covfn(" .. tostring(decl.id) .. ");"
						table.insert(combinedLineInsertions, { col = targetToken.column, text = modStr, priority = 1 })
						addedCount += 1
					end
				end
			end
		end

		-- Body hit markers
		local markers = ctx.functionInstrumentedLines[currentLineNo]
		if markers then
			for _, marker in ipairs(markers) do
				if marker.allocatedId then
					local hitStr = "_G.__covhit(" .. tostring(marker.allocatedId) .. ");"
					if marker.tokenIdx then
						local t = ctx.tokens[marker.tokenIdx]
						local relCol = t.column - currentColOffset
						if relCol >= 0 and relCol < #lineText then
							table.insert(combinedLineInsertions, { col = t.column, text = hitStr, priority = 2 })
							addedCount += 1
						end
					elseif currentLineNo ~= partStartLine then
						table.insert(modifications, hitStr)
						addedCount += 1
					end
				end
			end
		end

		-- Apply inline insertions
		if #combinedLineInsertions > 0 then
			table.sort(combinedLineInsertions, function(a, b)
				if a.col ~= b.col then
					return a.col > b.col
				end
				return (a.priority or 0) > (b.priority or 0)
			end)
			local newLine = lineText
			for _, ins in ipairs(combinedLineInsertions) do
				local tokenOnLine = nil
				local tokensOnLine = ctx.tokensByLine[currentLineNo]
				if tokensOnLine then
					for _, ti in ipairs(tokensOnLine) do
						if ti.token.column == ins.col then
							tokenOnLine = ti.token
							break
						end
					end
				end
				if tokenOnLine then
					local pos = tokenOnLine.column - currentColOffset + #tokenOnLine.value
					newLine = newLine:sub(1, pos) .. " " .. ins.text .. newLine:sub(pos + 1)
				end
			end
			lineText = newLine
			trimmed = lineText:match("^%s*(.-)%s*$") or ""
			indent = lineText:match("^(%s*)") or ""
		end

		-- Line hit
		local lineHitId = ctx.lineHitIds[currentLineNo]
		if lineHitId and (currentLineNo ~= partStartLine) then
			table.insert(modifications, "_G.__covhit(" .. tostring(lineHitId) .. ");")
			addedCount += 1
		end

		if #modifications > 0 then
			result[i] = indent .. table.concat(modifications, " ") .. " " .. trimmed
		else
			result[i] = lineText
		end
	end

	return table.concat(result, "\n"), addedCount
end

-- Instrument part of ternary expression
local function instrumentTernaryPart(
	ctx: GeneratorContext,
	part: string,
	partStartLine: number,
	partStartCol: number,
	firstTokens: { [number]: lexer.Token },
	processedBranchIds: { [number]: boolean }
): (string, string, string, number)
	local prefix = part:match("^(%s*)") or ""
	local suffix = part:match("(%s*)$") or ""
	local trimmed = part:sub(#prefix + 1, #part - #suffix)
	local instrumented, added = instrumentInternalExpressions(
		ctx,
		trimmed,
		partStartLine,
		partStartCol + #prefix,
		firstTokens,
		processedBranchIds
	)
	return instrumented, prefix, suffix, added
end

-- Handle nested ternary within a branch
local function instrumentNestedTernary(
	ctx: GeneratorContext,
	text: string,
	startLine: number,
	nestedBranchId: number,
	nestedBranchData: any,
	processedBranchIds: { [number]: boolean }
): (string?, string, string, number)
	processedBranchIds[nestedBranchId] = true

	local function getOffset(tokenIdx: number): number?
		if not tokenIdx then
			return nil
		end
		local t = ctx.tokens[tokenIdx]
		local offset = 0
		for i = startLine, t.line - 1 do
			offset = offset + #ctx.lines[i] + 1
		end
		return offset + t.column
	end

	local nestedThenPos = getOffset(nestedBranchData.thenTokenIdx)
	local nestedElsePos = getOffset(nestedBranchData.elseIdx)
	local nestedEndPos = getOffset(nestedBranchData.endTokenIdx)

	if not nestedThenPos or not nestedElsePos or not nestedEndPos then
		return nil, "", "", 0
	end

	local nestedThenMatchEnd = nestedThenPos + #ctx.tokens[nestedBranchData.thenTokenIdx].value
	local nestedElseMatchEnd = nestedElsePos + #ctx.tokens[nestedBranchData.elseIdx].value
	local nestedExprEnd = nestedEndPos + #ctx.tokens[nestedBranchData.endTokenIdx].value

	local nestedIfPos = getOffset(nestedBranchData.ifTokenIdx) or 1
	local nestedBeforeThen = text:sub(nestedIfPos + 1, nestedThenPos)
	local nestedThenKeyword = text:sub(nestedThenPos + 1, nestedThenMatchEnd)
	local nestedThenToElse = text:sub(nestedThenMatchEnd + 1, nestedElsePos)
	local nestedElseKeyword = text:sub(nestedElsePos + 1, nestedElseMatchEnd)
	local nestedElseToEnd = text:sub(nestedElseMatchEnd + 1, nestedExprEnd)

	local _, nestedThenLinesOffset = text:sub(1, nestedThenMatchEnd):gsub("\n", "\n")
	local _, nestedElseLinesOffset = text:sub(1, nestedElseMatchEnd):gsub("\n", "\n")

	local nestedInstrumentedThen, nestedPrefixThen, nestedSuffixThen, nestedThenAdded = instrumentTernaryPart(
		ctx,
		nestedThenToElse,
		startLine + nestedThenLinesOffset,
		ctx.tokens[nestedBranchData.thenTokenIdx].column + #ctx.tokens[nestedBranchData.thenTokenIdx].value,
		ctx.firstTokenPerLine,
		processedBranchIds
	)

	local nestedInstrumentedElse, nestedPrefixElse, nestedSuffixElse, nestedElseAdded = instrumentTernaryPart(
		ctx,
		nestedElseToEnd,
		startLine + nestedElseLinesOffset,
		ctx.tokens[nestedBranchData.elseIdx].column + #ctx.tokens[nestedBranchData.elseIdx].value,
		ctx.firstTokenPerLine,
		processedBranchIds
	)

	local nestedInstrumented = string.format(
		"%s%s%s_G.__covbranch(%d, 0)(%s)%s%s%s_G.__covbranch(%d, 1)(%s)%s",
		nestedBeforeThen,
		nestedThenKeyword,
		nestedPrefixThen,
		nestedBranchId,
		nestedInstrumentedThen,
		nestedSuffixThen,
		nestedElseKeyword,
		nestedPrefixElse,
		nestedBranchId,
		nestedInstrumentedElse,
		nestedSuffixElse
	)

	return nestedInstrumented, "", "", nestedThenAdded + nestedElseAdded + #nestedBranchData.locations
end

-- Replace ternary expression with instrumented version
replaceTernaryExpression = function(
	ctx: GeneratorContext,
	lines: { string },
	startLine: number,
	endLine: number,
	branchId: number,
	branchData: any,
	processedBranchIds: { [number]: boolean }?
): (string, number, number, number?, number?, { [number]: boolean }?, string?)
	processedBranchIds = processedBranchIds or {}
	(processedBranchIds :: { boolean })[branchId] = true

	local text = ""
	for i = startLine, math.min(endLine, #lines) do
		if i > startLine then
			text = text .. "\n"
		end
		text = text .. lines[i]
	end

	local function getOffset(tokenIdx: number): number?
		if not tokenIdx then
			return nil
		end
		local t = ctx.tokens[tokenIdx]
		local offset = 0
		for i = startLine, t.line - 1 do
			offset = offset + #lines[i] + 1
		end
		return offset + t.column
	end

	local ifPos = getOffset(branchData.ifTokenIdx)
	if not ifPos then
		return lines[startLine], 1, 0
	end

	local thenPos = getOffset(branchData.thenTokenIdx)
	if not thenPos then
		return lines[startLine], 1, 0
	end
	local thenMatchEnd = thenPos + #ctx.tokens[branchData.thenTokenIdx].value
	local thenKeyword = text:sub(thenPos + 1, thenMatchEnd)

	local elsePos = getOffset(branchData.elseIdx)
	if not elsePos then
		return lines[startLine], 1, 0
	end
	local elseMatchEnd = elsePos + #ctx.tokens[branchData.elseIdx].value
	local elseKeyword = text:sub(elsePos + 1, elseMatchEnd)

	local endPos = getOffset(branchData.endTokenIdx)
	if not endPos then
		return lines[startLine], 1, 0
	end
	local elseExprEnd = endPos + #ctx.tokens[branchData.endTokenIdx].value

	-- Detect ternary expressions with elseif branches (3+ paths)
	local elseifTokens = {}
	do
		local i = branchData.thenTokenIdx + 1
		while i < branchData.elseIdx do
			local tk = ctx.tokens[i]
			if tk.kind == "keyword" and tk.value == "elseif" then
				local thenIdx = nil
				for j = i + 1, #ctx.tokens do
					if ctx.tokens[j].kind == "keyword" and ctx.tokens[j].value == "then" then
						thenIdx = j
						break
					end
				end
				if thenIdx then
					table.insert(elseifTokens, { elseifIdx = i, thenIdx = thenIdx })
				end
			end
			i += 1
		end
	end

	-- Handle multi-branch ternary (with elseif)
	if #elseifTokens > 0 then
		local segments = {}

		local function nextTokenIdx(idx: number): number?
			if idx >= #ctx.tokens then
				return nil
			end
			return idx + 1
		end

		-- First branch (after initial then)
		local startTokIdx = nextTokenIdx(branchData.thenTokenIdx)
		local startOffset = startTokIdx and getOffset(startTokIdx)
		local firstSeparatorOffset = getOffset(elseifTokens[1].elseifIdx)
		if startOffset and firstSeparatorOffset then
			table.insert(segments, { path = 0, startOffset = startOffset, endOffset = firstSeparatorOffset })
		else
			return lines[startLine], 1, 0
		end

		-- Middle branches for each elseif
		for idx, info in ipairs(elseifTokens) do
			local branchStartTokIdx = nextTokenIdx(info.thenIdx)
			local branchStartOffset = branchStartTokIdx and getOffset(branchStartTokIdx)
			local branchEndOffset
			if idx < #elseifTokens then
				branchEndOffset = getOffset(elseifTokens[idx + 1].elseifIdx)
			else
				branchEndOffset = getOffset(branchData.elseIdx)
			end

			if branchStartOffset and branchEndOffset then
				table.insert(segments, { path = idx, startOffset = branchStartOffset, endOffset = branchEndOffset })
			else
				return lines[startLine], 1, 0
			end
		end

		-- Else branch
		local elseStartTokIdx = nextTokenIdx(branchData.elseIdx)
		local elseStartOffset = elseStartTokIdx and getOffset(elseStartTokIdx)
		local elseEndOffset = getOffset(branchData.endTokenIdx)
		if elseStartOffset and elseEndOffset then
			elseEndOffset = elseEndOffset + #ctx.tokens[branchData.endTokenIdx].value
			table.insert(segments, { path = #segments, startOffset = elseStartOffset, endOffset = elseEndOffset })
		else
			return lines[startLine], 1, 0
		end

		-- Assemble instrumented text
		local parts = {}
		local cursor = 0
		for _, seg in ipairs(segments) do
			parts[#parts + 1] = text:sub(cursor + 1, seg.startOffset)

			local exprEnd = seg.endOffset
			while exprEnd > seg.startOffset and text:sub(exprEnd, exprEnd):match("%s") do
				exprEnd -= 1
			end
			local trailing = text:sub(exprEnd + 1, seg.endOffset)

			parts[#parts + 1] =
				string.format("_G.__covbranch(%d, %d)(%s)", branchId, seg.path, text:sub(seg.startOffset + 1, exprEnd))
			parts[#parts + 1] = trailing

			cursor = seg.endOffset
		end
		parts[#parts + 1] = text:sub(cursor + 1)

		local instrumented = table.concat(parts)
		local _, linesConsumed = text:gsub("\n", "\n")
		linesConsumed = linesConsumed + 1

		-- Build expression replacement slice
		local exprStart = ifPos + 1
		local exprEnd = elseExprEnd
		local exprParts = {}
		local exprCursor = exprStart - 1
		for _, seg in ipairs(segments) do
			exprParts[#exprParts + 1] = text:sub(exprCursor + 1, seg.startOffset)

			local exprEndPos = seg.endOffset
			while exprEndPos > seg.startOffset and text:sub(exprEndPos, exprEndPos):match("%s") do
				exprEndPos -= 1
			end
			local trailingExpr = text:sub(exprEndPos + 1, seg.endOffset)

			exprParts[#exprParts + 1] = string.format(
				"_G.__covbranch(%d, %d)(%s)",
				branchId,
				seg.path,
				text:sub(seg.startOffset + 1, exprEndPos)
			)
			exprParts[#exprParts + 1] = trailingExpr

			exprCursor = seg.endOffset
		end
		exprParts[#exprParts + 1] = text:sub(exprCursor + 1, exprEnd)
		local expressionInstrumented = table.concat(exprParts)

		-- Clean up processed branches
		if ctx.branchInstrumentedLines then
			for lineNum = startLine, branchData.endLine do
				local lineEntries = ctx.branchInstrumentedLines[lineNum]
				if lineEntries then
					local filtered = {}
					for _, info in ipairs(lineEntries) do
						if not (processedBranchIds :: { boolean })[info.branchId] then
							table.insert(filtered, info)
						end
					end
					ctx.branchInstrumentedLines[lineNum] = filtered
				end
			end
		end

		return instrumented, linesConsumed, 0, exprStart, exprEnd, processedBranchIds, expressionInstrumented
	end

	-- Simple two-branch ternary
	local beforeThen = text:sub(1, thenPos)
	local thenToElse = text:sub(thenMatchEnd + 1, elsePos)
	local elseToEnd = text:sub(elseMatchEnd + 1, elseExprEnd)
	local afterTernary = text:sub(elseExprEnd + 1)

	local _, thenLinesOffset = text:sub(1, thenMatchEnd):gsub("\n", "\n")
	local _, elseLinesOffset = text:sub(1, elseMatchEnd):gsub("\n", "\n")

	-- Process then branch
	local instrumentedThen, prefixThen, suffixThen, thenAdded = instrumentTernaryPart(
		ctx,
		thenToElse,
		startLine + thenLinesOffset,
		ctx.tokens[branchData.thenTokenIdx].column + #ctx.tokens[branchData.thenTokenIdx].value,
		ctx.firstTokenPerLine,
		processedBranchIds :: { boolean }
	)

	-- Check for nested ternaries in then branch
	if ctx.branchInstrumentedLines then
		local thenStartLine = startLine + thenLinesOffset
		local thenToken = ctx.tokens[branchData.thenTokenIdx]
		local elseTokenLine = ctx.tokens[branchData.elseIdx].line

		for lineNum = thenStartLine, elseTokenLine do
			if ctx.branchInstrumentedLines[lineNum] then
				for _, info in ipairs(ctx.branchInstrumentedLines[lineNum]) do
					if info.isTernary and not (processedBranchIds :: { boolean })[info.branchId] then
						local innerBranchData = ctx.coverage.branchMap[info.branchId]
						if innerBranchData then
							local innerIfToken = ctx.tokens[innerBranchData.ifTokenIdx]

							if innerIfToken.line >= thenToken.line and innerBranchData.endLine <= elseTokenLine then
								local innerInstrumented, _, _, innerAdded = instrumentNestedTernary(
									ctx,
									text,
									startLine,
									info.branchId,
									innerBranchData,
									processedBranchIds :: { boolean }
								)
								if innerInstrumented then
									local innerIfPos = getOffset(innerBranchData.ifTokenIdx)
									local innerEndPos = getOffset(innerBranchData.endTokenIdx) or 1
									local innerExprEnd = innerEndPos + #ctx.tokens[innerBranchData.endTokenIdx].value

									prefixThen = text:sub(thenMatchEnd + 1, innerIfPos)
									instrumentedThen = innerInstrumented
									suffixThen = text:sub(innerExprEnd + 1, elsePos)
									thenAdded = innerAdded
								end
							end
						end
					end
				end
			end
		end
	end

	-- Process else branch
	local instrumentedElse, prefixElse, suffixElse, elseAdded = instrumentTernaryPart(
		ctx,
		elseToEnd,
		startLine + elseLinesOffset,
		ctx.tokens[branchData.elseIdx].column + #ctx.tokens[branchData.elseIdx].value,
		ctx.firstTokenPerLine,
		processedBranchIds :: { boolean }
	)

	-- Check for nested ternaries in else branch
	if ctx.branchInstrumentedLines then
		local elseToken = ctx.tokens[branchData.elseIdx]

		for lineNum = elseToken.line, branchData.endLine do
			if ctx.branchInstrumentedLines[lineNum] then
				for _, info in ipairs(ctx.branchInstrumentedLines[lineNum]) do
					if info.isTernary and not (processedBranchIds :: { boolean })[info.branchId] then
						local innerBranchData = ctx.coverage.branchMap[info.branchId]
						if innerBranchData then
							local innerIfPos = getOffset(innerBranchData.ifTokenIdx)
							local innerEndPos = getOffset(innerBranchData.endTokenIdx)
							if innerIfPos and innerEndPos then
								local innerExprEnd = innerEndPos + #ctx.tokens[innerBranchData.endTokenIdx].value

								if innerIfPos >= elseMatchEnd and innerExprEnd <= elseExprEnd then
									local betweenElseAndIf = text:sub(elseMatchEnd + 1, innerIfPos)
									local hasFunctionWrapper = false
									for k = branchData.elseIdx + 1, innerBranchData.ifTokenIdx - 1 do
										local tk = ctx.tokens[k]
										if tk.kind ~= "comment" then
											hasFunctionWrapper = true
											break
										end
									end

									if not hasFunctionWrapper then
										local innerInstrumented, _, _, innerAdded = instrumentNestedTernary(
											ctx,
											text,
											startLine,
											info.branchId,
											innerBranchData,
											processedBranchIds :: { boolean }
										)
										if innerInstrumented then
											prefixElse = betweenElseAndIf
											instrumentedElse = innerInstrumented
											suffixElse = text:sub(innerExprEnd + 1, elseExprEnd)
											elseAdded = innerAdded
										end
									end
								end
							end
						end
					end
				end
			end
		end
	end

	-- Build final instrumented version
	local instrumented = string.format(
		"%s%s%s_G.__covbranch(%d, 0)(%s)%s%s%s_G.__covbranch(%d, 1)(%s)%s",
		beforeThen,
		thenKeyword,
		prefixThen,
		branchId,
		instrumentedThen,
		suffixThen,
		elseKeyword,
		prefixElse,
		branchId,
		instrumentedElse,
		suffixElse .. afterTernary
	)

	local exprStart = ifPos + 1
	local exprEnd = elseExprEnd
	local expressionInstrumented = string.format(
		"%s%s%s_G.__covbranch(%d, 0)(%s)%s%s%s_G.__covbranch(%d, 1)(%s)%s",
		text:sub(exprStart, thenPos),
		thenKeyword,
		prefixThen,
		branchId,
		instrumentedThen,
		suffixThen,
		elseKeyword,
		prefixElse,
		branchId,
		instrumentedElse,
		suffixElse
	)

	-- Clean up processed branches
	if ctx.branchInstrumentedLines then
		for lineNum = startLine, branchData.endLine do
			local lineEntries = ctx.branchInstrumentedLines[lineNum]
			if lineEntries then
				local filtered = {}
				for _, info in ipairs(lineEntries) do
					if not (processedBranchIds :: { boolean })[info.branchId] then
						table.insert(filtered, info)
					end
				end
				ctx.branchInstrumentedLines[lineNum] = filtered
			end
		end
	end

	local _, linesConsumed = text:gsub("\n", "\n")
	linesConsumed = linesConsumed + 1

	return instrumented,
		linesConsumed,
		thenAdded + elseAdded,
		exprStart,
		exprEnd,
		processedBranchIds,
		expressionInstrumented
end

-- Generate instrumented source code
function codegen.generate(ctx: GeneratorContext): (string, number)
	local lines = ctx.lines
	local instrumented = {}
	local totalAdded = 0

	local lineNo = 1
	while lineNo <= #lines do
		local text = lines[lineNo]
		local modifications = {}
		local linesToSkip = 0
		local lineHitId = ctx.lineHitIds[lineNo]
		local bodyHitMarkers = ctx.functionInstrumentedLines[lineNo]

		-- Collect ternary infos for this line
		local ternaryInfos = nil
		if ctx.branchInstrumentedLines[lineNo] then
			for _, info in ipairs(ctx.branchInstrumentedLines[lineNo]) do
				if info.isTernary then
					ternaryInfos = ternaryInfos or {}
					table.insert(ternaryInfos, info)
				end
			end
		end

		local lineInsertions = {}

		-- Function declarations
		if ctx.functionDeclarationLines[lineNo] then
			for _, decl in ipairs(ctx.functionDeclarationLines[lineNo]) do
				table.insert(lineInsertions, {
					col = ctx.tokens[decl.tokenIdx].column,
					tokenIdx = decl.tokenIdx,
					text = "_G.__covfn(" .. tostring(decl.id) .. ");",
					priority = 1,
				})
				totalAdded += 1
			end
		end

		-- Body hit markers
		if bodyHitMarkers then
			for _, marker in ipairs(bodyHitMarkers) do
				if marker.allocatedId then
					local hitStr = "_G.__covhit(" .. tostring(marker.allocatedId) .. ");"
					if marker.tokenIdx then
						table.insert(lineInsertions, {
							col = ctx.tokens[marker.tokenIdx].column,
							tokenIdx = marker.tokenIdx,
							text = hitStr,
							priority = 2,
						})
					else
						table.insert(modifications, hitStr)
					end
					totalAdded += 1
				end
			end
		end

		-- Handle ternary expressions
		if ternaryInfos and #ternaryInfos > 0 then
			if #ternaryInfos > 1 then
				-- Multiple ternaries on same line
				local replacements = {}
				local processed = {}
				local maxConsumed = 1
				local maxEndLine = lineNo

				for _, info in ipairs(ternaryInfos) do
					local branchData = ctx.coverage.branchMap[info.branchId]
					if branchData and branchData.endLine > maxEndLine then
						maxEndLine = branchData.endLine
					end
				end

				for _, info in ipairs(ternaryInfos) do
					local branchId = info.branchId
					if not processed[branchId] then
						local branchData = ctx.coverage.branchMap[branchId]
						if branchData then
							local _, consumed, internalAdded, exprStart, exprEnd, processedSet, exprReplacement =
								replaceTernaryExpression(
									ctx,
									lines,
									lineNo,
									branchData.endLine,
									branchId,
									branchData,
									processed
								)
							processed = processedSet or processed
							maxConsumed = math.max(maxConsumed, consumed or 1)
							if exprReplacement and exprStart and exprEnd then
								table.insert(replacements, {
									startPos = exprStart,
									endPos = exprEnd,
									text = exprReplacement,
									branchId = branchId,
									internalAdded = internalAdded or 0,
									branchData = branchData,
								})
							end
						end
					end
				end

				if #replacements > 0 then
					table.sort(replacements, function(a, b)
						return a.startPos > b.startPos
					end)

					local blockText = ""
					for i = lineNo, maxEndLine do
						if i > lineNo then
							blockText = blockText .. "\n"
						end
						blockText = blockText .. lines[i]
					end

					for _, rep in ipairs(replacements) do
						blockText = blockText:sub(1, rep.startPos - 1) .. rep.text .. blockText:sub(rep.endPos + 1)
						totalAdded += #rep.branchData.locations + (rep.internalAdded or 0)
					end

					text = blockText
					linesToSkip = maxConsumed - 1
					lineInsertions = {}

					-- Handle remaining non-ternary branches
					if ctx.branchInstrumentedLines[lineNo] then
						local filtered = {}
						for _, info in ipairs(ctx.branchInstrumentedLines[lineNo]) do
							if not processed[info.branchId] then
								table.insert(filtered, info)
							end
						end
						ctx.branchInstrumentedLines[lineNo] = filtered
					end

					if ctx.branchInstrumentedLines[lineNo] then
						for _, bInfo in ipairs(ctx.branchInstrumentedLines[lineNo]) do
							table.insert(
								modifications,
								"_G.__covbranch("
									.. tostring(bInfo.branchId)
									.. ", "
									.. tostring(bInfo.pathIndex)
									.. ");"
							)
							totalAdded += 1
						end
					end
				else
					for _, bInfo in ipairs(ctx.branchInstrumentedLines[lineNo]) do
						table.insert(
							modifications,
							"_G.__covbranch(" .. tostring(bInfo.branchId) .. ", " .. tostring(bInfo.pathIndex) .. ");"
						)
						totalAdded += 1
					end
				end
			else
				-- Single ternary
				local ternaryInfo = ternaryInfos[1]
				local branchId = ternaryInfo.branchId
				local branchData = ctx.coverage.branchMap[branchId]
				local newText, consumed, internalAdded, _, _, processedSet =
					replaceTernaryExpression(ctx, lines, lineNo, branchData.endLine, branchId, branchData, nil)

				if newText ~= lines[lineNo] then
					text = newText
					linesToSkip = consumed - 1
					local branchCount = #branchData.locations
					totalAdded += branchCount + (internalAdded or 0)
					lineInsertions = {}

					if ctx.branchInstrumentedLines[lineNo] then
						local filtered = {}
						local processedBranches = processedSet or { [branchId] = true }
						for _, info in ipairs(ctx.branchInstrumentedLines[lineNo]) do
							if not processedBranches[info.branchId] then
								table.insert(filtered, info)
							end
						end
						ctx.branchInstrumentedLines[lineNo] = filtered
					end

					if ctx.branchInstrumentedLines[lineNo] then
						for _, bInfo in ipairs(ctx.branchInstrumentedLines[lineNo]) do
							table.insert(
								modifications,
								"_G.__covbranch("
									.. tostring(bInfo.branchId)
									.. ", "
									.. tostring(bInfo.pathIndex)
									.. ");"
							)
							totalAdded += 1
						end
					end
				else
					for _, bInfo in ipairs(ctx.branchInstrumentedLines[lineNo]) do
						table.insert(
							modifications,
							"_G.__covbranch(" .. tostring(bInfo.branchId) .. ", " .. tostring(bInfo.pathIndex) .. ");"
						)
						totalAdded += 1
					end
				end
			end
		else
			-- Normal branch instrumentation (statement-style if)
			if ctx.branchInstrumentedLines[lineNo] then
				for _, bInfo in ipairs(ctx.branchInstrumentedLines[lineNo]) do
					table.insert(
						modifications,
						"_G.__covbranch(" .. tostring(bInfo.branchId) .. ", " .. tostring(bInfo.pathIndex) .. ");"
					)
					totalAdded += 1
				end
			end
		end

		-- Line hit
		if lineHitId then
			table.insert(modifications, "_G.__covhit(" .. tostring(lineHitId) .. ");")
			totalAdded += 1
		end

		-- Apply inline insertions
		if #lineInsertions > 0 then
			table.sort(lineInsertions, function(a, b)
				if a.col ~= b.col then
					return a.col > b.col
				end
				return (a.priority or 0) > (b.priority or 0)
			end)

			for _, ins in ipairs(lineInsertions) do
				local targetToken = ctx.tokens[ins.tokenIdx]
				local pos = targetToken.column + #targetToken.value
				text = text:sub(1, pos) .. " " .. ins.text .. text:sub(pos + 1)
			end
		end

		-- Combine modifications with line
		if #modifications > 0 then
			local modStr = table.concat(modifications, " ")
			local currentIndent = string.match(text, "^(%s*)") or ""
			local currentTrimmed = string.match(text, "^%s*(.-)$") or ""
			if currentTrimmed ~= "" then
				instrumented[#instrumented + 1] = currentIndent .. modStr .. " " .. currentTrimmed
			else
				instrumented[#instrumented + 1] = currentIndent .. modStr
			end
		else
			instrumented[#instrumented + 1] = text
		end

		lineNo = lineNo + 1 + linesToSkip
	end

	return table.concat(instrumented, "\n"), totalAdded
end

return codegen
