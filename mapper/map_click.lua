-- ============================================================
--  map_click - pojedyncze kliknicie w lokacje na mapie wypisuje klikalne
--  "/gnaj <room_id>" (podpowiedz, nic nie rusza). Dwuklik, jak dotad, od razu
--  uruchamia chodzika.
--
--  Mudlet nie ma eventu "zmienilo sie zaznaczenie", wiec sluchamy klikniecia w
--  okno mapy (sysMapWindowMousePressEvent, Mudlet 4.20+) i po chwili czytamy
--  getMapSelection(). Dwuklik to dwa klikniecia - drugi wpis jest pomijany.
-- ============================================================

amap.map_click = amap.map_click or {}
local mc = amap.map_click

local settle = 0.1          -- chwila na aktualizacje zaznaczenia po kliknieciu
local repeat_window = 1     -- ten sam pokoj w tym czasie (dwuklik) - bez powtorki

-- pojedynczo zaznaczony pokoj (zaznaczenie wielu pokoi pomijamy)
function mc:selected_room()
    if not getMapSelection then return nil end
    local ok, selection = pcall(getMapSelection)
    local rooms = ok and selection and selection.rooms
    if not rooms or #rooms ~= 1 then return nil end
    return tonumber(selection.center or rooms[1])
end

-- liczba krokow tylko gdy chodzik stoi: getPath nadpisuje globalny speedWalkPath
local function steps_to(room)
    if amap.walker then return nil end
    local from = amap.curr and amap.curr.id
    if not from or from == -1 or from == room then return nil end
    if not getPath(from, room) then return nil end
    return #speedWalkPath
end

function mc:show(room)
    local cmd = "/gnaj " .. room
    local name = getRoomName(room)
    local steps = steps_to(room)
    cecho("<CadetBlue>(mapper)<tomato>: ")
    cechoLink("<light_slate_blue>" .. cmd, function() expandAlias(cmd, true) end, cmd, true)
    cecho("<grey> - " .. (name or "?") .. (steps and string.format(" (%d krokow)", steps) or "") .. "\n")
    resetFormat()
end

function mc:on_click()
    tempTimer(settle, function()
        local room = mc:selected_room()
        if not room then return end
        local now = getEpoch()
        if mc.last_room == room and mc.last_at and now - mc.last_at < repeat_window then return end
        mc.last_room, mc.last_at = room, now
        mc:show(room)
    end)
end

function mc:init()
    self.handler = scripts.event_register:force_register_event_handler(self.handler,
        "sysMapWindowMousePressEvent", function() mc:on_click() end)
end

mc:init()
