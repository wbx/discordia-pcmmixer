--[[lit-meta
    name = "wbx/discordia-pcmmixer"
    version = "0.4.1"
    homepage = "https://github.com/wbx/discordia-pcmmixer"
    description = "Simple audio mixer for Discordia bot voice connections."
    tags = { "discordia" }
    license = "MIT"
    author = { name = "Lyrthras", email = "me@lyr.pw" }
]]

local FFmpegProcess = require 'discordia'.class.classes.FFmpegProcess
local Emitter = require 'discordia'.class.classes.Emitter

local PCMMixer = require 'discordia'.class('PCMMixer', Emitter)

local SAMPLE_RATE = 48000
local CHANNELS = 2



--region-- FILTERS --

PCMMixer.filters = {'volume', 'pan'}

local min, max = math.min, math.max
local function clamp(v, l, h)
    return min(max(v, l), h)
end

--- Control loudness (linear). Range is 0 (muted) to X (X * amplitude) (1 is default)
---@param pcm number[]
---@param val number
function PCMMixer.filters.volume(pcm, val)
    if not val or val == 1.0 then return pcm end
    val = clamp(val, 0, 32767)
    for i = 1, #pcm do
        pcm[i] = clamp(pcm[i] * val, -32768, 32767)
    end
    return pcm
end

local sin, cos  = math.sin, math.cos
local _PIQR = math.pi / 4
local _TSQT = 2 / math.sqrt(2)

--- Control audio panning. Range is -1 (full left) to 1 (full right) (0 is default: center)
---@param pcm number[]
---@param val number
function PCMMixer.filters.pan(pcm, val)
    if not val or val == 0.0 then return pcm end
    val = clamp(val, -1, 1)

    local L = _TSQT * cos(_PIQR * (val+1))
    local R = _TSQT * sin(_PIQR * (val+1))
    for i = 1, #pcm, 2 do
        pcm[i] = clamp(pcm[i] * L, -32768, 32767)
        pcm[i+1] = clamp(pcm[i+1] * R, -32768, 32767)
    end
    return pcm
end

--endregion-- FILTERS --



-- Aggregate mixer function that simply combines two sources additively.
---@param pcm number[]
---@param pcmOther number[]
local function pcmAdd(pcm, pcmOther)
    for i = 1, #pcm do
        pcm[i] = clamp(pcm[i] + (pcmOther[i] or 0), -32768, 32767)
    end
    return pcm
end



--- Simple PCM mixer to play multiple sources at once
---@param aggregateFunction function?   @ Optional aggregate mixer function. Default is additive.
function PCMMixer:__init(aggregateFunction)
    Emitter.__init(self)
    self._fn = aggregateFunction or pcmAdd
    self._sources = {}
    self._masterFilters = {}
    self._shouldDetach = false
    self._attached = false
end


--- Add an audio file to the mixer (plays it immediately)
---@param src string|table
---@param id string|number|any
---@return boolean      @ true if source replaced older source with same id
function PCMMixer:addSource(src, id)
    local stream
    if type(src) == 'string' then
        stream = FFmpegProcess(src, SAMPLE_RATE, CHANNELS)
    else
        stream = src
    end

    for i = 1, #self._sources do
        local s = self._sources[i]
        if s[1] == id then
            if type(s[2].close) == 'function' then s[2]:close() end
            s[2] = stream
            self:emit('sourceRemove', id)
            self:emit('sourceAdd', id)
            return true
        end
    end
    self._sources[#self._sources + 1] = {id, stream, {}}
    self:emit('sourceAdd', id)
    return false
end


local function utoi16(v)
    return v > 32767 and -65536 + v or v
end

local floor = math.floor
local function _rawRead(self, n)
    if self.pos - 1 + n * 2 > #self.data then
        if self.pos > #self.data then return nil end
        n = floor((#self.data - self.pos + 1) / 2)
    end
    if n == 0 then return nil end

    local data = {}

    for i = self.pos, self.pos - 1 + n * 2, 2 do
        local low, high = self.data:byte(i, i+1)
        data[#data+1] = utoi16(low + (high or 0) * 256)
    end
    self.pos = self.pos + n * 2

    return data
end

--- Add a raw PCM string to the mixer (plays it immediately)
--- Only (2 channels, 48000 sample rate, s16le format) works (for now)
---@param data string       @ raw PCM data, possibly read from a file
---@param id string|number|any
function PCMMixer:addSourceRaw(data, id)
    assert(type(data) == 'string', "data must be a raw pcm string")
    return self:addSource({pos = 1, data = data, read = _rawRead}, id)
end

--
-- was too much for my 5am brain
--[[
function PCMMixer:addSourceRaw(data, id, channels, sampleRate, format)
    if not channels then channels = CHANNELS end
    if not sampleRate then sampleRate = SAMPLE_RATE end
    if not format then format = 's16le' end
    assert(channels > 0 and channels < 3, 'addSourceRaw can only accept 1 or 2 channels')
    assert(sampleRate % SAMPLE_RATE == 0, SAMPLE_RATE..' must be divisible by given sampleRate')
    local dt, bits, endi = format:match('([su])(%d+)([lb]?e?)')
end
--]]


--- Remove the audio source specified by id. Returns true if it did remove a source.
---@param id string|number|any
---@return boolean
function PCMMixer:removeSource(id)
    for i = 1, #self._sources do
        if self._sources[i][1] == id then
            table.remove(self._sources, i)
            self:emit('sourceRemove', id)
            return true
        end
    end
    return false
end


--- Set a filter setting for the mixer output.
--- Set value to `nil` to use default.
---@param filterName string
---@param filterValue number|any
function PCMMixer:masterFilter(filterName, filterValue)
    if not PCMMixer.filters[filterName] then
        error("invalid filter name '"..filterName.."'")
    end

    self._masterFilters[filterName] = filterValue
end

--- Set a filter setting for the source specified by srcId.
--- Set value to `nil` to use default.
---@param srcId string|number|any
---@param filterName string
---@param filterValue number|any
function PCMMixer:sourceFilter(srcId, filterName, filterValue)
    if not PCMMixer.filters[filterName] then
        error("invalid filter name '"..filterName.."'")
    end

    for i = 1, #self._sources do
        local s = self._sources[i]
        if s[1] == srcId then
            s[3][filterName] = filterValue
            return true
        end
    end
    return false
end


--- Attach to a VoiceConnection and start playback.
--- Blocking - it's where you normally use Connection:playFFmpeg etc.
---@param connection VoiceConnection
---@param duration number?  @ Optional duration of how long the mixer will stay attached
function PCMMixer:attach(connection, duration)
    assert(connection, "connection cannot be nil")
    self._attached = true
    self:emit('attach', connection)
    local res = connection:_play(self, duration)
    self:emit('detach')
    self._attached = false
    return res
end

--- Detach the mixer from the attached connection. Will 'pause' sources until the
--- mixer gets attached to another connection.
function PCMMixer:detach()
    if self._attached then
        self._shouldDetach = true
    end
end


local remove = table.remove
local filters = PCMMixer.filters

--- internal use
function PCMMixer:read(n)
    if self._shouldDetach then
        self._shouldDetach = false
        return nil
    end

    -- fill silence
    local pcmResult = {}
    for i = 1, n do
        pcmResult[i] = 0
    end

    local toRemove = {}
    local srcs = self._sources
    local fn = self._fn
    for i = 1, #srcs do
        local stream = srcs[i][2]
        local pcm = stream:read(n)
        if pcm ~= nil then
            -- apply source filters
            local filterValues = srcs[i][3]
            for j = 1, #filters do
                local filterName = filters[j]
                pcm = filters[filterName](pcm, filterValues[filterName])
            end

            -- merge
            fn(pcmResult, pcm)
        end
        if pcm == nil or stream._closed then
            toRemove[#toRemove+1] = i
        end
    end

    -- remove exhausted (ended) streams
    for i = #toRemove, 1, -1 do
        self:emit('sourceEnd', remove(srcs, toRemove[i])[1])
    end

    -- apply master filters
    for j = 1, #filters do
        local filterName = filters[j]
        pcmResult = filters[filterName](pcmResult, self._masterFilters[filterName])
    end

    return pcmResult
end


return PCMMixer
