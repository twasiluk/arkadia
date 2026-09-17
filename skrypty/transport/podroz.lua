-- ============================================================
--  podroz - czekanie na srodek transportu, wsiadanie i wysiadanie
--  na zadanym przystanku / w zadanym porcie (event amapGpsLocation)
-- ============================================================

scripts.podroz = scripts.podroz or {
    triggers = {},
    aliases = {},
    handlers = {},
}

-- target  - szukany fragment nazwy GPS
-- vehicle - "dylizans" | "statek" | nil (nil = nie jestes w pojezdzie)

local exit_commands = {
    dylizans = "wyjscie",
    statek   = "zejdz ze statku",
}

local sounds = {
    boarded = {
        dylizans = "horse-and-carriage.mp3",
        statek   = "sail-away.wav",
    },
    left = {
        dylizans = "horse-and-carriage.mp3",
        statek   = "icq-horn-dds.wav",
    },
}

local function print_log(msg)
    cecho("\n<CadetBlue>(podroz)<reset>: " .. msg .. "\n")
end

function scripts.podroz:matches(location)
    return location and self.target
        and location:lower():find(self.target:lower(), 1, true) ~= nil
end

-- ---------- pojazd ----------
-- Event gps nie mowi, czym jedziesz, a komendy wyjscia sa rozne. Do tego
-- lokalizator melduje te same nazwy, gdy wchodzisz do miasta pieszo - bez
-- zapamietanego wsiadania handler musi milczec.
function scripts.podroz:boarded(vehicle)
    self:stop_waiting(true)
    self.vehicle = vehicle
    raiseEvent("podrozBoarded", vehicle)
    if vehicle == "dylizans" then
        self:watch_carriage_exit()
    end
    if self.target then
        print_log("<DimGrey>na pokladzie (" .. vehicle .. "), cel " .. self.target)
    end
end

function scripts.podroz:left()
    if not self.vehicle then return end
    local vehicle = self.vehicle
    self.vehicle = nil
    if self.room_handler then
        killAnonymousEventHandler(self.room_handler)
        self.room_handler = nil
    end
    raiseEvent("podrozLeft", vehicle)
end

-- Z dylizansu nie ma stalej linii wyjscia. Wnetrze pojazdu nie ma mapy
-- w gmcp.room.info, wiec pierwsza lokacja z mapa po wnetrzu = wysiadka.
function scripts.podroz:watch_carriage_exit()
    if self.room_handler then killAnonymousEventHandler(self.room_handler) end
    local inside = false
    self.room_handler = registerAnonymousEventHandler("gmcp.room.info", function()
        if not gmcp.room.info.map then
            inside = true
        elseif inside then
            scripts.podroz:left()
        end
    end)
end

-- ---------- meldunek lokalizatora ----------
function scripts.podroz:gps(location)
    if not self.vehicle then return end
    if not self:matches(location) then return end
    send(exit_commands[self.vehicle], false)
    print_log("<green>wysiadam - " .. location)
    self:cancel(true)
end

-- ---------- czekanie na srodek transportu ----------
local boarding = {
    dylizans = {
        pattern = "dylizans powoli zatrzymuje sie",
        board = function()
            send("wejdz do dylizansu")
        end,
    },
    statek = {
        pattern = "Wszyscy na poklad!|(?:rypa|ratwa|rom|arka) przybija do brzegu\\.$",
        board = function()
            expandAlias("wem", true)    -- wez monety z sakiewki
            send("kup bilet")
            send("wsiadz na statek")
            expandAlias("wlm", true)    -- wloz monety z powrotem
        end,
    },
}

local wait_timeout = 900

-- Nie wiadomo, co kursuje z danego przystanku, wiec czekamy na oba pojazdy
-- naraz - pierwszy, ktory sie zatrzyma, wygrywa.
function scripts.podroz:wait()
    self:stop_waiting(true)
    self.wait_triggers = {}
    for _, cfg in pairs(boarding) do
        table.insert(self.wait_triggers, tempRegexTrigger(cfg.pattern, function()
            scripts.podroz:stop_waiting(true)
            cfg.board()
        end))
    end
    self.wait_timer = tempTimer(wait_timeout, function()
        scripts.podroz.wait_timer = nil
        scripts.podroz:cancel()
    end)
    print_log("<DimGrey>czekam na dylizans lub statek...")
end

function scripts.podroz:stop_waiting(silent)
    for _, id in ipairs(self.wait_triggers or {}) do killTrigger(id) end
    self.wait_triggers = nil
    if self.wait_timer then killTimer(self.wait_timer); self.wait_timer = nil end
    if not silent then print_log("<tomato>przestaje czekac") end
end

-- ---------- sterowanie ----------
function scripts.podroz:start(target)
    self:cancel(true)
    self.target = target
    self.timer = tempTimer(1800, function()
        scripts.podroz.timer = nil
        scripts.podroz:cancel()
    end)
    print_log("<green>cel - " .. target)
    if not self.vehicle then
        self:wait()
    end
end

function scripts.podroz:cancel(silent)
    self:stop_waiting(true)
    if self.timer then killTimer(self.timer); self.timer = nil end
    self.target = nil
    if not silent then print_log("<tomato>przerwane") end
end

function scripts.podroz:status()
    print_log(string.format("<DimGrey>cel=%s pojazd=%s czekam=%s",
        tostring(self.target), tostring(self.vehicle), tostring(self.wait_triggers ~= nil)))
end

-- ---------- dzwieki ----------
function scripts.podroz:play(kind, vehicle)
    local file = sounds[kind][vehicle]
    if not file then return end
    local path = getMudletHomeDir() .. "/sounds/" .. file
    if lfs.attributes(path) then
        playSoundFile(path)
    else
        print_log("<DimGrey>brak pliku dzwieku " .. path)
    end
end

-- ---------- rejestracja ----------
local vehicle_lines = {
    ["[Ww]siadasz do .*(dylizansu|wozu|powozu)\\.$"] = "dylizans",
    ["wspinasz sie na .*dylizans\\.$"]               = "dylizans",
    -- same "Wchodzisz na .+" lapaloby tez drzewa, mury itp. (i gralo dzwiek)
    ["^Wchodzisz na (?:poklad .+|.*(?:statek|okret|prom|barke|barkasa|feluke|skeid|tratwe|bryg|drakkar|szkute|buzar|knare|galere|galeon|lodz|lodke|kog|karake|karawele|kuter))\\.$"] = "statek",
}

local aliases = {
    ["^podroz do (.+)$"] = function() scripts.podroz:start(matches[2]) end,
    ["^podroz stop$"]    = function() scripts.podroz:cancel() end,
    ["^podroz stan$"]    = function() scripts.podroz:status() end,
}

local handlers = {
    amapGpsLocation = function(_, location) scripts.podroz:gps(location) end,
    podrozBoarded   = function(_, vehicle) scripts.podroz:play("boarded", vehicle) end,
    podrozLeft      = function(_, vehicle) scripts.podroz:play("left", vehicle) end,
}

function scripts.podroz:init()
    for _, id in ipairs(self.triggers) do killTrigger(id) end
    for _, id in ipairs(self.aliases) do killAlias(id) end
    for _, id in ipairs(self.handlers) do killAnonymousEventHandler(id) end
    self.triggers, self.aliases, self.handlers = {}, {}, {}

    for event, callback in pairs(handlers) do
        table.insert(self.handlers, registerAnonymousEventHandler(event, callback))
    end

    for pattern, vehicle in pairs(vehicle_lines) do
        table.insert(self.triggers,
            tempRegexTrigger(pattern, function() scripts.podroz:boarded(vehicle) end))
    end
    table.insert(self.triggers, tempRegexTrigger("^Schodzisz ze? .+\\.$", function()
        if scripts.podroz.vehicle == "statek" then scripts.podroz:left() end
    end))

    for regex, callback in pairs(aliases) do
        table.insert(self.aliases, tempAlias(regex, callback))
    end
end

scripts.podroz:init()
