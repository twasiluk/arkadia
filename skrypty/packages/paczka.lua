-- ============================================================
--  /paczka - "ob paczke", adresat z napisu na paczce -> lokacja
--  (pl:resolve) -> "/gnaj <room_id>" albo "/trasa <miasto> <room_id>".
--  Na poczcie (nazwa lokacji z "poczta") zapamietuje lokacje (tez /kurier
--  przy odbiorze); /paczka i "Oddajesz pocztowa paczke" wypisuja link powrotu.
--
--  scripts.packages.lookup to tez wspolne funkcje dla /kurier: lokacja
--  adresata, kroki, najblizsza poczta, miasto lokacji.
-- ============================================================

scripts.packages.lookup = scripts.packages.lookup or {}
local pl = scripts.packages.lookup

local npc_url = "https://delwing.github.io/arkadia-mapa/data/npc.json"
local npc_file = getMudletHomeDir() .. "/npc.json"
local timeout = 3
local walk_limit = 20   -- mniej krokow pieszo niz tyle -> od razu /gnaj zamiast /trasa

-- lokacje z "poczta" w nazwie, ktore nie przyjmuja zlecen (poczty prywatne)
local skip_posts = { [7304] = true, [7612] = true, [15485] = true }

-- ---------- npc.json ----------
function pl:load()
    local file = io.open(npc_file, "r")
    if not file then return end
    local ok, data = pcall(yajl.to_value, file:read("*a"))
    file:close()
    if ok and type(data) == "table" then
        self.npc = data
    else
        scripts:print_log("Nie udalo sie wczytac " .. npc_file)
    end
end

-- pobiera npc.json tylko, gdy nie ma go jeszcze na dysku
function pl:fetch()
    if io.exists(npc_file) then
        self:load()
        return
    end
    registerAnonymousEventHandler("sysDownloadDone", function(_, filename)
        if filename ~= npc_file then return true end
        pl:load()
    end, true)
    registerAnonymousEventHandler("sysDownloadError", function(_, err, filename)
        if filename ~= npc_file then return true end
        scripts:print_log("Nie udalo sie pobrac npc.json: " .. tostring(err))
    end, true)
    downloadFile(npc_file, npc_url)
end

-- ---------- lokacje ----------
-- id lokacji jako liczba; -1, nil i "" -> nil (baza trzyma room_id jako string)
local function room_id(room)
    room = tonumber(room)
    if room and room ~= -1 then return room end
end

function pl:current_room()
    return room_id(amap and amap.curr and amap.curr.id)
end

-- liczba krokow chodzika albo nil, gdy brak drogi
function pl:steps(from, to)
    from, to = room_id(from), room_id(to)
    if not from or not to then return nil end
    if from == to then return 0 end
    return getPath(from, to) and #speedWalkPath or nil
end

-- najblizsza z lokacji (opcjonalnie ponizej limit krokow): room, steps
function pl:nearest(rooms, limit)
    local from = self:current_room()
    local best, best_steps
    for _, room in ipairs(rooms) do
        local steps = self:steps(from, room)
        if steps and (not limit or steps < limit) and (not best_steps or steps < best_steps) then
            best, best_steps = room, steps
        end
    end
    return best, best_steps
end

function pl:is_post(room)
    room = room_id(room)
    if not room or skip_posts[room] then return false end
    local name = getRoomName(room)
    return name and string.find(string.lower(name), "poczta", 1, true) ~= nil
end

-- najblizsza poczta przyjmujaca zlecenia: room, steps
function pl:nearest_post()
    local from = self:current_room()
    if not from then return nil end
    if self:is_post(from) then return from, 0 end
    local posts = {}
    for room in pairs(searchRoom("poczta", false, false) or {}) do
        if self:is_post(room) then table.insert(posts, room_id(room)) end
    end
    return self:nearest(posts)
end

-- miasto = nazwa obszaru mapy (jak ostatni matcher scripts.trasa:resolve)
function pl:room_city(room)
    room = room_id(room)
    local area = room and getRoomArea(room)
    return area and getRoomAreaName(area) or nil
end

-- generyczne okreslenia przed nazwa miejsca na paczce ("OSADA FANDALL")
local city_prefixes = { "osada", "wioska", "wies", "miasto", "miasteczko",
    "gmina", "twierdza", "zamek", "port", "przystan" }

local function city_core(city)
    local lowered = string.lower(string.trim(city or ""))
    for _, prefix in ipairs(city_prefixes) do
        local rest = string.match(lowered, "^" .. prefix .. "%s+(.+)$")
        if rest then return rest end
    end
    return lowered
end

-- obszar mapy vs miasto z paczki w obie strony: obszar "Fandall" pasuje do
-- adresu "osada Fandall", a obszar "Osada Fandall" do adresu "Fandall"
function pl:in_city(room, city)
    local area = self:room_city(room)
    if not area or area == "" then return false end
    area, city = string.lower(area), city_core(city)
    if city == "" then return false end
    return string.find(area, city, 1, true) ~= nil
        or string.find(city, area, 1, true) ~= nil
end

-- ---------- zrodla lokacji adresata ----------
local function has_room(rooms, room)
    for _, known in ipairs(rooms) do
        if known == room then return true end
    end
    return false
end

local function add_room(rooms, room)
    room = room_id(room)
    if room and not has_room(rooms, room) then table.insert(rooms, room) end
end

-- npc.json z repo mapy
function pl:npc_rooms(name)
    local needle = string.lower(string.trim(name))
    local rooms = {}
    for _, npc in ipairs(self.npc or {}) do
        if npc.name and string.lower(npc.name) == needle then add_room(rooms, npc.loc) end
    end
    return rooms
end

-- baza asystenta paczek: lokacje udanych dostaw, wszystkie wiersze
function pl:db_rooms(name)
    local rooms = {}
    local packages = scripts.packages.db and scripts.packages.db.packages
    if not packages then return rooms end
    local escaped = string.trim(name):gsub('"', '""')
    local rows = db:fetch_sql(packages, 'SELECT * FROM packages WHERE name = "' .. escaped .. '" COLLATE NOCASE')
    for _, row in ipairs(rows or {}) do add_room(rooms, row.room_id) end
    return rooms
end

-- nazwy lokacji na mapie (adres bez przecinka, np. "POCZTA W JOUINARD")
function pl:map_rooms(name)
    local rooms = {}
    for room in pairs(searchRoom(name, false, true) or {}) do add_room(rooms, room) end
    table.sort(rooms)
    return rooms
end

local function list_text(rooms)
    local parts = {}
    for _, room in ipairs(rooms) do table.insert(parts, tostring(room)) end
    return table.concat(parts, ",")
end

-- lokacja adresata, wspolna dla /paczka i /kurier. Zrodla po kolei:
-- npc.json, baza asystenta (+ hint - lokacja z tablicy, od asystenta),
-- nazwy lokacji na mapie; pierwsze niepuste wygrywa. Kilka lokacji -> te
-- w miescie (opts.city, bez miasta - aktualne), z nich najblizsza.
-- Zwraca room, rooms (kandydaci), notes (rozbieznosci zrodel do logu)
function pl:resolve(name, opts)
    opts = opts or {}
    local notes = {}
    local npc = self:npc_rooms(name)
    local known = self:db_rooms(name)
    add_room(known, opts.hint)

    local rooms = npc
    if #npc > 0 then
        local others = {}
        for _, room in ipairs(known) do
            if not has_room(npc, room) then table.insert(others, room) end
        end
        if #others > 0 then
            table.insert(notes, string.format("baza paczek: %s, npc.json: %s - biore npc.json",
                list_text(others), list_text(npc)))
        end
    elseif #known > 0 then
        rooms = known
    else
        rooms = self:map_rooms(name)
    end
    if #rooms == 0 then return nil, rooms, notes end
    if #rooms == 1 then return rooms[1], rooms, notes end

    local city = opts.city or self:room_city(self:current_room())
    local candidates = {}
    for _, room in ipairs(rooms) do
        if city and self:in_city(room, city) then table.insert(candidates, room) end
    end
    if #candidates == 0 then
        table.insert(notes, string.format("adresat w %d lokacjach, zadna w %s - biore najblizsza",
            #rooms, city and ("\"" .. city .. "\"") or "nieznanym miescie"))
        candidates = rooms
    end
    return self:nearest(candidates) or candidates[1], candidates, notes
end

-- ---------- adres na paczce ----------
local function title_case(text)
    return (string.trim(text):lower():gsub("(%a)(%w*)", function(a, b) return a:upper() .. b end))
end

-- "IMIE, [FUNKCJA,] MIASTO." / "... - PILNE!" / "POCZTA W JOUINARD"
-- -> imie (lub nazwa miejsca), miasto (nil bez przecinka)
function pl:parse_address(text)
    text = text:gsub("%s+%-%s+.*$", ""):gsub("[%.!%s]+$", "")
    local parts = string.split(text, ",")
    local name = string.trim(parts[1])
    local city = #parts > 1 and title_case(parts[#parts]) or nil
    return name, city
end

-- ---------- poczta nadania ----------
-- room_id i nazwa lokacji (ustawia tez /kurier przy odbiorze)
function pl:set_post(room)
    room = room_id(room)
    if not room then return end
    self.post_room = room
    self.post_name = getRoomName(room)
end

-- lokacja poczty, jesli /paczka wywolane na poczcie
function pl:remember_post()
    local room = self:current_room()
    if self:is_post(room) then self:set_post(room) end
end

function pl:show_post()
    if not self.post_room then return end
    local cmd = "/gnaj " .. self.post_room
    local name = self.post_name or getRoomName(self.post_room) or "?"
    echo("\n")
    scripts:print_url("<light_slate_blue>Poczta: " .. name .. " (" .. self.post_room .. ")",
        function() expandAlias(cmd) end, cmd)
    echo("\n")
end

-- ---------- /paczka ----------
function pl:show_rooms(rooms, name)
    for _, room in ipairs(rooms) do
        local cmd = "/gnaj " .. room
        echo("\n")
        scripts:print_url("<light_slate_blue>" .. cmd, function() expandAlias(cmd) end, name)
    end
    echo("\n")
end

function pl:clear()
    if self.trigger then killTrigger(self.trigger); self.trigger = nil end
    if self.timer then killTimer(self.timer); self.timer = nil end
end

function pl:go(address)
    local name, city = self:parse_address(address)
    local room, rooms, notes = self:resolve(name, { city = city })
    for _, note in ipairs(notes) do scripts:print_log(note) end
    if not room then return scripts:print_log("Nie znam lokacji adresata: " .. name) end
    self:show_rooms(rooms, name)
    self:show_post()
    local steps = self:steps(self:current_room(), room)
    if steps and steps < walk_limit then
        scripts:print_log(string.format("Adresat %d krokow pieszo - /gnaj %d", steps, room))
        expandAlias("/gnaj " .. room)
    elseif city then
        expandAlias("/trasa " .. city .. " " .. room)
    else
        expandAlias("/trasa " .. room)
    end
end

function pl:run()
    self:clear()
    self:remember_post()
    self.trigger = tempRegexTrigger("^Wypisano na niej duzymi literami: (.+)$", function()
        pl:clear()
        pl:go(matches[2])
    end, 1)
    self.timer = tempTimer(timeout, function() pl:clear() end)
    send("ob paczke")
end

function pl:init()
    self:fetch()
    if self.alias then killAlias(self.alias) end
    self.alias = tempAlias("^/paczka$", function() pl:run() end)
    if self.delivered_trigger then killTrigger(self.delivered_trigger) end
    self.delivered_trigger = tempRegexTrigger("^Oddajesz pocztowa paczke", function() pl:show_post() end)
end

pl:init()
