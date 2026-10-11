-- ============================================================
--  /kasa - stan sakwy przeliczony na zloto ("Au 201" w belce
--  stanow) oraz zarobki z kursow kurierskich.
--  Zlote monety sa liczone ("policz zlote monety") - ich wartosc
--  jest pewna. Srebrne i miedziane oceniane ("ocen ... monety"),
--  a wartosc z oceny scinana o estimate_discount (20%).
--  "<ktos> wyplaca ci ..." dolicza monety do sakwy i do zarobkow.
--  Belka: element "kasa" w scripts.ui.cfg.footer_items.
-- ============================================================

scripts.kasa = scripts.kasa or {
    aliases = {},
    triggers = {},
    timers = {},
    handlers = {},
}

local ka = scripts.kasa

local estimate_discount = 0.2   -- zapas na blad oceny srebra i miedzi
local reply_timeout = 5         -- czekanie na odpowiedz na policz/ocen
local store_key = "kasa"
local label_color = "#ffd700"

-- wartosci w miedziakach, jak misc:get_valued
local coin_value = { zl = 240, sr = 12, mdz = 1 }
local coin_order = { "zl", "sr", "mdz" }
local coin_name = { zl = "zlote", sr = "srebrne", mdz = "miedziane" }
-- rdzen przymiotnika z gry -> rodzaj monety
local coin_adjective = { ["zlot"] = "zl", ["srebrn"] = "sr", ["miedzian"] = "mdz" }

local function print_log(msg)
    cecho("\n<CadetBlue>(kasa)<reset>: " .. msg .. "\n")
end

local function coin_kind(word)
    local lowered = string.lower(word or "")
    for prefix, kind in pairs(coin_adjective) do
        if lowered:sub(1, #prefix) == prefix then return kind end
    end
    return nil
end

-- "4 srebrne i 2 miedziane monety" -> { sr = 4, mdz = 2 }, 50
local function parse_coins(text)
    local coins, total = {}, 0
    for amount, word in string.gmatch(text or "", "(%d+)%s+(%a+)") do
        local kind = coin_kind(word)
        if kind then
            amount = tonumber(amount)
            coins[kind] = (coins[kind] or 0) + amount
            total = total + amount * coin_value[kind]
        end
    end
    return coins, total
end

-- ---------- stan ----------
function ka:blank()
    return {
        purse = {},
        earnings = { total = 0, count = 0, payers = {}, last = nil },
    }
end

function ka:load()
    local stored = scripts.state_store:get(store_key)
    local blank = self:blank()
    if type(stored) ~= "table" then
        self.purse, self.earnings = blank.purse, blank.earnings
        return
    end
    self.purse = type(stored.purse) == "table" and stored.purse or blank.purse
    self.earnings = type(stored.earnings) == "table" and stored.earnings or blank.earnings
    self.earnings.payers = self.earnings.payers or {}
    self.earnings.total = self.earnings.total or 0
    self.earnings.count = self.earnings.count or 0
end

function ka:save()
    scripts.state_store:set(store_key, { purse = self.purse, earnings = self.earnings })
end

-- ---------- sakwa ----------
-- wartosc jednego rodzaju monet: policzone licza sie w calosci,
-- ocenione po scieciu rabatu
function ka:set_counted(kind, count)
    self.purse[kind] = {
        count = count,
        value = count * coin_value[kind],
        source = "policz",
        at = os.time(),
    }
    self:after_change()
end

function ka:set_valued(kind, count, value)
    self.purse[kind] = {
        count = count,
        value = math.floor(value * (1 - estimate_discount)),
        source = "ocen",
        at = os.time(),
    }
    self:after_change()
end

-- monety, ktore wlasnie wpadly do sakwy - znamy je dokladnie, wiec
-- doliczamy pelna wartosc do tego, co bylo policzone/ocenione
function ka:add_coins(coins)
    for kind, amount in pairs(coins) do
        local entry = self.purse[kind] or { count = 0, value = 0, source = "wyplaty" }
        entry.count = (entry.count or 0) + amount
        entry.value = (entry.value or 0) + amount * coin_value[kind]
        entry.at = os.time()
        self.purse[kind] = entry
    end
    self:after_change()
end

function ka:value()
    local total = 0
    for _, entry in pairs(self.purse) do
        total = total + (entry.value or 0)
    end
    return total
end

function ka:gold()
    return math.floor(self:value() / coin_value.zl)
end

function ka:after_change()
    self:update_label()
    self:save()
end

-- ---------- belka stanow ----------
-- rejestracja elementu "kasa" w tabelach belki; dzieki temu wystarczy
-- dodac "kasa" do scripts.ui.cfg.footer_items
function ka:register_footer_item()
    local ui = scripts.ui
    if not ui or not ui.bar_to_id1 then return end
    ui.bar_to_eng["kasa"] = "kasa"
    ui.bar_to_id1["kasa"] = "kasalabel"
    ui.bar_to_id2["kasa"] = "kasagauge"
    ui.state_key_to_label_pre["kasa"] = "Au"
    -- tryby z paskami (mode1/mode6) czytaja max z footer_bar; kasa nie
    -- przychodzi z gmcp, wiec updater jej nie dotyka
    ui.footer_bar["kasa"] = ui.footer_bar["kasa"] or { name = "kasa", max = 1, background = {} }
end

function ka:update_label()
    local label = scripts.ui and scripts.ui.kasalabel
    if not label then return end
    if not self.label_click then
        label:setClickCallback(function() scripts.kasa:refresh() end)
        setLabelCursor(label.name, "PointingHand")
        self.label_click = true
    end
    label:echo(string.format(
        [[<center><font color='%s'>Au <font color="%s">%d</font></center>]],
        scripts.ui.footer_info_normal, label_color, self:gold()))
end

function ka:check_label()
    if scripts.ui and scripts.ui.kasalabel then return end
    if self.label_warned then return end
    self.label_warned = true
    print_log("<DimGrey>belka bez kasy - dodaj \"kasa\" do scripts.ui.cfg.footer_items")
end

-- ---------- przeliczenie sakwy ----------
function ka:clear_pending()
    for _, id in ipairs(self.timers) do killTimer(id) end
    self.timers = {}
    self.pending = nil
    self.valuing = nil
end

function ka:answered(kind)
    if not self.pending then return end
    if self.pending[kind] then
        self.pending[kind] = nil
        self.pending.left = self.pending.left - 1
    end
    if self.pending.left <= 0 then
        self:clear_pending()
        self:print_purse()
    end
end

-- policz zloto (pewne) + ocen srebro i miedz (z rabatem)
function ka:refresh()
    if self.pending then return print_log("<DimGrey>licze juz monety") end
    self.pending = { left = 3, zl = true, sr = true, mdz = true }
    table.insert(self.timers, tempTimer(reply_timeout, function()
        if not ka.pending then return end
        local missing = {}
        for _, kind in ipairs(coin_order) do
            if ka.pending[kind] then table.insert(missing, coin_name[kind]) end
        end
        ka:clear_pending()
        if #missing > 0 then
            print_log("<DimGrey>bez odpowiedzi: " .. table.concat(missing, ", ") .. " monety")
        end
        ka:print_purse()
    end))
    send("policz zlote monety")
    send("ocen srebrne monety")
    send("ocen miedziane monety")
end

-- ---------- wydruk ----------
function ka:purse_line()
    local parts = {}
    for _, kind in ipairs(coin_order) do
        local entry = self.purse[kind]
        if entry then
            table.insert(parts, string.format("<DimGrey>%s:<reset> %d szt (%s)",
                coin_name[kind], entry.count or 0, entry.source or "?"))
        end
    end
    if #parts == 0 then return "<DimGrey>sakwa nieprzeliczona (/kasa)" end
    return table.concat(parts, "<DimGrey>,<reset> ")
end

function ka:print_purse()
    self:check_label()
    print_log(self:purse_line())
    print_log(string.format("<gold>Au %d<reset> (%s<reset>), ocena srebra i miedzi scieta o %d%%",
        self:gold(), misc:get_valued_string(self:value()), math.floor(estimate_discount * 100)))
end

function ka:print_earnings()
    local earnings = self.earnings
    if earnings.count == 0 then
        return print_log("<DimGrey>brak wyplat za kursy")
    end
    print_log(string.format("kursy: wyplat <green>%d<reset>, razem%s<reset>, srednio%s",
        earnings.count, misc:get_valued_string(earnings.total),
        misc:get_valued_string(math.floor(earnings.total / earnings.count))))
    local last = earnings.last
    if last then
        cecho(string.format("  <DimGrey>ostatnia:<reset> %s%s<reset> <DimGrey>(%d min temu)\n",
            last.payer, misc:get_valued_string(last.value),
            math.floor((os.time() - (last.at or os.time())) / 60)))
    end
    local payers = {}
    for payer, data in pairs(earnings.payers) do
        table.insert(payers, { payer = payer, count = data.count or 0, value = data.value or 0 })
    end
    table.sort(payers, function(a, b) return a.value > b.value end)
    for _, data in ipairs(payers) do
        cecho(string.format("  <DimGrey>%s:<reset> %d x,%s\n", data.payer, data.count,
            misc:get_valued_string(data.value)))
    end
end

-- ---------- wyplaty kurierskie ----------
function ka:payment(payer, text)
    local coins, value = parse_coins(text)
    if value == 0 then return end
    local earnings = self.earnings
    earnings.total = earnings.total + value
    earnings.count = earnings.count + 1
    earnings.last = { payer = payer, value = value, at = os.time() }
    local by_payer = earnings.payers[payer] or { count = 0, value = 0 }
    by_payer.count = by_payer.count + 1
    by_payer.value = by_payer.value + value
    earnings.payers[payer] = by_payer
    self:add_coins(coins)
    print_log(string.format("%s:%s<reset> (razem%s<reset>, Au %d)",
        payer, misc:get_valued_string(value), misc:get_valued_string(earnings.total), self:gold()))
end

function ka:reset()
    local blank = self:blank()
    self.earnings = blank.earnings
    self:save()
    print_log("zarobki wyzerowane")
end

-- ---------- triggery ----------
local triggers = {
    -- "Doliczyles sie 25 zlotych monet." / "Doliczyles sie 1 zlotej monety."
    ["^Doliczyles sie (\\d+) (zlot|srebrn|miedzian)\\w* monet\\w*\\.$"] = function()
        local kind = coin_kind(matches[3])
        if not kind then return end
        ka:set_counted(kind, tonumber(matches[2]))
        ka:answered(kind)
    end,
    -- brak monet danego rodzaju
    ["^Nie (?:masz|posiadasz) (?:zadnych |ani jednej )?(zlot|srebrn|miedzian)\\w* monet\\w*"] = function()
        local kind = coin_kind(matches[2])
        if not kind then return end
        ka:set_counted(kind, 0)
        ka:answered(kind)
    end,
    -- "======= Oceniasz starannie wiele srebrnych monet. ========"
    ["Oceniasz(?: starannie)? .*?(zlot|srebrn|miedzian)\\w* monet"] = function()
        ka.valuing = coin_kind(matches[2])
    end,
    -- "Wydaje ci sie, ze jest tu 60 sztuk wartych 720 miedziakow, czyli 3 zl."
    ["^Wydaje ci sie, ze (?:jest|sa) tu (\\d+) sztu\\w+ wart\\w+ (\\d+) miedziak\\w*"] = function()
        local kind = ka.valuing
        if not kind then return end
        ka.valuing = nil
        ka:set_valued(kind, tonumber(matches[2]), tonumber(matches[3]))
        ka:answered(kind)
    end,
    -- "Tark wyplaca ci 1 zlota, 1 srebrna i 1 miedziana monete."
    ["^(\\S+) wyplaca ci (.+)\\.$"] = function()
        ka:payment(matches[2], matches[3])
    end,
}

-- ---------- aliasy ----------
local aliases = {
    ["^/kasa$"] = function() scripts.kasa:refresh() end,
    ["^/kasa stan$"] = function() scripts.kasa:print_purse() end,
    ["^/kasa kursy$"] = function() scripts.kasa:print_earnings() end,
    ["^/kasa reset$"] = function() scripts.kasa:reset() end,
}

function ka:init()
    for _, id in ipairs(self.aliases) do killAlias(id) end
    for _, id in ipairs(self.triggers) do killTrigger(id) end
    self.aliases, self.triggers = {}, {}
    self:clear_pending()
    self:load()
    self:register_footer_item()
    for regex, callback in pairs(aliases) do
        table.insert(self.aliases, tempAlias(regex, callback))
    end
    for regex, callback in pairs(triggers) do
        table.insert(self.triggers, tempRegexTrigger(regex, callback))
    end
    self.label_click = nil
    self.ui_handler = scripts.event_register:force_register_event_handler(
        self.ui_handler, "uiReady", function()
            scripts.kasa.label_click = nil
            scripts.kasa:update_label()
        end)
    self:update_label()
end

ka:init()
