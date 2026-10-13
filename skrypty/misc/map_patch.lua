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
--  pobraniu nowej wersji mapy. Mapa dochodzi regionami, wiec poprawki
--  do lokacji, ktorych jeszcze nie ma, czekaja w kolejce i wchodza przy
--  wejsciu w nowy obszar.
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
--
--  "lock_exits" = lista kierunkow ("dol", "gora", "polnoc", "down", "n",
--  kod 10...) - zamyka te wyjscia dla szukania drogi. Samo wyjscie
--  zostaje na mapie: chodzik (/gnaj, /idz, /podroz) go nie uzyje, ale
--  recznie da sie tam zejsc i mapper nadal poprawnie sledzi pozycje.
--  Tym blokujemy skroty, ktorych nie chcemy w trasach - np. tunele.
-- ============================================================
local patches = {
    -- [6430] = { gate = "uderz w brame", weight = 5 },
    -- ["i7f3a12cd"] = { note = "tu stoi straznik", lock = true },

    -- Tunele pod Oxenfurtem (z = -1). Caly poziom wisi na czterech
    -- zejsciach w dol - zamkniecie ich wyprowadza tunele z tras, a
    -- wyjscia "gora" zostaja otwarte, wiec z samych tuneli /gnaj
    -- nadal wyprowadzi.
    ["i53313986b"] = { lock_exits = { "dol" } },  -- 2543 -> 23613
    ["i87868731b"] = { lock_exits = { "dol" } },  -- 2553 -> 23597
    ["i3aa2dae28"] = { lock_exits = { "dol" } },  -- 2459 -> 23609
    ["ibb6918a0b"] = { lock_exits = { "dol" } },  -- 852  -> 10712
}

local function log(msg)
    cecho("\n<CadetBlue>(map_patch)<reset>: " .. msg .. "\n")
end

-- "dol" / "down" / "d" / 10 -> kod kierunku Mudleta
local function dir_code(dir)
    if tonumber(dir) then return tonumber(dir) end
    return amap.exitmap[amap.polish_to_english[dir] or dir]
end

-- zamyka wyjscia dla getPath; lista kierunkow albo jeden kierunek
local function lock_exits(id, dirs)
    if type(dirs) ~= "table" then dirs = { dirs } end
    for _, dir in ipairs(dirs) do
        local code = dir_code(dir)
        if code then
            lockExit(id, code, true)
        else
            log("<tomato>nieznany kierunek w lock_exits: " .. tostring(dir))
        end
    end
end

-- wlasciwosci mapy maja wlasne funkcje, reszta idzie w userData
local setters = {
    weight     = setRoomWeight,
    lock       = lockRoom,
    env        = setRoomEnv,
    name       = setRoomName,
    lock_exits = lock_exits,
}

-- id mudletowe z klucza poprawki; nil, jesli takiej lokacji nie ma na mapie
local function resolve(key)
    local id = tonumber(key)
    if not id and type(key) == "string" then
        id = tonumber(amap.internal_to_mudlet_id[key])
    end
    if id and roomExists(id) then return id end
    return nil
end

-- czy ktorys klucz jest id wewnetrznym ("i...") - tylko takie potrzebuja indeksu
local needs_internal_ids = false
for key in pairs(patches) do
    if not tonumber(key) then needs_internal_ids = true end
end

-- ============================================================
--  Gotowosc mapy
--
--  Same lokacje to za maly warunek. Mudlet wczytuje plik mapy razem z
--  profilem, ale indeks id wewnetrznych buduje dopiero
--  amap:init_map_data(), a core.lua odpala je z tempTimera - przy
--  ladowaniu skryptow lokacje wiec juz sa, a klucze "i..." jeszcze sie
--  nie rozwiazuja. Bez tego warunku pierwsze podejscie zglaszalo
--  wszystkie poprawki jako "brak na mapie" i - bo apply() zwracalo 0,
--  czyli wartosc prawdziwa - gasilo ponawianie.
-- ============================================================
local function map_loaded()
    if next(getRooms() or {}) == nil then return false end
    if not needs_internal_ids then return true end
    return next(amap.internal_to_mudlet_id or {}) ~= nil
end

-- ============================================================
--  Doladowywanie regionow
--
--  Mapa nie przychodzi cala naraz - regiony dochodza w trakcie gry,
--  wiec lokacji z poprawki moze jeszcze nie byc. To nie blad, tylko
--  stan przejsciowy: takie poprawki ida do kolejki i wracamy do nich,
--  az sie wyczerpie. Dlatego automatyczne przebiegi milcza o brakach,
--  a mowi o nich tylko /map_patch.
--
--  amap:init_map_data() indeksuje id wewnetrzne raz, dla lokacji
--  zaladowanych w tamtej chwili, wiec przed kazda proba uzupelniamy
--  indeks o to, co doszlo pozniej.
-- ============================================================
local function reindex()
    for id in pairs(getRooms() or {}) do
        local internal_id = getRoomUserData(id, "internal_id")
        if internal_id and internal_id ~= "" and amap.internal_to_mudlet_id[internal_id] == nil then
            amap.internal_to_mudlet_id[internal_id] = id
        end
    end
end

-- kolejka poprawek do nalozenia; pelna lista po kazdym zaladowaniu mapy,
-- bo swiezy plik mapy przychodzi bez naszych zmian
function scripts.map_patch:reset_pending()
    local pending = {}
    for key, props in pairs(patches) do pending[key] = props end
    self.pending = pending
    self.last_area = nil
end

function scripts.map_patch:pending_keys()
    local keys = {}
    for key in pairs(self.pending or {}) do table.insert(keys, tostring(key)) end
    table.sort(keys)
    return keys
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
    if not self.pending then self:reset_pending() end
    reindex()
    local applied = 0
    for key, props in pairs(self.pending) do
        local id = resolve(key)
        if id then
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
            self.pending[key] = nil
            applied = applied + 1
        end
    end
    if verbose then
        local waiting = self:pending_keys()
        local total = 0
        for _ in pairs(patches) do total = total + 1 end
        log("<DimGrey>poprawione lokacje: " .. (total - #waiting) .. "/" .. total ..
            (applied > 0 and " (nowych: " .. applied .. ")" or ""))
        if #waiting > 0 then
            log("<DimGrey>czekaja na doladowanie regionu: " .. table.concat(waiting, ", "))
        end
    end
    return applied
end

-- nowy obszar moze przyniesc lokacje, na ktore czekaja poprawki
function scripts.map_patch:on_new_location()
    if not self.pending or next(self.pending) == nil then return end
    local area = amap.curr and amap.curr.area
    if area == nil or area == self.last_area then return end
    self.last_area = area
    self:apply()
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
    scripts.map_patch:reset_pending()
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

    -- doladowanie regionu: wracamy do poprawek czekajacych na lokacje
    self.location_handler = scripts.event_register:force_register_event_handler(
        self.location_handler, "amapNewLocation",
        function() scripts.map_patch:on_new_location() end, true)

    -- start profilu (sysLoadEvent leci takze przy przeladowaniu profilu)
    self.load_handler = scripts.event_register:force_register_event_handler(
        self.load_handler, "sysLoadEvent",
        function() scripts.map_patch:apply_when_ready() end, true)

    -- przeladowanie samego pliku w trakcie sesji - sysLoadEvent juz byl
    self:apply_when_ready()
end

scripts.map_patch:init()
