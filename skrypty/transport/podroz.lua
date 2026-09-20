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
-- legs    - kolejne odcinki podrozy { {target, walk_to}, ... }

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

-- Chodzik podrozy biegnie szybciej niz ustawienie gracza (/opoz), wiec przed
-- pierwszym /gnaj zapamietujemy opoznienie i przywracamy je na koniec podrozy.
local walk_delay = 4

function scripts.podroz:save_delay()
    if self.saved_delay == nil then
        self.saved_delay = amap.walker_delay or amap.set_walker_delay
    end
end

function scripts.podroz:restore_delay()
    if self.saved_delay == nil then return end
    amap.walker_delay = self.saved_delay
    self.saved_delay = nil
end

-- losowa zwloka przed wsiadaniem i wysiadaniem (sekundy)
local delay_min, delay_max = 3, 6

-- dzwiek wsiadania/wysiadki gra po sound_delay od przyjazdu/meldunku celu,
-- nie dopiero po zwloce; event (podrozBoarded/podrozLeft) go wtedy nie powtarza
local sound_delay, sound_skip = 0.3, 30

function scripts.podroz:delayed(what, callback, kind, vehicle)
    if self.delay_timer then killTimer(self.delay_timer) end
    if kind and vehicle then
        self.early_sound = { kind = kind, time = os.time() }
        tempTimer(sound_delay, function() scripts.podroz:play(kind, vehicle) end)
    end
    local delay = delay_min + math.random() * (delay_max - delay_min)
    print_log(string.format("<DimGrey>%s za %.1f s", what, delay))
    self.delay_timer = tempTimer(delay, function()
        scripts.podroz.delay_timer = nil
        callback()
    end)
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
        -- nastepny odcinek rusza dopiero po dojsciu na przystanek, inaczej
        -- zlapalby pojazd, z ktorego postac wlasnie wysiadla
        self.next_on_walk = self.pending_legs ~= nil
        self:save_delay()
        -- chwila na ustawienie pozycji przez mapper
        tempTimer(1, function()
            expandAlias("/gnaj " .. room .. " " .. walk_delay, true)
        end)
    else
        -- wysiadka na ostatnim przystanku, bez dojscia - koniec podrozy
        self:restore_delay()
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
    print_log("<green>wysiadam - " .. location)
    local vehicle = self.vehicle
    local walk_to, legs, command = self.walk_to, self.legs, exit_commands[vehicle]
    self:cancel(true)
    self.pending_walk = walk_to
    self.pending_legs = walk_to and legs and #legs > 0 and legs or nil
    self:delayed("wysiadka", function() send(command, false) end, "left", vehicle)
end

-- ---------- czekanie na srodek transportu ----------
-- pattern - pojazd podjezdza/przybija
-- parked  - pojazd juz stoi na lokacji (linia z przedmiotami przy wejsciu / spojrz)
-- board(line) - linia, ktora zlapal pattern/parked (woz i powoz maja inna
-- komende wsiadania niz dylizans)
local boarding = {
    -- woz i powoz jezdza jak dylizans (to samo "wyjscie" i wnetrze bez mapy)
    dylizans = {
        pattern = "(?:dylizans|woz) powoli zatrzymuje sie|^(?:Woz|Powoz) cicho skrzypiac zatrzymuje sie",
        -- "Kupiecki stojacy woz powoli rusza w droge" to odjazd, nie postoj
        parked = "[A-Za-z]+ stojacy (?:dylizans|(?:po)?woz)(?!.* rusza)",
        board = function(line)
            local lower = line:lower()
            local vehicle = lower:match("powoz") and "powozu" or lower:match("woz") and "wozu"
            if not vehicle then
                send("wejdz do dylizansu")
                return
            end
            expandAlias("wem", true)    -- wez monety z sakiewki
            send("wsiadz do " .. vehicle)
            expandAlias("wlm", true)    -- wloz monety z powrotem
        end,
    },
    statek = {
        pattern = "Wszyscy na poklad!|(?:rypa|ratwa|rom|arka) przybija do brzegu\\.$",
        parked = "^(?:(?:[A-Za-z]+ ){1,2}(?:statek|knara|prom)|Tratwa|Rzeczna tratwa|Prom|Barka"
            .. "|Tajemniczy okret|Wielki trojmasztowy galeon|Stara (?:niewielka )?szkuta"
            .. "|Smukly drakkar|Mala feluka|Stary buzar|Smukly (?:majestatyczny )?bryg"
            .. "|Nieduzy barkas|Nieduza rzeczna barka|Wielka galera|Dluga niezgrabna barka"
            .. "|Plaskodenny skeid)(?:\\.|,| i )",
        board = function(_)
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
    for vehicle, cfg in pairs(boarding) do
        local board = function()
            local seen = line
            scripts.podroz:stop_waiting(true)
            scripts.podroz:delayed("wsiadanie", function() cfg.board(seen) end, "boarded", vehicle)
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
end

function scripts.podroz:stop_waiting(silent)
    for _, id in ipairs(self.wait_triggers or {}) do killTrigger(id) end
    self.wait_triggers = nil
    if self.wait_timer then killTimer(self.wait_timer); self.wait_timer = nil end
    if not silent then print_log("<tomato>przestaje czekac") end
end

-- ---------- sterowanie ----------
-- "Biala 6430 Nuln 6903 Kreutzhoffen" -> Biala (/gnaj 6430), Nuln (/gnaj 6903), Kreutzhoffen
-- "6621 Biala ..." - najpierw /gnaj 6621, potem odcinki; zwraca legs, id poczatkowe
local function is_room_id(word)
    return word:match("^%d+$") or (word:match("^i%w+$") and word:match("%d"))
end

function scripts.podroz:parse_legs(text)
    local legs, words, first = {}, {}, nil
    for word in text:gmatch("%S+") do
        if is_room_id(word) and #words == 0 and #legs == 0 and not first then
            first = word
        elseif is_room_id(word) then
            if #words == 0 then return nil end
            table.insert(legs, { target = table.concat(words, " "), walk_to = word })
            words = {}
        else
            table.insert(words, word)
        end
    end
    if #words > 0 then
        table.insert(legs, { target = table.concat(words, " ") })
    end
    if #legs == 0 then return nil end
    return legs, first
end

local function describe_legs(legs)
    local parts = {}
    for _, leg in ipairs(legs or {}) do table.insert(parts, leg.target) end
    return table.concat(parts, " -> ")
end

function scripts.podroz:start(legs)
    self:cancel(true)
    local leg = table.remove(legs, 1)
    local target, walk_to = leg.target, leg.walk_to
    self.target = target
    self.walk_to = walk_to
    self.legs = legs
    self.timer = tempTimer(1800, function()
        scripts.podroz.timer = nil
        scripts.podroz:cancel()
    end)
    local log_start = function()
        print_log("<green>cel - " .. target .. (walk_to and (", potem /gnaj " .. walk_to) or "")
            .. (#legs > 0 and ("<DimGrey>, dalej: " .. describe_legs(legs)) or ""))
        if scripts.podroz.wait_triggers then
            print_log("<DimGrey>czekam na dylizans, woz lub statek...")
        end
    end
    if self.vehicle then
        log_start()
        return
    end
    self:wait()
    if amap.walker then
        log_start()
    else
        -- log po opisie lokacji, zeby nie zginal nad nim
        send("spojrz", false)
        tempTimer(1, log_start)
    end
end

-- najpierw chodzik na przystanek, odcinki ruszaja po amapWalkerFinished
function scripts.podroz:walk_then_start(room, legs)
    self:cancel(true)
    if room == tostring(amap.curr.id) or room == amap.curr.internal_id then
        self:start(legs)
        return
    end
    self.pending_legs, self.next_on_walk = legs, true
    print_log("<green>najpierw /gnaj " .. room .. "<DimGrey>, potem: " .. describe_legs(legs))
    self:save_delay()
    expandAlias("/gnaj " .. room .. " " .. walk_delay, true)
end

function scripts.podroz:cancel(silent)
    self:stop_waiting(true)
    if self.timer then killTimer(self.timer); self.timer = nil end
    if self.delay_timer then killTimer(self.delay_timer); self.delay_timer = nil end
    self.target = nil
    self.walk_to = nil
    self.legs = nil
    self.pending_walk = nil
    self.pending_legs = nil
    self.next_on_walk = nil
    -- cancel(true) tylko przestawia odcinek, cancel() konczy cala podroz
    if not silent then
        self:restore_delay()
        print_log("<tomato>przerwane")
    end
end

function scripts.podroz:status()
    print_log(string.format("<DimGrey>cel=%s pojazd=%s czekam=%s idz=%s",
        tostring(self.target), tostring(self.vehicle), tostring(self.wait_triggers ~= nil),
        tostring(self.walk_to or self.pending_walk)))
    local legs = self.legs and #self.legs > 0 and self.legs or self.pending_legs
    if legs then
        print_log("<DimGrey>dalej: " .. describe_legs(legs))
    end
end

-- ---------- dzwieki ----------
-- z eventu: pomin, jesli ten dzwiek juz zagral przy przyjezdzie/meldunku
function scripts.podroz:play_event(kind, vehicle)
    local early = self.early_sound
    if early and early.kind == kind and os.time() - early.time <= sound_skip then
        self.early_sound = nil
        return
    end
    self:play(kind, vehicle)
end

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
    ["[Ww]siadasz (?:do|na) .*(?:dylizansu?|wozu?|powozu?)\\.$"] = "dylizans",
    ["wspinasz sie na .*dylizans\\.$"]               = "dylizans",
    -- same "Wchodzisz na .+" lapaloby tez drzewa, mury itp. (i gralo dzwiek)
    ["^Wchodzisz na (?:poklad .+|.*(?:statek|okret|prom|barke|barkasa|feluke|skeid|tratwe|bryg|drakkar|szkute|buzar|knare|galere|galeon|lodz|lodke|kog|karake|karawele|kuter))\\.$"] = "statek",
}

local aliases = {
    -- "stop"/"stan" maja wlasne aliasy
    ["^/podroz (?:do )?(?!(?:stop|stan)$)(.+)$"] = function()
        local legs, first = scripts.podroz:parse_legs(matches[2])
        if not legs then
            print_log("<tomato>uzycie: /podroz [do] [<id>] <cel> [<id> <cel> ...] [<id>]")
            return
        end
        if first then
            scripts.podroz:walk_then_start(first, legs)
        else
            scripts.podroz:start(legs)
        end
    end,
    ["^/podroz stop$"]   = function() scripts.podroz:cancel() end,
    ["^/podroz stan$"]   = function() scripts.podroz:status() end,
}

local handlers = {
    amapGpsLocation = function(_, location) scripts.podroz:gps(location) end,
    amapWalkerFinished = function()
        local self = scripts.podroz
        if self.next_on_walk then
            local legs = self.pending_legs
            self.next_on_walk, self.pending_legs = nil, nil
            self:start(legs)
        elseif self.wait_triggers then
            send("spojrz", false)
        elseif not self.vehicle and not self.target then
            -- dojscie po ostatnim odcinku - koniec podrozy
            self:restore_delay()
        end
    end,
    podrozBoarded   = function(_, vehicle) scripts.podroz:play_event("boarded", vehicle) end,
    podrozLeft      = function(_, vehicle) scripts.podroz:play_event("left", vehicle) end,
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
