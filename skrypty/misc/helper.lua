-- ============================================================
--  helper - obchod pol z mapy (qk, sz) i nagrywanie trasy (rec)
--    /qk <pole-id> [...]  - zabijanie snotlingow na polach
--    /sz <pole-id> [...]  - szukanie ziol na polach
--    /rec                 - nagrywanie odwiedzonych lokacji
-- ============================================================

scripts.helper = scripts.helper or {
    aliases = {},
    triggers = {},
    qk = {},
    sz = {},
    rec = { ids = {} },
}

local qk = scripts.helper.qk
local sz = scripts.helper.sz
local rec = scripts.helper.rec

local function log(name, msg)
    cecho("\n<CadetBlue>(" .. name .. ")<reset>: " .. msg .. "\n")
end

-- ============================================================
--  qk - obchod pol i zabijanie snotlingow
--  start = pole, na ktorym stoisz przy uruchomieniu
-- ============================================================

local HP_FULL = 6      -- gmcp.char.state.hp: 6 = pelne zdrowie
local HP_MIN = 4       -- ponizej polowy = powrot na start
local QK_DELAY = 95    -- sekundy postoju na polu przed ruchem do nastepnego
local QK_MAX_MOVES = 20 -- po tylu ruchach powrot na start

-- gmcp przysyla tylko zmienione wartosci, stad zapasowo stan skryptow
local function hp()
    return gmcp.char and gmcp.char.state and gmcp.char.state.hp
        or scripts.character.state.hp
end

function qk.stop(msg)
    for _, id in ipairs(qk.handlers or {}) do killAnonymousEventHandler(id) end
    qk.handlers = nil
    if qk.timer then killTimer(qk.timer); qk.timer = nil end
    if msg then log("qk", msg) end
end

function qk.go(id)
    if amap.walker then amap:terminate_walker() end
    expandAlias("/idz " .. id, false)
end

-- konczy chodzenie i od razu wraca na start
function qk.home(msg)
    qk.stop(msg .. ", wracam na " .. qk.start)
    if tostring(amap.curr.id) ~= qk.start then
        qk.go(qk.start)
    elseif amap.walker then
        amap:terminate_walker()
    end
end

-- nastepne pole z listy (w kolko), pomijajac to, na ktorym stoimy
function qk.next()
    if not qk.handlers then return end
    if qk.moves >= QK_MAX_MOVES then
        return qk.home("<green>limit " .. QK_MAX_MOVES .. " ruchow")
    end
    for _ = 1, #qk.poles do
        qk.index = qk.index % #qk.poles + 1
        local id = qk.poles[qk.index]
        if tostring(amap.curr.id) ~= id then
            qk.moves = qk.moves + 1
            log("qk", "<DimGrey>ruch " .. qk.moves .. "/" .. QK_MAX_MOVES .. " -> " .. id)
            return qk.go(id)
        end
    end
    qk.home("<tomato>brak innego pola")
end

-- numery snotlingow na lokacji (gmcp.objects.nums + opisy z ateam.objs);
-- %f - samo slowo "snotling", bez np. "krol snotlingow"
local function snotlings()
    local found = {}
    for _, num in pairs(gmcp.objects and gmcp.objects.nums or {}) do
        local obj = ateam.objs[tonumber(num)]
        local desc = obj and obj.desc and obj.desc:lower()
        if desc and desc:find("%f[%a]snotling%f[%A]") then
            table.insert(found, tonumber(num))
        end
    end
    return found
end

-- atakuje, gdy nie walczymy juz z ktoryms z obecnych snotlingow;
-- zwraca true, gdy jakis snotling jest na polu
function qk.hunt()
    local found = snotlings()
    if #found == 0 then
        qk.target = nil
        return false
    end
    if not (qk.target and table.contains(found, qk.target)) then
        qk.target = found[1]
        log("qk", "<orange>snotling na polu")
        send("zabij snotlinga")
    end
    return true
end

-- czysto (bez snotlinga) i pelne zdrowie = mozna isc bez postoju
local function qk_ready()
    return not qk.hunt() and hp() == HP_FULL
end

-- postoj na polu; ruch dopiero, gdy nie ma snotlinga
function qk.wait()
    if qk.timer then killTimer(qk.timer); qk.timer = nil end
    if qk_ready() then return qk.next() end
    qk.timer = tempTimer(QK_DELAY, function()
        qk.timer = nil
        if qk.hunt() then return qk.wait() end
        qk.next()
    end)
end

-- po dojsciu: sprawdz snotlinga, postoj, potem kolejny ruch (albo powrot, gdy limit)
function qk.arrived()
    if not qk.handlers then return end
    qk.target = nil
    qk.wait()
end

-- zmiana obiektow lub zdrowia w trakcie postoju: skroc postoj, gdy juz mozna
function qk.recheck()
    if not (qk.handlers and qk.timer) then return end
    if qk_ready() then
        killTimer(qk.timer)
        qk.timer = nil
        qk.next()
    end
end

function qk.check_hp()
    if not qk.handlers then return end
    local value = hp()
    if value and value >= 0 and value < HP_MIN then
        return qk.home("<red>zdrowie ponizej 50%")
    end
    qk.recheck()
end

function qk.start_alias(args)
    qk.stop()

    if args == "stop" then
        if amap.walker then amap:terminate_walker() end
        log("qk", "<tomato>przerwane")
        return
    end

    if not amap.curr.id or amap.curr.id == -1 then
        log("qk", "<tomato>nie znam aktualnej lokacji")
        return
    end

    local ids = {}
    for id in args:gmatch("%d+") do table.insert(ids, id) end
    if #ids < 1 then
        log("qk", "<tomato>uzycie: /qk <pole-id> [<pole-id>...] | /qk stop")
        return
    end

    qk.start = tostring(amap.curr.id)
    qk.poles = ids
    qk.index = 0
    qk.moves = 0
    qk.handlers = {
        registerAnonymousEventHandler("gmcp.char.state", qk.check_hp),
        registerAnonymousEventHandler("amapWalkerFinished", qk.arrived),
        registerAnonymousEventHandler("gmcp.objects.nums", qk.recheck),
        registerAnonymousEventHandler("gmcp_parsing_finished", qk.recheck),
    }

    log("qk", "<green>start " .. qk.start .. ", pola: " .. table.concat(qk.poles, " "))
    qk.check_hp()
    qk.next()
end

-- ============================================================
--  sz - obchod pol i szukanie ziol
--  start = pole, na ktorym stoisz przy uruchomieniu
-- ============================================================

local SLOIK_MAX = 16    -- pojemnosc sloika (sztuk ziol); po przekroczeniu powrot na start
local SLOIK_CO = 3      -- co ile pol wykonac komende "sloik"
local SZ_DELAY_MIN = 1  -- losowy postoj po skonczonym szukaniu (sekundy)
local SZ_DELAY_MAX = 3
local SZ_TIMEOUT = 20   -- zapas, gdy linia konca szukania nie przyjdzie
local SZ_MAX_MOVES = 20 -- po tylu ruchach powrot na start
local SOUND = "piano-870218.wav"   -- w getMudletHomeDir()/sounds

-- ---------- dzwiek ----------
function sz.sound_start()
    local path = getMudletHomeDir() .. "/sounds/" .. SOUND
    if not lfs.attributes(path) then
        return log("sz", "<DimGrey>brak pliku dzwieku " .. path)
    end
    stopSounds()
    playSoundFile(path)
end

-- ---------- sterowanie ----------
function sz.stop(msg)
    for _, id in ipairs(sz.handlers or {}) do killAnonymousEventHandler(id) end
    sz.handlers = nil
    sz.sloik_pending = nil
    sz.clear_search()
    sz.clear_sloik()
    sz.clear_check()
    if msg then log("sz", msg) end
end

function sz.go(id)
    if amap.walker then amap:terminate_walker() end
    expandAlias("/idz " .. id, false)
end

-- konczy chodzenie i od razu wraca na start
function sz.home(msg)
    sz.stop(msg .. ", wracam na " .. sz.start)
    stopSounds()
    if tostring(amap.curr.id) ~= sz.start then
        sz.go(sz.start)
    elseif amap.walker then
        amap:terminate_walker()
    end
end

-- nastepne pole z listy (w kolko), pomijajac to, na ktorym stoimy
function sz.next()
    if not sz.handlers then return end
    if sz.moves >= SZ_MAX_MOVES then
        return sz.home("<green>limit " .. SZ_MAX_MOVES .. " ruchow")
    end
    for _ = 1, #sz.poles do
        sz.index = sz.index % #sz.poles + 1
        local id = sz.poles[sz.index]
        if tostring(amap.curr.id) ~= id then
            sz.moves = sz.moves + 1
            log("sz", "<DimGrey>ruch " .. sz.moves .. "/" .. SZ_MAX_MOVES .. " -> " .. id)
            return sz.go(id)
        end
    end
    sz.home("<tomato>brak innego pola")
end

-- ---------- sloik ----------
local SLOIK_SEQ = 3.5   -- czas sekwencji otworz/wloz/zamknij, po niej liczymy ziola
local SLOIK_READ_TIMEOUT = 5   -- zapas na odczyt "ob sloik"

function sz.clear_sloik()
    for _, id in ipairs(sz.sloik_triggers or {}) do killTrigger(id) end
    sz.sloik_triggers = nil
    sz.ob_buf = nil
end

function sz.clear_check()
    if sz.check_timer then killTimer(sz.check_timer); sz.check_timer = nil end
    sz.check_after = nil
end

-- "Rozdeta aromatyczna lodyga jest zbyt ciezka." = sloik nie przyjmie wiecej
function sz.watch_overflow()
    sz.clear_sloik()
    sz.sloik_triggers = {
        tempRegexTrigger("jest zbyt ci", function()
            sz.home("<red>sloik pelny (ziolo zbyt ciezkie)")
        end),
        -- "Jestes teraz zajety czyms innym." - powtorz po skonczonej czynnosci
        tempRegexTrigger("[Jj]estes teraz zajety", function()
            sz.sloik_pending = true
            log("sloik", "<DimGrey>postac zajeta, powtorze po czynnosci")
        end),
    }
end

-- lista zawartosci: "... zawiera a, b, c i d." -> liczba ziol
local function count_herbs(text)
    text = text:gsub("%s+", " "):gsub("%s*%.%s*$", "")
    if text == "" then return 0 end
    local count = 1
    for _ in text:gmatch(",") do count = count + 1 end
    if text:find(" i ", 1, true) then count = count + 1 end
    return count
end

-- koniec liczenia: log, ewentualny powrot, potem kontynuacja (zwykle sz.next)
function sz.report_sloik(count)
    sz.clear_sloik()
    if sz.check_timer then killTimer(sz.check_timer); sz.check_timer = nil end
    local after = sz.check_after
    sz.check_after = nil

    if count then
        log("sz", "<DimGrey>sloik " .. count .. "/" .. SLOIK_MAX .. " ziol")
    else
        log("sz", "<DimGrey>nie odczytalem zawartosci sloika")
    end

    if count and count >= SLOIK_MAX and sz.handlers then
        return sz.home("<red>sloik pelny")
    end
    if after and sz.handlers then after() end
end

-- "ob sloik" -> zlicz ziola z opisu zawartosci (opis bywa lamany na kilka linii);
-- after odpala sie dopiero po odczycie (albo po SLOIK_READ_TIMEOUT), nie rownolegle
function sz.check_sloik(after)
    sz.clear_sloik()
    sz.check_after = after
    if sz.check_timer then killTimer(sz.check_timer) end
    sz.check_timer = tempTimer(SLOIK_READ_TIMEOUT, function()
        sz.check_timer = nil
        sz.report_sloik(nil)
    end)
    sz.sloik_triggers = {
        tempLineTrigger(1, 20, function()
            if not sz.ob_buf then
                local rest = line:match("zawiera (.+)$")
                if rest then
                    sz.ob_buf = rest
                elseif line:lower():find("pusty", 1, true) then
                    return sz.report_sloik(0)
                else
                    return
                end
            else
                sz.ob_buf = sz.ob_buf .. " " .. line
            end
            if sz.ob_buf:find("%.%s*$") then
                sz.report_sloik(count_herbs(sz.ob_buf))
            end
        end)
    }
    send("ob sloik")
end

-- co SLOIK_CO pol: komenda "sloik", odnowienie dzwieku, przeliczenie zawartosci,
-- a dopiero po tym wszystkim kontynuacja (after) - nic nie dzieje sie rownolegle
function sz.sloik(after)
    log("sz", "<orange>sloik (po " .. sz.pola .. " polach)")
    sz.watch_overflow()
    expandAlias("sloik", false)
    sz.sound_start()
    tempTimer(SLOIK_SEQ, function()
        if not sz.handlers then return end
        sz.check_sloik(after)
    end)
end

-- ---------- zbieranie ----------
-- koniec szukania:
--   "Znajdujesz kolczasta wysuszona rosline."
--   "Nie znajdujesz zadnych ziol."
--   "Szukasz wszedzie, ale nie znajdujesz zadnych ziol."
local search_end = {
    "^Znajdujesz ",
    "[Nn]ie znajdujesz",
}

-- "Zaczynasz szukac ziol." - dopoki trwa, gra nie przyjmie innych komend
local search_start = "[Zz]aczynasz szukac zi"

function sz.clear_search()
    for _, id in ipairs(sz.search_triggers or {}) do killTrigger(id) end
    sz.search_triggers = nil
    sz.searching = nil
    if sz.timer then killTimer(sz.timer); sz.timer = nil end
end

-- koniec szukania: sprzatnij triggery i odpal sloik, jesli czekal na ten moment
function sz.search_done()
    sz.clear_search()
    if sz.sloik_pending then
        sz.sloik_pending = nil
        scripts.helper.run_sloik()
    end
end

-- done - co zrobic po linii konca szukania (domyslnie: postoj i ruch dalej)
function sz.szukaj(done)
    done = done or sz.searched
    sz.clear_search()
    log("sz", "<green>szukam ziol")
    sz.searching = true
    sz.search_triggers = {}
    for _, pattern in ipairs(search_end) do
        table.insert(sz.search_triggers, tempRegexTrigger(pattern, function()
            sz.searching = nil
            done()
        end))
    end
    -- zapas: przedluzany, dopoki trwa szukanie (linia konca moglaby zginac w gagu)
    local function guard()
        sz.timer = tempTimer(SZ_TIMEOUT, function()
            sz.timer = nil
            if sz.searching then return guard() end
            done()
        end)
    end
    guard()
    send("szukaj ziol")
end

-- po skonczonym szukaniu: losowy postoj, potem sloik (co SLOIK_CO pol) i ruch dalej
function sz.searched()
    if not sz.handlers then return end
    sz.search_done()
    local delay = SZ_DELAY_MIN + math.random() * (SZ_DELAY_MAX - SZ_DELAY_MIN)
    sz.timer = tempTimer(delay, function()
        sz.timer = nil
        if not sz.handlers then return end
        if sz.pola % SLOIK_CO == 0 then
            sz.sloik(sz.next)   -- ruch dopiero po sloiku i przeliczeniu
        else
            sz.next()
        end
    end)
end

-- po dojsciu na pole: szukaj ziol (ruch dalej dopiero po znalezieniu/pudle)
function sz.arrived()
    if not sz.handlers then return end
    sz.pola = sz.pola + 1
    sz.szukaj()
end

function sz.start_alias(args)
    sz.stop()

    -- bez parametrow: samo szukanie na biezacej lokacji, bez obchodu;
    -- dzwiek gra do konca szukania
    if not args then
        sz.sound_start()
        sz.szukaj(function()
            sz.search_done()
            stopSounds()
        end)
        return
    end

    if args == "stop" then
        if amap.walker then amap:terminate_walker() end
        stopSounds()
        log("sz", "<tomato>przerwane")
        return
    end

    if not amap.curr.id or amap.curr.id == -1 then
        log("sz", "<tomato>nie znam aktualnej lokacji")
        return
    end

    local ids = {}
    for id in args:gmatch("%d+") do table.insert(ids, id) end
    if #ids < 1 then
        log("sz", "<tomato>uzycie: /sz [<pole-id> ...] | /sz stop")
        return
    end

    sz.start = tostring(amap.curr.id)
    sz.poles = ids
    sz.index = 0
    sz.moves = 0
    sz.pola = 0
    sz.handlers = {
        registerAnonymousEventHandler("amapWalkerFinished", sz.arrived),
    }

    log("sz", "<green>start " .. sz.start .. ", pola: " .. table.concat(sz.poles, " "))
    sz.sound_start()
    sz.check_sloik(sz.next)   -- pierwszy ruch dopiero po odczycie zawartosci
end

-- ============================================================
--  rec - nagrywanie odwiedzonych lokacji (lista id do /qk, /sz)
-- ============================================================

-- zapisuje ID, pomijajac powtorzenie ostatniego (np. ponowne ustawienie lokacji)
function rec.add(id)
    id = tonumber(id)
    if not id or id == -1 or rec.ids[#rec.ids] == id then return end
    table.insert(rec.ids, id)
end

function rec.start_alias(args)
    if args == "print" then
        log("rec", #rec.ids .. " lokacji: " .. table.concat(rec.ids, " "))
        return
    end

    if rec.handler then killAnonymousEventHandler(rec.handler); rec.handler = nil end
    rec.ids = {}

    if args == "stop" then
        log("rec", "<tomato>nagrywanie zakonczone, bufor wyczyszczony")
        return
    end

    rec.add(amap.curr.id)
    rec.handler = registerAnonymousEventHandler("amapNewLocation", function(_, id) rec.add(id) end)
    log("rec", "<green>nowy bufor")
end

-- ============================================================
--  sloik - przelozenie zebranych ziol do sloika
-- ============================================================

function scripts.helper.run_sloik()
    send("otworz sloik")
    tempTimer(1.5, function() send("wloz ziola do sloika") end)
    tempTimer(2.1, function() send("zamknij sloik") end)
end

-- w trakcie "szukaj ziol" sloik czeka na linie konca szukania
function scripts.helper.sloik_alias()
    if sz.searching then
        sz.sloik_pending = true
        log("sloik", "<DimGrey>czekam na koniec szukania ziol")
        return
    end
    scripts.helper.run_sloik()
end

-- ============================================================

local aliases = {
    ["^/qk (.+)$"] = function() qk.start_alias(matches[2]) end,
    ["^/sz(?: (.+))?$"] = function() sz.start_alias(matches[2]) end,
    ["^/rec(?: (print|stop))?$"] = function() rec.start_alias(matches[2]) end,
    ["^sloik$"] = function() scripts.helper.sloik_alias() end,
}

function scripts.helper:init()
    self.triggers = self.triggers or {}
    for _, id in ipairs(self.aliases) do killAlias(id) end
    for _, id in ipairs(self.triggers) do killTrigger(id) end
    self.aliases, self.triggers = {}, {}

    -- stan czynnosci "szukaj ziol" - takze dla recznego szukania
    table.insert(self.triggers, tempRegexTrigger(search_start, function() sz.searching = true end))
    for _, pattern in ipairs(search_end) do
        table.insert(self.triggers, tempRegexTrigger(pattern, function()
            sz.searching = nil
            if sz.sloik_pending then
                sz.sloik_pending = nil
                scripts.helper.run_sloik()
            end
        end))
    end

    for regex, callback in pairs(aliases) do
        table.insert(self.aliases, tempAlias(regex, callback))
    end
end

scripts.helper:init()
