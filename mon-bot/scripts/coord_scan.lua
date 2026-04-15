local START_ADDR = 0x02000000
local END_ADDR   = 0x0203FFFF
local STEP       = 2

local snapshotA = nil
local snapshotB = nil

local function read_u16_map()
    local values = {}
    local i = 1

    for addr = START_ADDR, END_ADDR, STEP do
        values[i] = emu:read16(addr)
        i = i + 1
    end

    return values
end

local function compare_snapshots(expected_a, expected_b)
    if not snapshotA or not snapshotB then
        console:log("Need two snapshots first.")
        return
    end

    local hits = 0
    local i = 1

    for addr = START_ADDR, END_ADDR, STEP do
        local a = snapshotA[i]
        local b = snapshotB[i]

        if a == expected_a and b == expected_b then
            console:log(string.format("Map at 0x%08X : %d -> %d", addr, a, b))
            hits = hits + 1
        end

        i = i + 1
    end

    console:log("Done. Hits: " .. hits)
end

function snap1()
    snapshotA = read_u16_map()
    console:log("Snapshot 1 saved (Ever Grande).")
end

function snap2()
    snapshotB = read_u16_map()
    console:log("Snapshot 2 saved (Victory Road).")
end

function find_map_change()
    compare_snapshots(15, 70)
end