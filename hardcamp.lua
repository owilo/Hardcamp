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

local getMappings = function(alphabet)
    local mappings = {
        length = #alphabet
    }

    for i = 1, #alphabet do
        mappings[alphabet:sub(i, i)] = i - 1
    end

    return mappings
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
    local charSize = ceilLog2(#mappings)
    for i = 1, size do
        self:writeBits(mappings[str:sub(i, i)] or 0, charSize)
    end
    return self
end

function BitWriter:writeAuthorList(authors)
    self:writeBits(#authors, 8)
    for _, author in ipairs(authors) do
        local prefix, playerName, tag = author:match("^(%+)?([%w_]+)#(%d%d%d%d)$")
        self:writeBits(prefix and 1 or 0, 1) -- "+" prefix
        self:writeBits(#playerName, 4) -- Author name length
        self:writeString(playerName, B64_MAPPINGS, #playerName) -- Author names can conveniently be treated as a base64 string
        self:writeBits(tonumber(tag), 14) -- Author tag
    end
end

function BitWriter:writeVariableLength(value, blockSize)
    blockSize = blockSize or 7
    while value > 0 do
        local block = B.band(value, B.lshift(1, blockSize) - 1)
        value = B.rshift(value, blockSize)
        self:writeBits(block, blockSize)
        self:writeBits(value > 0 and 1 or 0, 1) -- Continuation bit
    end
end

function BitWriter:writeMaps(maps, authors)
    self:writeBits(#maps, 16)
    local previousMapCode = 0
    local authorsBitCount = ceilLog2(#authors)

    for mapCode, mapDefinition in ipairs(maps) do
        local delta = mapCode - previousMapCode
        self:writeVariableLength(delta, 5)
        self:writeBits(map.author, authorsBitCount)
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
        t[i] = self.bytes[i]:char()
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
        chars[i] = string.char(alphabet[self:readBits(charSize)] or 0)
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

        local authorIndex = self:readBits(authorsBitCount)
        local difficulty = self:readBits(2) + 1
        local sizemapFlag = self:readBits(1) == 1

        maps[i] = {
            code = mapCode,
            author = authors[authorIndex + 1],
            difficulty = difficulty,
            sizemap = sizemapFlag,
        }
    end
    return maps
end