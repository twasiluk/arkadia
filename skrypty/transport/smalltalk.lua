-- ============================================================
--  smalltalk - zagadanie do pierwszej postaci w dylizansie
--  9 s po wejsciu, najwyzej raz na godzine
-- ============================================================

scripts.smalltalk = scripts.smalltalk or {
    last_run = 0,
}

local delay = 9
local cooldown = 3600

local lines = {
    "Daleko jedziesz?",
    "Siadam tutaj, i tak trzesie wszedzie tak samo.",
    "Hmf. Ciasno.",
    "Pilnuj sakiewki. Na trakcie bywa roznie.",
    "Ludzka robota. Resory z gowna, kola z gorszego.",
    "Krasnolud by to zbudowal raz. I staloby sto lat.",
    "W Mahakamie jezdzi sie pod ziemia. Prosto i bez wstrzasow.",
    "Za te cene wolalbym isc.",
    "Konie. Zawodne bydle. Kamien nigdy nie kuleje.",
}

-- pierwsza zywa postac na lokacji poza mna (kolejnosc z gmcp.objects.nums)
local function first_person()
    if not gmcp.objects or not gmcp.objects.nums or not ateam.objs then return nil end
    for _, num in ipairs(gmcp.objects.nums) do
        local id = tonumber(num)
        if id ~= ateam.my_id and ateam.objs[id] then
            return id
        end
    end
end

function scripts.smalltalk:boarded(vehicle)
    if vehicle ~= "dylizans" then return end
    if getEpoch() - self.last_run < cooldown then return end
    if self.timer then killTimer(self.timer) end
    self.timer = tempTimer(delay, function()
        scripts.smalltalk.timer = nil
        scripts.smalltalk:talk()
    end)
end

function scripts.smalltalk:talk()
    if scripts.podroz.vehicle ~= "dylizans" then return end
    local id = first_person()
    if not id then return end
    self.last_run = getEpoch()
    send("ob ob_" .. id)
    send("powiedz " .. lines[math.random(#lines)])
end

function scripts.smalltalk:left()
    if self.timer then killTimer(self.timer); self.timer = nil end
end

function scripts.smalltalk:init()
    for _, id in ipairs(self.handlers or {}) do killAnonymousEventHandler(id) end
    self.handlers = {
        registerAnonymousEventHandler("podrozBoarded", function(_, vehicle) scripts.smalltalk:boarded(vehicle) end),
        registerAnonymousEventHandler("podrozLeft", function() scripts.smalltalk:left() end),
    }
end

scripts.smalltalk:init()
