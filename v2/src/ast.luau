--!strict
local lexer = require("./lexer")
type Token = lexer.Token

--- AST module for Luau code parsing and instrumentation
--- Provides AST node types, builder, visitor, and code generator
local ast = {}

--- Base location info for all nodes
export type Location = {
    startLine: number,
    startColumn: number,
    endLine: number,
    endColumn: number,
    startTokenIdx: number?,
    endTokenIdx: number?,
}

-- Expression node types
export type Identifier = {
    type: "Identifier",
    name: string,
    loc: Location,
}

export type Literal = {
    type: "Literal",
    value: string, -- raw text
    literalType: "string" | "number" | "boolean" | "nil",
    loc: Location,
}

export type BinaryExpression = {
    type: "BinaryExpression",
    operator: string,
    left: Expression,
    right: Expression,
    loc: Location,
}

export type UnaryExpression = {
    type: "UnaryExpression",
    operator: string,
    argument: Expression,
    loc: Location,
}

export type CallExpression = {
    type: "CallExpression",
    callee: Expression,
    arguments: {Expression},
    loc: Location,
}

export type MemberExpression = {
    type: "MemberExpression",
    object: Expression,
    property: Identifier,
    separator: "." | ":",
    loc: Location,
}

export type IndexExpression = {
    type: "IndexExpression",
    object: Expression,
    index: Expression,
    loc: Location,
}

export type TableConstructor = {
    type: "TableConstructor",
    fields: {TableField},
    loc: Location,
}

export type TableField = {
    type: "TableField",
    key: Expression?, -- nil for array-style [expr]
    value: Expression,
    keyType: "none" | "name" | "bracket",
    loc: Location,
}

export type FunctionExpression = {
    type: "FunctionExpression",
    name: string?, -- nil for anonymous
    parameters: {string},
    body: Block,
    signatureEndLine: number,
    signatureEndColumn: number,
    signatureEndTokenIdx: number?,
    bodyStartTokenIdx: number?,
    isEmpty: boolean,
    loc: Location,
}

-- Ternary/inline if expression
export type IfExpression = {
    type: "IfExpression",
    condition: Expression,
    thenExpr: Expression,
    elseifBranches: {ElseifExprBranch}?,
    elseExpr: Expression,
    ifTokenIdx: number,
    thenTokenIdx: number,
    elseIdx: number,
    endTokenIdx: number,
    loc: Location,
}

export type ElseifExprBranch = {
    condition: Expression,
    thenExpr: Expression,
    elseifTokenIdx: number,
    thenTokenIdx: number,
}

export type ParenthesizedExpression = {
    type: "ParenthesizedExpression",
    expression: Expression,
    loc: Location,
}

export type VarargsExpression = {
    type: "VarargsExpression",
    loc: Location,
}

export type Expression = 
    Identifier | 
    Literal | 
    BinaryExpression | 
    UnaryExpression | 
    CallExpression | 
    MemberExpression | 
    IndexExpression | 
    TableConstructor | 
    FunctionExpression | 
    IfExpression |
    ParenthesizedExpression |
    VarargsExpression |
    RawExpression

-- Fallback for expressions we don't fully parse
export type RawExpression = {
    type: "RawExpression",
    tokens: {Token},
    loc: Location,
}

-- Statement node types
export type LocalStatement = {
    type: "LocalStatement",
    names: {string},
    values: {Expression}?,
    isFunction: boolean,
    functionExpr: FunctionExpression?,
    loc: Location,
}

export type AssignmentStatement = {
    type: "AssignmentStatement",
    targets: {Expression},
    values: {Expression},
    loc: Location,
}

export type FunctionStatement = {
    type: "FunctionStatement",
    name: string,
    isLocal: boolean,
    isMethod: boolean,
    parameters: {string},
    body: Block,
    signatureEndLine: number,
    signatureEndColumn: number,
    signatureEndTokenIdx: number?,
    bodyStartTokenIdx: number?,
    isEmpty: boolean,
    functionTokenIdx: number,
    loc: Location,
}

export type IfStatement = {
    type: "IfStatement",
    condition: Expression,
    thenBlock: Block,
    elseifBranches: {ElseifBranch}?,
    elseBlock: Block?,
    ifTokenIdx: number,
    thenTokenIdx: number,
    loc: Location,
}

export type ElseifBranch = {
    condition: Expression,
    block: Block,
    elseifTokenIdx: number,
    thenTokenIdx: number,
    startLine: number,
}

export type ForNumericStatement = {
    type: "ForNumericStatement",
    variable: string,
    start: Expression,
    stop: Expression,
    step: Expression?,
    body: Block,
    doTokenIdx: number?,
    loc: Location,
}

export type ForGenericStatement = {
    type: "ForGenericStatement",
    variables: {string},
    iterators: {Expression},
    body: Block,
    doTokenIdx: number?,
    loc: Location,
}

export type WhileStatement = {
    type: "WhileStatement",
    condition: Expression,
    body: Block,
    doTokenIdx: number?,
    loc: Location,
}

export type RepeatStatement = {
    type: "RepeatStatement",
    body: Block,
    condition: Expression,
    loc: Location,
}

export type DoStatement = {
    type: "DoStatement",
    body: Block,
    loc: Location,
}

export type ReturnStatement = {
    type: "ReturnStatement",
    values: {Expression}?,
    loc: Location,
}

export type BreakStatement = {
    type: "BreakStatement",
    loc: Location,
}

export type ContinueStatement = {
    type: "ContinueStatement",
    loc: Location,
}

export type ExpressionStatement = {
    type: "ExpressionStatement",
    expression: Expression,
    loc: Location,
}

export type TypeDeclaration = {
    type: "TypeDeclaration",
    isExport: boolean,
    name: string,
    loc: Location,
}

export type CommentNode = {
    type: "Comment",
    value: string,
    loc: Location,
}

export type EmptyLine = {
    type: "EmptyLine",
    loc: Location,
}

export type Statement = 
    LocalStatement | 
    AssignmentStatement | 
    FunctionStatement | 
    IfStatement | 
    ForNumericStatement | 
    ForGenericStatement | 
    WhileStatement | 
    RepeatStatement | 
    DoStatement | 
    ReturnStatement | 
    BreakStatement | 
    ContinueStatement | 
    ExpressionStatement |
    TypeDeclaration |
    CommentNode |
    EmptyLine |
    RawStatement

-- Fallback for statements we don't fully parse
export type RawStatement = {
    type: "RawStatement",
    tokens: {Token},
    startTokenIdx: number,
    endTokenIdx: number,
    loc: Location,
}

-- Block is a sequence of statements
export type Block = {
    statements: {Statement},
    startLine: number,
    endLine: number,
}

-- Root AST node
export type Program = {
    type: "Program",
    body: Block,
    tokens: {Token},
    lines: {string},
    loc: Location,
}

local KEYWORDS = {
    ["and"] = true, ["break"] = true, ["continue"] = true, ["do"] = true,
    ["else"] = true, ["elseif"] = true, ["end"] = true, ["false"] = true,
    ["for"] = true, ["function"] = true, ["if"] = true, ["in"] = true,
    ["local"] = true, ["nil"] = true, ["not"] = true, ["or"] = true,
    ["repeat"] = true, ["return"] = true, ["then"] = true, ["true"] = true,
    ["until"] = true, ["while"] = true,
}

local CLOSING_KEYWORDS = {
    ["end"] = true, ["else"] = true, ["elseif"] = true, ["until"] = true,
}

export type BuilderContext = {
    tokens: {Token},
    lines: {string},
    pos: number, -- current token index
    firstTokenPerLine: {[number]: Token},
    tokensByLine: {[number]: {index: number, token: Token}},
}

-- Create a new builder context
function ast.createContext(tokens: {Token}, lines: {string}): BuilderContext
    local firstTokenPerLine: {[number]: Token} = {}
    local tokensByLine: {[number]: {index: number, token: Token}} = {}
    
    for idx, token in ipairs(tokens) do
        if not firstTokenPerLine[token.line] then
            firstTokenPerLine[token.line] = token
        end
        if not tokensByLine[token.line] then
            tokensByLine[token.line] = {} :: {index: number, token: Token}
        end
        table.insert(tokensByLine[token.line], {index = idx, token = token})
    end
    
    return {
        tokens = tokens,
        lines = lines,
        pos = 1,
        firstTokenPerLine = firstTokenPerLine,
        tokensByLine = tokensByLine,
    }
end

-- Peek at current token
function ast.peek(ctx: BuilderContext): Token?
    return ctx.tokens[ctx.pos]
end

-- Peek at token at offset from current position
function ast.peekAt(ctx: BuilderContext, offset: number): Token?
    return ctx.tokens[ctx.pos + offset]
end

-- Advance to next token
function ast.advance(ctx: BuilderContext): Token?
    local token = ctx.tokens[ctx.pos]
    ctx.pos += 1
    return token
end

-- Check if current token matches
function ast.check(ctx: BuilderContext, kind: string, value: string?): boolean
    local token = ast.peek(ctx)
    if not token then return false end
    if token.kind ~= kind then return false end
    if value and token.value ~= value then return false end
    return true
end

-- Consume token if it matches, return it or nil
function ast.consume(ctx: BuilderContext, kind: string, value: string?): Token?
    if ast.check(ctx, kind, value) then
        return ast.advance(ctx)
    end
    return nil
end

-- Check if we're at end of tokens
function ast.isAtEnd(ctx: BuilderContext): boolean
    return ctx.pos > #ctx.tokens
end

-- Create location from token range
function ast.makeLocation(startToken: Token, endToken: Token): Location
    return {
        startLine = startToken.line,
        startColumn = startToken.column,
        endLine = endToken.line,
        endColumn = endToken.column + #endToken.value,
        startTokenIdx = startToken.index,
        endTokenIdx = endToken.index,
    }
end

-- Extract function name from tokens
function ast.extractFunctionName(tokens: {Token}, startIndex: number): string
    local i = startIndex
    if i > #tokens then
        return "<anonymous>"
    end
    
    local nameParts = {}
    local token = tokens[i]
    
    if token.kind == "identifier" then
        table.insert(nameParts, token.value)
        i += 1
        
        while i <= #tokens do
            local sep = tokens[i]
            if sep.kind == "symbol" and (sep.value == "." or sep.value == ":") then
                table.insert(nameParts, sep.value)
                i += 1
                if i <= #tokens and tokens[i].kind == "identifier" then
                    table.insert(nameParts, tokens[i].value)
                    i += 1
                else
                    break
                end
            else
                break
            end
        end
        
        return table.concat(nameParts, "")
    end
    
    return "<anonymous>"
end

-- Skip over type annotation (after : in return type or parameter)
function ast.skipTypeAnnotation(ctx: BuilderContext): number
    local startPos = ctx.pos
    local parenDepth = 0
    local angleDepth = 0
    local braceDepth = 0
    local bracketDepth = 0
    
    while not ast.isAtEnd(ctx) do
        local token = ast.peek(ctx)
        if not token then break end
        local prev = ctx.tokens[ctx.pos - 1]
        
        -- Check for newline break at depth 0
        if parenDepth == 0 and angleDepth == 0 and braceDepth == 0 and bracketDepth == 0 and prev and token.line > prev.line then
            local isCont = (token.kind == "symbol" and (token.value == "|" or token.value == "&" or token.value == "," or token.value == "." or token.value == ":" or token.value == "->" or token.value == "?" or token.value == "<"))
            local prevIsCont = (prev.kind == "symbol" and (prev.value == "|" or prev.value == "&" or prev.value == "," or prev.value == "." or prev.value == ":" or prev.value == "->" or prev.value == "<"))
            if not isCont and not prevIsCont then
                break
            end
        end
        
        if token.kind == "symbol" then
            if token.value == "(" then
                parenDepth += 1
            elseif token.value == ")" then
                if parenDepth == 0 then break end
                parenDepth -= 1
            elseif token.value == "{" then
                braceDepth += 1
            elseif token.value == "}" then
                if braceDepth == 0 then break end
                braceDepth -= 1
            elseif token.value == "[" then
                bracketDepth += 1
            elseif token.value == "]" then
                if bracketDepth == 0 then break end
                bracketDepth -= 1
            elseif token.value == "<" then
                angleDepth += 1
            elseif token.value == ">" then
                if angleDepth > 0 then angleDepth -= 1 end
            elseif token.value == "->" or token.value == "." or token.value == ":" or token.value == "?" or token.value == "|" or token.value == "&" or token.value == "," or token.value == "..." then
                -- Continue
            else
                if parenDepth == 0 and angleDepth == 0 and braceDepth == 0 and bracketDepth == 0 then
                    break
                end
            end
        elseif token.kind == "identifier" then
            -- Continue
        elseif token.kind == "keyword" and (token.value == "nil" or token.value == "true" or token.value == "false") then
            -- Continue
        else
            if parenDepth == 0 and angleDepth == 0 and braceDepth == 0 and bracketDepth == 0 then
                break
            end
        end
        
        ast.advance(ctx)
    end
    
    return ctx.pos - startPos
end

-- Check if an 'if' token is a ternary expression based on context
function ast.isTernaryIf(ctx: BuilderContext, ifTokenIdx: number): boolean
    local tokens = ctx.tokens
    local ifToken = tokens[ifTokenIdx]
    local firstOnLine = ctx.firstTokenPerLine[ifToken.line]
    
    -- Not first on line = likely ternary
    if firstOnLine ~= ifToken then
        return true
    end
    
    -- Check previous token for expression context
    if ifTokenIdx > 1 then
        local prev = tokens[ifTokenIdx - 1]
        if prev.kind == "symbol" and (prev.value == "(" or prev.value == "{" or prev.value == "[" or prev.value == "," or prev.value == "=") then
            return true
        end
        if prev.kind == "keyword" and (prev.value == "return" or prev.value == "local") then
            return true
        end
    end
    
    -- Find 'then' and check if it's first on its line (multi-line ternary pattern)
    local j = ifTokenIdx + 1
    while j <= #tokens do
        local t = tokens[j]
        if t.kind == "keyword" and t.value == "then" then
            local thenFirstOnLine = ctx.firstTokenPerLine[t.line]
            if t.line > ifToken.line and thenFirstOnLine == t then
                return true
            end
            break
        end
        j += 1
    end
    
    return false
end

-- Find matching end/else/elseif for an if statement
-- Returns: endTokenIdx, elseIdx (if found), list of elseif indices
function ast.findIfEnd(ctx: BuilderContext, ifTokenIdx: number, isTernary: boolean): (number, number?, {{elseifIdx: number, thenIdx: number}}?)
    local tokens = ctx.tokens
    local depth = 1
    local inlineIfDepth = 0
    local j = ifTokenIdx + 1
    local elseIdx = nil
    local elseifList = {}
    local foundElse = false
    
    -- Find the initial 'then'
    local thenIdx = nil
    while j <= #tokens do
        if tokens[j].kind == "keyword" and tokens[j].value == "then" then
            thenIdx = j
            j += 1
            break
        end
        j += 1
    end
    
    if not thenIdx then
        return #tokens, nil, nil
    end
    
    while j <= #tokens and depth > 0 do
        local t = tokens[j]
        
        -- Ternary expression termination logic
        if isTernary and depth == 1 and foundElse then
            if t.kind == "symbol" and (t.value == ")" or t.value == "," or t.value == ";" or t.value == "]" or t.value == "}") then
                return j - 1, elseIdx, #elseifList > 0 and elseifList or nil
            elseif t.kind == "keyword" then
                local shouldTerminate = false
                if t.value == "local" or t.value == "return" or t.value == "end" or t.value == "do" or t.value == "for" or t.value == "while" or t.value == "repeat" or t.value == "until" or t.value == "break" or t.value == "continue" or t.value == "elseif" or t.value == "else" then
                    shouldTerminate = true
                elseif t.value == "if" then
                    local prevTok = tokens[j - 1]
                    if not prevTok or prevTok.kind ~= "keyword" or prevTok.value ~= "else" then
                        shouldTerminate = true
                    end
                end
                if shouldTerminate then
                    return j - 1, elseIdx, #elseifList > 0 and elseifList or nil
                end
            elseif ctx.firstTokenPerLine[t.line] == t and elseIdx and t.line > tokens[elseIdx].line then
                -- New line after else - check for continuation
                local prev = tokens[j - 1]
                local continue = false
                if prev then
                    if prev.kind == "symbol" then
                        local v = prev.value
                        if v == "(" or v == "[" or v == "{" or v == "," or v == "=" or v == "+" or v == "-" or v == "*" or v == "/" or v == "//" or v == "%" or v == "^" or v == ".." or v == "==" or v == "~=" or v == "<" or v == ">" or v == "<=" or v == ">=" or v == "." or v == ":" or v == "::" or v == "->" then
                            continue = true
                        end
                    elseif prev.kind == "keyword" then
                        local v = prev.value
                        if v == "and" or v == "or" or v == "not" or v == "in" or v == "else" then
                            continue = true
                        end
                    end
                end
                if not continue then
                    return j - 1, elseIdx, #elseifList > 0 and elseifList or nil
                end
            end
        end
        
        if t.kind == "keyword" then
            if t.value == "if" or t.value == "do" or t.value == "for" or t.value == "function" or t.value == "while" or t.value == "repeat" then
                -- Check for inline if expression
                local isExpressionIf = false
                if t.value == "if" then
                    local prevTok = tokens[j - 1]
                    if prevTok then
                        if prevTok.kind == "symbol" and (prevTok.value == "(" or prevTok.value == "{" or prevTok.value == "[" or prevTok.value == "," or prevTok.value == "=") then
                            isExpressionIf = true
                        elseif prevTok.kind == "keyword" and (prevTok.value == "return" or prevTok.value == "local") then
                            isExpressionIf = true
                        elseif ctx.firstTokenPerLine[t.line] ~= t then
                            isExpressionIf = true
                        end
                    end
                end
                
                if isExpressionIf then
                    depth += 1
                    inlineIfDepth += 1
                else
                    depth += 1
                end
            elseif t.value == "end" or t.value == "until" then
                depth -= 1
                if depth == 0 then
                    return j, elseIdx, #elseifList > 0 and elseifList or nil
                end
            elseif depth == 1 and t.value == "elseif" then
                -- Find the 'then' after elseif
                local elseifThenIdx = nil
                for k = j + 1, #tokens do
                    if tokens[k].kind == "keyword" and tokens[k].value == "then" then
                        elseifThenIdx = k
                        break
                    end
                end
                if elseifThenIdx then
                    table.insert(elseifList, { elseifIdx = j, thenIdx = elseifThenIdx })
                end
            elseif inlineIfDepth > 0 and t.value == "else" then
                depth -= 1
                inlineIfDepth -= 1
            elseif depth == 1 and t.value == "else" then
                foundElse = true
                elseIdx = j
            end
        elseif t.kind == "symbol" then
            if t.value == "(" or t.value == "{" or t.value == "[" then
                depth += 1
            elseif t.value == ")" or t.value == "}" or t.value == "]" then
                depth -= 1
            end
        end
        
        if depth > 0 then
            j += 1
        end
    end
    
    -- Ternary that reaches end of tokens
    if isTernary and foundElse and j > #tokens then
        return #tokens, elseIdx, #elseifList > 0 and elseifList or nil
    end
    
    return math.min(j, #tokens), elseIdx, #elseifList > 0 and elseifList or nil
end

-- Find end of function body
function ast.findFunctionEnd(ctx: BuilderContext, functionTokenIdx: number): number
    local tokens = ctx.tokens
    local depth = 1
    local j = functionTokenIdx + 1
    
    -- Skip past parameter list and return type
    local parenDepth = 0
    local foundParen = false
    
    while j <= #tokens do
        local t = tokens[j]
        if t.kind == "symbol" and t.value == "(" then
            foundParen = true
            parenDepth += 1
        elseif t.kind == "symbol" and t.value == ")" then
            parenDepth -= 1
            if parenDepth == 0 and foundParen then
                j += 1
                -- Skip return type annotation if present
                if j <= #tokens and tokens[j].kind == "symbol" and tokens[j].value == ":" then
                    ctx.pos = j + 1
                    ast.skipTypeAnnotation(ctx)
                    j = ctx.pos
                end
                break
            end
        end
        j += 1
    end
    
    -- Now find matching 'end'
    while j <= #tokens do
        local t = tokens[j]
        if t.kind == "keyword" then
            if t.value == "if" or t.value == "do" or t.value == "for" or t.value == "function" or t.value == "while" or t.value == "repeat" then
                depth += 1
            elseif t.value == "end" then
                depth -= 1
                if depth == 0 then
                    return j
                end
            elseif t.value == "until" then
                depth -= 1
            end
        end
        j += 1
    end
    
    return #tokens
end

-- Find end of loop body (for/while)
function ast.findLoopEnd(ctx: BuilderContext, loopTokenIdx: number): (number, number?)
    local tokens = ctx.tokens
    local depth = 1
    local j = loopTokenIdx + 1
    local doTokenIdx = nil
    
    -- Find 'do' first
    while j <= #tokens do
        local t = tokens[j]
        if t.kind == "keyword" then
            if t.value == "function" then
                -- Skip nested function
                local funcEnd = ast.findFunctionEnd(ctx, j)
                j = funcEnd
            elseif t.value == "do" then
                doTokenIdx = j
                j += 1
                break
            end
        end
        j += 1
    end
    
    -- Now find matching 'end'
    while j <= #tokens do
        local t = tokens[j]
        if t.kind == "keyword" then
            if t.value == "if" or t.value == "do" or t.value == "for" or t.value == "function" or t.value == "while" or t.value == "repeat" then
                depth += 1
            elseif t.value == "end" then
                depth -= 1
                if depth == 0 then
                    return j, doTokenIdx
                end
            elseif t.value == "until" then
                depth -= 1
            end
        end
        j += 1
    end
    
    return #tokens, doTokenIdx
end

-- Find end of repeat..until
function ast.findRepeatEnd(ctx: BuilderContext, repeatTokenIdx: number): number
    local tokens = ctx.tokens
    local depth = 1
    local j = repeatTokenIdx + 1
    
    while j <= #tokens do
        local t = tokens[j]
        if t.kind == "keyword" then
            if t.value == "if" or t.value == "do" or t.value == "for" or t.value == "function" or t.value == "while" or t.value == "repeat" then
                depth += 1
            elseif t.value == "end" then
                depth -= 1
            elseif t.value == "until" then
                depth -= 1
                if depth == 0 then
                    -- Find end of condition
                    local k = j + 1
                    while k <= #tokens do
                        local tk = tokens[k]
                        -- Condition ends at newline or certain keywords
                        if ctx.firstTokenPerLine[tk.line] == tk and tk.line > t.line then
                            return k - 1
                        end
                        k += 1
                    end
                    return #tokens
                end
            end
        end
        j += 1
    end
    
    return #tokens
end

-- Build AST from tokens
function ast.buildProgram(tokens: {Token}, lines: {string}): Program
    local ctx = ast.createContext(tokens, lines)
    local body = ast.parseBlock(ctx, nil)
    
    local startToken = tokens[1] or { line = 1, column = 0, index = 1, kind = "", value = "" }
    local endToken = tokens[#tokens] or startToken
    
    return {
        type = "Program",
        body = body,
        tokens = tokens,
        lines = lines,
        loc = ast.makeLocation(startToken :: Token, endToken :: Token),
    }
end

-- Parse a block of statements until we hit a terminator
function ast.parseBlock(ctx: BuilderContext, terminators: {string}?): Block
    local statements: {Statement} = {}
    local astPeekCtx = ast.peek(ctx)
    local startLine = astPeekCtx and astPeekCtx.line or 1
    local endLine = startLine
    
    while not ast.isAtEnd(ctx) do
        local token = ast.peek(ctx)
        if not token then break end
        
        -- Check for terminators
        if terminators and token.kind == "keyword" then
            local isTerminator = false
            for _, t in ipairs(terminators) do
                if token.value == t then
                    isTerminator = true
                    break
                end
            end
            if isTerminator then
                break
            end
        end
        
        local stmt = ast.parseStatement(ctx)
        if stmt then
            table.insert(statements, stmt)
            endLine = stmt.loc.endLine
        else
            -- Skip unknown token
            ast.advance(ctx)
        end
    end
    
    return {
        statements = statements,
        startLine = startLine,
        endLine = endLine,
    }
end

-- Parse a single statement
function ast.parseStatement(ctx: BuilderContext): Statement?
    local token = ast.peek(ctx)
    if not token then return nil end
    
    -- Handle keywords
    if token.kind == "keyword" then
        if token.value == "local" then
            return ast.parseLocalStatement(ctx)
        elseif token.value == "function" then
            return ast.parseFunctionStatement(ctx, false)
        elseif token.value == "if" then
            return ast.parseIfStatementOrExpression(ctx)
        elseif token.value == "for" then
            return ast.parseForStatement(ctx)
        elseif token.value == "while" then
            return ast.parseWhileStatement(ctx)
        elseif token.value == "repeat" then
            return ast.parseRepeatStatement(ctx)
        elseif token.value == "do" then
            return ast.parseDoStatement(ctx)
        elseif token.value == "return" then
            return ast.parseReturnStatement(ctx)
        elseif token.value == "break" then
            local startToken = ast.advance(ctx) :: Token
            return {
                type = "BreakStatement",
                loc = ast.makeLocation(startToken, startToken),
            }
        elseif token.value == "continue" then
            local startToken = ast.advance(ctx) :: Token
            return {
                type = "ContinueStatement",
                loc = ast.makeLocation(startToken, startToken),
            }
        elseif CLOSING_KEYWORDS[token.value] then
            -- Don't consume closing keywords - let caller handle
            return nil
        end
    end
    
    -- Handle type declarations
    if token.kind == "identifier" and (token.value == "type" or token.value == "export") then
        return ast.parseTypeDeclaration(ctx)
    end
    
    -- Handle expression statements (assignments, function calls)
    return ast.parseExpressionStatement(ctx)
end

-- Parse local statement
function ast.parseLocalStatement(ctx: BuilderContext): LocalStatement?
    local startToken = ast.advance(ctx) :: Token -- consume 'local'
    local token = ast.peek(ctx)
    
    if not token then
        return nil
    end
    
    -- local function name()
    if token.kind == "keyword" and token.value == "function" then
        local funcStmt = ast.parseFunctionStatement(ctx, true)
        if funcStmt then
            return {
                type = "LocalStatement",
                names = {funcStmt.name},
                values = nil,
                isFunction = true,
                functionExpr = {
                    type = "FunctionExpression",
                    name = funcStmt.name,
                    parameters = funcStmt.parameters,
                    body = funcStmt.body,
                    signatureEndLine = funcStmt.signatureEndLine,
                    signatureEndColumn = funcStmt.signatureEndColumn,
                    signatureEndTokenIdx = funcStmt.signatureEndTokenIdx,
                    bodyStartTokenIdx = funcStmt.bodyStartTokenIdx,
                    isEmpty = funcStmt.isEmpty,
                    loc = funcStmt.loc,
                },
                loc = ast.makeLocation(startToken, ctx.tokens[funcStmt.loc.endTokenIdx or ctx.pos - 1]),
            }
        end
    end
    
    -- local name, name2 = value, value2
    local names: {string} = {}
    while not ast.isAtEnd(ctx) do
        local nameToken = ast.peek(ctx)
        if nameToken and nameToken.kind == "identifier" then
            table.insert(names, nameToken.value)
            ast.advance(ctx)
            
            -- Skip type annotation if present
            if ast.check(ctx, "symbol", ":") then
                ast.advance(ctx)
                ast.skipTypeAnnotation(ctx)
            end
            
            if ast.check(ctx, "symbol", ",") then
                ast.advance(ctx)
            else
                break
            end
        else
            break
        end
    end
    
    local values: {Expression}? = nil
    local endToken = ctx.tokens[ctx.pos - 1]
    
    if ast.check(ctx, "symbol", "=") then
        ast.advance(ctx)
        values = {}
        -- Parse values - simplified, just collect tokens until end of line or statement
        local valueStart = ctx.pos
        local depth = 0
        while not ast.isAtEnd(ctx) do
            local t = ast.peek(ctx) :: Token
            if t.kind == "symbol" then
                if t.value == "(" or t.value == "{" or t.value == "[" then
                    depth += 1
                elseif t.value == ")" or t.value == "}" or t.value == "]" then
                    depth -= 1
                elseif depth == 0 and t.value == "," then
                    -- End of this value, start of next
                    ast.advance(ctx)
                end
            elseif depth == 0 and t.kind == "keyword" and CLOSING_KEYWORDS[t.value] then
                break
            elseif depth == 0 and ctx.firstTokenPerLine[t.line] == t and t.line > ctx.tokens[valueStart].line then
                -- New line, check for continuation
                local prev = ctx.tokens[ctx.pos - 1]
                local isCont = prev and prev.kind == "symbol" and (prev.value == "," or prev.value == "(" or prev.value == "{" or prev.value == "[" or prev.value == "+" or prev.value == "-" or prev.value == "*" or prev.value == "/" or prev.value == ".." or prev.value == "=" or prev.value == "." or prev.value == ":")
                if not isCont then
                    break
                end
            end
            ast.advance(ctx)
        end
        endToken = ctx.tokens[ctx.pos - 1]
        
        -- Create a raw expression for the values
        local valueTokens = {}
        for i = valueStart, ctx.pos - 1 do
            table.insert(valueTokens, ctx.tokens[i])
        end
        if #valueTokens > 0 then
            table.insert(values :: {Expression}, {
                type = "RawExpression",
                tokens = valueTokens,
                loc = ast.makeLocation(valueTokens[1], valueTokens[#valueTokens]),
            } :: Expression)
        end
    end
    
    return {
        type = "LocalStatement",
        names = names,
        values = values,
        isFunction = false,
        functionExpr = nil,
        loc = ast.makeLocation(startToken, endToken),
    }
end

-- Parse function statement
function ast.parseFunctionStatement(ctx: BuilderContext, isLocal: boolean): FunctionStatement?
    local funcToken = ast.advance(ctx) :: Token -- consume 'function'
    local funcTokenIdx = funcToken.index
    
    -- Get function name
    local name = ast.extractFunctionName(ctx.tokens, ctx.pos)
    local isMethod = string.find(name, ":") ~= nil
    
    -- Skip past name tokens
    while not ast.isAtEnd(ctx) do
        local t = ast.peek(ctx)
        if t and (t.kind == "identifier" or (t.kind == "symbol" and (t.value == "." or t.value == ":"))) then
            ast.advance(ctx)
        else
            break
        end
    end
    
    -- Skip parameter list
    local parameters: {string} = {}
    if ast.check(ctx, "symbol", "(") then
        ast.advance(ctx)
        local parenDepth = 1
        while not ast.isAtEnd(ctx) and parenDepth > 0 do
            local t = ast.peek(ctx) :: Token
            if t.kind == "symbol" and t.value == "(" then
                parenDepth += 1
            elseif t.kind == "symbol" and t.value == ")" then
                parenDepth -= 1
            elseif parenDepth == 1 and t.kind == "identifier" then
                table.insert(parameters, t.value)
            end
            ast.advance(ctx)
        end
    end
    
    local signatureEndTokenIdx = ctx.pos - 1
    
    -- Skip return type annotation if present
    if ast.check(ctx, "symbol", ":") then
        ast.advance(ctx)
        ast.skipTypeAnnotation(ctx)
        signatureEndTokenIdx = ctx.pos - 1
    end
    
    local signatureEndToken = ctx.tokens[signatureEndTokenIdx]
    local signatureEndLine = signatureEndToken.line
    local signatureEndColumn = signatureEndToken.column + #signatureEndToken.value
    
    -- Find body start token
    local bodyStartTokenIdx = ctx.pos
    
    -- Parse body
    local body = ast.parseBlock(ctx, {"end"})
    
    -- Consume 'end'
    local endToken = ast.peek(ctx)
    if endToken and endToken.kind == "keyword" and endToken.value == "end" then
        ast.advance(ctx)
    end
    
    -- Check if body is empty
    local isEmpty = #body.statements == 0
    
    return {
        type = "FunctionStatement",
        name = name,
        isLocal = isLocal,
        isMethod = isMethod,
        parameters = parameters,
        body = body,
        signatureEndLine = signatureEndLine,
        signatureEndColumn = signatureEndColumn,
        signatureEndTokenIdx = signatureEndTokenIdx,
        bodyStartTokenIdx = bodyStartTokenIdx,
        isEmpty = isEmpty,
        functionTokenIdx = funcTokenIdx,
        loc = ast.makeLocation(funcToken, endToken or ctx.tokens[ctx.pos - 1]),
    }
end

-- Parse if statement or if expression (ternary)
function ast.parseIfStatementOrExpression(ctx: BuilderContext): Statement?
    local ifToken = ast.advance(ctx) :: Token -- consume 'if'
    local ifTokenIdx = ifToken.index
    local isTernary = ast.isTernaryIf(ctx, ifTokenIdx)
    
    -- Find 'then'
    local thenTokenIdx = nil
    local conditionStart = ctx.pos
    while not ast.isAtEnd(ctx) do
        local t = ast.peek(ctx)
        if t and t.kind == "keyword" and t.value == "then" then
            thenTokenIdx = ctx.pos
            ast.advance(ctx)
            break
        end
        ast.advance(ctx)
    end
    
    if not thenTokenIdx then
        -- Malformed if, return raw statement
        return {
            type = "RawStatement",
            tokens = {},
            startTokenIdx = ifTokenIdx,
            endTokenIdx = ctx.pos - 1,
            loc = ast.makeLocation(ifToken, ctx.tokens[ctx.pos - 1] or ifToken),
        }
    end
    
    -- Find end of if construct
    local endTokenIdx, elseIdx, elseifList = ast.findIfEnd(ctx, ifTokenIdx, isTernary)
    
    if isTernary then
        -- Build IfExpression node
        local elseifBranches: {ElseifExprBranch}? = nil
        if elseifList and #elseifList > 0 then
            elseifBranches = {}
            for _, info in ipairs(elseifList) do
                table.insert(elseifBranches :: {ElseifExprBranch}, {
                    condition = { type = "RawExpression", tokens = {}, loc = ast.makeLocation(ctx.tokens[info.elseifIdx], ctx.tokens[info.thenIdx]) } :: Expression,
                    thenExpr = { type = "RawExpression", tokens = {}, loc = ast.makeLocation(ctx.tokens[info.thenIdx], ctx.tokens[info.thenIdx]) } :: Expression,
                    elseifTokenIdx = info.elseifIdx,
                    thenTokenIdx = info.thenIdx,
                })
            end
        end
        
        ctx.pos = endTokenIdx + 1
        
        -- Wrap ternary in an ExpressionStatement
        return {
            type = "ExpressionStatement",
            expression = {
                type = "IfExpression",
                condition = { type = "RawExpression", tokens = {}, loc = ast.makeLocation(ctx.tokens[conditionStart], ctx.tokens[thenTokenIdx - 1]) } :: Expression,
                thenExpr = { type = "RawExpression", tokens = {}, loc = ast.makeLocation(ctx.tokens[thenTokenIdx], ctx.tokens[elseIdx or endTokenIdx]) } :: Expression,
                elseifBranches = elseifBranches,
                elseExpr = { type = "RawExpression", tokens = {}, loc = ast.makeLocation(ctx.tokens[elseIdx or endTokenIdx], ctx.tokens[endTokenIdx]) } :: Expression,
                ifTokenIdx = ifTokenIdx,
                thenTokenIdx = thenTokenIdx,
                elseIdx = elseIdx or endTokenIdx,
                endTokenIdx = endTokenIdx,
                loc = ast.makeLocation(ifToken, ctx.tokens[endTokenIdx]),
            },
            loc = ast.makeLocation(ifToken, ctx.tokens[endTokenIdx]),
        }
    else
        -- Statement if
        local thenBlock = ast.parseBlock(ctx, {"else", "elseif", "end"})
        
        local elseifBranches: {ElseifBranch}? = nil
        local elseBlock: Block? = nil
        
        -- Parse elseif branches
        while ast.check(ctx, "keyword", "elseif") do
            if not elseifBranches then
                elseifBranches = {}
            end
            local elseifToken = ast.advance(ctx) :: Token
            local elseifTokenIdx = elseifToken.index
            local elseifStartLine = elseifToken.line
            
            -- Skip condition until 'then'
            local elseifThenIdx = nil
            while not ast.isAtEnd(ctx) do
                local t = ast.peek(ctx)
                if t and t.kind == "keyword" and t.value == "then" then
                    elseifThenIdx = ctx.pos
                    ast.advance(ctx)
                    break
                end
                ast.advance(ctx)
            end
            
            local branchBlock = ast.parseBlock(ctx, {"else", "elseif", "end"})
            table.insert(elseifBranches :: {ElseifBranch}, {
                condition = { type = "RawExpression", tokens = {}, loc = ast.makeLocation(elseifToken, ctx.tokens[elseifThenIdx or ctx.pos - 1]) } :: Expression,
                block = branchBlock,
                elseifTokenIdx = elseifTokenIdx,
                thenTokenIdx = elseifThenIdx or ctx.pos - 1,
                startLine = elseifStartLine,
            })
        end
        
        -- Parse else block
        if ast.check(ctx, "keyword", "else") then
            ast.advance(ctx)
            elseBlock = ast.parseBlock(ctx, {"end"})
        end
        
        -- Consume 'end'
        local endToken = ast.peek(ctx)
        if endToken and endToken.kind == "keyword" and endToken.value == "end" then
            ast.advance(ctx)
        end
        
        return {
            type = "IfStatement",
            condition = { type = "RawExpression", tokens = {}, loc = ast.makeLocation(ctx.tokens[conditionStart], ctx.tokens[thenTokenIdx - 1]) } :: Expression,
            thenBlock = thenBlock,
            elseifBranches = elseifBranches,
            elseBlock = elseBlock,
            ifTokenIdx = ifTokenIdx,
            thenTokenIdx = thenTokenIdx,
            loc = ast.makeLocation(ifToken, endToken or ctx.tokens[ctx.pos - 1]),
        }
    end
end

-- Parse for statement
function ast.parseForStatement(ctx: BuilderContext): Statement?
    local forToken = ast.advance(ctx) :: Token -- consume 'for'
    local endTokenIdx, doTokenIdx = ast.findLoopEnd(ctx, forToken.index)
    
    -- Skip to 'do'
    ctx.pos = (doTokenIdx or endTokenIdx) + 1
    
    -- Parse body
    local body = ast.parseBlock(ctx, {"end"})
    
    -- Consume 'end'
    local endToken = ast.peek(ctx)
    if endToken and endToken.kind == "keyword" and endToken.value == "end" then
        ast.advance(ctx)
    end
    
    -- Return generic for statement (simplified)
    return {
        type = "ForGenericStatement",
        variables = {},
        iterators = {},
        body = body,
        doTokenIdx = doTokenIdx,
        loc = ast.makeLocation(forToken, endToken or ctx.tokens[ctx.pos - 1]),
    }
end

-- Parse while statement
function ast.parseWhileStatement(ctx: BuilderContext): Statement?
    local whileToken = ast.advance(ctx) :: Token -- consume 'while'
    local endTokenIdx, doTokenIdx = ast.findLoopEnd(ctx, whileToken.index)
    
    -- Skip to 'do'
    ctx.pos = (doTokenIdx or endTokenIdx) + 1
    
    -- Parse body
    local body = ast.parseBlock(ctx, {"end"})
    
    -- Consume 'end'
    local endToken = ast.peek(ctx)
    if endToken and endToken.kind == "keyword" and endToken.value == "end" then
        ast.advance(ctx)
    end
    
    return {
        type = "WhileStatement",
        condition = { type = "RawExpression", tokens = {}, loc = ast.makeLocation(whileToken, ctx.tokens[doTokenIdx or ctx.pos - 1]) } :: Expression,
        body = body,
        doTokenIdx = doTokenIdx,
        loc = ast.makeLocation(whileToken, endToken or ctx.tokens[ctx.pos - 1]),
    }
end

-- Parse repeat statement
function ast.parseRepeatStatement(ctx: BuilderContext): Statement?
    local repeatToken = ast.advance(ctx) :: Token -- consume 'repeat'
    
    -- Parse body
    local body = ast.parseBlock(ctx, {"until"})
    
    -- Consume 'until' and condition
    local untilToken = ast.peek(ctx)
    if untilToken and untilToken.kind == "keyword" and untilToken.value == "until" then
        ast.advance(ctx)
        -- Skip condition tokens
        local condStart = ctx.pos
        while not ast.isAtEnd(ctx) do
            local t = ast.peek(ctx)
            if t and ctx.firstTokenPerLine[t.line] == t and t.line > untilToken.line then
                break
            end
            ast.advance(ctx)
        end
    end
    
    return {
        type = "RepeatStatement",
        body = body,
        condition = { type = "RawExpression", tokens = {}, loc = ast.makeLocation(untilToken or repeatToken, ctx.tokens[ctx.pos - 1]) } :: Expression,
        loc = ast.makeLocation(repeatToken, ctx.tokens[ctx.pos - 1]),
    }
end

-- Parse do statement
function ast.parseDoStatement(ctx: BuilderContext): Statement?
    local doToken = ast.advance(ctx) :: Token -- consume 'do'
    
    -- Parse body
    local body = ast.parseBlock(ctx, {"end"})
    
    -- Consume 'end'
    local endToken = ast.peek(ctx)
    if endToken and endToken.kind == "keyword" and endToken.value == "end" then
        ast.advance(ctx)
    end
    
    return {
        type = "DoStatement",
        body = body,
        loc = ast.makeLocation(doToken, endToken or ctx.tokens[ctx.pos - 1]),
    }
end

-- Parse return statement
function ast.parseReturnStatement(ctx: BuilderContext): Statement?
    local returnToken = ast.advance(ctx) :: Token -- consume 'return'
    
    -- Collect return values until end of statement
    local startPos = ctx.pos
    local depth = 0
    while not ast.isAtEnd(ctx) do
        local t = ast.peek(ctx) :: Token
        if t.kind == "symbol" then
            if t.value == "(" or t.value == "{" or t.value == "[" then
                depth += 1
            elseif t.value == ")" or t.value == "}" or t.value == "]" then
                depth -= 1
            end
        elseif depth == 0 and t.kind == "keyword" and CLOSING_KEYWORDS[t.value] then
            break
        elseif depth == 0 and ctx.firstTokenPerLine[t.line] == t and t.line > returnToken.line then
            -- Check for continuation
            local prev = ctx.tokens[ctx.pos - 1]
            local isCont = prev and prev.kind == "symbol" and (prev.value == "," or prev.value == "(" or prev.value == "{" or prev.value == "[" or prev.value == "+" or prev.value == "-" or prev.value == "*" or prev.value == "/" or prev.value == "..")
            if not isCont then
                break
            end
        end
        ast.advance(ctx)
    end
    
    local values: {Expression}? = nil
    if ctx.pos > startPos then
        local valueTokens = {}
        for i = startPos, ctx.pos - 1 do
            table.insert(valueTokens, ctx.tokens[i])
        end
        values = {
            {
                type = "RawExpression",
                tokens = valueTokens,
                loc = ast.makeLocation(valueTokens[1], valueTokens[#valueTokens]),
            } :: Expression
        }
    end
    
    return {
        type = "ReturnStatement",
        values = values,
        loc = ast.makeLocation(returnToken, ctx.tokens[ctx.pos - 1] or returnToken),
    }
end

-- Parse type declaration
function ast.parseTypeDeclaration(ctx: BuilderContext): TypeDeclaration?
    local startToken = ast.peek(ctx) :: Token
    local isExport = startToken.value == "export"
    
    if isExport then
        ast.advance(ctx)
    end
    
    -- Should be 'type' now
    local typeToken = ast.peek(ctx)
    if not typeToken or typeToken.value ~= "type" then
        return nil
    end
    ast.advance(ctx)
    
    -- Get type name
    local nameToken = ast.peek(ctx)
    local name = nameToken and nameToken.kind == "identifier" and nameToken.value or ""
    
    -- Skip rest of type declaration until end of line
    while not ast.isAtEnd(ctx) do
        local t = ast.peek(ctx) :: Token
        if ctx.firstTokenPerLine[t.line] == t and t.line > startToken.line then
            break
        end
        ast.advance(ctx)
    end
    
    return {
        type = "TypeDeclaration",
        isExport = isExport,
        name = name,
        loc = ast.makeLocation(startToken, ctx.tokens[ctx.pos - 1] or startToken),
    }
end

-- Parse expression statement (assignments, function calls)
function ast.parseExpressionStatement(ctx: BuilderContext): Statement?
    local startToken = ast.peek(ctx)
    if not startToken then return nil end
    local startPos = ctx.pos
    
    -- Collect tokens until we reach end of statement
    local depth = 0
    while not ast.isAtEnd(ctx) do
        local t = ast.peek(ctx) :: Token
        if t.kind == "symbol" then
            if t.value == "(" or t.value == "{" or t.value == "[" then
                depth += 1
            elseif t.value == ")" or t.value == "}" or t.value == "]" then
                depth -= 1
            end
        elseif depth == 0 and t.kind == "keyword" then
            if CLOSING_KEYWORDS[t.value] then
                break
            elseif t.value == "local" or t.value == "function" or t.value == "if" or t.value == "for" or t.value == "while" or t.value == "repeat" or t.value == "do" or t.value == "return" or t.value == "break" or t.value == "continue" then
                -- New statement
                if ctx.pos > startPos then
                    break
                end
            end
        elseif depth == 0 and ctx.firstTokenPerLine[t.line] == t and t.line > startToken.line then
            -- Check for continuation
            local prev = ctx.tokens[ctx.pos - 1]
            local isCont = false
            if prev then
                if prev.kind == "symbol" then
                    local v = prev.value
                    if v == "," or v == "(" or v == "{" or v == "[" or v == "+" or v == "-" or v == "*" or v == "/" or v == ".." or v == "=" or v == "." or v == ":" or v == "==" or v == "~=" or v == "<" or v == ">" or v == "<=" or v == ">=" then
                        isCont = true
                    end
                elseif prev.kind == "keyword" then
                    if prev.value == "and" or prev.value == "or" or prev.value == "not" then
                        isCont = true
                    end
                end
            end
            if not isCont then
                break
            end
        end
        ast.advance(ctx)
    end
    
    if ctx.pos == startPos then
        ast.advance(ctx)
        return nil
    end
    
    local stmtTokens = {}
    for i = startPos, ctx.pos - 1 do
        table.insert(stmtTokens, ctx.tokens[i])
    end
    
    return {
        type = "ExpressionStatement",
        expression = {
            type = "RawExpression",
            tokens = stmtTokens,
            loc = ast.makeLocation(stmtTokens[1], stmtTokens[#stmtTokens]),
        } :: Expression,
        loc = ast.makeLocation(stmtTokens[1], stmtTokens[#stmtTokens]),
    }
end

return ast
