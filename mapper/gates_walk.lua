-- ============================================================
--  gates_walk - /gnaj: /idz, ktory stuka w brame przed przejsciem
--
--  Brama = krok miedzy dwoma pokojami oznaczonymi jako brama (userData
--  "gate" lub amap.id_to_open_gate). Przed takim krokiem chodzik stuka,
--  czeka 1-3 s i idzie dalej. Bez zmian w walker.lua: opakowanie
--  amap:auto_walker, pauza w amap.walker_timer_id (kasuje ja /stop i blokery).
--  Brama nieoznaczona: po odbiciu stuka i wznawia /gnaj (gw:gate_stopped).
--
--  /gnaj przyjmuje kilka celow (punkty trasy): "/gnaj 7640 7615 8122".
--
--  Opoznienie kroku jest zawsze dynamiczne - przed kazdym krokiem chodzik
--  czyta ZME (zmeczenie z #footer.main) i sam dobiera tempo (gw:step_delay).
--  Opoznienie na koncu komendy ("/gnaj 7640 4") jest przyjmowane dla zgodnosci
--  ze starymi wywolaniami (m.in. /podroz), ale ignorowane.
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
--  ZME (scripts.character.state.fatigue, 0-9, rosnie z wyczerpaniem) -> opoznienie
local fatigue_to_delay = {
    [0] = 0.5,
    [1] = 0.5,
    [2] = 0.5,
    [3] = 2,
    [4] = 3,
    [5] = 6,
    [6] = 7,
    [7] = 9,
    [8] = 12,
    [9] = 20,
}

-- nil, gdy nie znamy jeszcze ZME (brak gmcp) - wtedy zostaje opoznienie z /opoz
function gw:step_delay()
    local state = scripts and scripts.character and scripts.character.state
    local level = state and tonumber(state.fatigue)
    if not level or level < 0 then return nil end
    level = math.floor(level)
    if level > 9 then level = 9 end
    return fatigue_to_delay[level], level
end

-- przed krokiem: opoznienie na nastepny takt (walker_delay czyta kazdy takt);
-- log tylko przy zmianie wartosci
function gw:apply_step_delay()
    local delay, level = self:step_delay()
    if not delay or delay == amap.walker_delay then return end
    amap.walker_delay = delay
    amap:print_log(string.format("ZME %d - opoznienie chodzika %s", level, tostring(delay)))
end

-- opakowanie raz, odporne na przeladowanie pliku
if not gw.original then gw.original = amap.auto_walker end
function amap:auto_walker()
    if amap.walker_gates then
        gw:apply_step_delay()
        if gw:before_step() then return end
    end
    return gw.original(self)
end

function gw:reset()
    if amap.walker_gates then self.stopped_at = getEpoch() end
    amap.walker_gates = false
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
        gw:go(tostring(walk.dest), true)
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

-- ostatnia liczba to ignorowane opoznienie ("/gnaj 7640 4"), chyba ze wyglada
-- na lokacje: calkowita, co najmniej delay_limit i istniejaca na mapie
-- ("/gnaj 7640 7615" to dwa punkty trasy)
local function parse_args(text)
    -- "#etykieta" do konca linii to opis po stronie klienta, nie cel
    text = text:gsub("%s+#.*$", "")
    local targets = {}
    for word in string.gmatch(text, "%S+") do table.insert(targets, word) end
    if #targets < 2 then return targets end
    local last = targets[#targets]
    local number = tonumber(last)
    local looks_like_room = number and last:match("^%d+$")
        and number >= delay_limit and roomExists(number)
    if number and not looks_like_room then
        table.remove(targets)
    end
    return targets
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

-- /gnaj <id|skrot>
function gw:go(target, resume)
    if amap.walker then
        local room = resolve_room(target)
        if room and self:walking_to(room) then
            amap:print_log("Chodzik juz tam idzie, tempo i tak jedzie na ZME")
            return true
        end
        amap:print_log("Chodzik aktualnie pracuje, najpierw zastopuj uzywajac '/stop'")
        return false
    end
    if self.start_timer then killTimer(self.start_timer); self.start_timer = nil end
    if self.queue_cancel then killTimer(self.queue_cancel); self.queue_cancel = nil end

    local room = resolve_room(target)
    if not room then
        amap:print_log("Nie znam lokacji ani skrotu: " .. target)
        return false
    end
    if not amap.curr.id or amap.curr.id == -1 or not getPath(amap.curr.id, room) then
        amap:print_log("Nie ma polaczenia z aktualnej lokacji do docelowej")
        return false
    end

    if not resume then self.walk = { dest = room, knocked = {} } end
    -- kroki razy opoznienie chodzika (bez przerw na bramy)
    local steps = #speedWalkPath
    local seconds = math.floor(steps * (self:step_delay() or amap.walker_delay or 0) + 0.5)
    amap:print_log(string.format("/gnaj %d: %d krokow, %d:%02dm", room, steps, math.floor(seconds / 60), seconds % 60))
    local start = amap.curr.id
    self.path = { [0] = start }
    for i, id in ipairs(speedWalkPath) do self.path[i] = tonumber(id) end
    self.knocked = nil

    local run = function()
        gw.start_timer = nil
        gw.pending_dest = room
        -- po pauzie na brame ZME moze byc inne niz przy wywolaniu /gnaj
        amap:speedwalk_from_id(tostring(room), gw:step_delay())
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
    if not self:go(target) then self.queue = nil end
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
        local targets = parse_args(matches[2])
        -- powtorzony /gnaj w trakcie chodzika nie przerywa marszu
        if amap.walker then return gw:go(targets[1]) end
        if gw.queue_timer then killTimer(gw.queue_timer); gw.queue_timer = nil end
        gw.queue = { targets = targets, index = 0 }
        gw:next_leg()
    end)
end

gw:init()
