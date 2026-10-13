-- ============================================================
--  gates_walk - /gnaj: /idz, ktory stuka w brame przed przejsciem
--
--  Brama = krok miedzy dwoma pokojami oznaczonymi jako brama (userData
--  "gate" lub amap.id_to_open_gate). Przed takim krokiem chodzik stuka,
--  czeka 1-3 s i idzie dalej. Bez zmian w walker.lua: opakowanie
--  amap:auto_walker, pauza w amap.walker_timer_id (kasuje ja /stop i blokery).
--  Brama nieoznaczona: po odbiciu stuka i wznawia /gnaj (gw:gate_stopped).
--
--  /gnaj przyjmuje kilka celow (punkty trasy) i opoznienie na koncu:
--  "/gnaj 7640 7615 8122 3". Powtorzony /gnaj do celu, do ktorego chodzik
--  wlasnie idzie, tylko zmienia opoznienie (jak /opoz).
--
--  Bez podanego opoznienia chodzik idzie dynamicznie: przed kazdym krokiem
--  czyta ZME (zmeczenie z #footer.main) i ustawia opoznienie z mapowania
--  fatigue_to_delay. Podane opoznienie wylacza dynamike na ten chodzik.
-- ============================================================

amap.gates_walk = amap.gates_walk or {}
local gw = amap.gates_walk

local pause_min, pause_max = 1, 3
local delay_limit = 100      -- liczba ponizej tej wartosci to opoznienie, nie lokacja
local leg_retry = 0.5        -- czekanie na potwierdzenie lokacji przed nastepnym etapem
local leg_tries = 10

local function gate_cmd(room)
    local cmd = getRoomUserData(room, "gate")
    if cmd and cmd ~= "" then return cmd end
    return amap.id_to_open_gate[room]
end

-- komenda otwarcia, jesli krok from -> to przechodzi przez brame
function gw:gate_between(from, to)
    if not from or not to then return nil end
    local cmd = gate_cmd(from)
    if cmd and gate_cmd(to) then return cmd end
    return nil
end

local function pause()
    return pause_min + math.random() * (pause_max - pause_min)
end

function gw:knock(cmd, callback)
    local delay = pause()
    amap:print_log(string.format("brama - %s, dalej za %.1f s", cmd, delay))
    send(cmd, true)
    return tempTimer(delay, callback)
end

-- krok, ktory zaraz pojdzie: path[current_index] -> path[current_index + 1]
function gw:before_step()
    local next_index = (amap.current_index or 0) + 1
    if not self.path or self.knocked == next_index then return false end
    local cmd = self:gate_between(self.path[next_index - 1], self.path[next_index])
    if not cmd then return false end
    self.knocked = next_index
    amap.walker_timer_id = self:knock(cmd, function() gw.original(amap) end)
    return true
end

-- ---------- dynamiczne opoznienie od zmeczenia ----------
--  Model: ZME (scripts.character.state.fatigue, 0-9, rosnie z wyczerpaniem) to
--  zbiornik - krok dolewa c, regeneracja odlewa r na sekunde, wiec przy opoznieniu
--  d poziom zmienia sie o (c - r*d) na krok. Opoznienie break-even d* = c/r trzyma
--  ZME w miejscu, mniejsze podnosi, wieksze obniza. Maksymalizujemy kroki na czas
--  przy twardym warunku ZME < 9 (przy 9 postac przestaje isc, por.
--  scripts.character.break_fatigue_level). Dla monotonicznego stanu z takim
--  ograniczeniem optimum jest bang-bang + luk brzegowy, czyli:
--    1. zryw: ZME w buforze (<= burst_exit) - ograniczenie nieaktywne, idziemy
--       najszybciej jak wolno (d_min) i wydajemy zapas zmeczenia;
--    2. trzymanie: ZME przy setpoincie - opoznienie ~ d*, czyli maksymalna
--       podtrzymywalna predkosc; kazdy poziom nad setpointem to growth razy wolniej;
--    3. odpoczynek: ZME >= rest_level - pauza bez kroku (jak przy bramie), az ZME
--       spadnie pod setpoint; to gwarantuje, ze nie dobijemy do 9 nawet gdy d*
--       jest wieksze od d_max (np. przeciazenie);
--    4. histereza: ZME spadlo do burst_enter - znowu zryw. Profil wychodzi
--       piloksztaltny: krotkie zrywy przeplatane trzymaniem, nie jedna srednia.
--  Na marszu dluzszym od zapasu srednia predkosc i tak dazy do 1/d* (zapas to suma
--  zerowa), ale kazdy marsz krotszy od zapasu konczy sie szybciej - stad zrywy.
--  d* zalezy od postaci, obciazenia i terenu, wiec nie jest wpisane na sztywno:
--  hold_delay uczy sie w marszu (AIMD - mnozymy, gdy ZME ucieklo nad setpoint,
--  odejmujemy po probe_steps krokach bez wzrostu) i zbiega do d*.
local d_min, d_max = 0.5, 20           -- widelki opoznienia kroku
local setpoint = 7                     -- ZME, na ktorym trzymamy marsz (prog 9 z marginesem)
local rest_level = 8                   -- od tego ZME pauza bez kroku
local rest_tick = 5                    -- co ile sekund sprawdzamy ZME w odpoczynku
local burst_exit, burst_enter = 6, 4   -- histereza zrywu: konczymy nad 6, wracamy na 4
local growth = 1.6                     -- ile razy wolniej na kazdy poziom ZME nad setpointem
local hold_init, hold_min, hold_max = 6, 1, 20    -- start i widelki uczonego d*
local hold_up, hold_down = 0.3, 0.3    -- AIMD: mnoznik w gore, odejmowanie w dol
local probe_steps = 5                  -- po tylu krokach bez wzrostu ZME probujemy szybciej
local burst_eta_init = 20              -- zalozona dlugosc zrywu w krokach, dopoki nie zmierzona

gw.hold_delay = gw.hold_delay or hold_init

local function clamp(value, low, high)
    if value < low then return low end
    if value > high then return high end
    return value
end

-- nil, gdy nie znamy jeszcze ZME (brak gmcp) - wtedy zostaje opoznienie z /opoz
local function fatigue_level()
    local state = scripts and scripts.character and scripts.character.state
    local level = state and tonumber(state.fatigue)
    if not level or level < 0 then return nil end
    return clamp(math.floor(level), 0, 9)
end

-- AIMD: ZME nad setpointem = szlismy za szybko (d < d*), mnozymy opoznienie;
-- ZME ponizej albo stabilne = probujemy odjac i isc szybciej
function gw:learn(level)
    if level ~= self.last_level then
        local over = level - setpoint
        if over > 0 then
            gw.hold_delay = clamp(gw.hold_delay * (1 + hold_up * over), hold_min, hold_max)
        elseif over < 0 then
            gw.hold_delay = clamp(gw.hold_delay - hold_down, hold_min, hold_max)
        end
        self.last_level, self.level_steps = level, 0
        return
    end
    self.level_steps = (self.level_steps or 0) + 1
    if level <= setpoint and self.level_steps >= probe_steps then
        self.level_steps = 0
        gw.hold_delay = clamp(gw.hold_delay - hold_down, hold_min, hold_max)
    end
end

-- opoznienie kroku dla biezacego ZME; nil = zostaje opoznienie z /opoz.
-- peek liczy tylko wartosc (podglad do ETA), bez uczenia i bez zmiany histerezy
function gw:step_delay(peek)
    local level = fatigue_level()
    if not level then return nil end
    if self.burst == nil then self.burst = level <= burst_exit end
    if self.burst then
        if level <= burst_exit then
            if not peek then self.burst_count = (self.burst_count or 0) + 1 end
            return d_min, level
        end
        if not peek then
            self.burst = false
            gw.burst_len = ((gw.burst_len or self.burst_count or 0) + (self.burst_count or 0)) / 2
            self.burst_count = nil
        end
    elseif level <= burst_enter then
        if not peek then self.burst, self.burst_count = true, 0 end
        return d_min, level
    end
    if not peek then self:learn(level) end
    return clamp(gw.hold_delay * growth ^ (level - setpoint), d_min, d_max), level
end

-- przed krokiem: opoznienie na nastepny takt (walker_delay czyta kazdy takt);
-- log tylko przy zmianie wartosci
function gw:apply_step_delay()
    if not self.dynamic then return end
    local delay, level = self:step_delay()
    if not delay then return end
    delay = math.floor(delay * 10 + 0.5) / 10
    if delay == amap.walker_delay then return end
    amap.walker_delay = delay
    amap:print_log(string.format("ZME %d - opoznienie chodzika %s%s", level, tostring(delay),
        self.burst and " (zryw)" or ""))
end

-- orientacyjny czas marszu: reszta zrywu po d_min, potem trzymanie po ~d*
-- (dlugosc zrywu jest uczona - gw.burst_len, srednia z ostatnich zrywow)
function gw:eta(steps)
    local now = self:step_delay(true)
    if not now then return nil end
    local burst = 0
    if now <= d_min then burst = clamp(gw.burst_len or burst_eta_init, 0, steps) end
    return burst * d_min + (steps - burst) * math.max(gw.hold_delay, now)
end

-- ZME przy progu: pauza bez kroku (pauza siedzi w amap.walker_timer_id, wiec /stop
-- i blokery ja kasuja), az zmeczenie zejdzie pod setpoint
function gw:rest_pause()
    if not self.dynamic then return false end
    local level = fatigue_level()
    if not level then return false end
    if not self.resting and level < rest_level then return false end
    if level < setpoint then
        self.resting = false
        self.last_level, self.level_steps = nil, nil
        return false
    end
    if not self.resting then
        self.resting = true
        gw.hold_delay = clamp(gw.hold_delay * (1 + hold_up), hold_min, hold_max)
        amap:print_log(string.format("ZME %d - odpoczynek, chodzik ruszy przy ZME %d", level, setpoint - 1))
    end
    amap.walker_timer_id = tempTimer(rest_tick, function()
        if amap.walker then amap:auto_walker() end
    end)
    return true
end

-- opakowanie raz, odporne na przeladowanie pliku
if not gw.original then gw.original = amap.auto_walker end
function amap:auto_walker()
    if amap.walker_gates then
        if gw:rest_pause() then return end
        gw:apply_step_delay()
        if gw:before_step() then return end
    end
    return gw.original(self)
end

function gw:reset()
    if amap.walker_gates then self.stopped_at = getEpoch() end
    amap.walker_gates = false
    self.resting = false
    self.path, self.knocked, self.pending_dest = nil, nil, nil
end

-- brama bez oznaczenia na mapie: walker staje na "Probujesz otworzyc ...",
-- bloker cofa i przerywa. Wtedy stukamy (amap.gate_bind z mapper/gates.lua)
-- i ruszamy /gnaj do tego samego celu - raz na lokacje. Trigger bramy
-- bywa przed albo po przerwaniu (amapGateStoppedWalker / amapGateStopped),
-- stad okno czasu po przerwaniu i odlozone wznowienie.
function gw:gate_stopped()
    if not self.walk then return end
    local recent = self.stopped_at and getEpoch() - self.stopped_at < 1
    if not (amap.walker_gates or recent) then return end
    if self.resume_timer then return end
    self.resume_timer = tempTimer(0.5, function() gw:resume() end)
end

function gw:resume()
    self.resume_timer = nil
    local walk = self.walk
    if not walk or amap.walker then return end
    local room = amap.curr.id
    if walk.knocked[room] then
        amap:print_log("brama nadal zamknieta - /gnaj " .. walk.dest .. " wstrzymane")
        self.walk = nil
        return
    end
    walk.knocked[room] = true
    self.start_timer = self:knock(amap.gate_bind or "zastukaj we wrota", function()
        gw.start_timer = nil
        gw:go(tostring(walk.dest), walk.delay, true)
    end)
end

-- flaga dopiero, gdy chodzik naprawde ruszyl do celu z /gnaj
function gw:started()
    amap.walker_gates = self.pending_dest ~= nil and self.pending_dest == tonumber(amap.walker_dest)
    self.pending_dest = nil
end

local function resolve_room(target)
    local room = target:match("^%d+$") and target
        or (target:match("^i[0-9a-z]+$") and amap.internal_to_mudlet_id[target])
        or amap.shortcuts:get_room_by_name(target)
    return tonumber(room)
end

-- ostatnia liczba to opoznienie (jak dotad: "/gnaj 7640 4"), chyba ze wyglada
-- na lokacje: calkowita, co najmniej delay_limit i istniejaca na mapie
-- ("/gnaj 7640 7615" to dwa punkty trasy)
local function parse_args(text)
    local targets = {}
    for word in string.gmatch(text, "%S+") do table.insert(targets, word) end
    if #targets < 2 then return targets, nil end
    local last = targets[#targets]
    local number = tonumber(last)
    local looks_like_room = number and last:match("^%d+$")
        and number >= delay_limit and roomExists(number)
    if number and not looks_like_room then
        table.remove(targets)
        return targets, last
    end
    return targets, nil
end

-- cel, do ktorego chodzik wlasnie idzie, albo dalszy punkt biezacej trasy
function gw:walking_to(room)
    if room == tonumber(amap.walker_dest) then return true end
    local queue = self.queue
    for i = (queue and queue.index or 0) + 1, queue and #queue.targets or 0 do
        if room == resolve_room(queue.targets[i]) then return true end
    end
    return false
end

-- opoznienie dziala od nastepnego kroku (walker_delay czyta kazdy takt);
-- bez zmiany /opoz, czyli domyslnego amap.set_walker_delay
function gw:set_delay(delay)
    self.dynamic = false
    amap.walker_delay = delay
    if self.walk then self.walk.delay = tostring(delay) end
    if self.queue then self.queue.delay = tostring(delay) end
    amap:print_log("Zmienilem opoznienie chodzika do " .. tostring(delay))
end

-- /gnaj <id|skrot> [opoznienie]
function gw:go(target, delay, resume)
    if amap.walker then
        local room, new_delay = resolve_room(target), tonumber(delay)
        if room and new_delay and self:walking_to(room) then
            self:set_delay(new_delay)
            return true
        end
        amap:print_log("Chodzik aktualnie pracuje, najpierw zastopuj uzywajac '/stop'")
        return false
    end
    if self.start_timer then killTimer(self.start_timer); self.start_timer = nil end
    if self.queue_cancel then killTimer(self.queue_cancel); self.queue_cancel = nil end

    if delay == "" then delay = nil end
    local room = resolve_room(target)
    if not room then
        amap:print_log("Nie znam lokacji ani skrotu: " .. target)
        return false
    end
    if not amap.curr.id or amap.curr.id == -1 or not getPath(amap.curr.id, room) then
        amap:print_log("Nie ma polaczenia z aktualnej lokacji do docelowej")
        return false
    end

    if not resume then self.walk = { dest = room, delay = delay, knocked = {} } end
    -- bez podanego opoznienia chodzik jedzie na ZME (gw:apply_step_delay)
    self.dynamic = delay == nil
    if self.dynamic and not resume then self.burst, self.last_level, self.resting = nil, nil, false end
    local start_delay = delay
    if self.dynamic then start_delay = self:step_delay(true) end
    -- orientacyjny czas (bez przerw na bramy i na odpoczynek)
    local steps = #speedWalkPath
    local seconds = self.dynamic and self:eta(steps)
        or steps * (tonumber(start_delay) or amap.walker_delay or 0)
    seconds = math.floor((seconds or steps * (amap.walker_delay or 0)) + 0.5)
    amap:print_log(string.format("/gnaj %d: %d krokow, %d:%02dm", room, steps, math.floor(seconds / 60), seconds % 60))
    local start = amap.curr.id
    self.path = { [0] = start }
    for i, id in ipairs(speedWalkPath) do self.path[i] = tonumber(id) end
    self.knocked = nil

    local run = function()
        gw.start_timer = nil
        gw.pending_dest = room
        -- po pauzie na brame ZME moze byc inne niz przy wywolaniu /gnaj
        amap:speedwalk_from_id(tostring(room), gw.dynamic and gw:step_delay(true) or delay)
    end
    -- pierwszy krok idzie z doSpeedWalk, nie z auto_walker
    local cmd = self:gate_between(start, self.path[1])
    if cmd then
        self.knocked = 1
        self.start_timer = self:knock(cmd, run)
    else
        run()
    end
    return true
end

-- ---------- punkty trasy ----------
function gw:next_leg()
    local queue = self.queue
    if not queue then return end
    queue.index = queue.index + 1
    local target = queue.targets[queue.index]
    if not target then
        self.queue = nil
        return
    end
    if #queue.targets > 1 then
        amap:print_log(string.format("/gnaj etap %d/%d: %s", queue.index, #queue.targets, target))
    end
    if not self:go(target, queue.delay) then self.queue = nil end
end

-- nastepny etap startuje po potwierdzeniu lokacji: amapWalkerFinished leci
-- czesto przed aktualizacja amap.curr przez mapper
function gw:queue_next(from_room)
    local queue = self.queue
    if not queue or queue.index >= #queue.targets then
        self.queue = nil
        return
    end
    local tries = 0
    local function start()
        gw.queue_timer = nil
        if gw.queue ~= queue or amap.walker then return end
        tries = tries + 1
        if from_room and tonumber(amap.curr.id) ~= from_room and tries < leg_tries then
            gw.queue_timer = tempTimer(leg_retry, start)
            return
        end
        gw:next_leg()
    end
    self.queue_timer = tempTimer(leg_retry, start)
end

-- przerwany chodzik konczy trase, ale stukanie w nieoznaczona brame wznawia
-- /gnaj (gw:resume) - stad odlozone kasowanie i test tozsamosci kolejki
function gw:queue_terminated()
    local queue = self.queue
    if not queue then return end
    if self.queue_cancel then killTimer(self.queue_cancel) end
    self.queue_cancel = tempTimer(5, function()
        gw.queue_cancel = nil
        if gw.queue == queue then gw.queue = nil end
    end)
end

function gw:init()
    self.handler_started = scripts.event_register:force_register_event_handler(self.handler_started,
        "amapWalkerStarted", function() gw:started() end)
    self.handler_finished = scripts.event_register:force_register_event_handler(self.handler_finished,
        "amapWalkerFinished", function()
            local dest = gw.walk and gw.walk.dest
            gw:reset()
            gw.walk = nil
            gw:queue_next(dest)
        end)
    self.handler_terminated = scripts.event_register:force_register_event_handler(self.handler_terminated,
        "amapWalkerTerminated", function() gw:reset(); gw:queue_terminated() end)
    self.handler_gate = scripts.event_register:force_register_event_handler(self.handler_gate,
        "amapGateStoppedWalker", function() gw:gate_stopped() end)
    self.handler_gate_idle = scripts.event_register:force_register_event_handler(self.handler_gate_idle,
        "amapGateStopped", function() gw:gate_stopped() end)
    if self.alias then killAlias(self.alias) end
    self.alias = tempAlias("^/gnaj\\s+(\\S+(?:\\s+\\S+)*)$", function()
        local targets, delay = parse_args(matches[2])
        -- powtorzony /gnaj w trakcie chodzika: tylko opoznienie, bez nowej trasy
        if amap.walker then return gw:go(targets[1], delay) end
        if gw.queue_timer then killTimer(gw.queue_timer); gw.queue_timer = nil end
        gw.queue = { targets = targets, index = 0, delay = delay }
        gw:next_leg()
    end)
end

gw:init()
