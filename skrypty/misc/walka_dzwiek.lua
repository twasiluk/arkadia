-- ============================================================
--  walka_dzwiek - dlugi utwor grany przez cala walke
--
--  Podpiete pod event "ateam_am_attacked" - to samo zrodlo, z ktorego
--  belka na dole bierze "Walka: on/off" (skrypty/character/combat_state.lua).
--  Event leci tylko na zmianie stanu, wiec kolejne ataki w trakcie walki
--  nie przerywaja utworu. Koniec walki przed czasem = stopSounds().
--
--  Dodatkowo spadek zdrowia (gmcp.char.state.hp, 6 = pelne ... 0) na
--  poziom HURT_MAX lub nizej gra krotki dzwiek "ala" - rownolegle z utworem.
-- ============================================================

scripts.walka_dzwiek = scripts.walka_dzwiek or {
    handlers = {},
    aliases = {},
    enabled = true,
    playing = false,
}

local SOUND = "dbz-attack.mp3"   -- w getMudletHomeDir()/sounds
local LENGTH = 36                -- dlugosc pliku w sekundach
local HURT_SOUND = "charlie-that-hurts.mp3"
local HURT_MAX = 4               -- spadek na 5 jeszcze nie gra

local function print_log(msg)
    cecho("\n<CadetBlue>(walka_dzwiek)<reset>: " .. msg .. "\n")
end

function scripts.walka_dzwiek:path()
    return getMudletHomeDir() .. "/sounds/" .. SOUND
end

function scripts.walka_dzwiek:play()
    if not self.enabled or self.playing then return end

    local path = self:path()
    if not lfs.attributes(path) then
        print_log("<DimGrey>brak pliku dzwieku " .. path)
        return
    end

    stopSounds()
    playSoundFile(path)
    self.playing = true

    -- Mudlet nie informuje o koncu odtwarzania, wiec sami zwalniamy blokade
    -- po dlugosci pliku - inaczej kolejna walka juz by nic nie zagrala.
    if self.timer then killTimer(self.timer) end
    self.timer = tempTimer(LENGTH, function()
        scripts.walka_dzwiek.playing = false
        scripts.walka_dzwiek.timer = nil
    end)
end

function scripts.walka_dzwiek:stop()
    if self.timer then
        killTimer(self.timer)
        self.timer = nil
    end
    if self.playing then
        stopSounds()
        self.playing = false
    end
end

-- gmcp przysyla tylko zmienione wartosci - bez "hp" nic sie nie zmienilo
function scripts.walka_dzwiek:check_hp()
    local hp = gmcp.char and gmcp.char.state and tonumber(gmcp.char.state.hp)
    if not hp then return end

    local last = self.last_hp
    self.last_hp = hp
    if not self.enabled or not last or hp >= last or hp > HURT_MAX then return end

    local path = getMudletHomeDir() .. "/sounds/" .. HURT_SOUND
    if lfs.attributes(path) then
        playSoundFile(path)
    else
        print_log("<DimGrey>brak pliku dzwieku " .. path)
    end
end

function scripts.walka_dzwiek:switch(on)
    self.enabled = on
    if not on then self:stop() end
    print_log(on and "<green>on" or "<tomato>off")
end

local handlers = {
    ateam_am_attacked = function(_, state)
        if state then
            scripts.walka_dzwiek:play()
        else
            scripts.walka_dzwiek:stop()
        end
    end,
    ["gmcp.char.state"] = function() scripts.walka_dzwiek:check_hp() end,
}

local aliases = {
    ["^/walka_dzwiek$"]      = function() scripts.walka_dzwiek:switch(not scripts.walka_dzwiek.enabled) end,
    ["^/walka_dzwiek on$"]   = function() scripts.walka_dzwiek:switch(true) end,
    ["^/walka_dzwiek off$"]  = function() scripts.walka_dzwiek:switch(false) end,
    ["^/walka_dzwiek test$"] = function()
        scripts.walka_dzwiek:stop()
        scripts.walka_dzwiek:play()
    end,
}

function scripts.walka_dzwiek:init()
    for _, id in ipairs(self.aliases) do killAlias(id) end
    for _, id in ipairs(self.handlers) do killAnonymousEventHandler(id) end
    self.aliases, self.handlers = {}, {}

    for event, callback in pairs(handlers) do
        table.insert(self.handlers, registerAnonymousEventHandler(event, callback))
    end

    for regex, callback in pairs(aliases) do
        table.insert(self.aliases, tempAlias(regex, callback))
    end
end

scripts.walka_dzwiek:init()
