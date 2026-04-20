-- Integrated Pokémon leveling and fighting bot for mGBA Lua (Emerald US)
-- Combines movement routing, battle handling, and recovery logic

local frame = 0
local runningRoute = false
local stop = false
local stuckCounter = 0
local recoveryMode = false
local recoveryDelay = 0
local routeActiveFrames = 0
local lastPos = { x = nil, y = nil }
local nurseStarted = false
local returningToNurse = false
local returningToFarm = false
local dialog_baseline = 57  -- From your initial mem_save
local buttonReleaseDelay = 0
local party_hp_score = 0
local faint_state = nil


-- ─── RAM ADDRESSES ──────────────────────────────────────────────────────────
local X_ADDR = 0x02037360
local Y_ADDR = 0x02037362
local MAP_ADDR = 0x0203732C

-- Battle detection and state
local BATTLE_FLAG_ADDR = 0x02024068
local PLAYER_HP_CURRENT = 0x020240AC
local PLAYER_HP_MAX = 0x020240B0
local ENEMY_HP_CURRENT = 0x02024104
local ENEMY_HP_MAX = 0x02024108

-- Nure pokecenter
local NURSE_ACTIVE_ADDR = 0x020375F2

-- Player moves and PP
local PP_MOVE1 = 0x020240A8
local PP_MOVE2 = 0x020240A9
local PP_MOVE3 = 0x020240AA
local PP_MOVE4 = 0x020240AB

-- Menu cursors
local TOP_MENU_CURSOR = 0x020244AC
local MOVE_MENU_CURSOR = 0x020244B0
local PARTY_MENU_CURSOR = 0x0203CED1
local NEXT_POKEMON_CURSOR = 0x02024333
local PARTY_MENU_ACTIVE = 0x02021834
local MENU_STATE_SECONDARY = 0x02024332
local MENU_STATE_ADDR = 0x020207EE

-- Faint detection
local FAINT_PROMPT_ACTIVE = 0x02000418
local FAINT_CURSOR_POS = 0x02024A82
local FAINT_CURSOR_POS_OPTION = 0x02024332

-- Party HP structure
local PARTY_BASE = 0x020244EC
local POKEMON_STRUCT_SIZE = 0x64
local HP_CURRENT_OFFSET = 0x56
local HP_MAX_OFFSET = 0x58
local LEVEL_OFFSET = 0x54

-- Player and enemy battle mons
local PLAYER_STRUCT = 0x02024084
local ENEMY_STRUCT = 0x020240DC
local PLAYER_TYPE1_ADDR = PLAYER_STRUCT + 0x21
local PLAYER_TYPE2_ADDR = PLAYER_STRUCT + 0x22
local ENEMY_TYPE1_ADDR = ENEMY_STRUCT + 0x21
local ENEMY_TYPE2_ADDR = ENEMY_STRUCT + 0x22
local PLAYER_SPECIES_ADDR = PLAYER_STRUCT + 0x00
local ENEMY_SPECIES_ADDR = ENEMY_STRUCT + 0x00

local PLAYER_MOVE_ADDRS = {
    0x02024090,
    0x02024092,
    0x02024094,
    0x02024096,
}
local PP_ADDRS = { PP_MOVE1, PP_MOVE2, PP_MOVE3, PP_MOVE4 }

-- phonecall counter 
local dialog_addr = 0x02024AA6

-- ─── CONSTANTS ──────────────────────────────────────────────────────────────
local STUCK_THRESHOLD = 90
local RECOVERY_DELAY_FRAMES = 60
local VICTORY_ROAD_MAP = 70
local EVER_GARDE_MAP = 15
local HP_THRESHOLD = 2 -- 1.5 real value 3 is debug value

local DIRECTIONS = {
    Up    = { dx =  0, dy = -1, key = "Up",    bit = 64 },
    Down  = { dx =  0, dy =  1, key = "Down",  bit = 128 },
    Left  = { dx = -1, dy =  0, key = "Left",  bit = 32 },
    Right = { dx =  1, dy =  0, key = "Right", bit = 16 }
}

local BUTTONS = {
    A = { name = "A", key = "A", bit = 1 },
    B = { name = "B", key = "B", bit = 2 },
}

local TYPE_NAMES = {
    [0]="Normal",[1]="Fighting",[2]="Flying",[3]="Poison",[4]="Ground",
    [5]="Rock",[6]="Bug",[7]="Ghost",[8]="Steel",[9]="???",
    [10]="Fire",[11]="Water",[12]="Grass",[13]="Electric",
    [14]="Psychic",[15]="Ice",[16]="Dragon",[17]="Dark",
}

local TYPE_EFFECTIVENESS = {
    [0] = { [1]=2, [5]=0.5 },
    [1] = { [0]=2, [5]=2, [15]=2, [17]=2, [2]=0.5, [14]=0.5, [8]=2 },
    [2] = { [1]=2, [6]=2, [12]=2, [5]=0.5, [13]=0.5 },
    [3] = { [12]=2, [6]=2, [4]=0.5, [14]=0.5 },
    [4] = { [3]=2, [5]=2, [10]=2, [13]=2, [8]=2, [12]=0.5, [11]=0.5 },
    [5] = { [2]=2, [6]=2, [10]=2, [15]=2, [11]=0.5, [12]=0.5, [1]=0.5, [4]=0.5 },
    [6] = { [12]=2, [14]=2, [17]=2, [2]=0.5, [5]=0.5, [10]=0.5 },
    [7] = { [7]=2, [14]=2, [17]=0.5 },
    [8] = { [15]=2, [5]=2, [0]=2, [3]=2, [12]=2, [10]=0.5, [1]=0.5, [4]=0.5 },
    [10] = { [12]=2, [15]=2, [8]=2, [11]=0.5, [4]=0.5, [5]=0.5 },
    [11] = { [4]=2, [5]=2, [10]=2, [13]=0.5, [12]=0.5 },
    [12] = { [4]=2, [5]=2, [11]=2, [2]=0.5, [3]=0.5, [10]=0.5, [15]=0.5 },
    [13] = { [11]=2, [2]=2, [4]=0.5 },
    [14] = { [1]=2, [3]=2, [6]=0.5, [7]=0.5, [17]=0.5 },
    [15] = { [2]=2, [4]=2, [12]=2, [16]=2, [10]=0.5, [1]=0.5, [5]=0.5, [8]=0.5 },
    [16] = { [16]=2, [15]=0.5 },
    [17] = { [7]=2, [14]=2, [1]=0.5, [6]=0.5, [8]=1.0 },
}

local TYPE_IMMUNITY = {
    [2] = { [4] = true },  -- Flying immune to Ground
    [7] = { [0] = true, [1] = true },  -- Ghost immune to Normal and Fighting
    [8] = { [3] = true },  -- Steel immune to Poison
}

local moveData = {
    [6]   = { type = 6,  damage = true },   -- X-Scissor
    [13]  = { type = 2,  damage = true },   -- Air Slash
    [19]  = { type = 2,  damage = true },
    [38]  = { type = 0,  damage = true },   -- Double Edge
    [55]  = { type = 11, damage = true },   -- Water Gun
    [56]  = { type = 11, damage = true },   -- Hydro Pump
    [58]  = { type = 15, damage = true },
    [61]  = { type = 11, damage = true },   -- Bubble Beam
    [73]  = { type = 12, damage = false },
    [78]  = { type = 12, damage = false },
    [85]  = { type = 13, damage = true },
    [86]  = { type = 13, damage = false },
    [89]  = { type = 4,  damage = true },   -- Earthquake
    [94]  = { type = 14, damage = true },
    [97]  = { type = 0,  damage = false },
    [103] = { type = 0,  damage = false },
    [104] = { type = 0,  damage = false },
    [125] = { type = 4,  damage = true },   -- Mud Bomb
    [127] = { type = 11, damage = true },
    [156] = { type = 0,  damage = false },
    [157] = { type = 5,  damage = true },
    [188] = { type = 3,  damage = true },   -- Sludge Bomb
    [198] = { type = 5,  damage = true },   -- Head Smash
    [202] = { type = 12, damage = true },
    [209] = { type = 13, damage = true },
    [212] = { type = 0,  damage = false },  -- Mean Look
    [231] = { type = 8,  damage = true },
    [242] = { type = 17, damage = true },
    [254] = { type = 0,  damage = false },  -- Stockpile
    [255] = { type = 0,  damage = true },   -- Spit Up
    [256] = { type = 0,  damage = false },  -- Swallow
    [283] = { type = 0,  damage = false },  -- Endeavor
    [300] = { type = 1,  damage = true },
    [326] = { type = 14, damage = true },
    [337] = { type = 16, damage = true },
    [346] = { type = 16, damage = true },
    [347] = { type = 14, damage = false },
    [349] = { type = 16, damage = false },
}

-- Routes for farming
--route 1
local route = {
    {x=10, y=11}, {x=10, y=12}, {x=10, y=13}, {x=10, y=14}, {x=10, y=15},
    {x=11, y=15}, {x=12, y=15}, {x=13, y=15}, {x=14, y=15}, {x=15, y=15}, {x=16, y=15},
    {x=16, y=16}, {x=16, y=17}, {x=16, y=18},
    {x=25, y=12}, {x=25, y=13}, {x=25, y=14}, {x=25, y=15}, {x=25, y=16}, {x=25, y=17}, {x=25, y=18}, {x=25, y=19}, {x=25, y=20}, {x=25, y=21}, {x=25, y=22}, {x=25, y=23}, {x=25, y=24},
    {x=26, y=24}, {x=27, y=24}, {x=28, y=24}, {x=29, y=24}, {x=30, y=24}, {x=31, y=24}, {x=32, y=24},
    {x=32, y=25}, {x=32, y=26}, {x=32, y=27}, {x=32, y=28}, {x=32, y=29}, {x=32, y=30}, {x=32, y=31}, {x=32, y=32}, {x=32, y=33}, {x=32, y=34}, {x=32, y=35},
    {x=31, y=35}, {x=30, y=35}, {x=29, y=35}, {x=28, y=35}, {x=27, y=35}, {x=26, y=35}, {x=25, y=35},
    {x=25, y=34},
    {x=46, y=12},{x=45, y=12},{x=44, y=12},{x=43, y=12},{x=43, y=12},{x=42, y=12},{x=41, y=12},{x=40, y=12},{x=39, y=12},{x=38, y=12},{x=37, y=12},
}
local farming_route = {
    {x=45, y=12},{x=44, y=12},{x=43, y=12},{x=43, y=12},{x=42, y=12},{x=41, y=12},{x=40, y=12},{x=39, y=12},{x=38, y=12},{x=37, y=12},
}

-- route 2
local route_map4 = {
    {x=14, y=11}, {x=14, y=14}, {x=14, y=15},
    {x=21, y=14}, {x=21, y=15}, {x=21, y=16},
    {x=19, y=17}, {x=15, y=17}, {x=8, y=17},
}

local route_map29 = {
    {x=41, y=17}, {x=33, y=17}, {x=28, y=17}, {x=28, y=24}, {x=28, y=31},
    {x=28, y=39}, {x=28, y=44}, {x=28, y=46}, {x=28, y=53}, {x=28, y=55},
    {x=25, y=55}, {x=25, y=56}, {x=25, y=57}, {x=25, y=60},
    {x=22, y=57}, {x=21, y=57}, {x=21, y=56}, {x=21, y=54},
    {x=19, y=54}, {x=19, y=56}, {x=19, y=60}, {x=20, y=62},
    {x=22, y=63}, {x=22, y=67}, {x=26, y=67}, {x=30, y=67},
    {x=33, y=67}, {x=33, y=63}, {x=35, y=63}, {x=35, y=66},
    {x=35, y=70}, {x=35, y=74}, {x=35, y=78}, {x=35, y=80},
    {x=31, y=80}, {x=31, y=77}, {x=31, y=73}, {x=31, y=72},
    {x=28, y=72}, {x=24, y=72}, {x=23, y=73}, {x=21, y=73},
    {x=21, y=77}, {x=19, y=77}, {x=15, y=77}, {x=15, y=74}, {x=15, y=70},
}
-- ─── ROUTING STATE ──────────────────────────────────────────────────────────
local currentRouteIndex = 1
local routeToFollow = nil
local movementTask = nil
local inBattle = false
local fainting = false
local fightPhase = "startup"
local targetMove = 0
local targetTopMenu = 0
local targetPartySlot = 0
local startupStep = 0
local buttonHoldFrames = 0
local currentButton = nil
local battleFrameCounter = 0
local routeDirection = 1

-- ─── UTILITY FUNCTIONS ──────────────────────────────────────────────────────

function log(formatString, ...)
    local msg = string.format(formatString, ...)
    if console and console.log then
        console:log(msg)
    else
        print(msg)
    end
end

function get_position()
    return {
        x = emu:read16(X_ADDR),
        y = emu:read16(Y_ADDR)
    }
end

function positions_equal(a, b)
    return a and b and a.x == b.x and a.y == b.y
end


function apply_input(btn)
    if emu and emu.setKeys then emu:setKeys(btn.bit)
    elseif input  and input.set  then input.set({ [btn.key] = true })
    elseif joypad and joypad.set then joypad.set({ [btn.key] = true })
    end
    buttonHoldFrames = 5 -- hold button for 5 frames
    currentButton = btn
end


function clear_input()
    if emu and emu.setKeys then
        emu:setKeys(0)
    elseif input and input.set then
        input.set({})
    elseif joypad and joypad.set then
        joypad.set({})
    end
end

function advance_frame()
    if type(frameadvance) == "function" then
        frameadvance()
        return
    end
    if emu then
        if type(emu.frameadvance) == "function" then
            emu.frameadvance()
            return
        elseif type(emu.wait) == "function" then
            emu:wait(1)
            return
        end
    end
    error("No frame advance API available")
end

function wait_until(predicate, maxFrames)
    local frames = 0
    while frames < maxFrames do
        if predicate() then
            return true
        end
        advance_frame()
        frames = frames + 1
    end
    return false
end

function reverse_route(route)
    local rev = {}
    for i = #route, 1, -1 do
        rev[#rev + 1] = route[i]
    end
    return rev
end

function read_hp(addr)
    if not addr then return 0 end
    return emu:read16(addr)
end

function get_player_hp()
    local cur = read_hp(PLAYER_HP_CURRENT)
    local max = read_hp(PLAYER_HP_MAX)
    return cur, max, (max > 0 and cur / max or 0)
end

function get_enemy_hp()
    local cur = read_hp(ENEMY_HP_CURRENT)
    local max = read_hp(ENEMY_HP_MAX)
    return cur, max, (max > 0 and cur / max or 0)
end

function battle_flag_is_set()
    if BATTLE_FLAG_ADDR then return emu:read16(BATTLE_FLAG_ADDR) ~= 0 end
    return false
end

function get_party_hp(slot)
    local base = PARTY_BASE + (slot * POKEMON_STRUCT_SIZE)
    local hp = emu:read16(base + HP_CURRENT_OFFSET) or 0
    local maxhp = emu:read16(base + HP_MAX_OFFSET) or 0
    return {base = base, hp = hp, maxhp = maxhp}
end

function find_next_awake_slot()
    for slot = 0, 5 do
        local mon = get_party_hp(slot)
        if mon.maxhp == mon.hp then
            return slot
        end
    end
    return -1
end

function get_party_hp_ratio(slot)
    local base = PARTY_BASE + (slot * POKEMON_STRUCT_SIZE)
    local hp = emu:read16(base + HP_CURRENT_OFFSET) or 0
    local maxhp = emu:read16(base + HP_MAX_OFFSET) or 0

    if maxhp == 0 then return 0 end
    return hp / maxhp
end

function check_party_hp_score()
    local ratio = 0
    for slot = 0, 5 do
        local slot_ratio = get_party_hp_ratio(slot)
        ratio = ratio + slot_ratio
    end
    return ratio
end

-- ─── RECOVERY AND STUCK DETECTION ──────────────────────────────────────────

function recovery_tick(pos)
    if pos.x == 0 and pos.y == 0 then
        stuckCounter = 0
        recoveryMode = false
        recoveryDelay = 0
        return false
    end

    if not runningRoute then
        stuckCounter = 0
        recoveryMode = false
        recoveryDelay = 0
        routeActiveFrames = 0
        lastPos.x, lastPos.y = pos.x, pos.y
        return false
    end

    routeActiveFrames = routeActiveFrames + 1

    if not positions_equal(pos, lastPos) then
        stuckCounter = 0
        recoveryMode = false
        recoveryDelay = 0
        lastPos.x, lastPos.y = pos.x, pos.y
        return false
    end

    if routeActiveFrames < 12 then
        return false
    end

    stuckCounter = stuckCounter + 1

    if stuckCounter < STUCK_THRESHOLD then
        return false
    end

    if recoveryMode then
        apply_input(BUTTONS.A)
        return true
    end

    if recoveryDelay == 0 then
        recoveryDelay = RECOVERY_DELAY_FRAMES
        stop_movement()
        log("Stuck detected, waiting %d frames before recovery", RECOVERY_DELAY_FRAMES)
        return true
    end

    recoveryDelay = recoveryDelay - 1
    if recoveryDelay > 0 then
        return true
    end

    recoveryMode = true
    return true
end
-- ─── NURSE POKECENTER ───────────────────────────────────────────────────
local function isNurseActive()
    return emu:read8(NURSE_ACTIVE_ADDR) == 1
end

-- returns true when done
function handle_nurse(active)
    if buttonHoldFrames > 0 or currentButton ~= nil then
        return false
    end

    if not active and party_hp_score > HP_THRESHOLD then
        nurseStarted = false
        return true
    end
    -- Step 1: start interaction
    if not nurseStarted then
        if active then
            nurseStarted = true
            return false
        end
        apply_input(BUTTONS.A)
        return false
    end

    -- Step 2: keep advancing dialogue while active
    if active then
        apply_input(BUTTONS.A)
        return false
    end
end

-- ─── MOVEMENT AND ROUTING ───────────────────────────────────────────────────

function start_movement(directionName, targetX, targetY)
    movementTask = {
        direction = directionName,
        targetX = targetX,
        targetY = targetY,
        frames = 0,
        timeout = 90
    }
    apply_input(DIRECTIONS[directionName])
end

function stop_movement()
    movementTask = nil
    clear_input()
end

function set_route(route)
    log("Setting new route with %d steps", #route)
    routeToFollow = route
    currentRouteIndex = 1
end

function find_closest_route_index(route, pos)
    local bestIndex = 1
    local bestDist = math.huge

    for i, step in ipairs(route) do
        local dist = math.abs(step.x - pos.x) + math.abs(step.y - pos.y)
        if dist < bestDist then
            bestDist = dist
            bestIndex = i
        end
    end

    return bestIndex
end

function follow_route()
    if not routeToFollow then
        return false, "no_route_set"
    end

    local pos = get_position()
    if pos.x == 0 and pos.y == 0 then
        return nil
    end

    if movementTask then
        if pos.x == movementTask.targetX and pos.y == movementTask.targetY then
            stop_movement()
            currentRouteIndex = currentRouteIndex + 1
            return nil
        end

        movementTask.frames = movementTask.frames + 1
        if movementTask.frames > movementTask.timeout then
            stop_movement()
            inBattle = true
            local cur_hp = get_player_hp()
            if cur_hp == 0 and not battle_flag_is_set() and battleFrameCounter < 1 then
                log("Faint prompt detected at (%d,%d)", pos.x, pos.y)
            else
                log("Battle detected at (%d,%d)", pos.x, pos.y)
                stop_movement()
            end
            return nil
        end

        apply_input(DIRECTIONS[movementTask.direction])
        return nil
    end

    while currentRouteIndex <= #routeToFollow do
        local step = routeToFollow[currentRouteIndex]
        if pos.x == step.x and pos.y == step.y then
            currentRouteIndex = currentRouteIndex + 1
        else
            break
        end
    end

    if currentRouteIndex > #routeToFollow then
        return true
    end

    local step = routeToFollow[currentRouteIndex]
    local dx = step.x - pos.x
    local dy = step.y - pos.y

    if dx == 1 and dy == 0 then
        start_movement("Right", step.x, step.y)
        return nil
    elseif dx == -1 and dy == 0 then
        start_movement("Left", step.x, step.y)
        return nil
    elseif dx == 0 and dy == 1 then
        start_movement("Down", step.x, step.y)
        return nil
    elseif dx == 0 and dy == -1 then
        start_movement("Up", step.x, step.y)
        return nil
    elseif pos.x == 25 and pos.y == 12 then
        start_movement("Up", step.x, step.y)
        return nil
        elseif pos.x == 16 and pos.y == 18 then
        start_movement("Down", step.x, step.y)
        return nil
    elseif pos.x == 46 and pos.y == 12 then
        start_movement("Down", step.x, step.y)
    return nil
    else
        return false, string.format("failed at step %d (%d,%d): target_not_adjacent pos=(%d,%d) dx=%d dy=%d",
            currentRouteIndex, step.x, step.y, pos.x, pos.y, dx, dy)
    end
end

-- function startRoute()
--     local pos = get_position()

--     local found = false
--     local startIndex = 1
--     for i = 1, #route do
--         if route[i].x == pos.x and route[i].y == pos.y then
--             startIndex = i + 1
--             found = true
--             break
--         end
--     end

--     if not found then
--         if route[1] and (route[1].x ~= pos.x or route[1].y ~= pos.y) then
--             log("Position (%d,%d) not in route, not starting", pos.x, pos.y)
--             return
--         end
--     end

--     runningRoute = true
--     stop = false
--     stuckCounter = 0
--     recoveryMode = false
--     recoveryDelay = 0
--     routeActiveFrames = 0
--     stop_movement()
--     set_route(route)
--     currentRouteIndex = startIndex
--     local first = { x = 0, y = 0 }
--     if routeToFollow and routeToFollow[currentRouteIndex] then
--         first = routeToFollow[currentRouteIndex]
--     end
--     log("Route started: current=(%d,%d) startIndex=%d startStep=(%d,%d)", pos.x, pos.y, currentRouteIndex, first.x, first.y)
-- end

function goBack(back)
    runningRoute = true
    stop = false
    stuckCounter = 0
    recoveryMode = false
    recoveryDelay = 0
    routeActiveFrames = 0
    local real_route
    if back then
        real_route = reverse_route(route)
    else
        real_route = route
    end
    stop_movement()
    local pos = get_position()
    set_route(real_route)
    currentRouteIndex = find_closest_route_index(routeToFollow, pos)
    local first = routeToFollow[currentRouteIndex]
    log("Go back started: current=(%d,%d) startIndex=%d startStep=(%d,%d)", pos.x, pos.y, currentRouteIndex, first.x, first.y)
end

function stopBot()
    runningRoute = false
    stop = true
    stop_movement()
    log("Bot stopped")
end

function resetBot()
    runningRoute = false
    stop = false
    stop_movement()
    routeToFollow = nil
    log("Bot reset")
end

-- ─── BATTLE FUNCTIONS ───────────────────────────────────────────────────────

function every_n_frames(n)
    return frame % n == 0  -- clean, no increment
end
function control_cursors()
    local top_cursor = emu:read8(TOP_MENU_CURSOR)
    local move_cursor = emu:read8(MOVE_MENU_CURSOR)
    local party_cursor = emu:read8(PARTY_MENU_CURSOR)
    local next_pokemon_cursor = emu:read8(NEXT_POKEMON_CURSOR)

    return {top = top_cursor, move = move_cursor, party = party_cursor, next_pokemon = next_pokemon_cursor}
end

function detect_faint_menu_state()
    local prompt_active = emu:read8(FAINT_PROMPT_ACTIVE)
    local cursor_state = emu:read16(FAINT_CURSOR_POS_OPTION)
    local party_active = emu:read8(PARTY_MENU_ACTIVE)

    log("[FAINT] prompt_active=%d, cursor_state=%d, party_active=%d", prompt_active, cursor_state, party_active)

    if prompt_active ~= 1 then
        return "not_fainted"
    end

    if cursor_state == 1 and party_active == 1 then
        return "faint_menu_yes"
    elseif cursor_state == 0 or cursor_state == 257 then
        return "faint_menu_no"
    else
        return "unknown"
    end
end

function detect_post_faint_menu_state()
    local party_active = emu:read8(PARTY_MENU_ACTIVE)
    local menu_state_sec = emu:read16(MENU_STATE_SECONDARY)

    log("[POST_FAINT] party_active=%d, menu_state=%d", party_active, menu_state_sec)

    if menu_state_sec == 257 or party_active == 1 then
        return "party_list"
    elseif menu_state_sec == 1 then
        return "yes_no_prompt"
    else
        return "unknown"
    end
end

function score_move(move_id, enemy_type1, enemy_type2)
    local move_info = moveData[move_id]
    if not move_info then return 0 end

    if not move_info.damage then return 0 end

    local move_type = move_info.type

    -- Check immunity (move won't hit at all)
    if TYPE_IMMUNITY[enemy_type1] and TYPE_IMMUNITY[enemy_type1][move_type] then
        return 0
    end
    if TYPE_IMMUNITY[enemy_type2] and TYPE_IMMUNITY[enemy_type2][move_type] then
        return 0
    end

    local eff = TYPE_EFFECTIVENESS[move_type] or {}
    local eff1 = eff[enemy_type1] or 1.0
    local eff2 = eff[enemy_type2] or 1.0

    return eff1 * eff2
end

function best_move_slot()
    local enemy_type1 = emu:read8(ENEMY_TYPE1_ADDR)
    local enemy_type2 = emu:read8(ENEMY_TYPE2_ADDR)

    local best_score = -1
    local best_slot = -1

    for i = 1, 4 do
        local pp = emu:read8(PP_ADDRS[i])
        if pp == 0 then
        else
            local move_id = emu:read16(PLAYER_MOVE_ADDRS[i])
            local score = score_move(move_id, enemy_type1, enemy_type2)
            if score > best_score then
                best_score = score
                best_slot = i - 1
            end
        end
    end

    if best_slot >= 0 then
        return best_slot
    end

    log("WARNING: All moves out of PP! Returning move 0 as last resort.")
    return 0
end

function move_cursor_step(target)
    local cur = emu:read8(MOVE_MENU_CURSOR)

    if cur == target then return true end
    if cur % 2 ~= target % 2 then
        apply_input(target % 2 > cur % 2 and DIRECTIONS.Right or DIRECTIONS.Left)
    else
        apply_input(math.floor(target/2) > math.floor(cur/2) and DIRECTIONS.Down or DIRECTIONS.Up)
    end
    return false
end

function party_cursor_step(target)
    local cur = emu:read8(PARTY_MENU_CURSOR)
    if cur == target then return true end
    if target > cur then
        apply_input(DIRECTIONS.Down)
    else
        apply_input(DIRECTIONS.Up)
    end
    return false
end
-- TODO: Fainted ! is not working 100% of the time more lite every time 70% at the time
function handle_fainted()
    local faint_state_menu = detect_faint_menu_state()
    local post_faint_state = detect_post_faint_menu_state()

    if fightPhase == "faint_message" then
        log("[FAINT] Dismissing faint message, pressing A")
        apply_input(BUTTONS.A)
        return
    end

    
    if faint_state_menu == "not_fainted" then
        log("[FAINT] Prompt no longer active, exiting faint handling")
        fightPhase = "top"
        return
    end

    if faint_state_menu == "faint_menu_no" then
        apply_input(DIRECTIONS.Up)
        return
    elseif faint_state_menu == "faint_menu_yes" and faint_state == nil then
        apply_input(BUTTONS.A)
        faint_state = "faint_party"
        targetPartySlot = 0
        log("[FAINT] Pressed A on YES, moving to FAINT_PARTY phase")
        return
    elseif faint_state == "faint_party" then
        
        log("[FAINT] Post-faint menu state: %s", post_faint_state)

        if post_faint_state == "yes_no_prompt" then
            log("[FAINT] Still in Yes/No prompt, waiting for party menu to open")
            return
        end

        if post_faint_state == "party_list" then
            log("[FAINT_PARTY] Party menu is open, navigating to party slot %d", targetPartySlot)
            if targetPartySlot == 0 then
                targetPartySlot = find_next_awake_slot()
                log("[FAINT_PARTY] Found target slot: %d", targetPartySlot)
            end

            local on_target = party_cursor_step(targetPartySlot)
            if on_target then
                log("[FAINT_PARTY] Reached slot %d, pressing A to send out", targetPartySlot)
                apply_input(BUTTONS.A)
                fightPhase = "top"
                log("[FAINT_PARTY] Pokémon %d sent out, returning to TOP phase", targetPartySlot)
                faint_state = nil
            end
        end
    end
end

function handle_fighting()
    local top_cursor = emu:read8(TOP_MENU_CURSOR)
    local move_cursor = emu:read8(MOVE_MENU_CURSOR)
    local ctl_curs = control_cursors()
    local menu_state = emu:read8(MENU_STATE_ADDR)

    if fightPhase == "startup" then
        if startupStep == 0 then
            log("[STARTUP STEP 0] next_pokemon=%d", ctl_curs.next_pokemon)
            if ctl_curs.next_pokemon == 5 then
                log("[STARTUP STEP 0] Wild pokemon dismissed, advancing to step 1")
                startupStep = 1
                return
            end
            if buttonHoldFrames == 0 then
                log("[STARTUP STEP 0] Pressing A to dismiss wild pokemon screen")
                apply_input(BUTTONS.A)
            end
            return
        elseif startupStep == 1 then
            log("[STARTUP STEP 1] Pressing A to dismiss encounter message")
            apply_input(BUTTONS.A)
            startupStep = 2
            return
        else
            log("[STARTUP STEP 2] Transitioning to TOP phase")
            fightPhase = "top"
            startupStep = 0
            
            return
        end
    end

    if menu_state == 0 then
        local top_cursor = emu:read8(TOP_MENU_CURSOR)

        if top_cursor == targetTopMenu then
            log("[TOP MENU] Cursor at target (%d), pressing A", top_cursor)
            apply_input(BUTTONS.A)
            targetMove = best_move_slot()
            local pp = emu:read8(PP_ADDRS[targetMove + 1])
            log("[TOP MENU] Selected move slot %d with PP=%d, transitioning to MOVE phase", targetMove, pp)

            fightPhase = "move"
            
            return
        else
            log("[TOP MENU] Cursor at %d, target is %d - navigating", top_cursor, targetTopMenu)
            if top_cursor % 2 ~= targetTopMenu % 2 then
                apply_input(targetTopMenu % 2 > top_cursor % 2 and DIRECTIONS.Right or DIRECTIONS.Left)
            else
                apply_input(math.floor(targetTopMenu/2) > math.floor(top_cursor/2) and DIRECTIONS.Down or DIRECTIONS.Up)
            end
            return
        end
    end

    if menu_state == 1 then
        

        log("[MOVE PHASE] Navigating to move slot %d", targetMove)
        local on_target = move_cursor_step(targetMove)
        if not on_target then
            log("[MOVE PHASE] Still navigating to slot %d", targetMove)
            return
        end
        if targetMove == move_cursor then
            log("[MOVE PHASE] Cursor already at target move slot %d, pressing A to confirm", targetMove)
            log("[MOVE PHASE] Move confirmed, transitioning back to TOP phase")
            fightPhase = "top"
            return
        end
        return
    end
end

function handle_battle()
    local cur_hp = get_player_hp()
    local faint_menu_state = detect_faint_menu_state()

    if cur_hp == 0 then
        fainting = true
        if faint_menu_state ~= "not_fainted" then
            fightPhase = faint_menu_state
        else
            fightPhase = "faint_message"
        end
        handle_fainted()
    else
        fainting = false
        handle_fighting()
    end
end

-- ── pokemon center routes ───────────────────────────────────────────────────
-- 1st check hp of team decide when to go back
-- 2st go all the way back to center, stand infront of the nurse
-- 3st talk and finish the the whole dialogue, repeat press A until pokemons health is 100%
-- 4st turn around and go back to the farming route



-- ─── FARMING ROUTES ─────────────────────────────────────────────────────────

function start_farming(direction)
    local r = direction == 1 and farming_route or reverse_route(farming_route)
    --local r = direction == 1 and route or reverse_route(route)
    local pos = get_position()
    local startIndex = 1
    local found = false
        for i = 1, #r do
        if r[i].x == pos.x and r[i].y == pos.y then
            startIndex = i + 1; found = true; break
        end
    end
    if not found then
        if r[1] and (r[1].x ~= pos.x or r[1].y ~= pos.y) then
            log("pos=(%d,%d) not on farming route, not starting", pos.x, pos.y)
            return
        end
    end
    routeDirection = direction
    runningRoute   = true
    stop           = false
    stop_movement()
    set_route(r)
    currentRouteIndex = startIndex
end

-- ─── MAIN CALLBACK ──────────────────────────────────────────────────────────

function checkMap()
    if stop then return end
    frame = frame + 1
    local map = emu:read16(MAP_ADDR)
    local pos = get_position()

    if buttonReleaseDelay > 0 then
        buttonReleaseDelay = buttonReleaseDelay - 1
        return  -- skip everything until delay is done
    end

    
    if buttonHoldFrames > 0 then
        buttonHoldFrames = buttonHoldFrames - 1
        if currentButton and emu and emu.setKeys then emu:setKeys(currentButton.bit)
        elseif currentButton and input and input.set then input.set({ [currentButton.key] = true })
        elseif currentButton and joypad and joypad.set then joypad.set({ [currentButton.key] = true })
        end
        return
    elseif currentButton then
        if emu and emu.setKeys then emu:setKeys(0)
        elseif input and input.set then input.set({ [currentButton.key] = false })
        elseif joypad and joypad.set then joypad.set({ [currentButton.key] = false })
        end
        currentButton = nil
        buttonReleaseDelay = 3  
    end
        --log("pos=(" .. pos.x .. "," .. pos.y .. ") map: " .. map .. ")")

   

    if battle_flag_is_set() and not inBattle then
        inBattle = true
        fightPhase = "startup"
        startupStep = 0
        fainting = false
        log("Battle started (flag)")
    end

    if inBattle then
        local enemy_cur = get_enemy_hp()
        party_hp_score = check_party_hp_score()


        if not battle_flag_is_set() then
            if fainting then
                handle_fainted()
                return
            end
            if enemy_cur == 0 then
                inBattle = false
                log("Battle ended")
                if party_hp_score <= HP_THRESHOLD then
                    goBack(true)
                    return
                else
                    start_farming(routeDirection)
                    return
                end
            end
            return
        end
        if every_n_frames(30) then
           handle_battle()
        end
        return
    end


    if every_n_frames(60) then
        if recovery_tick(pos) then
            return
        end
    end

    --  if not inBattle then
    --     log("[DEBUG]: not in battle")
    -- end

    --  if not returningToNurse then
    --     log("[DEBUG]: not returning to nurse ")
    -- end

    if every_n_frames(5) then
        party_hp_score = check_party_hp_score()
        local active = isNurseActive()

        if map == EVER_GARDE_MAP and pos.x == 10 and pos.y == 11 then
            local done = handle_nurse(active)
            
            if done then
                if not returningToFarm then
                    log("Nurse done, going back to farm")
                    returningToFarm = true
                    goBack(false)
                end
            end
        end

        if map ~= VICTORY_ROAD_MAP and not runningRoute and  party_hp_score > HP_THRESHOLD then
            goBack(false)
        end
    
        if map == VICTORY_ROAD_MAP and not runningRoute and not inBattle and party_hp_score >= HP_THRESHOLD then
            start_farming(1)
        end

        if party_hp_score < HP_THRESHOLD and not inBattle and not returningToNurse then
            log("Party HP low (score=%.2f), returning to nurse", party_hp_score)
            returningToNurse = true
            goBack(true)
            return
        end

        local ok, err = follow_route()
        if ok == true then
            runningRoute = false
            if map == VICTORY_ROAD_MAP and party_hp_score >= HP_THRESHOLD then
                local next = routeDirection == 1 and -1 or 1
                log("Arrived at farming area")
                start_farming(next)
                return
            end
        elseif ok == false then
            runningRoute = false
            log("Route error: %s", err)
        end
    end


    
    if every_n_frames(200) then
        if not inBattle then  -- your existing battle check
            local current_val = emu:read8(dialog_addr)
            if current_val == dialog_baseline then
                apply_input(BUTTONS.A)
            end
        end
    end
end


---DEBUGGING COMMANDS should not be in this file
function logNurseDebug()
    print(string.format(
        "active:%d text:%d stage:%d",
        emu:read8(0x020375F2),
        emu:read8(0x020206A6),
        emu:read16(0x02024A92)
    ))
end

function debug_party()
    for slot = 0, 5 do
        local base = PARTY_BASE + (slot * POKEMON_STRUCT_SIZE)
        local level = emu:read8(base + LEVEL_OFFSET) or 0
        local hp = emu:read16(base + HP_CURRENT_OFFSET) or 0
        local maxhp = emu:read16(base + HP_MAX_OFFSET) or 0
        log("slot %d base=0x%X level=%d hp=%d/%d", slot, base, level, hp, maxhp)
    end
end

function debug_next_awake_slot()
        local targetPartySlot = find_next_awake_slot()
        log("[FAINT_PARTY] Found target slot: %d", targetPartySlot)
end

function detect_battle_menu_state()
    local menu_state = emu:read8(MENU_STATE_ADDR)
    local top_cursor = emu:read8(TOP_MENU_CURSOR)
    local move_cursor = emu:read8(MOVE_MENU_CURSOR)
    local party_cursor = emu:read8(PARTY_MENU_CURSOR)

    log("═══ MENU STATE SNAPSHOT ═══")
    log("0x020207EE (MENU_STATE): %d", menu_state)
    log("0x020244AC (TOP_CURSOR):    %d", top_cursor)
    log("0x020244B0 (MOVE_CURSOR):   %d", move_cursor)
    log("0x0203CED1 (PARTY_CURSOR):  %d", party_cursor)
    log("═══════════════════════════")
end

callbacks:add("frame", checkMap)
