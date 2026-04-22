-- Pokémon Type Finder - Movement + Battle Detection + Type Check
-- Reuses movement code from main_bot, keeps it minimal

local frame = 0
local stop = false
local inBattle = false
local currentRouteIndex = 1
local routeToFollow = nil
local movementTask = nil
local fightPhase = "startup"
local buttonHoldFrames = 0
local currentButton = nil
local buttonReleaseDelay = 0
local topMenuNavigationAttempts = 0  

-- ─── RAM ADDRESSES ──────────────────────────────────────────────────────────
local X_ADDR = 0x02037360
local Y_ADDR = 0x02037362
local MAP_ADDR = 0x0203732C

local BATTLE_FLAG_ADDR = 0x02024068
local MENU_STATE_ADDR = 0x020207EE
local ENEMY_SPECIES_ADDR = 0x020240DC
local ENEMY_TYPE1_ADDR = 0x020240DC + 0x21
local ENEMY_TYPE2_ADDR = 0x020240DC + 0x22
local TOP_MENU_CURSOR = 0x020244AC
local MOVE_MENU_CURSOR = 0x020244B0
local PARTY_MENU_CURSOR = 0x0203CED1
local NEXT_POKEMON_CURSOR = 0x02024333

-- ─── CONSTANTS ──────────────────────────────────────────────────────────────
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

-- ─── CONFIG: Edit these to customize your search ─────────────────────────────
-- Only catch pure Water types (type1=Water, type2=None)
local WANTED_TYPE = {
    [14] = true,  -- Psychic
    [16] = true,  -- Dragon
}


-- Pokemon IDs to skip (add species IDs you don't want here) [328] is feebas
local SKIP_POKEMON = {
    [326] = true, --corphis
    [120] = true,
    -- [123] = true,  -- Example: skip Scyther
}

--route  map13🥇
-- local route = {
--     {x=22, y=8}, {x=23, y=8}, {x=24, y=8}, {x=25, y=8},
--     {x=26, y=8}, {x=27, y=8}, {x=28, y=8}, {x=29, y=8},
--     {x=30, y=8}, {x=31, y=8}, {x=32, y=8}, {x=33, y=8},
--     {x=34, y=8}, {x=35, y=8}, {x=36, y=8}, {x=37, y=8},
--     {x=38, y=8}, {x=39, y=8}, {x=40, y=8}, {x=41, y=8},
--     {x=42, y=8}, {x=43, y=8}, {x=44, y=8}, {x=45, y=8},
--     {x=46, y=8}, {x=47, y=8}, {x=48, y=8}, {x=49, y=8},
--     {x=50, y=8}, {x=51, y=8}, {x=52, y=8}, {x=53, y=8},
--     {x=54, y=8}, {x=55, y=8}, {x=56, y=8}, {x=57, y=8},
-- }
local route = {
    {x=26, y=133},
    {x=26, y=134},
    {x=26, y=135},
    {x=26, y=136},
    {x=26, y=137},
    {x=26, y=138},
    {x=26, y=139},
    {x=26, y=140},
    {x=26, y=141},
    {x=26, y=142},
    {x=26, y=143},
    {x=26, y=144},
    {x=26, y=145},
    {x=26, y=146},
    {x=66, y=7},
    {x=66, y=8},
    {x=66, y=9},
    {x=66, y=10},
    {x=66, y=11},
    {x=66, y=12},
    {x=66, y=13},
    {x=66, y=14},
    {x=66, y=15},
    {x=66, y=16},
    {x=66, y=17},
    {x=66, y=18},
    {x=66, y=19},
    {x=66, y=20},
    {x=65, y=20},
    {x=64, y=20},
    {x=63, y=20},
    {x=62, y=20},
    {x=61, y=20},
    {x=60, y=20},
    {x=59, y=20},
    {x=59, y=19},
    {x=59, y=18},
    {x=59, y=17},
    {x=59, y=16},
}


-- ─── UTILITY FUNCTIONS ──────────────────────────────────────────────────────

function log(formatString, ...)
    local msg = string.format(formatString, ...)
    if console and console.log then
        console:log(msg)
    else
        print(msg)
    end
end
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

function get_position()
    return {
        x = emu:read16(X_ADDR),
        y = emu:read16(Y_ADDR)
    }
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

function battle_flag_is_set()
    if BATTLE_FLAG_ADDR then return emu:read16(BATTLE_FLAG_ADDR) ~= 0 end
    return false
end

-- ─── MOVEMENT ───────────────────────────────────────────────────────────────

function reverse_route(r)
    local rev = {}
    for i = #r, 1, -1 do
        rev[#rev + 1] = r[i]
    end
    return rev
end

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
    routeToFollow = route
    currentRouteIndex = 1
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
        routeToFollow = reverse_route(routeToFollow)
        currentRouteIndex = 1
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
    elseif pos.x == 26 and pos.y == 146 then
    start_movement("Down", pos.x, pos.y - 1)
        return nil
    elseif pos.x == 66 and pos.y == 7 then
    start_movement("Up", pos.x, pos.y + 1)
        return nil
    else
        return false, string.format("failed at step %d (%d,%d)", currentRouteIndex, step.x, step.y)
    end
end

-- ─── BATTLE LOGIC ───────────────────────────────────────────────────────────

local runPhase = nil
local runStartupStep = 0
local runStateFrames = 0
local startupFrameCounter = 0

function handle_run_sequence()
    local menu_state = emu:read8(MENU_STATE_ADDR)
    local top_cursor = emu:read8(TOP_MENU_CURSOR)

    if menu_state == 1 then
        apply_input(BUTTONS.B)
    end 

    if fightPhase == "startup" then
        startupFrameCounter = startupFrameCounter + 1

        if runStartupStep == 0 then
            apply_input(BUTTONS.A)

            if startupFrameCounter > 20 then
                runStartupStep = 1
                startupFrameCounter = 0
            end
            return
        elseif runStartupStep == 1 then
            apply_input(BUTTONS.A)

            if startupFrameCounter > 20 then
                runStartupStep = 2
                startupFrameCounter = 0
            end
            return
        else
            fightPhase = "top"
            runStartupStep = 0
            startupFrameCounter = 0
            return
        end
    end

    if menu_state == 0 then
        if top_cursor == 3 then
            apply_input(BUTTONS.A)
            topMenuNavigationAttempts = 0
            return
        else
            topMenuNavigationAttempts = topMenuNavigationAttempts + 1

            if topMenuNavigationAttempts > 20 then
                apply_input(BUTTONS.A)
                topMenuNavigationAttempts = 0
                fightPhase = "top_pressed_a"
                return
            end

            if top_cursor % 2 ~= 3 % 2 then
                apply_input(3 % 2 > top_cursor % 2 and DIRECTIONS.Right or DIRECTIONS.Left)
            else
                apply_input(math.floor(3/2) > math.floor(top_cursor/2) and DIRECTIONS.Down or DIRECTIONS.Up)
            end
            return
        end
    end
end

function get_enemy_info()
    local species = emu:read16(ENEMY_SPECIES_ADDR)
    local type1 = emu:read8(ENEMY_TYPE1_ADDR)
    local type2 = emu:read8(ENEMY_TYPE2_ADDR)
    return species, type1, type2
end

function handle_battle()
    local species, type1, type2 = get_enemy_info()

    log("[BATTLE] Species: %d | Type 1: %d (%s), Type 2: %d (%s)",
        species,
        type1, TYPE_NAMES[type1] or "?",
        type2, TYPE_NAMES[type2] or "?")

    if SKIP_POKEMON[species] then
        if not runPhase then
            runPhase = "startup"
            runStartupStep = 0
        end
        handle_run_sequence()
        return
    end

    if WANTED_TYPE[type1] and (type2 == 0 or WANTED_TYPE[type2]) then
        log("[BATTLE] WANTED TYPE! Stopping to catch.")
        stop = true
        clear_input()
        return
    end


    if not runPhase then
        runPhase = "startup"
        runStartupStep = 0
    end
    handle_run_sequence()
end

-- ─── MAIN CALLBACK ──────────────────────────────────────────────────────────

function checkMap()
    if stop then return end
    frame = frame + 1

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

    if inBattle then
        if not battle_flag_is_set() then
            inBattle = false
            fightPhase = "startup"
            runPhase = nil
            runStartupStep = 0
            stop_movement()
            local pos = get_position()
            for i = 1, #routeToFollow do
                if routeToFollow[i].x == pos.x and routeToFollow[i].y == pos.y then
                    currentRouteIndex = i + 1
                    break
                end
            end
            follow_route()
            return
        end

        if fightPhase == "startup" and frame % 20 == 0 then
            handle_run_sequence()
        else
            handle_battle()
        end
        return
    end

    if not inBattle and not routeToFollow then
        follow_route()
    end

    if battle_flag_is_set() and not inBattle then
        inBattle = true
        fightPhase = "startup"
        return
    end

    follow_route()
end

-- ─── CALLBACKS ──────────────────────────────────────────────────────────────

function startFinder(routeParam)
    stop = false
    inBattle = false

    local pos = get_position()
    local r = routeParam or route
    set_route(r)

    local startIndex = 1
    for i = 1, #routeToFollow do
        if routeToFollow[i].x == pos.x and routeToFollow[i].y == pos.y then
            startIndex = i + 1
            break
        end
    end

    currentRouteIndex = startIndex
end

function stopFinder()
    stop = true
    stop_movement()
end

callbacks:add("frame", checkMap)
