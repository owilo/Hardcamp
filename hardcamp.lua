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

local B64_MAPPINGS = getMappings(B64_ALPHABET)

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

function BitWriter:writeAuthorList(authors)
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
    self:writeBits(#maps, 16)
    local previousMapCode = 0
    local authorsBitCount = ceilLog2(#authors)

    for _, map in ipairs(maps) do
        local delta = map.mapCode - previousMapCode
        previousMapCode = map.mapCode

        self:writeVariableLength(delta, 5)
        self:writeBits(map.author - 1, authorsBitCount)
        self:writeBits(map.difficulty - 1, 2)
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

function BitReader:readAuthorList()
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

        maps[i] = {
            mapCode = mapCode,
            author = authorIndex,
            difficulty = difficulty,
            sizemap = sizemap
        }
    end

    return maps
end

----------------------
-- Global variables --
----------------------

local room = {
    respawnPlayers = {}
}

------------------------
-- Players management --
------------------------

local function markPlayerForRespawn(playerName)
    room.respawnPlayers[#room.respawnPlayers + 1] = playerName
end

local function respawnPlayers()
    for i = 1, #room.respawnPlayers do
        tfm.exec.respawnPlayer(room.respawnPlayers[i])
    end
    room.respawnPlayers = {}
end

function eventPlayerDied(playerName)
    markPlayerForRespawn(playerName)
end

function eventPlayerWon(playerName)
    markPlayerForRespawn(playerName)
end

function eventNewPlayer(playerName)
    markPlayerForRespawn(playerName)
end

----------
-- Maps --
----------

local MAPS_DATA = "T0ZiSQDAPZrZeVxKASBCLEUAwDGe1sLiCQCwYUVbkWQYZbCi8Nmh8PkFOKDUzs6LAQB3oSsnsi0A4AbRA9GW_QJY1M3o7AEAUCq1jkRXF-1yEhxrrKoCADjyOI9lRfQU2RYAkJKbeqvGnugXwAx02zwSAECGtsoOm6JWFCXXCASsLQkAoEXUVgBABWsqyoyXFND15GSu9L4AJbnwyQIAlxHZ1ltZjVtFAAAxqkt-AZZBXdabY-7dTgDAPavWtuj5BTBgNbVTtLHooJ2iV5oaiAIAzhDP2SVFAIACKVqWaIqWKACAgfDTVo8TSS0MAQBXiWsrniIAwKTW-7TzC4BXx2md13oAgJRCrdTOzlsBAFeJZ6uBnj1AgVJb0W32xBMAUIZmlh4fCYnO1dauroMUQ5wdqsIcExzXEwBgmeausgcASMMVWe1MvRUAsJcWax2KoiiKAgBOKLXz1E4AQF6dlqIlGncAAHzQtYW11-sA2YL-LCkuBSYRzToGBprbiumKtlOWWGeNC9E09danCxWx6AEArpFRcUPdL4AFped5LAAghVBbS8-bZQAAKZp2ng_KQENUBQCcoqXaKpIAgJRalyO9dWUBAAy4K7pqXOlpKwsAyMjTStQ9NRkAYEAsaqsMAKhCBFERAECJm6YAgMs0jvTcFQBQwZqKMgDAjhTlSBYAYAbamdwWmzFkdMVTBABc5H0u63UKgAVOtA29dUM3GwBgicayXggAKMsTvXP1YorWwvLpZDCAFNETFGzckK4oJ5IAgJRa9PU69PUAACa9WkmKCouzRO08xZjEew5Qb_UC4HR_ZZZZLo8ARLY3BLhRkRggtUMokR2ci0TyukrE9nchkFnPg4TksC1oofM6SCRGxaGQlxeDREy2HQi4RZwogD_BIREeFYNEbJCpxazPwgDaXoUD7jI55MfLIJEVnRIBUc-W0BYa8XFQQMBuh4TkNjiERPFAAFMcFCHr5gDddYNETLlIYM2DQUg1UOANCQRm-VtALyUGYJAQZK__QZAU70TB2zcY5M-FQ3TRLQSBWz844JYvQViWOgQ-L0Fenzhkjj1BTOgg_GSDA3ASDA4xazs4gPyNBlT8DxxwzeiAmCYUOuXvsFFnDoDJ6ZA6HwNH8ueBcQ4O2O1YOCS0oQfmunhg7XeCAN2VDZRyOAwc6cdVOETcz-CA1uYDAvz4FhI5VSoRsAyDRE6SSWg0gwNSmUuIvsWAkL0-Dll9LRFxHBL56TJw4N9F4Zb0zhzx-8cRx5HBkcERwYHAAcGBwJEVSUQEy-AWvhVusVVUwOVMh4R6vBYSM_1qE50NDqjrg5BaHiBA-yEC2TYkmUVxkGDcAwJknDmEPo3DfBXK6YWpw2RWSSzcg8TaFMvF7JEJ7BGpJK23XO6ZoICOg0RQNdDlfw0J0nupwNeTXWL0UOg8FwHak1EEbysHyHnITSWHhPgUqgDFLV7gUxglFSXg9pwXLFjpLpH2JxxIZeUQ0lPg1IlK0lC4AASFXNI5qYRHqQp-_w0mcN-tF5MVMNjXIxFULk5ZFVJGhJRdLDqBsQx40dAo3j1fYFJQgO12C3crA34ODlEOujKYMjhL5iIZbA7S6UWXsoY02MPiAvkcNnBZ5gLQfQ5Cy-AC2x40gfdBgb0sOHidQ0jTUGSGuYPIqoNSRC5Bv8va-BDFJA8PQGiSfi4mIV3hl_8lKqhXogJ1Jz5ZSeET4SPho-CT4BPiE9wWPrkjncY2OGDXkY9GVPikFxddQr04JA4UOEfhANL4JD4-6dHiEzb4oCSFA2SS-CRui0_GX_gkhj5xhU9-XFDA5YMPcgOoHPuI-CCtiU_WPPls5z4o_8A4XQ6AiSkI8OoD3g0-aYPPig9infi8hI1L1tsQRR2LS2w60KRfEwiiT9rgA94OPkDVBwKwHT5ZPnk-0T4pPlk-yT4hPjpR4iPRNT5am0_2etAp3o1PjI9Wm7hEBwVd3OQT2x50IVMhg10dPhp0MoUPXnDIBBybTGZRACH4iORC8M1DhNkIRk0-CT6QjU9Od_jMhC7IxWQpGSYUkx1CdNCAgK4L0nT-gIi9A5Jy5JOyGOH5BESFU9AKolP6bFIoFAnXTnhQgGSHT-DeIIF8iY9a4wM0Nk4K3-ETXhUgGyGIZDL4JO-LD-qSyED2IGJxIxMUJEooY0MEtvqkh4dR7P_4pBWEW-FAGBAePrGJj2rQuAR1EZ1o98pk3oNM1D845cgktYMM-NooCYyHTFzz-CT4IPik-0Rmh0_--vgELYOP7FSAJD8yccvEBHE0TDi5D1LJ9Fg5oR6VU2KaOOWEq2Hc1CDkVI2PznAwqWUHEcJEFV5ECJDFQBWWT0z9KxQiVAJUAhQCVAIU9oSE_BaITog5JQLucEilSKFIBe-IgW0hFdUtSDlnZZj7FExJTGljgYR7JUiyfUMFnxVWSVeDFJEjaW-RVVB7WMFvUDkpFMoBlQSFkyjGxkgZu5VcCVX2QeVCSULlQclAyZ9cEdWAtFMp5r2Hj84GFQKVA7UBpQC1tzksOUi45Ligj1LS8cCY8hWM0v9gBZovSFLj4aT4DEj6z8Cl_iPllQNCbkOV0XBll4eUyNFgoQ9c4cXgKBQVINDFYaVqFToWTjrFgZAZWyVsgxbsGHEejg2C5HhYZW8Iiy-CZnhw-R0LUnm0IC2FBRLShhR4FUhZ44AU2RVOSf_lGPU2juHxQFE_VFzga8GY3kIGXIVXTHF4gRUJpl5oBR0-YMDf4LVWHmJQZ4LkNQ9gAF2hqX-Tof6TZPSYMMn9EUhU55TUDkwSxSOGkw8godngGHODTH4JZVBWgGwWIAM="
local bitReader = BitReader.fromBase64(MAPS_DATA)
local AUTHORS = bitReader:readAuthorList()
local MAPS = bitReader:readMaps(AUTHORS)

local function getMapEntry(mapCode)
    local mapEntry = sortedSearch(MAPS, mapCode, function(entry)
        return entry.mapCode
    end)
    if mapEntry then
        local newMapEntry = deepCopy(mapEntry)
        newMapEntry.author = AUTHORS[mapEntry.author] or "Module"
        return newMapEntry
    else
        local isPlayerMap = tfm.get.room.xmlMapInfo and tfm.get.room.xmlMapInfo.mapCode == mapCode
        return {
            mapCode = mapCode,
            author = isPlayerMap and tfm.get.room.xmlMapInfo.author,
            difficulty = 0,
            sizemap = false
        }
    end
end

local DIFFICULTY_STARS = {
    "<G>★★★★",
    "<VP>★<G>★★★",
    "<J>★★<G>★★",
    "<O>★★★<G>★",
    "<R>★★★★"
}

local updateMapDataUi = function(mapEntry)
    local difficultyDisplay = DIFFICULTY_STARS[mapEntry.difficulty + 1] or DIFFICULTY_STARS[1]
    if mapEntry.author then
        -- Player maps
        ui.setMapName(string.format(
            "<J>%s <BL>- @%d %s  <G>|<N>   Difficulty : %s<G>",
            mapEntry.author,
            mapEntry.mapCode,
            mapEntry.sizemap and "<V>[S]" or "",
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
        tfm.exec.newGame(MAPS[math.random(#MAPS)].mapCode)
    end

    respawnPlayers()
end

function eventNewGame()
    local mapCode = tonumber(tfm.get.room.currentMap:match("(%d+)"))
    local mapEntry = getMapEntry(mapCode)
    updateMapDataUi(mapEntry)
    tfm.exec.setGameTime(360, true)
end

----------------
-- Main logic --
----------------

local function main()    
    tfm.exec.disableAfkDeath()
    tfm.exec.disableAutoNewGame()
    tfm.exec.disableAutoShaman()
    tfm.exec.disableAutoTimeLeft()

    tfm.exec.newGame(MAPS[math.random(#MAPS)].mapCode)
end

main()