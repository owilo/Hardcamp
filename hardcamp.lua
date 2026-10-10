------------------
-- Data storage --
------------------

local B = bit32

local function ceilLog2(count)
    local b = 0
    local s = 1
    while s < count do
        b = b + 1
        s = B.lshift(s, 1)
    end
    return b
end

local function getMappings(alphabet)
    local mappings = {
        length = #alphabet
    }

    for i = 1, #alphabet do
        mappings[alphabet:sub(i, i)] = i - 1
    end

    return mappings
end

local function sortedSearch(t, value, key)
    key = key or function(entry)
        return entry
    end

    local low = 1
    local high = #t

    while low <= high do
        local mid = math.floor((low + high) / 2)
        local entry = t[mid]
        local entryKey = key(entry)

        if entryKey == value then
            return entry
        elseif entryKey < value then
            low = mid + 1
        else
            high = mid - 1
        end
    end

    return nil
end

local function deepCopy(t)
    if type(t) ~= "table" then
        return t
    end

    local copy = {}
    for k, v in pairs(t) do
        copy[k] = deepCopy(v)
    end

    return copy
end

-- Base 64 helpers

local B64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local B64_MAPPINGS = getMappings(B64_ALPHABET)

local function encodeBase64(str)
    local out = {}
    local n = #str
    local i = 1
    while i <= n do
        local b1 = str:byte(i)
        local b2 = str:byte(i + 1)
        local b3 = str:byte(i + 2)

        local c1 = B.rshift(b1, 2)
        local c2 = B.bor(B.lshift(B.band(b1, 0x03), 4), b2 and B.rshift(b2, 4) or 0)
        local c3 = b2 and B.bor(B.lshift(B.band(b2, 0x0F), 2), b3 and B.rshift(b3, 6) or 0)
        local c4 = b3 and B.band(b3, 0x3F)

        out[#out + 1] = B64_ALPHABET:sub(c1 + 1, c1 + 1)
        out[#out + 1] = B64_ALPHABET:sub(c2 + 1, c2 + 1)
        out[#out + 1] = c3 and B64_ALPHABET:sub(c3 + 1, c3 + 1) or "="
        out[#out + 1] = c4 and B64_ALPHABET:sub(c4 + 1, c4 + 1) or "="

        i = i + 3
    end
    return table.concat(out)
end

local function decodeBase64(str)
    str = str:gsub("[^%w_%-=]", "")

    local out = {}
    local i = 1
    local n = #str
    while i <= n do
        local c1 = B64_MAPPINGS[str:sub(i, i)] or 0
        local c2 = B64_MAPPINGS[str:sub(i + 1, i + 1)] or 0
        local c3 = B64_MAPPINGS[str:sub(i + 2, i + 2)]
        local c4 = B64_MAPPINGS[str:sub(i + 3, i + 3)]

        out[#out + 1] = string.char(B.band(B.bor(B.lshift(c1, 2), B.rshift(c2, 4)), 0xFF))
        if c3 then
            out[#out + 1] = string.char(B.band(B.bor(B.lshift(c2, 4), B.rshift(c3, 2)), 0xFF))
        end
        if c4 then
            out[#out + 1] = string.char(B.band(B.bor(B.lshift(c3, 6), c4), 0xFF))
        end

        i = i + 4
    end
    return table.concat(out)
end

-- Writer

local BitWriter = {}
BitWriter.__index = BitWriter

function BitWriter.new()
    return setmetatable({
        bytes = {0},
        currentBit = 0,
    }, BitWriter)
end

function BitWriter:writeBits(value, bitCount)
    value = B.band(value, B.lshift(1, bitCount) - 1)

    while bitCount > 0 do
        local take = math.min(8 - self.currentBit, bitCount)

        self.bytes[#self.bytes] = B.band(B.bor(self.bytes[#self.bytes], B.lshift(value, self.currentBit)), 0xFF)

        value = B.rshift(value, take)
        bitCount = bitCount - take
        self.currentBit = self.currentBit + take

        if self.currentBit == 8 then
            self.bytes[#self.bytes + 1] = 0
            self.currentBit = 0
        end
    end

    return self
end

function BitWriter:writeString(str, mappings, size)
    size = size or #str
    local charSize = ceilLog2(mappings.length)
    for i = 1, size do
        self:writeBits(mappings[str:sub(i, i)] or 0, charSize)
    end
    return self
end

function BitWriter:writePlayerList(authors)
    self:writeBits(#authors, 8)
    for _, author in ipairs(authors) do
        local prefix, playerName, tag = author:match("^(%+?)([%w_]+)#(%d%d%d%d)$")
        self:writeBits(prefix == "+" and 1 or 0, 1) -- "+" prefix
        self:writeBits(#playerName, 4) -- Author name length
        self:writeString(playerName, B64_MAPPINGS, #playerName) -- Author names can conveniently be treated as a base64 string
        self:writeBits(tonumber(tag), 14) -- Author tag
    end
end

function BitWriter:writeVariableLength(value, blockSize)
    blockSize = blockSize or 7
    repeat
        local block = B.band(value, B.lshift(1, blockSize) - 1)
        value = B.rshift(value, blockSize)
        self:writeBits(block, blockSize)
        self:writeBits(value > 0 and 1 or 0, 1) -- Continuation bit
    until value == 0
end

function BitWriter:writeMaps(maps, authors)
    local mapCount = 0
    local indices = {}
    for i = 1, #maps do
        mapCount = mapCount + #maps[i]
        indices[i] = 1
    end

    self:writeBits(mapCount, 16)
    local previousMapCode = 0
    local authorsBitCount = ceilLog2(#authors)

    for i = 1, mapCount do
        local minCode = math.huge
        local minDifficultyIndex = 0
        for j = 1, #maps do
            local mapIndex = indices[j]
            if mapIndex <= #maps[j] and maps[j][mapIndex].mapCode < minCode then
                minCode = maps[j][mapIndex].mapCode
                minDifficultyIndex = j
            end
        end

        local minMapIndex = indices[minDifficultyIndex]
        indices[minDifficultyIndex] = minMapIndex + 1

        local map = maps[minDifficultyIndex][minMapIndex]
        local delta = map.mapCode - previousMapCode
        previousMapCode = map.mapCode

        self:writeVariableLength(delta, 5)
        self:writeBits(map.author - 1, authorsBitCount)
        self:writeBits(minDifficultyIndex - 1, 2)
        self:writeBits(map.sizemap and 1 or 0, 1)
    end
end

function BitWriter:toString()
    local count = #self.bytes

    if self.currentBit == 0 then
        count = count - 1
    end

    local t = {}

    for i = 1, count do
        t[i] = string.char(self.bytes[i])
    end

    return table.concat(t)
end

function BitWriter:toBase64()
    return encodeBase64(self:toString())
end

-- Reader

local BitReader = {}
BitReader.__index = BitReader

function BitReader.fromString(data)
    return setmetatable({
        data = data,
        currentByte = 1,
        currentBit = 0,
    }, BitReader)
end

function BitReader.fromBase64(b64)
    return BitReader.fromString(decodeBase64(b64))
end

function BitReader:readBits(bitCount)
    local value = 0
    local shift = 0

    while bitCount > 0 do
        local take = math.min(8 - self.currentBit, bitCount)

        local byte = self.data:byte(self.currentByte) or 0
        local bits = B.band(B.rshift(byte, self.currentBit), B.lshift(1, take) - 1)

        value = B.bor(value, B.lshift(bits, shift))
        shift = shift + take
        bitCount = bitCount - take

        self.currentBit = self.currentBit + take
        if self.currentBit == 8 then
            self.currentBit = 0
            self.currentByte = self.currentByte + 1
        end
    end

    return value
end

function BitReader:readString(alphabet, size)
    local charSize = ceilLog2(#alphabet)

    local chars = {}
    for i = 1, size do
        local index = self:readBits(charSize) + 1
        chars[i] = alphabet:sub(index, index)
    end

    return table.concat(chars)
end

function BitReader:readPlayerList()
    local authors = {}
    local count = self:readBits(8)
    for i = 1, count do
        local prefix = self:readBits(1) == 1 and "+" or "" -- "+" prefix
        local playerNameLength = self:readBits(4) -- Author name length
        local playerName = self:readString(B64_ALPHABET, playerNameLength) -- Author name
        local tag = string.format("%04d", self:readBits(14)) -- Author tag
        authors[i] = string.format("%s%s#%s", prefix, playerName, tag)
    end
    return authors
end

function BitReader:readVariableLength(payloadSize)
    payloadSize = payloadSize or 7
    local value = 0
    local shift = 0
    while shift < 64 do
        local block = self:readBits(payloadSize)
        value = B.bor(value, B.lshift(block, shift))
        shift = shift + payloadSize
        local continuationBit = self:readBits(1)
        if continuationBit == 0 then
            return value
        end
    end
    -- Failsafe
    return value
end

function BitReader:readMaps(authors)
    local maps = {}

    for i = 1, 4 do
        maps[i] = {}
    end

    local mapCount = self:readBits(16)
    local previousMapCode = 0
    local authorsBitCount = ceilLog2(#authors)

    for i = 1, mapCount do
        local delta = self:readVariableLength(5)
        local mapCode = previousMapCode + delta
        previousMapCode = mapCode

        local authorIndex = self:readBits(authorsBitCount) + 1
        local difficulty = self:readBits(2) + 1
        local sizemap = self:readBits(1) == 1

        maps[difficulty][#maps[difficulty] + 1] = {
            mapCode = mapCode,
            author = authorIndex,
            sizemap = sizemap
        }
    end

    return maps
end

-----------------
-- XML parsing --
-----------------

local function parseAttributes(attributes)
    local attrs = {}
    for key, value in attributes:gmatch("(%w+)%s*=%s*\"(.-)\"") do
        attrs[key] = value
    end
    return attrs
end

local function parseXML(xml)
    local currentChar = 1
    local tagStack = {{}}

    -- Escape backslashes and quotes in the XML string
    xml = xml:gsub("\\\\", "&bsol;"):gsub("\\\"", "&quot;")

    -- Escape angle brackets in attribute values
    xml = xml:gsub("(%w+)%s*=%s*\"(.-)\"", function(key, value)
        local escapedValue = value:gsub(">", "&gt;"):gsub("<", "&lt;")
        return key .. '="' .. escapedValue .. '"'
    end)
    
    local stack = {}
    local root = { attributes = {}, children = {} }
    local current = root

    local i = 1
    while i <= #xml do
        -- Match opening tags, closing tags, and self-closing tags
        local isClosingTag, tagName, attributes, isSelfClosing = xml:match("<(%/?)%s*(%w+)%s*(.-)%s*(%/?)>", i)

        if isClosingTag == "/" then
            -- Pop from stack when closing tag is found
            current = table.remove(stack)
        else
            -- Create new element node
            local newElement = {
                tag = tagName,
                attributes = parseAttributes(attributes),
                children = {},
            }

            table.insert(current.children, newElement)

            -- Push current node to stack if not self-closing
            if isSelfClosing ~= "/" then
                table.insert(stack, current)
                current = newElement
            end
        end

        -- Move to next tag
        i = xml:find(">", i) + 1
    end

    -- Return the root
    return root.children[1]
end

local function xmlFind(node, path)
    local nodes = {}
    local matchingNodes = {{children = {node}}}

    for tags in path:gmatch("([^.]+)") do
        nodes = matchingNodes

        if #nodes == 0 then
            return {}
        end

        matchingNodes = {}

        for tag in tags:gmatch("([^;]+)") do
            for _, node in ipairs(nodes) do
                for _, child in ipairs(node.children) do
                    if child.tag == "*" or child.tag == tag then
                        table.insert(matchingNodes, child)
                    end
                end
            end
        end
    end

    return matchingNodes
end

----------------------
-- Global variables --
----------------------

local room = {
    respawnPlayers = {},
    currentMapEntry = nil,
    isSizeMap = false,
    playerSizes = nil,
    rotation = {1, 3, 2, 1, 4, 2, 1, 3, 2},
    currentRotationIndex = 1,
    xmlTree = nil,
    leaderboard = {}
}

--------
-- UI --
--------

-- Text areas

local TextArea = {}
TextArea.__index = TextArea

local idCounter = 0

function TextArea.new(text, x, y, width, height, backgroundColor, borderColor, backgroundAlpha, fixed)
    idCounter = idCounter + 1
    return setmetatable({
        id = idCounter,
        text = text,
        x = x,
        y = y,
        width = width,
        height = height,
        backgroundColor = backgroundColor,
        borderColor = borderColor,
        backgroundAlpha = backgroundAlpha,
        fixed = fixed,
        shownTo = {}
    }, TextArea)
end

function TextArea:show(playerName)
    self.shownTo[playerName] = true
    ui.addTextArea(self.id, self.text, playerName, self.x + 5, self.y + 5, self.width - 10, self.height - 10, self.backgroundColor, self.borderColor, self.backgroundAlpha, self.fixed)
end

function TextArea:hide(playerName)
    self.shownTo[playerName] = nil
    ui.removeTextArea(self.id, playerName)
end

function TextArea:toggle(playerName, state)
    if state == nil then
        state = not self.shownTo[playerName]
    end

    if state then
        self:show(playerName)
    else
        self:hide(playerName)
    end
end

function TextArea:updateText(newText)
    self.text = newText
    ui.updateTextArea(self.id, newText, nil)
end

-- Text area groups

local TextAreaGroup = {}
TextAreaGroup.__index = TextAreaGroup

function TextAreaGroup.new(textAreas)
    return setmetatable({
        textAreas = textAreas
    }, TextAreaGroup)
end

function TextAreaGroup:show(playerName)
    for _, textArea in ipairs(self.textAreas) do
        textArea:show(playerName)
    end
end

function TextAreaGroup:hide(playerName)
    for _, textArea in ipairs(self.textAreas) do
        textArea:hide(playerName)
    end
end

-- UI elements

local UI = {
    helpButton = TextAreaGroup.new{
        TextArea.new("", 0, 20, 40, 10, 0x301f16, 0x301f16, 1.0, true),
        TextArea.new("<font size='10'><J><B>Help</B></J></font>", 0, 15, 50, 30, 0x000000, 0x000000, 0, true)
    },
    leaderboard = TextArea.new("", 10, 40, 200, 160, 0x301f16, 0x301f16, 0.75, true)
}

---------------
-- Callbacks --
---------------

local KEY_CALLBACKS = {}
KEY_CALLBACKS[string.byte("G")] = function(playerName, down)
    if down then
        tfm.exec.killPlayer(playerName)
    end
end

KEY_CALLBACKS[string.byte("J")] = function(playerName, down)
    if down and room.isSizeMap then
        tfm.exec.changePlayerSize(playerName, room.playerSizes[1])
    end
end

KEY_CALLBACKS[string.byte("K")] = function(playerName, down)
    if down and room.isSizeMap then
        tfm.exec.changePlayerSize(playerName, room.playerSizes[2])
    end
end

KEY_CALLBACKS[string.byte("L")] = function(playerName, down)
    if down and room.isSizeMap then
        tfm.exec.changePlayerSize(playerName, room.playerSizes[3])
    end
end

KEY_CALLBACKS[string.byte("O")] = function(playerName, down)
    UI.leaderboard:toggle(playerName, down)
end

function eventKeyboard(playerName, keyCode, down, xPlayerPosition, yPlayerPosition)
    local callback = KEY_CALLBACKS[keyCode]
    if callback then
        callback(playerName, down)
    end
end

------------------------
-- Players management --
------------------------

local function markPlayerForRespawn(playerName)
    room.respawnPlayers[#room.respawnPlayers + 1] = playerName
end

local function respawnPlayers()
    for i = 1, #room.respawnPlayers do
        tfm.exec.respawnPlayer(room.respawnPlayers[i])
        if room.isSizeMap then
            tfm.exec.changePlayerSize(room.respawnPlayers[i], room.playerSizes[2])
        end
    end
    room.respawnPlayers = {}
end

function eventPlayerDied(playerName)
    markPlayerForRespawn(playerName)
end

local function addLeaderboardEntry(playerName, time)
    if #room.leaderboard == 0 then
        room.leaderboard[1] = {playerName = playerName, time = time}
        return
    end

    for i = 1, #room.leaderboard do
        if time < room.leaderboard[i].time then
            table.insert(room.leaderboard, i, {playerName = playerName, time = time})
            if #room.leaderboard > 20 then
                table.remove(room.leaderboard)
            end
            return
        end
    end
    
    if #room.leaderboard < 20 then
        room.leaderboard[#room.leaderboard + 1] = {playerName = playerName, time = time}
    end
end

local RANKING_COLORS = {
    "J",
    "N2",
    "CE"
}

local function updateLeaderboard()
    local leaderboardText = "<p align='center'><b>Leaderboard</b></p>\n"
    for i = 1, #room.leaderboard do
        local entry = room.leaderboard[i]
        local color = RANKING_COLORS[i] or "BL"
        leaderboardText = leaderboardText .. string.format("<p align='left'><%s>%d.</%s> %s <G>-</G> <V>%.2fs</V></p>", color, i, color, entry.playerName, entry.time / 100)
    end
    UI.leaderboard:updateText(leaderboardText)
end

local function clearLeaderboard()
    room.leaderboard = {}
    updateLeaderboard()
end

function eventPlayerWon(playerName, timeElapsed, timeElapsedSinceRespawn)
    addLeaderboardEntry(playerName, timeElapsedSinceRespawn)
    updateLeaderboard()
    tfm.exec.setPlayerScore(playerName, room.currentMapEntry.difficulty, true)
    markPlayerForRespawn(playerName)
end

local function initializePlayer(playerName)
    tfm.exec.setPlayerScore(playerName, 0, false)
    for key, _ in pairs(KEY_CALLBACKS) do
        system.bindKeyboard(playerName, key, true, true)
        system.bindKeyboard(playerName, key, false, true)
    end
    UI.helpButton:show(playerName)
end

function eventNewPlayer(playerName)
    initializePlayer(playerName)
    markPlayerForRespawn(playerName)
end

----------
-- Maps --
----------

local MAPS_DATA = "T0ZiSQDAPZrZeVxKASBCLEUAwDGe1sLiCQCwYUVbkWQYZbCi8Nmh8PkFOKDUzs6LAQB3oSsnsi0A4AbRA9GW_QJY1M3o7AEAUCq1jkRXF-1yEhxrrKoCADjyOI9lRfQU2RYAkJKbeqvGnugXwAx02zwSAECGtsoOm6JWFCXXCASsLQkAoEXUVgBABWsqyoyXFND15GSu9L4AJbnwyQIAlxHZ1ltZjVtFAAAxqkt-AZZBXdabY-7dTgDAPavWtuj5BTBgNbVTtLHooJ2iV5oaiAIAzhDP2SVFAIACKVqWaIqWKACAgfDTVo8TSS0MAQBXiWsrniIAwKTW-7TzC4BXx2md13oAgJRCrdTOzlsBAFeJZ6uBnj1AgVJb0W32xBMAUIZmlh4fCYnO1dauroMUQ5wdqsIcExzXEwBgmeausgcASMMVWe1MvRUAsJcWax2KoiiKAgBOKLXz1E4AQF6dlqIlGncAAHzQtYW11-sA2YL-LCkuBSYRzToGBprbiumKtlOWWGeNC9E09danCxWx6AEArpFRcUPdL4AFped5LAAghVBbS8-bZQAAKZp2ng_KQENUBQCcoqXaKpIAgJRalyO9dWUBAAy4K7pqXOlpKwsAyMjTStQ9NRkAYEAsaqsMAKhCBFERAECJm6YAgMs0jvTcFQBQwZqKMgDAjhTlSBYAYAbamdwWmzFkdMVTBABc5H0u63UKgAVOtA29dUM3GwBgicayXggAKMsTvXP1YorWwvLpZDCAFNETFGzckK4oJ5IAgJRa9PU69PUAACa9WkmKCouzRO08xZjEew5Qb_UC4HR_ZZZZLo8ARLY3BLhRkRggtUMokR2ci0TyukrE9nchkFnPg4TksC1oofM6SCRGxaGQlxeDREy2HQi4RZwogD_BIREeFYNEbJCpxazPwgDaXoUD7jI55MfLIJEVnRIBUc-W0BYa8XFQQMBuh4TkNjiERPFAAFMcFCHr5gDddYNETLlIYM2DQUg1UOANCQRm-VtALyUGYJAQZK__QZAU70TB2zcY5M-FQ3TRLQSBWz844JYvQViWOgQ-L0Fenzhkjj1BTOgg_GSDA3ASDA4xazs4gPyNBlT8DxxwzeiAmCYUOuXvsFFnDoDJ6ZA6HwNH8ueBcQ4O2O1YOCS0oQfmunhg7XeCAN2VDZRyOAwc6cdVOETcz-CA1uYDAvz4FhI5VSoRsAyDRE6SSWg0gwNSmUuIvsWAkL0-Dll9LRFxHBL56TJw4N9F4Zb0zhzx-8cRx5HBkcERwYHAAcGBwJEVSUQEy-AWvhVusVVUwOVMh4R6vBYSM_1qE50NDqjrg5BaHiBA-yEC2TYkmUVxkGDcAwJknDmEPo3DfBXK6YWpw2RWSSzcg8TaFMvF7JEJ7BGpJK23XO6ZoICOg0RQNdDlfw0J0nupwNeTXWL0UOg8FwHak1EEbysHyHnITSWHhPgUqgDFLV7gUxglFSXg9pwXLFjpLpH2JxxIZeUQ0lPg1IlK0lC4AASFXNI5qYRHqQp-_w0mcN-tF5MVMNjXIxFULk5ZFVJGhJRdLDqBsQx40dAo3j1fYFJQgO12C3crA34ODlEOujKYMjhL5iIZbA7S6UWXsoY02MPiAvkcNnBZ5gLQfQ5Cy-AC2x40gfdBgb0sOHidQ0jTUGSGuYPIqoNSRC5Bv8va-BDFJA8PQGiSfi4mIV3hl_8lKqhXogJ1Jz5ZSeET4SPho-CT4BPiE9wWPrkjncY2OGDXkY9GVPikFxddQr04JA4UOEfhANL4JD4-6dHiEzb4oCSFA2SS-CRui0_GX_gkhj5xhU9-XFDA5YMPcgOoHPuI-CCtiU_WPPls5z4o_8A4XQ6AiSkI8OoD3g0-aYPPig9infi8hI1L1tsQRR2LS2w60KRfEwiiT9rgA94OPkDVBwKwHT5ZPnk-0T4pPlk-yT4hPjpR4iPRNT5am0_2etAp3o1PjI9Wm7hEBwVd3OQT2x50IVMhg10dPhp0MoUPXnDIBBybTGZRACH4iORC8M1DhNkIRk0-CT6QjU9Od_jMhC7IxWQpGSYUkx1CdNCAgK4L0nT-gIi9A5Jy5JOyGOH5BESFU9AKolP6bFIoFAnXTnhQgGSHT-DeIIF8iY9a4wM0Nk4K3-ETXhUgGyGIZDL4JO-LD-qSyED2IGJxIxMUJEooY0MEtvqkh4dR7P_4pBWEW-FAGBAePrGJj2rQuAR1EZ1o98pk3oNM1D845cgktYMM-NooCYyHTFzz-CT4IPik-0Rmh0_--vgELYOP7FSAJD8yccvEBHE0TDi5D1LJ9Fg5oR6VU2KaOOWEq2Hc1CDkVI2PznAwqWUHEcJEFV5ECJDFQBWWT0z9KxQiVAJUAhQCVAIU9oSE_BaITog5JQLucEilSKFIBe-IgW0hFdUtSDlnZZj7FExJTGljgYR7JUiyfUMFnxVWSVeDFJEjaW-RVVB7WMFvUDkpFMoBlQSFkyjGxkgZu5VcCVX2QeVCSULlQclAyZ9cEdWAtFMp5r2Hj84GFQKVA7UBpQC1tzksOUi45Ligj1LS8cCY8hWM0v9gBZovSFLj4aT4DEj6z8Cl_iPllQNCbkOV0XBll4eUyNFgoQ9c4cXgKBQVINDFYaVqFToWTjrFgZAZWyVsgxbsGHEejg2C5HhYZW8Iiy-CZnhw-R0LUnm0IC2FBRLShhR4FUhZ44AU2RVOSf_lGPU2juHxQFE_VFzga8GY3kIGXIVXTHF4gRUJpl5oBR0-YMDf4LVWHmJQZ4LkNQ9gAF2hqX-Tof6TZPSYMMn9EUhU55TUDkwSxSOGkw8godngGHODTH4JZVBWgGwWIAM="
local bitReader = BitReader.fromBase64(MAPS_DATA)
local AUTHORS = bitReader:readPlayerList()
local MAPS = bitReader:readMaps(AUTHORS)

local function getMapEntry(maps, mapCode)
    for i = 1, #maps do
        local mapEntry = sortedSearch(maps[i], mapCode, function(entry)
            return entry.mapCode
        end)

        if mapEntry then
            local newMapEntry = deepCopy(mapEntry)
            newMapEntry.author = AUTHORS[mapEntry.author] or "Module"
            newMapEntry.difficulty = i
            return newMapEntry
        end
    end

    local isPlayerMap = tfm.get.room.xmlMapInfo and tfm.get.room.xmlMapInfo.mapCode == mapCode
    return {
        mapCode = mapCode,
        author = isPlayerMap and tfm.get.room.xmlMapInfo.author,
        difficulty = 0,
        sizemap = false
    }
end

local function playRandomMap(difficulty)
    if difficulty then
        difficulty = math.max(1, math.min(4, difficulty))
    else
        difficulty = math.random(4)
    end
    local mapList = MAPS[difficulty]
    tfm.exec.newGame(mapList[math.random(#mapList)].mapCode)
end

local function playNextMap()
    local difficulty = room.rotation[room.currentRotationIndex]
    room.currentRotationIndex = (room.currentRotationIndex % #room.rotation) + 1
    playRandomMap(difficulty)
end

local DIFFICULTY_STARS = {
    "<G>★★★★",
    "<VP>★<G>★★★",
    "<J>★★<G>★★",
    "<O>★★★<G>★",
    "<R>★★★★"
}

local function updateMapDataUi(mapEntry)
    local difficultyDisplay = DIFFICULTY_STARS[mapEntry.difficulty + 1] or DIFFICULTY_STARS[1]
    if mapEntry.author then
        -- Player maps
        ui.setMapName(string.format(
            "<J>%s <BL>- @%d %s  <G>|<N>   Difficulty : %s<G>",
            mapEntry.author,
            mapEntry.mapCode,
            room.isSizeMap and "<V>[S]" or "",
            difficultyDisplay
        ))
    else
        -- Vanilla maps
        ui.setMapName(string.format(
            "<J>%d   <G>|<N>   Difficulty : %s<G>",
            mapEntry.mapCode,
            difficultyDisplay
        ))
    end
end

function eventLoop(elapsedTime, remainingTime)
    if remainingTime < 500 then
        playNextMap()
    end

    respawnPlayers()
end

function eventNewGame()
    local mapCode = tonumber(tfm.get.room.currentMap:match("(%d+)"))
    room.currentMapEntry = getMapEntry(MAPS, mapCode)

    room.playerSizes = nil
    if room.currentMapEntry.author then
        room.xmlTree = parseXML(tfm.get.room.xmlMapInfo.xml)
        local mapParameters = xmlFind(room.xmlTree, "C.P")
        local sizeAttribute = mapParameters[1].attributes.size
        room.isSizeMap = sizeAttribute ~= nil
        if room.isSizeMap then
            local min, mid, max = sizeAttribute:match("^(%d+%.?%d*)%s*,%s*(%d+%.?%d*)%s*,%s*(%d+%.?%d*)$")
            room.playerSizes = {tonumber(min) or 0.5, tonumber(mid) or 1, tonumber(max) or 2}

            for playerName, _ in pairs(tfm.get.room.playerList) do
                tfm.exec.changePlayerSize(playerName, room.playerSizes[2])
            end            
        end
    else
        room.isSizeMap = false
    end

    if not room.isSizeMap then
        for playerName, _ in pairs(tfm.get.room.playerList) do
            tfm.exec.changePlayerSize(playerName, 1)
        end
    end

    updateMapDataUi(room.currentMapEntry)
    clearLeaderboard()
    tfm.exec.setGameTime(360, true)
end

----------------
-- Main logic --
----------------

local function initializeRoom()
    tfm.exec.disableAutoNewGame()
    tfm.exec.disableAutoShaman()
    tfm.exec.disableAutoScore()
    tfm.exec.disableAutoTimeLeft()
    tfm.exec.disableAfkDeath()
    tfm.exec.disableDebugCommand()
    tfm.exec.disablePhysicalConsumables()

    for playerName, _ in pairs(tfm.get.room.playerList) do
        initializePlayer(playerName)
    end
end    

local function main()    
    initializeRoom()
    playNextMap()
end

function eventChatCommand(playerName, command)
    local cmd, args = command:match("^(%S+)%s*(.*)$")
    if cmd == "map" or cmd == "np" then
        local difficulty = tonumber(args:match("^%d+$"))
        if difficulty and MAPS[difficulty] then
            playRandomMap(difficulty)
        else
            playRandomMap()
        end
    elseif cmd == "next" then
        playNextMap()
    elseif cmd == "reset" then
        tfm.exec.newGame(room.currentMapEntry.mapCode)
    elseif cmd == "dump" then
        print("<R>" .. MAPS_DATA .. "</R>")
    elseif cmd == "time" then
        local newTime = tonumber(args:match("^%d+$"))
        if newTime then
            tfm.exec.setGameTime(newTime, true)
        end
    end
end

main()