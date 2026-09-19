-- ============================================================
--  trasa - wyszukiwanie polaczen (statki, dylizansy) z przesiadkami
--  po sieci ze skrypty/transport/network.lua
--
--  /trasa [<skad> > | do] <dokad> [<id lokacji>] - skad/dokad: nazwa lub id
--  lokacji, bez <skad> = aktualna lokacja; <dokad> <id> = przystanki <dokad>,
--  potem pieszo do <id>. Wypisuje odcinki i komende /podroz.
-- ============================================================

scripts.trasa = scripts.trasa or {
    aliases = {},
}

-- koszty w sekundach
scripts.trasa.config = {
    walk_step = 2,         -- jeden krok pieszo
    board_wait = 120,      -- czekanie na pojazd (kara za kazde wsiadanie)
    ride_default = 60,     -- odcinek bez znanego czasu
    transfer_steps = 30,   -- max krokow pieszo miedzy przystankami
    access_steps = 40,     -- max krokow z/do lokacji spoza sieci
}

local function print_log(msg)
    cecho("\n<CadetBlue>(trasa)<reset>: " .. msg .. "\n")
end

local function normalize(text)
    text = text:lower()
    local polish = { ["ą"] = "a", ["ć"] = "c", ["ę"] = "e", ["ł"] = "l", ["ń"] = "n",
                     ["ó"] = "o", ["ś"] = "s", ["ź"] = "z", ["ż"] = "z",
                     ["Ą"] = "a", ["Ć"] = "c", ["Ę"] = "e", ["Ł"] = "l", ["Ń"] = "n",
                     ["Ó"] = "o", ["Ś"] = "s", ["Ź"] = "z", ["Ż"] = "z" }
    for from, to in pairs(polish) do
        text = text:gsub(from, to)
    end
    return (text:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " "))
end

-- ---------- graf ----------
-- wezly: przystanek (room_id), przystanek po dojsciu pieszo "w<room_id>"
-- (tylko wsiadanie - bez sklejania przejsc w dlugi marsz) i peron
-- "<route.id>@<room_id>" (w pojezdzie danej trasy na danym przystanku)
local function platform(route, stop)
    return route.id .. "@" .. stop
end

function scripts.trasa:build()
    local network = scripts.transport_network
    local cfg = self.config
    self.routes, self.boarding, self.rides = {}, {}, {}

    local function ride(route, from, to, time)
        local key = platform(route, from)
        self.rides[key] = self.rides[key] or {}
        table.insert(self.rides[key], { to = platform(route, to), stop = to, cost = time or cfg.ride_default })
    end

    for _, route in ipairs(network.routes) do
        self.routes[route.id] = route
        local stops = route.line or route.cycle
        local times = route.times or {}
        for i, stop in ipairs(stops) do
            self.boarding[stop] = self.boarding[stop] or {}
            table.insert(self.boarding[stop], route)
            local next_stop = stops[i + 1] or (route.cycle and stops[1])
            if next_stop then
                ride(route, stop, next_stop, times[i])
                if route.line then ride(route, next_stop, stop, times[i]) end
            end
        end
    end
    self.walk_cache = {}
end

-- ---------- chodzenie po mapie ----------
local function neighbours(room, reverse)
    local result = {}
    if reverse then
        for _, id in pairs(getAllRoomEntrances(room) or {}) do table.insert(result, id) end
    else
        for _, id in pairs(getRoomExits(room) or {}) do table.insert(result, id) end
        for _, id in pairs(getSpecialExitsSwap(room) or {}) do table.insert(result, id) end
    end
    return result
end

-- przystanki w zasiegu limit krokow: { [room_id] = kroki }
function scripts.trasa:nearby_stops(room, limit, reverse)
    local stops = scripts.transport_network.stops
    local dist, queue, found = { [room] = 0 }, { room }, {}
    local head = 1
    while queue[head] do
        local current = queue[head]
        head = head + 1
        if stops[current] then found[current] = dist[current] end
        if dist[current] < limit then
            for _, id in ipairs(neighbours(current, reverse)) do
                id = tonumber(id)
                if id and not dist[id] and not roomLocked(id) then
                    dist[id] = dist[current] + 1
                    table.insert(queue, id)
                end
            end
        end
    end
    return found
end

function scripts.trasa:transfers(stop)
    if not self.walk_cache[stop] then
        self.walk_cache[stop] = self:nearby_stops(stop, self.config.transfer_steps)
    end
    return self.walk_cache[stop]
end

-- ---------- skad / dokad ----------
-- zwraca { [room_id przystanku] = kroki pieszo }, opis
function scripts.trasa:resolve(text, reverse)
    local network = scripts.transport_network
    local room = text:match("^%d+$") and tonumber(text)
    if not room and text:match("^i%w+$") and amap.internal_to_mudlet_id then
        room = tonumber(amap.internal_to_mudlet_id[text])
    end
    if room then
        if not roomExists(room) then return nil end
        return self:nearby_stops(room, self.config.access_steps, reverse), tostring(room), room
    end

    local name = normalize(text)
    name = normalize(network.aliases[name] or name)
    local matchers = {
        function(stop) return normalize(stop.city or stop.gps or "") == name end,
        function(stop) return normalize(stop.gps or "") == name end,
        function(stop) return normalize(stop.gps or ""):find(name, 1, true)
                           or normalize(stop.city or ""):find(name, 1, true) end,
        function(_, id) return normalize(getRoomAreaName(getRoomArea(id)) or ""):find(name, 1, true) end,
    }
    for _, matches in ipairs(matchers) do
        local found = {}
        for id, stop in pairs(network.stops) do
            if matches(stop, id) then found[id] = 0 end
        end
        if next(found) then return found, text end
    end
    return nil
end

-- przystanki celu -> { [przystanek] = kroki do room }, room (bez limitu krokow)
function scripts.trasa:walk_to(targets, room)
    if not roomExists(room) then return nil end
    local result
    for stop in pairs(targets) do
        local steps = stop == room and 0 or (getPath(stop, room) and #speedWalkPath)
        if steps then
            result = result or {}
            result[stop] = steps
        end
    end
    return result, room
end

-- ---------- wyszukiwanie ----------
-- Dijkstra od wielu zrodel do wielu celow; zwraca liste krawedzi
function scripts.trasa:find(sources, targets)
    local cfg = self.config
    local dist, prev, done = {}, {}, {}

    local function relax(node, cost, edge)
        if not dist[node] or cost < dist[node] then
            dist[node], prev[node] = cost, edge
        end
    end
    for stop, steps in pairs(sources) do
        relax(steps > 0 and "w" .. stop or stop, steps * cfg.walk_step, { kind = "walk", to = stop, steps = steps })
    end

    while true do
        local node, best
        for candidate, cost in pairs(dist) do
            if not done[candidate] and (not best or cost < best) then node, best = candidate, cost end
        end
        if not node then break end
        done[node] = true

        local walked = type(node) == "string" and tonumber(node:match("^w(%d+)$"))
        if type(node) == "number" or walked then
            local stop = walked or node
            if not walked then
                for other, steps in pairs(self:transfers(stop)) do
                    if other ~= stop then
                        relax("w" .. other, best + steps * cfg.walk_step, { kind = "walk", from = node, to = other, steps = steps })
                    end
                end
            end
            for _, route in ipairs(self.boarding[stop] or {}) do
                relax(platform(route, stop), best + cfg.board_wait, { kind = "board", from = node, route = route, stop = stop })
            end
        else
            local route_id, stop = node:match("^(.+)@(%d+)$")
            stop = tonumber(stop)
            relax(stop, best, { kind = "alight", from = node, route = self.routes[route_id], stop = stop })
            for _, edge in ipairs(self.rides[node] or {}) do
                relax(edge.to, best + edge.cost, { kind = "ride", from = node, route = self.routes[route_id], stop = edge.stop, cost = edge.cost })
            end
        end
    end

    local target, total
    local target_stop
    for stop, steps in pairs(targets) do
        for _, node in ipairs({ stop, "w" .. stop }) do
            local cost = dist[node] and dist[node] + steps * cfg.walk_step
            if cost and (not total or cost < total) then target, target_stop, total = node, stop, cost end
        end
    end
    if not target then return nil end

    local edges, node = {}, target
    while node do
        local edge = prev[node]
        table.insert(edges, 1, edge)
        node = edge.from
    end
    if targets[target_stop] > 0 then
        table.insert(edges, { kind = "walk", from = target_stop, steps = targets[target_stop] })
    end
    return edges, total
end

-- krawedzie -> odcinki: { kind = "walk", from, to, steps } / { kind = "ride", route, from, to, stops, time }
function scripts.trasa:legs(edges, destination)
    local legs = {}
    for _, edge in ipairs(edges) do
        local last = legs[#legs]
        if edge.kind == "walk" and edge.steps > 0 then
            local to = edge.to or destination
            if last and last.kind == "walk" then
                last.to, last.steps = to, last.steps + edge.steps
            else
                table.insert(legs, { kind = "walk", from = edge.from, to = to, steps = edge.steps })
            end
        elseif edge.kind == "board" then
            table.insert(legs, { kind = "ride", route = edge.route, from = edge.stop, to = edge.stop, stops = 0, time = 0 })
        elseif edge.kind == "ride" then
            last.to, last.stops, last.time = edge.stop, last.stops + 1, last.time + edge.cost
        end
    end
    return legs
end

-- komendy /podroz; kolejny odcinek w tej samej komendzie tylko po dojsciu
-- chodzikiem (/podroz rusza dalej po amapWalkerFinished), dojscie na pierwszy
-- przystanek jako id na poczatku (/podroz <id> <cel> ...)
function scripts.trasa:podroz_commands(legs)
    local stops = scripts.transport_network.stops
    local commands, words = {}, {}
    local function flush()
        if #words == 1 and words[1]:match("^%d+$") then
            table.insert(commands, "/gnaj " .. words[1])
        elseif #words > 0 then
            table.insert(commands, "/podroz " .. table.concat(words, " "))
        end
        words = {}
    end
    -- start z nazwy: nie wiadomo, gdzie stoi postac - id przystanku na poczatku
    if legs[1] and legs[1].kind == "ride" then table.insert(words, tostring(legs[1].from)) end
    for i, leg in ipairs(legs) do
        if leg.kind == "walk" then
            table.insert(words, tostring(leg.to))
        else
            -- przesiadka bez chodzenia: /gnaj do biezacej lokacji nie konczy chodzika
            if legs[i - 1] and legs[i - 1].kind == "ride" then flush() end
            local gps = stops[leg.to].gps
            if gps then
                table.insert(words, gps)
            else
                flush()
                table.insert(commands, "(wysiadz recznie: " .. leg.to .. ")")
            end
        end
    end
    flush()
    return commands
end

-- ---------- wypisywanie ----------
local function stop_label(id)
    local stop = scripts.transport_network.stops[id]
    return string.format("%s <DimGrey>%d<reset>", stop and stop.gps or getRoomName(id) or "?", id)
end

local function minutes(seconds)
    return string.format("%d min", math.max(1, math.floor(seconds / 60 + 0.5)))
end

function scripts.trasa:show(from_text, to_text)
    if not self.rides then self:build() end
    if not from_text then
        if not amap.curr.id or amap.curr.id == -1 then
            print_log("<tomato>nieznana aktualna lokacja")
            return
        end
        from_text = tostring(amap.curr.id)
    end
    local sources, from_label, from_room = self:resolve(from_text)
    if not sources then return print_log("<tomato>nie znam miejsca: " .. from_text) end
    -- "<miasto> <id lokacji>": przystanki miasta, potem pieszo do lokacji
    local city, destination = to_text:match("^(.-)%s+(%d+)$")
    if city and not city:match("^%d*$") then to_text = city else destination = nil end
    local targets, to_label, to_room = self:resolve(to_text, true)
    if not targets then return print_log("<tomato>nie znam miejsca: " .. to_text) end
    if destination then
        targets, to_room = self:walk_to(targets, tonumber(destination))
        if not targets then return print_log("<tomato>nie ma przejscia z " .. to_label .. " do " .. destination) end
        to_label = to_label .. " " .. destination
    end
    if not next(sources) then return print_log("<tomato>brak przystanku w zasiegu " .. from_text) end
    if not next(targets) then return print_log("<tomato>brak przystanku w zasiegu " .. to_text) end

    local edges, total = self:find(sources, targets)
    if not edges then return print_log("<tomato>brak polaczenia " .. from_label .. " -> " .. to_label) end
    local legs = self:legs(edges, to_room)
    if legs[1] and legs[1].kind == "walk" and not legs[1].from then legs[1].from = from_room end

    local rides, unverified = 0, false
    for _, leg in ipairs(legs) do
        if leg.kind == "ride" then rides = rides + 1 end
    end
    print_log(string.format("<green>%s -> %s<reset>: %s, ok. %s", from_label, to_label,
        rides == 0 and "pieszo" or "przesiadki: " .. (rides - 1), minutes(total)))
    for i, leg in ipairs(legs) do
        if leg.kind == "walk" then
            cecho(string.format(" %d. pieszo%s -> %s (%d krokow)\n", i,
                leg.from and (" " .. stop_label(leg.from)) or "", stop_label(leg.to), leg.steps))
        else
            local mark = ""
            if leg.route.verified == false then
                mark, unverified = " <orange>*<reset>", true
            end
            cecho(string.format(" %d. %s <yellow>%s<reset>%s: %s -> %s (%d przyst., ok. %s)\n", i,
                leg.route.type, leg.route.name, mark, stop_label(leg.from), stop_label(leg.to),
                leg.stops, minutes(leg.time)))
        end
    end
    if unverified then
        cecho(" <orange>*<reset> <DimGrey>kolejnosc przystankow niezweryfikowana<reset>\n")
    end
    local commands = {}
    if rides > 0 then
        commands = self:podroz_commands(legs)
    elseif legs[#legs] and legs[#legs].to then
        -- bez pojazdu: sam chodzik do celu
        commands = { "/gnaj " .. legs[#legs].to }
    end
    for _, command in ipairs(commands) do
        if command:sub(1, 1) == "/" then
            echo(" ")
            cechoLink("<cyan>" .. command .. "<reset>", function() expandAlias(command) end, command, true)
            echo("\n")
        else
            cecho(" <cyan>" .. command .. "<reset>\n")
        end
    end
end

-- ---------- rejestracja ----------
local aliases = {
    ["^/trasa (.+)$"] = function()
        local text = matches[2]:gsub("^do ", "")
        local from, to = text:match("^(.-)%s*>%s*(.+)$")
        if not from then from, to = text:match("^(.-) do (.+)$") end
        if from and from ~= "" then
            scripts.trasa:show(from, to)
        else
            scripts.trasa:show(nil, to or text)
        end
    end,
}

function scripts.trasa:init()
    for _, id in ipairs(self.aliases) do killAlias(id) end
    self.aliases = {}
    self.rides = nil
    for regex, callback in pairs(aliases) do
        table.insert(self.aliases, tempAlias(regex, callback))
    end
end

scripts.trasa:init()
