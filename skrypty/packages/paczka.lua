-- ============================================================
--  /paczka - "ob paczke", adresat z napisu na paczce, lokacja
--  z pola "Paczki" (userData pokoju) na mapie -> "/idz <room_id>"
-- ============================================================

scripts.packages.lookup = scripts.packages.lookup or {}
local pl = scripts.packages.lookup

local field = "Paczki"
local timeout = 3

-- pokoje, ktorych pole "Paczki" zawiera imie (bez wielkosci liter)
function pl:find_rooms(name)
    local needle = string.lower(name)
    local rooms = {}
    for _, value in pairs(searchRoomUserData(field) or {}) do
        if string.find(string.lower(value), needle, 1, true) then
            for _, room in pairs(searchRoomUserData(field, value) or {}) do
                table.insert(rooms, tonumber(room))
            end
        end
    end
    table.sort(rooms)
    return rooms
end

function pl:show(name)
    local rooms = self:find_rooms(name)
    if #rooms == 0 then
        scripts:print_log("Brak lokacji z '" .. name .. "' w polu " .. field .. " na mapie")
        return
    end
    for _, room in ipairs(rooms) do
        local cmd = "/idz " .. room
        echo("\n")
        scripts:print_url("<light_slate_blue>" .. cmd, function() expandAlias(cmd) end, name)
    end
    echo("\n")
end

function pl:clear()
    if self.trigger then killTrigger(self.trigger); self.trigger = nil end
    if self.timer then killTimer(self.timer); self.timer = nil end
end

function pl:run()
    self:clear()
    self.trigger = tempRegexTrigger("^Wypisano na niej duzymi literami: ([^,]+),", function()
        local name = matches[2]
        pl:clear()
        pl:show(name)
    end, 1)
    self.timer = tempTimer(timeout, function() pl:clear() end)
    send("ob paczke")
end

function pl:init()
    if self.alias then killAlias(self.alias) end
    self.alias = tempAlias("^/paczka$", function() pl:run() end)
end

pl:init()
