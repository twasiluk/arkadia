-- ============================================================
--  /qm - kolejka zadan (FIFO). Zadanie = komenda (alias lub komenda
--  gry) wykonywana przez expandAlias; nastepne rusza, gdy poprzednie
--  sie skonczy, plus opoznienie (/qm delay).
--
--  Koniec zadania: po wyslaniu komendy i start_grace sekund kolejka co
--  poll_interval sprawdza, czy cos jeszcze pracuje (busy): chodzik,
--  trasa /gnaj, /podroz, /kurier. Dwa kolejne odczyty "wolne" = koniec.
--  Komenda gry bez skryptu konczy sie wiec po start_grace.
--  Kolejka i opoznienie zapamietane miedzy sesjami (state_store).
-- ============================================================

scripts.qm = scripts.qm or {
    aliases = {},
}

local qm = scripts.qm

local store_key = "qm"
local start_grace = 1.5   -- czas na rozruch skryptu po wyslaniu komendy
local poll_interval = 0.5
local idle_polls = 2      -- tyle kolejnych odczytow "wolne" = koniec zadania

local function print_log(msg)
    cecho("\n<CadetBlue>(qm)<reset>: " .. msg .. "\n")
end

-- ---------- stan ----------
function qm:load()
    local stored = scripts.state_store:get(store_key)
    stored = type(stored) == "table" and stored or {}
    self.tasks = type(stored.tasks) == "table" and stored.tasks or {}
    self.next_id = tonumber(stored.next_id) or 1
    self.delay = tonumber(stored.delay) or 0
end

function qm:save()
    scripts.state_store:set(store_key, {
        tasks = self.tasks,
        next_id = self.next_id,
        delay = self.delay,
    })
end

local function find_index(id)
    id = tonumber(id)
    for index, task in ipairs(qm.tasks) do
        if task.id == id then return index end
    end
end

-- ---------- co pracuje ----------
-- powod zajetosci (do /qm list) albo nil
function qm:busy()
    if amap and amap.walker then return "chodzik" end
    if amap and amap.gates_walk and amap.gates_walk.queue then return "/gnaj" end
    local podroz = scripts.podroz
    if podroz and (podroz.target or podroz.pending_legs or podroz.next_on_walk
        or podroz.wait_triggers) then
        return "/podroz"
    end
    if scripts.kurier and scripts.kurier.running then return "/kurier" end
    return nil
end

-- ---------- wykonanie ----------
function qm:clear_timer()
    if self.timer then killTimer(self.timer); self.timer = nil end
end

-- zdejmuje pierwsze zadanie i wykonuje je; po koncu: on_done()
function qm:run_task(on_done)
    local task = table.remove(self.tasks, 1)
    self:save()
    self.current = task
    print_log("<green>" .. task.id .. ": " .. task.cmd)
    expandAlias(task.cmd, true)

    local idle = 0
    local function poll()
        qm.timer = nil
        if qm.current ~= task then return end
        if qm:busy() then
            idle = 0
        else
            idle = idle + 1
            if idle >= idle_polls then
                qm.current = nil
                print_log("<DimGrey>" .. task.id .. " zakonczone")
                return on_done and on_done()
            end
        end
        qm.timer = tempTimer(poll_interval, poll)
    end
    self.timer = tempTimer(start_grace, poll)
end

function qm:step()
    if not self.running then return end
    if #self.tasks == 0 then
        self.running = nil
        return print_log("<green>kolejka pusta, koniec")
    end
    self:run_task(function()
        if not qm.running then return end
        if qm.delay > 0 and #qm.tasks > 0 then
            print_log(string.format("<DimGrey>nastepne za %g s", qm.delay))
            qm.timer = tempTimer(qm.delay, function()
                qm.timer = nil
                qm:step()
            end)
        else
            qm:step()
        end
    end)
end

-- ---------- komendy ----------
function qm:list()
    local state = self.running and "<green>dziala" or "<DimGrey>zatrzymana"
    local busy = self:busy()
    print_log(string.format("%s<reset>, opoznienie %g s%s", state, self.delay,
        busy and ("<DimGrey>, pracuje: " .. busy) or ""))
    if self.current then
        cecho(string.format("  <yellow>> %d<reset> %s\n", self.current.id, self.current.cmd))
    end
    if #self.tasks == 0 then
        return cecho("  <DimGrey>(pusta)\n")
    end
    for index, task in ipairs(self.tasks) do
        cecho(string.format("  <DimGrey>%d.<reset> <LightSkyBlue>%d<reset> ", index, task.id))
        echo(task.cmd .. "\n")
    end
end

function qm:push(cmd)
    cmd = string.trim(cmd or "")
    if cmd == "" then return print_log("<tomato>/qm push <komenda>") end
    local task = { id = self.next_id, cmd = cmd }
    self.next_id = self.next_id + 1
    table.insert(self.tasks, task)
    self:save()
    print_log(string.format("dodane %d: %s <DimGrey>(pozycja %d)", task.id, cmd, #self.tasks))
end

-- pop: zdejmuje pierwsze zadanie i wykonuje je jednorazowo (bez kolejnych)
function qm:pop()
    if self.running or self.current then
        return print_log("<tomato>kolejka dziala (/qm stop)")
    end
    if #self.tasks == 0 then return print_log("<DimGrey>kolejka pusta") end
    self:run_task()
end

function qm:show_next()
    local task = self.tasks[1]
    if not task then return print_log("<DimGrey>kolejka pusta") end
    print_log(string.format("nastepne: <LightSkyBlue>%d<reset> %s", task.id, task.cmd))
end

function qm:move(id, shift)
    local index = find_index(id)
    if not index then return print_log("<tomato>brak zadania " .. tostring(id)) end
    local target = index + shift
    if target < 1 or target > #self.tasks then
        return print_log("<DimGrey>zadanie " .. id .. " juz na " .. (shift < 0 and "poczatku" or "koncu"))
    end
    self.tasks[index], self.tasks[target] = self.tasks[target], self.tasks[index]
    self:save()
    self:list()
end

-- id zadania albo fragment komendy (bez wielkosci liter, wszystkie pasujace)
function qm:remove(what)
    what = string.trim(what or "")
    if what == "" then return print_log("<tomato>/qm rm <id|fragment komendy>") end
    local index = what:match("^%d+$") and find_index(what)
    local removed = {}
    if index then
        table.insert(removed, table.remove(self.tasks, index))
    else
        local needle = string.lower(what)
        for i = #self.tasks, 1, -1 do
            if string.find(string.lower(self.tasks[i].cmd), needle, 1, true) then
                table.insert(removed, 1, table.remove(self.tasks, i))
            end
        end
    end
    if #removed == 0 then return print_log("<tomato>brak zadania: " .. what) end
    self:save()
    for _, task in ipairs(removed) do
        print_log(string.format("usuniete %d: %s", task.id, task.cmd))
    end
end

function qm:start()
    if self.running then return print_log("<DimGrey>kolejka juz dziala") end
    if #self.tasks == 0 then return print_log("<DimGrey>kolejka pusta") end
    self.running = true
    print_log("<green>start, zadan: " .. #self.tasks)
    -- trwa zadanie z /qm pop: kolejka ruszy po jego koncu
    if self.current then return end
    self:step()
end

-- stop: dalsze zadania nie ruszaja; biezaca komenda nie jest przerywana
function qm:stop()
    local was = self.running or self.current
    self.running = nil
    self.current = nil
    self:clear_timer()
    print_log(was and "<tomato>zatrzymana" or "<DimGrey>kolejka nie dziala")
end

function qm:set_delay(seconds)
    seconds = tonumber(seconds)
    if not seconds or seconds < 0 then return print_log("<tomato>/qm delay <sekundy>") end
    self.delay = seconds
    self:save()
    print_log(string.format("opoznienie %g s", seconds))
end

local commands = {
    list = function() qm:list() end,
    push = function(arg) qm:push(arg) end,
    pop = function() qm:pop() end,
    next = function() qm:show_next() end,
    up = function(arg) qm:move(arg, -1) end,
    down = function(arg) qm:move(arg, 1) end,
    rm = function(arg) qm:remove(arg) end,
    start = function() qm:start() end,
    stop = function() qm:stop() end,
    delay = function(arg) qm:set_delay(arg) end,
}

function qm:command(name, arg)
    if not name or name == "" then name = "list" end
    local handler = commands[name]
    if not handler then
        return print_log("<tomato>/qm list|push|pop|next|up|down|rm|start|stop|delay")
    end
    handler(arg)
end

function qm:init()
    self:load()
    for _, id in ipairs(self.aliases) do killAlias(id) end
    self.aliases = {
        tempAlias("^/qm(?:\\s+(\\S+)(?:\\s+(.+))?)?$", function()
            scripts.qm:command(matches[2], matches[3])
        end),
    }
end

qm:init()
