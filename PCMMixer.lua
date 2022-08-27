--[[lit-meta
    name = "wbx/discordia-pcmmixer"
    version = "0.1.0"
    homepage = "https://github.com/wbx/discordia-pcmmixer"
    description = "Simple audio mixer for Discordia bot voice connections."
    tags = { "discordia" }
    license = "MIT"
    author = { name = "Lyrthras", email = "me@lyr.pw" }
]]

local FFmpegProcess = require 'discordia'.class.classes.FFmpegProcess

local SAMPLE_RATE = 48000
local CHANNELS = 2

local PCMMixer = require 'discordia'.class 'PCMMixer'

-- Aggregate mixer function that simply combines two sources additively.
local function pcmAdd(pcm, pcmOther)
    for i = 1, #pcm do
        pcm[i] = pcm[i] + (pcmOther[i] or 0)
        if pcm[i] > 32767 then pcm[i] = 32767 end
        if pcm[i] < -32768 then pcm[i] = -32768 end
    end
    return pcm
end

--- Simple PCM mixer to play multiple sources at once
---@param aggregateFunction function?   @ Optional aggregate mixer function. Default is additive.
function PCMMixer:__init(aggregateFunction)
    self._fn = aggregateFunction or pcmAdd
    self._sources = {}
    self._shouldDetach = false
    self._attached = false
end

--- Add an audio file to the mixer (plays it immediately)
---@param src string
---@param id string|number|any
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
            return
        end
    end
    self._sources[#self._sources + 1] = {id, stream}
end

--- Remove the audio source specified by id. Returns true if it did remove a source.
---@param id string|number|any
---@return boolean
function PCMMixer:removeSource(id)
    for i = 1, #self._sources do
        if self._sources[i][1] == id then
            table.remove(self._sources, i)
            return true
        end
    end
    return false
end

--- internal use
function PCMMixer:read(n)
    if self._shouldDetach then
        self._shouldDetach = false
        return nil
    end
    local pcmResult = {}
    for i = 1, n do
        pcmResult[i] = 0
    end

    local toRemove = {}
    for i = 1, #self._sources do
        local stream = self._sources[i][2]
        local pcm = stream:read(n)
        if pcm ~= nil then
            self._fn(pcmResult, pcm)
        end
        if pcm == nil or stream._closed then
            toRemove[#toRemove+1] = i
        end
    end

    for i = #toRemove, 1, -1 do
        table.remove(self._sources, toRemove[i])
    end

    return pcmResult
end

--- Attach to a VoiceConnection and start playback.
--- Blocking - it's where you normally use Connection:playFFmpeg etc.
---@param connection VoiceConnection
---@param duration number?  @ Optional duration of how long the mixer will stay attached
function PCMMixer:attach(connection, duration)
    assert(connection, "connection cannot be nil")
    self._attached = true
    local res = connection:_play(self, duration)
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

return PCMMixer
