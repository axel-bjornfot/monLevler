
local frame = 0

function checkMap()
    frame = frame + 1
    if frame % 60 ~= 0 then return end

    local map = emu:read16(0x0203732C)
    local x = emu:read16(0x02037360)
    local y = emu:read16(0x02037362)

    console:log("Map: " .. map .. " | X: " .. x .. " | Y: " .. y)
end

callbacks:add("frame", checkMap)