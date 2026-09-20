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

function scripts.map_patch:apply(verbose)
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

function scripts.map_patch:init()
    for _, id in ipairs(self.aliases) do killAlias(id) end
    self.aliases = {}
    table.insert(self.aliases, tempAlias("^/map_patch$", function()
        scripts.map_patch:apply(true)
    end))

    -- przeladowanie pliku w trakcie sesji - mapa juz stoi w pamieci
    if next(getRooms() or {}) then
        self:apply()
    end
end

scripts.map_patch:init()
