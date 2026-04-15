local X_ADDR = 0x02037360
local Y_ADDR = 0x02037362
local INPUT_ADDR = 0x04000130

local last = ""

callbacks:add("frame", function()
    local x = emu:read16(X_ADDR)
    local y = emu:read16(Y_ADDR)

    local input = emu:read16(INPUT_ADDR)

    local pressed = {}

    if (input & 0x0001) == 0 then pressed[#pressed+1] = "A" end
    if (input & 0x0040) == 0 then pressed[#pressed+1] = "Up" end
    if (input & 0x0080) == 0 then pressed[#pressed+1] = "Down" end
    if (input & 0x0020) == 0 then pressed[#pressed+1] = "Left" end
    if (input & 0x0010) == 0 then pressed[#pressed+1] = "Right" end

    local input_str = (#pressed > 0) and table.concat(pressed, "+") or ""

    local current = string.format("X=%d Y=%d %s", x, y, input_str)

    if current ~= last then
        console:log(current)
        last = current
    end
end)