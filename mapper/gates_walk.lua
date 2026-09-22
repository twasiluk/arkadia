-- ============================================================
--  gates_walk - /gnaj: /idz, ktory stuka w brame przed przejsciem
--
--  Brama = krok miedzy dwoma pokojami oznaczonymi jako brama (userData
--  "gate" lub amap.id_to_open_gate). Przed takim krokiem chodzik stuka,
--  czeka 1-3 s i idzie dalej. Bez zmian w walker.lua: opakowanie
--  amap:auto_walker, pauza w amap.walker_timer_id (kasuje ja /stop i blokery).
--  Brama nieoznaczona: po odbiciu stuka i wznawia /gnaj (gw:gate_stopped).
-- ============================================================

amap.gates_walk = amap.gates_walk or {}
local gw = amap.gates_walk

local pause_min, pause_max = 1, 3

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

-- opakowanie raz, odporne na przeladowanie pliku
if not gw.original then gw.original = amap.auto_walker end
function amap:auto_walker()
    if amap.walker_gates and gw:before_step() then return end
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
        gw:go(tostring(walk.dest), walk.delay, true)
    end)
end

-- flaga dopiero, gdy chodzik naprawde ruszyl do celu z /gnaj
function gw:started()
    amap.walker_gates = self.pending_dest ~= nil and self.pending_dest == tonumber(amap.walker_dest)
    self.pending_dest = nil
end

-- /gnaj <id|skrot> [opoznienie]
function gw:go(target, delay, resume)
    if amap.walker then
        amap:print_log("Chodzik aktualnie pracuje, najpierw zastopuj uzywajac '/stop'")
        return
    end
    if self.start_timer then killTimer(self.start_timer); self.start_timer = nil end

    if delay == "" then delay = nil end
    local room = target:match("^%d+$") and target
        or (target:match("^i[0-9a-z]+$") and amap.internal_to_mudlet_id[target])
        or amap.shortcuts:get_room_by_name(target)
    room = tonumber(room)
    if not room then
        amap:print_log("Nie znam lokacji ani skrotu: " .. target)
        return
    end
    if not amap.curr.id or amap.curr.id == -1 or not getPath(amap.curr.id, room) then
        amap:print_log("Nie ma polaczenia z aktualnej lokacji do docelowej")
        return
    end

    if not resume then self.walk = { dest = room, delay = delay, knocked = {} } end
    -- kroki razy opoznienie chodzika (bez przerw na bramy)
    local steps = #speedWalkPath
    local seconds = math.floor(steps * (tonumber(delay) or amap.walker_delay or 0) + 0.5)
    amap:print_log(string.format("/gnaj %d: %d krokow, %d:%02ds", room, steps, math.floor(seconds / 60), seconds % 60))
    local start = amap.curr.id
    self.path = { [0] = start }
    for i, id in ipairs(speedWalkPath) do self.path[i] = tonumber(id) end
    self.knocked = nil

    local run = function()
        gw.start_timer = nil
        gw.pending_dest = room
        amap:speedwalk_from_id(tostring(room), delay)
    end
    -- pierwszy krok idzie z doSpeedWalk, nie z auto_walker
    local cmd = self:gate_between(start, self.path[1])
    if cmd then
        self.knocked = 1
        self.start_timer = self:knock(cmd, run)
    else
        run()
    end
end

function gw:init()
    self.handler_started = scripts.event_register:force_register_event_handler(self.handler_started,
        "amapWalkerStarted", function() gw:started() end)
    self.handler_finished = scripts.event_register:force_register_event_handler(self.handler_finished,
        "amapWalkerFinished", function() gw:reset(); gw.walk = nil end)
    self.handler_terminated = scripts.event_register:force_register_event_handler(self.handler_terminated,
        "amapWalkerTerminated", function() gw:reset() end)
    self.handler_gate = scripts.event_register:force_register_event_handler(self.handler_gate,
        "amapGateStoppedWalker", function() gw:gate_stopped() end)
    self.handler_gate_idle = scripts.event_register:force_register_event_handler(self.handler_gate_idle,
        "amapGateStopped", function() gw:gate_stopped() end)
    if self.alias then killAlias(self.alias) end
    self.alias = tempAlias("^/gnaj (\\S+)(?: (\\d+|\\d+\\.\\d+))?$", function()
        gw:go(matches[2], matches[3])
    end)
end

gw:init()
