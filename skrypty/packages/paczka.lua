-- ============================================================
--  /paczka - "ob paczke", adresat z napisu na paczce, lokacja
--  z npc.json mapy (Delwing/arkadia-mapa) -> "/idz <room_id>"
--  Zapas: baza asystenta paczek (scripts.packages).
--  Na poczcie (nazwa lokacji z "poczta") zapamietuje lokacje;
--  po "Oddajesz pocztowa paczke" wypisuje link powrotu.
--  Po /idz wykonuje /trasa <miasto> (ostatni czlon adresu na paczce).
-- ============================================================

scripts.packages.lookup = scripts.packages.lookup or {}
local pl = scripts.packages.lookup

local npc_url = "https://delwing.github.io/arkadia-mapa/data/npc.json"
local npc_file = getMudletHomeDir() .. "/npc.json"
local timeout = 3

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

-- lokacje npc o danym imieniu (bez wielkosci liter); zapas: baza asystenta,
-- nazwa lokacji na mapie (adres bez przecinka, np. "POCZTA W JOUINARD")
function pl:find_rooms(name)
    local needle = string.lower(string.trim(name))
    local rooms, seen = {}, {}
    local function add(room)
        room = tonumber(room)
        if room and room ~= -1 and not seen[room] then
            seen[room] = true
            table.insert(rooms, room)
        end
    end
    for _, npc in ipairs(self.npc or {}) do
        if npc.name and string.lower(npc.name) == needle then add(npc.loc) end
    end
    if #rooms == 0 then
        local match = scripts.packages:get_from_db(needle)
        if match then add(match.room_id) end
    end
    if #rooms == 0 then
        for room in pairs(searchRoom(name, false, true) or {}) do add(room) end
        table.sort(rooms)
    end
    return rooms
end

function pl:show(name)
    local rooms = self:find_rooms(name)
    if #rooms == 0 then
        scripts:print_log("Nie znam lokacji adresata: " .. name)
        return rooms
    end
    for _, room in ipairs(rooms) do
        local cmd = "/idz " .. room
        echo("\n")
        scripts:print_url("<light_slate_blue>" .. cmd, function() expandAlias(cmd) end, name)
    end
    echo("\n")
    return rooms
end

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

function pl:clear()
    if self.trigger then killTrigger(self.trigger); self.trigger = nil end
    if self.timer then killTimer(self.timer); self.timer = nil end
end

-- lokacja poczty, jesli /paczka wywolane na poczcie
function pl:remember_post()
    local room = amap and amap.curr and amap.curr.id
    local name = room and room ~= -1 and getRoomName(room)
    if name and string.find(string.lower(name), "poczta", 1, true) then
        self.post_room = room
    end
end

function pl:show_post()
    if not self.post_room then return end
    local cmd = "/idz " .. self.post_room
    echo("\n")
    scripts:print_url("<light_slate_blue>Poczta: " .. cmd, function() expandAlias(cmd) end, getRoomName(self.post_room) or cmd)
    echo("\n")
end

function pl:run()
    self:clear()
    self:remember_post()
    self.trigger = tempRegexTrigger("^Wypisano na niej duzymi literami: (.+)$", function()
        local name, city = pl:parse_address(matches[2])
        pl:clear()
        local rooms = pl:show(name)
        if city then
            expandAlias("/trasa " .. city)
        elseif #rooms == 1 then
            expandAlias("/trasa " .. rooms[1])
        end
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
