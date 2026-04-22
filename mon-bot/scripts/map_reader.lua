
local frame = 0
local PLAYER_MOVE_ADDRS   = {                      -- verified slots 1&2; 3&4 TBD
    0x02024090,
    0x02024092,
    0x02024094,
    0x02024096,
}

function get_move_id()
    for i = 1, 4 do
        local move_id = emu:read16(PLAYER_MOVE_ADDRS[i])
        console:log(string.format("Move %d: %d", i - 1, move_id))

    end
end

function checkMap()
    frame = frame + 1
    if frame % 5 ~= 0 then return end

    local map = emu:read16(0x0203732C)
    local x = emu:read16(0x02037360)
    local y = emu:read16(0x02037362)

    console:log("Map: " .. map .. " | X: " .. x .. " | Y: " .. y)
end

callbacks:add("frame", checkMap)