-- ============================================================
--  /kurier [n] - petla kurierska: poczta -> pierwsza paczka z tablicy
--  -> podroz do adresata -> "daj paczke <imie w celowniku>".
--  /kurier 0 - jeden kurs bez powrotu na poczte.
--  Kazdy etap poprzedza losowa zwloka (delay_min..delay_max).
--  Na starcie "ob paczke": paczka juz w rekach -> od razu do adresata.
--  Kazdy problem lub niejednoznacznosc konczy petle.
-- ============================================================

scripts.kurier = scripts.kurier or {
    aliases = {},
    triggers = {},
    handlers = {},
    timers = {},
}

local ku = scripts.kurier

local delay_min, delay_max = 1.5, 4.5
local walk_limit = 50        -- pieszo do adresata bez szukania polaczenia
local board_timeout = 20     -- czekanie na tablice z przesylkami
local pickup_timeout = 20    -- czekanie na wydanie paczki
local travel_timeout = 1800  -- czekanie na dotarcie do adresata
local reply_timeout = 10     -- czekanie na odpowiedz "odmien"
local check_timeout = 5      -- czekanie na napis na paczce ("ob paczke")
local board_retries = 2      -- powroty do tablicy po "Lista przesylek zmienila sie"

local package_sound = "w10-usb-in.mp3"  -- paczka w rekach (odbior / "ob paczke")

local function print_log(msg)
    cecho("\n<CadetBlue>(kurier)<reset>: " .. msg .. "\n")
end

-- jak scripts.podroz:play - plik z <katalog Mudleta>/sounds
local function play_sound(file)
    local path = getMudletHomeDir() .. "/sounds/" .. file
    if lfs.attributes(path) then
        playSoundFile(path)
    else
        print_log("<DimGrey>brak pliku dzwieku " .. path)
    end
end

-- ---------- sprzatanie ----------
function ku:clear_waiting()
    for _, id in ipairs(self.triggers) do killTrigger(id) end
    for _, id in ipairs(self.timers) do killTimer(id) end
    for _, id in ipairs(self.handlers) do killAnonymousEventHandler(id) end
    self.triggers, self.timers, self.handlers = {}, {}, {}
    self.watching, self.deadline_info = {}, nil
end

function ku:stop(msg, color)
    self:clear_waiting()
    self.running = nil
    self.left = nil
    self.package = nil
    if msg then print_log("<" .. (color or "tomato") .. ">" .. msg) end
end

-- ---------- pomocniki ----------
-- kolejny etap po losowej zwloce
function ku:next(what, callback)
    if not self.running then return end
    local delay = delay_min + math.random() * (delay_max - delay_min)
    print_log(string.format("<DimGrey>%s za %.1f s", what, delay))
    self.stage = { name = what, at = os.time() + delay }
    table.insert(self.timers, tempTimer(delay, function()
        if ku.running then callback() end
    end))
end

function ku:watch(pattern, callback)
    table.insert(self.triggers, tempRegexTrigger(pattern, callback))
    self.watching = self.watching or {}
    table.insert(self.watching, pattern)
end

function ku:deadline(seconds, msg)
    table.insert(self.timers, tempTimer(seconds, function() ku:stop(msg) end))
    self.deadline_info = { msg = msg, at = os.time() + seconds }
end

-- chodzik skonczony i postac stoi w oczekiwanej lokacji; amapWalkerFinished
-- leci takt chodzika po wyslaniu ostatniego kroku, czesto zanim mapper
-- zmieni lokacje - wtedy dojscie lapie dopiero amapNewLocation
function ku:on_arrival(room, callback)
    room = tonumber(room)
    local function check()
        if not ku.running or amap.walker then return end
        if tonumber(amap.curr.id) == room then
            ku:clear_waiting()
            callback()
        end
    end
    table.insert(self.handlers, registerAnonymousEventHandler("amapWalkerFinished", check))
    table.insert(self.handlers, registerAnonymousEventHandler("amapNewLocation", check))
end

local function current_room()
    return amap and amap.curr and amap.curr.id
end

-- lokacje z "poczta" w nazwie, ktore nie przyjmuja zlecen (poczty prywatne)
local skip_posts = { [7304] = true, [7612] = true, [15485] = true }

local function room_is_post(room)
    room = tonumber(room)
    if not room or room == -1 or skip_posts[room] then return false end
    local name = getRoomName(room)
    return name and string.find(string.lower(name), "poczta", 1, true) ~= nil
end

-- ---------- etap 1: najblizsza poczta ----------
function ku:nearest_post()
    local from = current_room()
    if not from or from == -1 then return nil end
    if room_is_post(from) then return from, 0 end
    local found = searchRoom("poczta", false, false)
    if type(found) ~= "table" then return nil end
    local best, best_steps
    for room in pairs(found) do
        room = tonumber(room)
        if room and room ~= -1 and room_is_post(room) then
            local steps = room == from and 0 or (getPath(from, room) and #speedWalkPath)
            if steps and (not best_steps or steps < best_steps) then
                best, best_steps = room, steps
            end
        end
    end
    return best, best_steps
end

-- po dojsciu: tablica, albo "gotowe" po ostatnim kursie (last)
function ku:goto_post(last)
    local function arrived()
        if last then return ku:stop("gotowe", "green") end
        ku:next("tablica", function() ku:read_board() end)
    end
    local room, steps = self:nearest_post()
    if not room then return self:stop("nie znalazlem poczty na mapie") end
    if steps == 0 then
        print_log("<DimGrey>juz na poczcie " .. room)
        return arrived()
    end
    print_log(string.format("<green>poczta %d (%d krokow)", room, steps))
    self:clear_waiting()
    self:on_arrival(room, arrived)
    self:deadline(travel_timeout, "nie dotarlem na poczte")
    expandAlias("/gnaj " .. room, true)
end

-- ---------- etap 2: tablica z przesylkami ----------
function ku:read_board()
    self:clear_waiting()
    -- tablice czyta asystent paczek (scripts.packages), my czekamy na jej koniec
    self:watch("^ \\|      Symbolem \\* oznaczono", function()
        ku:clear_waiting()
        ku:next("wybor paczki", function() ku:pick_package() end)
    end)
    self:deadline(board_timeout, "nie doczekalem sie tablicy z przesylkami")
    send("obejrzyj tablice")
end

-- ---------- etap 3: pierwsza paczka ----------
-- adresaci pomijani na tablicy (bez wielkosci liter)
local ignored_recipients = {
    "ARIBERT D'AQUITAINE",
    "Vorster Main",
}

local function is_ignored(name)
    local lowered = string.lower(string.trim(name or ""))
    for _, ignored in ipairs(ignored_recipients) do
        if lowered == string.lower(ignored) then return true end
    end
    return false
end

-- indeksy w current_offer trzymane sa tak, jak zlapal je trigger tablicy
-- (tekst), wiec pierwsza oferta to ta o najmniejszym numerze; adresaci
-- z ignored_recipients pomijani
local function first_offer()
    local best_index, best
    for index, offer in pairs(scripts.packages.current_offer or {}) do
        local number = tonumber(index)
        if number and is_ignored(offer.name) then
            print_log("<DimGrey>pomijam paczke " .. index .. ": " .. offer.name)
        elseif number and (not best_index or number < tonumber(best_index)) then
            best_index, best = index, offer
        end
    end
    return best_index, best
end

-- miasto = nazwa obszaru mapy (jak ostatni matcher scripts.trasa:resolve)
local function room_city(room)
    local area = room and room ~= -1 and getRoomArea(room)
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
local function in_city(room, city)
    local area = room_city(room)
    if not area or area == "" then return false end
    area, city = string.lower(area), city_core(city)
    if city == "" then return false end
    return string.find(area, city, 1, true) ~= nil
        or string.find(city, area, 1, true) ~= nil
end

-- lokacja adresata: asystent paczek, potem npc.json/baza/nazwa lokacji
-- (/paczka); kilka lokacji -> te w miescie z tablicy, bez miasta na
-- tablicy -> w aktualnym miescie; z pozostalych najblizsza. Miasto tylko
-- zaweza liste z listy npc - nieznane miasto nie blokuje kursu
function ku:resolve_location(offer)
    -- baza asystenta trzyma room_id jako string ("1279" ~= 1279)
    local location = tonumber(offer.location)
    if location and location ~= -1 then return location end
    local lookup = scripts.packages.lookup
    local rooms = lookup and lookup:find_rooms(offer.name) or {}
    if #rooms == 0 then return nil, "nie znam lokacji adresata: " .. offer.name end
    if #rooms == 1 then return rooms[1] end

    local city = offer.city or room_city(current_room())
    local candidates = {}
    for _, room in ipairs(rooms) do
        if city and in_city(room, city) then table.insert(candidates, room) end
    end
    if #candidates == 0 then
        print_log(string.format("<DimGrey>adresat w %d lokacjach, zadna w %s - biore najblizsza",
            #rooms, city and ("\"" .. city .. "\"") or "nieznanym miescie"))
        candidates = rooms
    end

    local from = current_room()
    local best, best_steps
    for _, room in ipairs(candidates) do
        local steps = room == from and 0 or (getPath(from, room) and #speedWalkPath)
        if steps and (not best_steps or steps < best_steps) then best, best_steps = room, steps end
    end
    return best or candidates[1]
end

function ku:pick_package()
    local index, offer = first_offer()
    if not offer then return self:stop("brak paczki na tablicy (poza pomijanymi adresatami)") end
    if not offer.name then return self:stop("paczka bez adresata") end
    local room, err = self:resolve_location(offer)
    if not room then return self:stop(err) end

    local plan = self:plan_route(room)
    if not plan then return end

    self.package = { name = offer.name, room = room, plan = plan }
    print_log("<green>paczka " .. index .. ": " .. offer.name .. " -> " .. room .. " (" .. plan.label .. ")")

    self:clear_waiting()
    self:watch("^.* przekazuje ci jakas paczke\\.", function()
        ku:clear_waiting()
        ku.board_retry = 0
        scripts.packages.lookup:set_post(current_room())
        play_sound(package_sound)
        ku:next("podroz", function() ku:travel() end)
    end)
    self:watch("Ty juz dla nas dostatecznie ciezko zapracowales"
        .. "|Nie ufam ci na tyle, aby powierzyc ci dostarczenie tej przesylki"
        .. "|Cos ci sie chyba pomylilo, nie ma takiej oferty"
        .. "|Niestety, nie widzisz tu nikogo, od kogo mozna by wziac zlecenie", function()
        ku:stop("poczta nie wydala paczki")
    end)
    -- tablica nieaktualna: od nowa "obejrzyj tablice", najwyzej board_retries razy
    self:watch("^Lista przesylek zmienila sie", function()
        if (ku.board_retry or 0) >= board_retries then
            return ku:stop("poczta nie wydala paczki (lista przesylek wciaz sie zmienia)")
        end
        ku.board_retry = (ku.board_retry or 0) + 1
        ku:clear_waiting()
        ku.package = nil
        print_log(string.format("<DimGrey>lista przesylek zmienila sie (%d/%d)", ku.board_retry, board_retries))
        ku:next("tablica", function() ku:read_board() end)
    end)
    self:deadline(pickup_timeout, "nie doczekalem sie paczki")
    send("wybierz paczke " .. index)
end

-- ---------- etap 0: paczka juz w rekach ----------
-- "ob paczke" -> napis z adresem -> kurs od podrozy; brak napisu w
-- check_timeout -> nie mamy paczki, zwykly start od poczty
function ku:check_package()
    self:clear_waiting()
    self:watch("^Wypisano na niej duzymi literami: (.+)$", function()
        ku:clear_waiting()
        play_sound(package_sound)
        ku:resume_package(matches[2])
    end)
    table.insert(self.timers, tempTimer(check_timeout, function()
        if not ku.running then return end
        ku:clear_waiting()
        ku:goto_post()
    end))
    send("ob paczke")
end

function ku:resume_package(address)
    local name, city = scripts.packages.lookup:parse_address(address)
    local offer = { name = name, city = city }
    -- asystent zapamietal lokacje przy odbiorze tej paczki
    local picked = scripts.packages.picked_offer
    if picked and picked.name and string.lower(picked.name) == string.lower(name) then
        offer.location = picked.location
    end
    local room, err = self:resolve_location(offer)
    if not room then return self:stop("mam paczke, ale " .. err) end
    local plan = self:plan_route(room, true)
    if not plan then return end
    self.package = { name = name, room = room, plan = plan }
    print_log("<green>mam paczke: " .. name .. " -> " .. room .. " (" .. plan.label .. ")")
    self:next("podroz", function() ku:travel() end)
end

-- ---------- trasa do adresata ----------
-- pieszo ponizej walk_limit krokow, dalej dowolna trasa (przesiadki i pojazdy
-- bez ograniczen); held = paczka juz w rekach, trzeba ja dostarczyc - gdy
-- trasy nie da sie ulozyc - pieszo, byle istniala droga (np. adresat w tej
-- samej twierdzy, kilkadziesiat krokow dalej, a w okolicy zadnego przystanku)
function ku:plan_route(room, held)
    local from = current_room()
    if not from or from == -1 then
        self:stop("nieznana aktualna lokacja")
        return nil
    end
    if not roomExists(room) then
        self:stop("lokacja adresata nie istnieje na mapie: " .. room)
        return nil
    end

    local steps = room == from and 0 or (getPath(from, room) and #speedWalkPath)
    if steps and steps < walk_limit then
        return { commands = { "/gnaj " .. room }, label = steps .. " krokow pieszo" }
    end

    -- z paczka w rekach kursu nie ma jak pominac: zamiast konczyc petle
    -- idziemy pieszo, jesli droga istnieje
    local function fail(msg)
        if held and steps then
            print_log(string.format("<DimGrey>%s - ide pieszo (%d krokow)", msg, steps))
            return { commands = { "/gnaj " .. room }, label = steps .. " krokow pieszo" }
        end
        self:stop(msg)
        return nil
    end

    local trasa = scripts.trasa
    if not trasa then
        return fail("brak skryptu trasy")
    end
    if not trasa.rides then trasa:build() end

    local sources = trasa:resolve(tostring(from))
    local targets, _, to_room = trasa:resolve(tostring(room), true)
    if not sources or not next(sources) then
        return fail("brak przystanku w zasiegu lokacji " .. from)
    end
    if not targets or not next(targets) then
        return fail("brak przystanku w zasiegu adresata")
    end

    local edges = trasa:find(sources, targets)
    if not edges then
        return fail("brak polaczenia do " .. room)
    end
    local legs = trasa:legs(edges, to_room)

    local rides = {}
    for _, leg in ipairs(legs) do
        if leg.kind == "ride" then table.insert(rides, leg) end
    end
    local names = {}
    for _, ride in ipairs(rides) do
        table.insert(names, ride.route.name)
    end

    local commands = trasa:podroz_commands(legs)
    if #commands ~= 1 then
        return fail("trasa nie miesci sie w jednej komendzie /podroz")
    end
    if commands[1]:sub(1, 1) ~= "/" then
        return fail("trasa wymaga recznej wysiadki")
    end
    return { commands = commands, label = #rides > 0 and table.concat(names, " + ") or "pieszo" }
end

-- ---------- etap 4: podroz ----------
-- adresat-instytucja ("BANK WYZIMSKI", "POCZTA W NULN", "PIEKARNIA ...",
-- "RATUSZ MIEJSKI, MARIBOR", "TAWERNA 'POD GROTEM WLOCZNI', NOVIGRAD",
-- "URZAD POCZTOWY W DAEVON, DAEVON"): bez przedstawiania i odmiany, paczke
-- zostawia sie "oddaj paczke"
local place_prefixes = { "bank", "poczta", "piekarnia", "ratusz", "tawerna",
    "zajazd", "zaklad", "pracownia", "urzad" }

local function is_place(name)
    local lowered = string.lower(name or "")
    for _, prefix in ipairs(place_prefixes) do
        if lowered:sub(1, #prefix) == prefix then return true end
    end
    return false
end

-- adresat sam na lokacji (jedyna zywa postac poza mna) - wtedy paczke bierze
-- po numerze gmcp ("daj paczke ob_123", jak scripts.smalltalk), bez
-- przedstawiania sie i odmiany imienia. Numer jest jednoznaczny i nie wymaga
-- zgadywania rodzaju ani rasy; gdy komenda nie przejdzie, wraca zwykla sciezka
function ku:single_npc()
    if not gmcp or not gmcp.objects or not gmcp.objects.nums then return nil end
    if not ateam or not ateam.objs then return nil end
    local found
    for _, num in pairs(gmcp.objects.nums) do
        local id = tonumber(num)
        if id and id ~= ateam.my_id and ateam.objs[id] then
            if found then return nil end
            found = id
        end
    end
    return found
end

-- etap po dotarciu do adresata
function ku:at_recipient()
    if is_place(self.package.name) then
        return self:next("oddanie paczki", function() ku:deliver("oddaj paczke") end)
    end
    local npc = self:single_npc()
    if npc then
        return self:next("oddanie paczki (ob_" .. npc .. ")", function()
            ku:deliver("daj paczke ob_" .. npc, function() ku:to_delivery() end)
        end)
    end
    self:to_delivery()
end

-- adresat wymieniony na lokacji pod swoim imieniem = gra zna juz jego imie
-- (nieznajomy jest na liscie jako opis, np. "jakis mezczyzna")
function ku:recipient_listed()
    local first = string.lower(string.match(self.package.name or "", "^[^%s,]+") or "")
    if first == "" or not ateam or not ateam.objs then return false end
    if not gmcp or not gmcp.objects then return false end
    for _, num in pairs(gmcp.objects.nums or {}) do
        local obj = ateam.objs[tonumber(num)]
        local desc = obj and obj["desc"] and string.lower(obj["desc"])
        if desc and string.find(desc, first, 1, true) then return true end
    end
    return false
end

-- przedstawiamy sie, dopoki gra nie pokazuje imienia adresata na lokacji;
-- wlasna pamiec sesji nie wystarcza - liczy sie to, co widac teraz
function ku:to_delivery()
    if not self:recipient_listed() then
        return self:next("przedstawienie sie", function() ku:introduce() end)
    end
    print_log("<DimGrey>adresat wymieniony z imienia, pomijam przedstawienie sie")
    self:next("odmiana imienia", function() ku:decline() end)
end

function ku:travel()
    local package = self.package
    self:clear_waiting()
    if tonumber(current_room()) == package.room then
        return self:at_recipient()
    end
    self:on_arrival(package.room, function() ku:at_recipient() end)
    self:deadline(travel_timeout, "nie dotarlem do adresata")
    expandAlias(package.plan.commands[1], true)
end

-- ---------- etap 5: przedstawienie sie ----------
-- gra zna imie adresata dopiero, gdy on sam sie przedstawi ("Rumiany ublocony
-- halfling przedstawia sie jako: Ignatio, Ceramista di Citta Ebino, halfling.")
-- - wczesniej "odmien <imie>" odpowiada "Odmien <kto/co>?". Czekamy wiec na
-- imie w tekscie, a nie na stala zwloke
local function regex_escape(text)
    return (text:gsub("(%W)", "\\%1"))
end

function ku:introduce()
    local first_name = string.match(self.package.name or "", "^[^%s,]+")
    self:clear_waiting()
    if first_name then
        self:watch("(?i)\\b" .. regex_escape(first_name) .. "\\b", function()
            ku:clear_waiting()
            ku:next("odmiana imienia", function() ku:decline() end)
        end)
        -- nikt sie nie przedstawil: probujemy odmiany tak czy inaczej
        table.insert(self.timers, tempTimer(reply_timeout, function()
            if not ku.running then return end
            ku:clear_waiting()
            print_log("<DimGrey>brak przedstawienia adresata, probuje odmiany")
            ku:decline()
        end))
    else
        self:next("odmiana imienia", function() ku:decline() end)
    end
    send("przedstaw sie")
end

-- ---------- etap 6: odmien <imie> -> celownik ----------
function ku:decline()
    local first_name = string.match(self.package.name, "^[^%s,]+")
    if not first_name then return self:stop("nie znam imienia adresata") end
    self:clear_waiting()
    -- "   Celownik: Dolbrumowi," - wiersze wyrownane spacjami do prawej
    self:watch("^\\s*Celownik: (.+)$", function()
        local form = string.trim(matches[2] or "")
        form = form:gsub("[%.!,;]+$", "")
        form = string.match(form, "^%S+")
        if not form or form == "" then return ku:stop("nie odczytalem celownika") end
        ku:clear_waiting()
        ku.package.dative = string.lower(form)
        ku:next("oddanie paczki", function() ku:deliver("daj paczke " .. ku.package.dative) end)
    end)
    self:deadline(reply_timeout, "brak odmiany imienia " .. first_name)
    send("odmien " .. string.lower(first_name))
end

-- ---------- etap 7: oddanie paczki ----------
-- fallback: bez potwierdzenia w reply_timeout probujemy dalej po staremu
-- (przedstawienie sie + odmiana), zamiast konczyc petle
function ku:deliver(command, fallback)
    self:clear_waiting()
    self:watch("^Oddajesz pocztowa paczke", function()
        ku:clear_waiting()
        ku:finish_round()
    end)
    if fallback then
        table.insert(self.timers, tempTimer(reply_timeout, function()
            if not ku.running then return end
            ku:clear_waiting()
            print_log("<DimGrey>skrot nie zadzialal, przedstawiam sie")
            fallback()
        end))
    else
        self:deadline(reply_timeout * 3, "paczka nie zostala oddana")
    end
    send(command)
end

function ku:finish_round()
    self.package = nil
    self.left = (self.left or 1) - 1
    if self.left <= 0 then
        if self.no_return then return self:stop("gotowe", "green") end
        return self:next("powrot na poczte", function() ku:goto_post(true) end)
    end
    print_log("<green>zostalo kursow: " .. self.left)
    self:next("nastepny kurs", function() ku:goto_post() end)
end

-- ---------- sterowanie ----------
function ku:run(count)
    -- nowy /kurier zastepuje dzialajacy
    if self.running then self:stop("przerwane - nowy /kurier", "DimGrey") end
    self.running = true
    -- /kurier 0: jeden kurs bez powrotu na poczte
    self.no_return = count == 0
    self.left = math.max(count or 1, 1)
    self.package = nil
    self.board_retry = 0
    print_log("<green>start, kursow: " .. self.left)
    self.stage = { name = "sprawdzenie paczki", at = os.time() }
    self:check_package()
end

-- ---------- /kurier stan ----------
-- stringi w cudzyslowie: widac "1279" vs 1279
local function show(value)
    if type(value) == "string" then return string.format("%q", value) end
    if type(value) ~= "table" then return tostring(value) end
    local parts = {}
    for k, v in pairs(value) do table.insert(parts, tostring(k) .. "=" .. show(v)) end
    table.sort(parts)
    return "{ " .. table.concat(parts, ", ") .. " }"
end

function ku:state()
    local now = os.time()
    local room = current_room()
    local lines = {
        { "running", self.running },
        { "left", self.left },
        { "no_return", self.no_return },
        { "board_retry", self.board_retry },
        { "stage", self.stage and string.format("%s (%+ds)", self.stage.name, self.stage.at - now) },
        { "deadline", self.deadline_info and string.format("%s (za %ds)", self.deadline_info.msg, self.deadline_info.at - now) },
        { "package", self.package },
        { "triggers/timers/handlers", #self.triggers .. "/" .. #self.timers .. "/" .. #self.handlers },
        { "room", room and string.format("%s %s [%s]", room, tostring(room ~= -1 and getRoomName(room)), tostring(room_city(room))) },
        { "walker", amap and string.format("%s dest=%s", tostring(amap.walker), tostring(amap.walker_dest)) },
        { "single_npc", self:single_npc() },
        { "current_offer", scripts.packages.current_offer },
        { "picked_offer", scripts.packages.picked_offer },
    }
    print_log("<CadetBlue>stan")
    for _, line in ipairs(lines) do
        local value = type(line[2]) == "string" and line[2] or show(line[2])
        cecho(string.format("  <DimGrey>%s:<reset> %s\n", line[1], value))
    end
    for _, pattern in ipairs(self.watching or {}) do
        cecho("  <DimGrey>watch:<reset> ")
        echo(pattern .. "\n")
    end
end

local aliases = {
    ["^/kurier(?: (\\d+))?$"] = function()
        scripts.kurier:run(tonumber(matches[2]) or 1)
    end,
    ["^/kurier stop$"] = function()
        scripts.kurier:stop("przerwane")
    end,
    ["^/kurier stan$"] = function()
        scripts.kurier:state()
    end,
}

function ku:init()
    for _, id in ipairs(self.aliases) do killAlias(id) end
    self.aliases = {}
    self:clear_waiting()
    for regex, callback in pairs(aliases) do
        table.insert(self.aliases, tempAlias(regex, callback))
    end
end

ku:init()
