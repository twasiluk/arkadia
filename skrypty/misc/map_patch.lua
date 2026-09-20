-- ============================================================
--  map_patch - lokalne poprawki lokacji nakladane na mape
--
--  Mapa (map_master3.dat) przychodzi z repozytorium arkadia-mapa i kazda
--  nowa wersja nadpisuje plik, wiec recznych zmian nie da sie w niej
--  utrzymac. Tutaj trzymamy wlasne wartosci i nakladamy je na mape w
--  pamieci po kazdym jej zaladowaniu - skrypty (chodzik, /gnaj, /podroz,
--  gps) czytaja mape wylacznie przez API Mudleta, wiec widza poprawki
--  tak samo jak dane z pliku.
--
--  Poprawki zyja tylko w pamieci. /zapisz_mape wypali je w lokalny plik,
--  ale i tak zniknie on przy nastepnej wersji mapy.
--
--  Poprawki wchodza same: na starcie profilu, po /zaladuj_mape i po
--  pobraniu nowej wersji mapy.
--
--  /map_patch - naklada poprawki ponownie i wypisuje, co zrobil
-- ============================================================

scripts.map_patch = scripts.map_patch or {
    aliases = {},
}

-- ============================================================
--  Poprawki - tu dopisujemy wlasne lokacje
--
--  Klucz: id mudletowe (liczba, np. 6430) albo stabilne id wewnetrzne
--  (string "i...", np. "i7f3a12cd"). Id wewnetrzne przezywa przebudowe
--  mapy w repozytorium, mudletowe niekoniecznie - w razie watpliwosci
--  bierzemy id wewnetrzne z /lokacja.
--
--  Wartosci: klucze userData lokacji (stringi) czytane przez skrypty -
--  "gate", "note", "bind", "bind_printable", "walk_pre_cmd",
--  "walk_post_cmd", "dir_bind", "drinkable", "description", "gps",
--  "team_follow_link". Do tego cztery wlasciwosci samej mapy: "weight"
--  (liczba), "lock" (bool), "env" (kolor, liczba), "name" (string).
--  false kasuje dany klucz userData.
-- ============================================================
local patches = {
    -- [6430] = { gate = "uderz w brame", weight = 5 },
    -- ["i7f3a12cd"] = { note = "tu stoi straznik", lock = true },
}

-- wlasciwosci mapy maja wlasne funkcje, reszta idzie w userData
local setters = {
    weight = setRoomWeight,
    lock   = lockRoom,
    env    = setRoomEnv,
    name   = setRoomName,
}

local function log(msg)
    cecho("\n<CadetBlue>(map_patch)<reset>: " .. msg .. "\n")
end

-- id mudletowe z klucza poprawki; nil, jesli takiej lokacji nie ma na mapie
local function resolve(key)
    local id = tonumber(key)
    if not id and type(key) == "string" then
        id = tonumber(amap.internal_to_mudlet_id[key])
    end
    if id and roomExists(id) then return id end
    return nil
end

local function map_loaded()
    return next(getRooms() or {}) ~= nil
end

-- zwraca liczbe poprawionych lokacji albo nil, gdy mapy jeszcze nie ma
function scripts.map_patch:apply(verbose)
    if next(patches) == nil then
        if verbose then log("<DimGrey>brak poprawek w pliku") end
        return 0
    end
    if not map_loaded() then
        if verbose then log("<tomato>mapa nie jest zaladowana") end
        return nil
    end
    local applied, missing = 0, {}
    for key, props in pairs(patches) do
        local id = resolve(key)
        if not id then
            table.insert(missing, tostring(key))
        else
            for prop, value in pairs(props) do
                local setter = setters[prop]
                if setter then
                    setter(id, value)
                elseif value == false then
                    clearRoomUserDataItem(id, prop)
                else
                    setRoomUserData(id, prop, tostring(value))
                end
            end
            applied = applied + 1
        end
    end
    if #missing > 0 then
        log("<tomato>brak na mapie: " .. table.concat(missing, ", "))
    end
    if verbose or #missing > 0 then
        log("<DimGrey>poprawione lokacje: " .. applied)
    end
    return applied
end

-- ============================================================
--  Podpiecie pod zaladowanie mapy
--
--  amap:init_map_data() to jedyne wspolne miejsce dla startu profilu
--  (amap:open_map) i przeladowania mapy (scripts.installer:load_map,
--  czyli /zaladuj_mape i pobranie nowej wersji). Opakowujemy je raz,
--  odpornie na przeladowanie pliku - tak samo jak gates_walk opakowuje
--  amap:auto_walker. Poprawki musza isc po odbudowaniu
--  amap.internal_to_mudlet_id, bo klucze "i..." z niego korzystaja.
-- ============================================================
if not scripts.map_patch.original then
    scripts.map_patch.original = amap.init_map_data
end

function amap:init_map_data()
    scripts.map_patch.original(self)
    scripts.map_patch:apply()
end

-- ============================================================
--  Start profilu
--
--  Na starcie mapa bywa jeszcze niezaładowana, gdy skrypty juz stoja,
--  wiec zamiast jednego podejscia probujemy, az pojawia sie lokacje.
--  Bez tego wszystkie id poszlyby w raport jako "brak na mapie".
-- ============================================================
local retry_delay, retry_max = 1, 15

function scripts.map_patch:apply_when_ready(attempt)
    if self.retry_timer then killTimer(self.retry_timer); self.retry_timer = nil end
    if self:apply() then return end
    attempt = (attempt or 0) + 1
    if attempt > retry_max then
        log("<tomato>mapa nie zaladowala sie - poprawki nie sa nalozone, uzyj /map_patch")
        return
    end
    self.retry_timer = tempTimer(retry_delay, function()
        scripts.map_patch.retry_timer = nil
        scripts.map_patch:apply_when_ready(attempt)
    end)
end

function scripts.map_patch:init()
    for _, id in ipairs(self.aliases) do killAlias(id) end
    self.aliases = {}
    table.insert(self.aliases, tempAlias("^/map_patch$", function()
        scripts.map_patch:apply(true)
    end))

    -- start profilu (sysLoadEvent leci takze przy przeladowaniu profilu)
    self.load_handler = scripts.event_register:force_register_event_handler(
        self.load_handler, "sysLoadEvent",
        function() scripts.map_patch:apply_when_ready() end, true)

    -- przeladowanie samego pliku w trakcie sesji - sysLoadEvent juz byl
    self:apply_when_ready()
end

scripts.map_patch:init()
