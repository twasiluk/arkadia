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
-- walk_to - id lokacji, do ktorej chodzik idzie po wysiadce (opcjonalne)

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
    if self.pending_walk then
        local room = self.pending_walk
        self.pending_walk = nil
        -- chwila na ustawienie pozycji przez mapper
        tempTimer(1, function() expandAlias("/idz " .. room .. " 4", true) end)
    end
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
    local walk_to = self.walk_to
    self:cancel(true)
    self.pending_walk = walk_to
end

-- ---------- czekanie na srodek transportu ----------
-- pattern - pojazd podjezdza/przybija
-- parked  - pojazd juz stoi na lokacji (linia z przedmiotami przy wejsciu / spojrz)
local boarding = {
    dylizans = {
        pattern = "dylizans powoli zatrzymuje sie",
        parked = "[A-Za-z]+ stojacy dylizans",
        board = function()
            send("wejdz do dylizansu")
        end,
    },
    statek = {
        pattern = "Wszyscy na poklad!|(?:rypa|ratwa|rom|arka) przybija do brzegu\\.$",
        parked = "^(?:(?:[A-Za-z]+ ){1,2}(?:statek|knara|prom)|Tratwa|Rzeczna tratwa|Prom|Barka"
            .. "|Tajemniczy okret|Wielki trojmasztowy galeon|Stara (?:niewielka )?szkuta"
            .. "|Smukly drakkar|Mala feluka|Stary buzar|Smukly (?:majestatyczny )?bryg"
            .. "|Nieduzy barkas|Nieduza rzeczna barka|Wielka galera|Dluga niezgrabna barka"
            .. "|Plaskodenny skeid)(?:\\.|,| i )",
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
-- naraz - pierwszy, ktory sie zatrzyma, wygrywa. Pojazd moze tez juz stac
-- na przystanku, zanim postac tam dojdzie - wtedy lapiemy go w opisie lokacji.
-- W trakcie chodzika opis pomijamy (mijany port to nie przystanek), a po jego
-- zakonczeniu rozgladamy sie jeszcze raz.
function scripts.podroz:wait()
    self:stop_waiting(true)
    self.wait_triggers = {}
    for _, cfg in pairs(boarding) do
        local board = function()
            scripts.podroz:stop_waiting(true)
            cfg.board()
        end
        table.insert(self.wait_triggers, tempRegexTrigger(cfg.pattern, board))
        table.insert(self.wait_triggers, tempRegexTrigger(cfg.parked, function()
            if amap.walker then return end
            print_log("<DimGrey>pojazd juz stoi na lokacji")
            board()
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
function scripts.podroz:start(target, walk_to)
    self:cancel(true)
    self.pending_walk = nil
    self.target = target
    self.walk_to = walk_to
    self.timer = tempTimer(1800, function()
        scripts.podroz.timer = nil
        scripts.podroz:cancel()
    end)
    print_log("<green>cel - " .. target .. (walk_to and (", potem /idz " .. walk_to) or ""))
    if not self.vehicle then
        self:wait()
        if not amap.walker then send("spojrz", false) end
    end
end

function scripts.podroz:cancel(silent)
    self:stop_waiting(true)
    if self.timer then killTimer(self.timer); self.timer = nil end
    self.target = nil
    self.walk_to = nil
    if not silent then print_log("<tomato>przerwane") end
end

function scripts.podroz:status()
    print_log(string.format("<DimGrey>cel=%s pojazd=%s czekam=%s idz=%s",
        tostring(self.target), tostring(self.vehicle), tostring(self.wait_triggers ~= nil),
        tostring(self.walk_to or self.pending_walk)))
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
    ["^podroz do (.+?)(?: (\\d+|i[0-9a-z]+))?$"] = function() scripts.podroz:start(matches[2], matches[3] ~= "" and matches[3] or nil) end,
    ["^podroz stop$"]    = function() scripts.podroz:cancel() end,
    ["^podroz stan$"]    = function() scripts.podroz:status() end,
}

local handlers = {
    amapGpsLocation = function(_, location) scripts.podroz:gps(location) end,
    amapWalkerFinished = function()
        if scripts.podroz.wait_triggers then send("spojrz", false) end
    end,
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
