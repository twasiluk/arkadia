function compass_click(dir)
    if amap.walker then
        amap:terminate_walker()
    end

    if dir == "special1" and amap.ui.compass.special_exit1 then
        send(amap.ui.compass.special_exit1)
    elseif dir == "special2" and amap.ui.compass.special_exit2 then
        send(amap.ui.compass.special_exit2)
    elseif dir == "special3" and amap.ui.compass.special_exit3 then
        send(amap.ui.compass.special_exit3)
    else
        local dir_full = amap.short_to_long[dir]
        amap.dir_from_key = dir_full
        amap:keybind_pressed(dir_full)
    end

    amap.team_follow = false
end

function compass_on_enter(dir)
    -- po /reload etykiety zostaja, a amap.ui.compass jest tworzony od nowa bez przyciskow
    local button = dir and amap.ui.compass["button_" .. dir]
    if button then
        button:setStyleSheet(amap.ui["hover_button"])
    end
end

function compass_on_leave(dir)
    -- po /reload etykiety zostaja, a amap.ui.compass jest tworzony od nowa bez przyciskow
    local button = dir and amap.ui.compass["button_" .. dir]
    if button then
        button:setStyleSheet(amap.ui["normal_button"])
    end
end

