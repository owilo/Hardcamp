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

----- base 64

local B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

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

        out[#out + 1] = B64_CHARS:sub(c1 + 1, c1 + 1)
        out[#out + 1] = B64_CHARS:sub(c2 + 1, c2 + 1)
        out[#out + 1] = c3 and B64_CHARS:sub(c3 + 1, c3 + 1) or "="
        out[#out + 1] = c4 and B64_CHARS:sub(c4 + 1, c4 + 1) or "="

        i = i + 3
    end
    return table.concat(out)
end

local B64_DECODE = {}
for i = 1, #B64_CHARS do
    B64_DECODE[B64_CHARS:sub(i, i)] = i - 1
end

local function decodeBase64(str)
    str = str:gsub("[^%w_%-=]", "")

    local out = {}
    local i = 1
    local n = #str
    while i <= n do
        local c1 = B64_DECODE[str:sub(i, i)] or 0
        local c2 = B64_DECODE[str:sub(i + 1, i + 1)] or 0
        local c3 = B64_DECODE[str:sub(i + 2, i + 2)]
        local c4 = B64_DECODE[str:sub(i + 3, i + 3)]

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

----- Writer

local BitWriter = {}
BitWriter.__index = BitWriter

function BitWriter.new()
    return setmetatable({
        bytes = {0},
        currentBit = 0,
    }, BitWriter)
end

function BitWriter:writeBits(value, bitCount)
    value = B.band(value, B.lshift(1, bits) - 1)

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

function BitWriter:writeString(str, size, minDictionaryRange, maxDictionaryRange)
    size = size or #str
    minDictionaryRange = minDictionaryRange or 0
    maxDictionaryRange = maxDictionaryRange or 255
    local charSize = ceilLog2(maxDictionaryRange - minDictionaryRange + 1)

    for i = 1, size do
        self:writeBits(str:byte(i) - minDictionaryRange, charSize)
    end

    return self
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

----- Reader

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

function BitReader:readString(size, minDictionaryRange, maxDictionaryRange)
    minDictionaryRange = minDictionaryRange or 0
    maxDictionaryRange = maxDictionaryRange or 255
    local charSize = ceilLog2(maxDictionaryRange - minDictionaryRange + 1)

    local chars = {}
    for i = 1, size do
        chars[i] = string.char(self:readBits(charSize) + minDictionaryRange)
    end

    return table.concat(chars)
end