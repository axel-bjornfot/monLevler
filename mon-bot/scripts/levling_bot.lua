-- Clean tile-based movement system for mGBA Lua

local frame = 0
local runningRoute = false
local stop = false
local stuckCounter = 0
local recoveryMode = false
local recoveryDelay = 0
local routeActiveFrames = 0
local lastPos = { x = nil, y = nil }

-- Use the confirmed tile coordinates for the player.
local X_ADDR = 0x02037360  -- Player X in tiles
local Y_ADDR = 0x02037362  -- Player Y in tiles
local MAP_ADDR = 0x0203732C

-- Tile-based directions. The confirmed RAM values are already tile coordinates.
local DIRECTIONS = {
    Up    = { dx =  0, dy = -1, key = "Up",    bit = 64 },
    Down  = { dx =  0, dy =  1, key = "Down",  bit = 128 },
    Left  = { dx = -1, dy =  0, key = "Left",  bit = 32 },
    Right = { dx =  1, dy =  0, key = "Right", bit = 16 }
}

local BUTTONS = {
    A = { key = "A", bit = 1 }
}

-- Read the current player position from RAM.
function get_position()
    return {
        x = emu:read16(X_ADDR),
        y = emu:read16(Y_ADDR)
    }
end

-- Press one direction key for one frame (or two frames if needed).
function apply_input(direction)
    if emu and emu.setKeys then
        emu:setKeys(direction.bit)
    elseif input and input.set then
        input.set({ [direction.key] = true })
    elseif joypad and joypad.set then
        joypad.set({ [direction.key] = true })
    else
        error("No input API available")
    end
end

function press_button(button)
    apply_input(button)
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

function positions_equal(a, b)
    return a and b and a.x == b.x and a.y == b.y
end

local STUCK_THRESHOLD = 90
local RECOVERY_DELAY_FRAMES = 60

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
        press_button(BUTTONS.A)
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
    log("Recovery active: spamming A")
    press_button(BUTTONS.A)
    return true
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

function log(formatString, ...)
    local msg = string.format(formatString, ...)
    if console and console.log then
        console:log(msg)
    else
        print(msg)
    end
end

-- Press a direction for one tile movement.
function press_button(directionName)
    local dir = DIRECTIONS[directionName]
    if not dir then
        return false, "invalid_direction"
    end

    apply_input(dir)
    return true
end

-- Wait until some condition is true or a timeout occurs.
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

-- Move exactly one tile in the given direction.
function move_one_tile(directionName)
    local dir = DIRECTIONS[directionName]
    if not dir then
        return false, "invalid_direction"
    end

    local start = get_position()
    local targetX = start.x + dir.dx
    local targetY = start.y + dir.dy

    apply_input(dir)
    local arrived = wait_until(function()
        local pos = get_position()
        return pos.x == targetX and pos.y == targetY
    end, 120)

    clear_input()

    if not arrived then
        return false, "move_timeout"
    end

    return true
end

-- Move to an adjacent tile described in tile coordinates.
function move_to_adjacent_tile(targetTile)
    local pos = get_position()
    local dx = targetTile.x - pos.x
    local dy = targetTile.y - pos.y

    if dx == 1 and dy == 0 then
        return move_one_tile("Right")
    elseif dx == -1 and dy == 0 then
        return move_one_tile("Left")
    elseif dx == 0 and dy == 1 then
        return move_one_tile("Down")
    elseif dx == 0 and dy == -1 then
        return move_one_tile("Up")
    else
        log("Adjacency fail: pos=(%d,%d) target=(%d,%d) dx=%d dy=%d", pos.x, pos.y, targetTile.x, targetTile.y, dx, dy)
        return false, "target_not_adjacent"
    end
end

local currentRouteIndex = 1
local routeToFollow = nil
local movementTask = nil

function reverse_route(route)
    local rev = {}
    for i = #route, 1, -1 do
        rev[#rev + 1] = route[i]
    end
    return rev
end

function find_route_start_index(route, pos)
    for i, step in ipairs(route) do
        if pos.x == step.x and pos.y == step.y then
            return i
        end
    end
    return 1
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

function follow_route()
    if not routeToFollow then
        return false, "no_route_set"
    end

    local pos = get_position()

    if movementTask then
        if pos.x == movementTask.targetX and pos.y == movementTask.targetY then
            stop_movement()
            currentRouteIndex = currentRouteIndex + 1
            return nil
        end

        movementTask.frames = movementTask.frames + 1
        if movementTask.frames > movementTask.timeout then
            stop_movement()
            return false, string.format("move_timeout at step %d", currentRouteIndex)
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
    else
        return false, string.format("failed at step %d (%d,%d): target_not_adjacent pos=(%d,%d) dx=%d dy=%d",
            currentRouteIndex, step.x, step.y, pos.x, pos.y, dx, dy)
    end
end

-- Route data is tile-based. Keep route shapes as data only.

local route = {
    {x=10, y=11}, {x=10, y=12}, {x=10, y=13}, {x=10, y=14}, {x=10, y=15},
    {x=11, y=15}, {x=12, y=15}, {x=13, y=15}, {x=14, y=15}, {x=15, y=15}, {x=16, y=15},
    {x=16, y=16}, {x=16, y=17}, {x=16, y=18}, {x=16, y=19}, {x=16, y=20}, {x=16, y=21}, {x=16, y=22}, {x=16, y=23}, {x=16, y=24},
    {x=17, y=24}, {x=18, y=24}, {x=19, y=24}, {x=20, y=24}, {x=21, y=24}, {x=22, y=24}, {x=23, y=24}, {x=24, y=24}, {x=25, y=12}, {x=25, y=13}, {x=25, y=14}, {x=25, y=15}, {x=25, y=16}, {x=25, y=17}, {x=25, y=18}, {x=25, y=19}, {x=25, y=20}, {x=25, y=21}, {x=25, y=22}, {x=25, y=23}, {x=25, y=24},
    {x=26, y=24}, {x=27, y=24}, {x=28, y=24}, {x=29, y=24}, {x=30, y=24}, {x=31, y=24}, {x=32, y=24},
    {x=32, y=25}, {x=32, y=26}, {x=32, y=27}, {x=32, y=28}, {x=32, y=29}, {x=32, y=30}, {x=32, y=31}, {x=32, y=32}, {x=32, y=33}, {x=32, y=34}, {x=32, y=35},
    {x=31, y=35}, {x=30, y=35}, {x=29, y=35}, {x=28, y=35}, {x=27, y=35}, {x=26, y=35}, {x=25, y=35},
    {x=25, y=34}, {x=46, y=12},
}
local farming_route = {
    {x=45, y=12},{x=44, y=12},{x=43, y=12},{x=43, y=12},{x=42, y=12},{  x=41, y=12},{x=40, y=12},{x=39, y=12},{x=38, y=12},{x=37, y=12},
}
    
function find_closest_route_index(pos, route)
    local minDist = math.huge
    local closestIndex = 1
    for i = 1, #route do
        local dx = route[i].x - pos.x
        local dy = route[i].y - pos.y
        local dist = dx*dx + dy*dy
        if dist < minDist then
            minDist = dist
            closestIndex = i
        end
    end
    return closestIndex
end

function set_route(route)
    routeToFollow = route
    currentRouteIndex = 1
end

function startRoute()
    local pos = get_position()
    
    -- Find the index in route where route[index] == pos, to resume from there
    local found = false
    local startIndex = 1
    for i = 1, #route do
        if route[i].x == pos.x and route[i].y == pos.y then
            startIndex = i + 1
            found = true
            break
        end
    end
    
    if not found then
        if route[1] and (route[1].x ~= pos.x or route[1].y ~= pos.y) then
            log("Position (%d,%d) not in route, not starting", pos.x, pos.y)
            return
        end
        -- If pos == route[1], startIndex remains 1, and follow_route will skip it
    end
    
    runningRoute = true
    stop = false
    stuckCounter = 0
    recoveryMode = false
    recoveryDelay = 0
    routeActiveFrames = 0
    stop_movement()
    set_route(route)
    currentRouteIndex = startIndex
    local first = { x = 0, y = 0 }
    if routeToFollow and routeToFollow[currentRouteIndex] then
        first = routeToFollow[currentRouteIndex]
    end
    log("Route started: current=(%d,%d) startIndex=%d startStep=(%d,%d)", pos.x, pos.y, currentRouteIndex, first.x, first.y)
end

function goBack()
    runningRoute = true
    stop = false
    stuckCounter = 0
    recoveryMode = false
    recoveryDelay = 0
    routeActiveFrames = 0
    stop_movement()
    set_route(reverse_route(route))
    local pos = get_position()
    local first = { x = 0, y = 0 }
    if routeToFollow and routeToFollow[currentRouteIndex] then
        first = routeToFollow[currentRouteIndex]
    end
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

function checkMap()
    if stop then return end
    frame = frame + 1

    local map = emu:read16(MAP_ADDR)
    local pos = get_position()

    if map == 15 and not runningRoute then
        startRoute()
    end

    if runningRoute and map == 15 then
        if recovery_tick(pos) then
            return
        end

        local ok, err = follow_route()
        if ok == true then
            runningRoute = false
            log("Route complete")
            stop_movement()
        elseif ok == false then
            runningRoute = false
            log("Route error: %s", err)
        end
    end
    if map == 70 then
         log("Not on route but on correct map, starting route")
         stop_movement()
    end
    if frame % 60 == 0 then
        log("Map: %d | X: %d | Y: %d", map, pos.x, pos.y)
    end
end

callbacks:add("frame", checkMap)
