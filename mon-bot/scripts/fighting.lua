-- Fighting bot for Pokémon Emerald US
-- Walks farming_route back and forth inside Victory Road to trigger encounters.
-- Battle detection is positional: when movement is blocked, we assume a battle.
local frame  = 0
local stop   = false

-- ─── debug values ────────────────────────────────────────────────────────────
local BATTLE_DETECT = 0
local BATTLE_START = 0
local LAST_BATTLE_POS = {}
local DIALOG_DETECT = 0

-- ─── RAM addresses ────────────────────────────────────────────────────────────

local X_ADDR   = 0x02037360
local Y_ADDR   = 0x02037362
local MAP_ADDR = 0x0203732C

-- How to find BATTLE_FLAG: note value outside battle, enter battle, see what changed to non-zero.
-- How to find HP: use Tools → Memory Search → search 16-bit value = your current HP,
--   take damage, search new HP value.  Two searches usually give 1-2 candidates.
local BATTLE_FLAG_ADDR  = 0x02024068  -- confirmed: 0 outside battle, 1 inside
local PLAYER_HP_CURRENT = 0x020240AC  -- confirmed: current HP of lead Pokémon
local PLAYER_HP_MAX     = 0x020240B0  -- confirmed: max HP of lead Pokémon
local ENEMY_HP_CURRENT  = 0x02024104  -- confirmed: gBattleMons[1] current HP (player + 0x58)
local ENEMY_HP_MAX      = 0x02024108  -- confirmed: gBattleMons[1] max HP

-- PP for player's moves (u8).  Confirmed via pp_save()/pp_diff().
-- PP[0..3] are 4 consecutive bytes in the player battle struct at offset 0x24.
-- PP_MOVE2 was previously listed as 0x02024083 (likely wrong — that's far outside the struct).
local PP_MOVE1 = 0x020240A8   -- struct+0x24
local PP_MOVE2 = 0x020240A9   -- struct+0x25 (corrected from 0x02024083)
local PP_MOVE3 = 0x020240AA   -- struct+0x26
local PP_MOVE4 = 0x020240AB   -- struct+0x27

-- Top menu cursor
local TOP_MENU_CURSOR = 0x020244AC
-- 0 = Fight, 1 = Bag, 2 = Pokemon, 3 = Run
local MOVE_MENU_CURSOR = 0x020244B0
-- 0 = Move 1, 1 = Move 2, 2 = Move 3, 3 = Move 4
local PARTY_MENU_CURSOR = 0x0203CED1
-- slot 1 = 0, slot 2 = 1, slot 3 = 2, slot 4 = 3, slot 5 = 4, slot 6 = 5
local NEXT_POKEMON_CURSOR = 0x02024333
-- read8: 0 = Yes, 1 = No (only meaningful when prompt is visible)

local PARTY_MENU_ACTIVE = 0x02021834      -- 0 = not in party, 1 = in party
local MENU_STATE_SECONDARY = 0x02024332   -- 1 = yes/no, 257 = party list

local MENU_STATE_ADDR = 0x020207EE
-- 0 = top-menu, 1 = move-menu, possibly 2 in faint menu (to be tested)

-- Party Pokémon HP structure (u16 current, u16 max).
-- Estimated: gPlayerParty at 0x02024290, each Pokémon struct = 0x64 bytes, HP current at +0x58
-- If wrong, use mGBA Tools → Memory Search to locate party HP addresses and update below.
local PARTY_BASE        = 0x02024290
local POKEMON_STRUCT_SIZE = 0x64
local HP_CURRENT_OFFSET = 0x58

-- PP lookup table (index 1-4 maps to move slots 0-3)
local PP_ADDRS = { PP_MOVE1, PP_MOVE2, PP_MOVE3, PP_MOVE4 }

-- ════ FAINT MENU STATE DETECTION ════
-- Reliable detection of faint prompt and Yes/No cursor position
local FAINT_PROMPT_ACTIVE = 0x02000418      -- 0 = not showing, 1 = showing
local FAINT_CURSOR_POS = 0x02024A82  
local FAINT_CURSOR_POS_OPTION = 0x02024332-- YES=1, NO=257 

function detect_faint_menu_state()
    local prompt_active = emu:read8(FAINT_PROMPT_ACTIVE)
    local cursor_state = emu:read16(FAINT_CURSOR_POS_OPTION)
    local party_active = emu:read8(PARTY_MENU_ACTIVE)

    log("[FAINT] prompt_active=%d, cursor_state=%d", prompt_active, cursor_state)

    -- Is the faint prompt on screen?
    if prompt_active ~= 1 then
        return "not_fainted"
    end

    -- Which button is selected? (YES=1, NO=257)
    if cursor_state == 1 then
        return "faint_menu_yes"
    elseif cursor_state == 257 then
        return "faint_menu_no"
    else
        log("UNKNOWN cursor_state=%d", cursor_state)
        return "unknown"
    end
    
end

-- ════ POST-FAINT MENU STATE DETECTION ════
-- Distinguishes between Yes/No prompt and party list selection after faint
function detect_post_faint_menu_state()
    local party_active = emu:read8(PARTY_MENU_ACTIVE)
    local menu_state = emu:read16(MENU_STATE_SECONDARY)

    log("[POST_FAINT] party_active=%d, menu_state=%d", party_active, menu_state)

    -- Party menu is open when menu_state == 257 or party_active == 1
    if menu_state == 257 or party_active == 1 then
        return "party_list"
    -- Still in Yes/No prompt when menu_state == 1
    elseif menu_state == 1 then
        return "yes_no_prompt"
    else
        return "unknown"
    end
end

-- ════ MENU STATE DETECTION (for battle moves) ════
-- Reads all relevant memory addresses and logs them to identify which menu is active
function detect_battle_menu_state()
    local menu_state = emu:read8(MENU_STATE_ADDR)
    local top_cursor = emu:read8(TOP_MENU_CURSOR)
    local move_cursor = emu:read8(MOVE_MENU_CURSOR)
    local party_cursor = emu:read8(PARTY_MENU_CURSOR)
    local next_pokemon = emu:read8(NEXT_POKEMON_CURSOR)

    -- Read some additional addresses that might distinguish menus
    local addr_0203C794 = emu:read8(0x0203C794)
    local addr_0203C795 = emu:read8(0x0203C795)
    local addr_0203C796 = emu:read8(0x0203C796)
    local addr_0203C797 = emu:read8(0x0203C797)

    log("═══ MENU STATE SNAPSHOT ═══")
    log("0x020207EE (MENU_STATE): %d", menu_state)
    log("0x020244AC (TOP_CURSOR):    %d", top_cursor)
    log("0x020244B0 (MOVE_CURSOR):   %d", move_cursor)
    log("0x0203CED1 (PARTY_CURSOR):  %d", party_cursor)
    log("0x02024333 (NEXT_POKEMON):  %d", next_pokemon)
    log("0x0203C794: %d", addr_0203C794)
    log("0x0203C795: %d", addr_0203C795)
    log("0x0203C796: %d", addr_0203C796)
    log("0x0203C797: %d", addr_0203C797)
    log("═══════════════════════════")
end

--My party pokedex
local MY_PARTY = {Breloom = 286, Aggron = 306, Manectric = 310,} 
-- moves of party memebers
local moveNamesById = {
    [73]  = "Leech Seed",
    [78]  = "Stun Spore",
    [202] = "Giga Drain",
    [300] = "Drain Punch",
    [157] = "Rock Slide",
    [231] = "Iron Tail",
    [156] = "Rest",
    [103] = "Screech",
    [19]  = "Fly",
    [346] = "Draco Meteor",
    [337] = "Dragon Claw",
    [349] = "Dragon Dance",
    [242] = "Crunch",
    [58]  = "Ice Beam",
    [127] = "Waterfall",
    [97]  = "Agility",
    [94]  = "Psychic",
    [326] = "Extrasensory",
    [347] = "Calm Mind",
    [104] = "Double Team",
    [85]  = "Thunderbolt",
    [209] = "Spark",
    [86]  = "Thunder Wave",
}

-- Move data: type ID and whether it deals damage
local moveData = {
    [73]  = { type = 12, damage = false },  -- Leech Seed
    [78]  = { type = 12, damage = false },  -- Stun Spore
    [202] = { type = 12, damage = true },   -- Giga Drain
    [300] = { type = 1,  damage = true },   -- Drain Punch
    [157] = { type = 5,  damage = true },   -- Rock Slide
    [231] = { type = 8,  damage = true },   -- Iron Tail
    [156] = { type = 0,  damage = false },  -- Rest
    [103] = { type = 0,  damage = false },  -- Screech
    [19]  = { type = 2,  damage = true },   -- Fly
    [346] = { type = 16, damage = true },   -- Draco Meteor
    [337] = { type = 16, damage = true },   -- Dragon Claw
    [349] = { type = 16, damage = false },  -- Dragon Dance
    [242] = { type = 17, damage = true },   -- Crunch
    [58]  = { type = 15, damage = true },   -- Ice Beam
    [127] = { type = 11, damage = true },   -- Waterfall
    [97]  = { type = 0,  damage = false },  -- Agility
    [94]  = { type = 14, damage = true },   -- Psychic
    [326] = { type = 14, damage = true },   -- Extrasensory
    [347] = { type = 14, damage = false },  -- Calm Mind
    [104] = { type = 0,  damage = false },  -- Double Team
    [85]  = { type = 13, damage = true },   -- Thunderbolt
    [209] = { type = 13, damage = true },   -- Spark
    [86]  = { type = 13, damage = false },  -- Thunder Wave
}

-- gBattleMons[0] (player) and [1] (enemy).
-- Enemy species confirmed correct at 0x020240E8 (reads national dex ID).
-- Player move 1&2 confirmed correct at 0x02024094/0x02024096.
-- Player species at struct+0x00 is still unverified — use find_player_species(dex_id).
-- Player move 3&4 addresses unknown — use find_move_addr(move_id) to locate them.
-- local PLAYER_STRUCT      = 0x02024084
-- local ENEMY_STRUCT       = 0x020240E8
local BATTLE_MON_SIZE    = 0x58

local PLAYER_STRUCT      = 0x02024084   -- if this is the one you already proved with player moves
local ENEMY_STRUCT       = 0x020240DC


local PLAYER_TYPE1_ADDR   = PLAYER_STRUCT + 0x21
local PLAYER_TYPE2_ADDR   = PLAYER_STRUCT + 0x22
local ENEMY_TYPE1_ADDR    = ENEMY_STRUCT  + 0x21
local ENEMY_TYPE2_ADDR    = ENEMY_STRUCT  + 0x22

local PLAYER_SPECIES_ADDR = PLAYER_STRUCT + 0x00  -- u16 (reads wrong; needs find_player_species)
local PLAYER_MOVE_ADDRS   = {                      -- verified slots 1&2; 3&4 TBD
    0x02024090,
    0x02024092,
    0x02024094,
    0x02024096,
}
local ENEMY_SPECIES_ADDR  = ENEMY_STRUCT + 0x00   -- u16 confirmed correct
-- Full type name table indexed by Gen-3 type ID (0–17).
-- Type 9 is the "???" glitch type; Fire/Water/etc start at 10.
local TYPE_NAMES = {
    [0]="Normal",[1]="Fighting",[2]="Flying",[3]="Poison",[4]="Ground",
    [5]="Rock",[6]="Bug",[7]="Ghost",[8]="Steel",[9]="???",
    [10]="Fire",[11]="Water",[12]="Grass",[13]="Electric",
    [14]="Psychic",[15]="Ice",[16]="Dragon",[17]="Dark",
}

-- Type effectiveness: TYPE_EFFECTIVENESS[attacker_type][defender_type] = multiplier
-- 2.0 = super effective, 1.0 = neutral, 0.5 = resists
-- Gleaming Emerald: Dark and Ghost hit Steel for neutral (1.0)
local TYPE_EFFECTIVENESS = {
    [0] = { [1]=2, [5]=0.5 },                             -- Normal: 2x Fighting, 0.5x Rock/Ghost
    [1] = { [0]=2, [5]=2, [15]=2, [17]=2, [2]=0.5, [14]=0.5, [8]=2 },  -- Fighting
    [2] = { [1]=2, [6]=2, [12]=2, [5]=0.5, [13]=0.5 },   -- Flying
    [3] = { [12]=2, [6]=2, [4]=0.5, [14]=0.5 },          -- Poison
    [4] = { [3]=2, [5]=2, [10]=2, [13]=2, [8]=2, [12]=0.5, [11]=0.5 },  -- Ground
    [5] = { [2]=2, [6]=2, [10]=2, [15]=2, [11]=0.5, [12]=0.5, [1]=0.5, [4]=0.5 },  -- Rock
    [6] = { [12]=2, [14]=2, [17]=2, [2]=0.5, [5]=0.5, [10]=0.5 },  -- Bug
    [7] = { [7]=2, [14]=2, [17]=0.5 },                   -- Ghost (Gleaming: neutral to Steel, no entry means 1.0x)
    [8] = { [15]=2, [5]=2, [0]=2, [3]=2, [12]=2, [10]=0.5, [1]=0.5, [4]=0.5 },  -- Steel
    [10] = { [12]=2, [15]=2, [8]=2, [11]=0.5, [4]=0.5, [5]=0.5 },  -- Fire
    [11] = { [4]=2, [5]=2, [10]=2, [13]=0.5, [12]=0.5 },  -- Water
    [12] = { [4]=2, [5]=2, [11]=2, [2]=0.5, [3]=0.5, [10]=0.5, [15]=0.5 },  -- Grass
    [13] = { [11]=2, [2]=2, [4]=0.5 },                   -- Electric
    [14] = { [1]=2, [3]=2, [6]=0.5, [7]=0.5, [17]=0.5 }, -- Psychic
    [15] = { [2]=2, [4]=2, [12]=2, [16]=2, [10]=0.5, [1]=0.5, [5]=0.5, [8]=0.5 },  -- Ice
    [16] = { [16]=2, [15]=0.5 },                         -- Dragon
    [17] = { [7]=2, [14]=2, [1]=0.5, [6]=0.5, [8]=1.0 }, -- Dark (Gleaming: neutral to Steel instead of resisting)
}

local DIRECTIONS = {
    Up    = { name = "Up",    dx =  0, dy = -1, key = "Up",    bit = 64  },
    Down  = { name = "Down",  dx =  0, dy =  1, key = "Down",  bit = 128 },
    Left  = { name = "Left",  dx = -1, dy =  0, key = "Left",  bit = 32  },
    Right = { name = "Right", dx =  1, dy =  0, key = "Right", bit = 16  },
}
local BUTTONS = {
    A = { name = "A", key = "A", bit = 1 },
    B = { name = "B", key = "B", bit = 2 },
}

local VICTORY_ROAD_MAP    = 70
local BATTLE_INTRO_FRAMES = 370 -- wait for encounter flash + Pokémon intro animation
local BATTLE_TOP_MENU_FRAMES = 250
local BATTLE_CURSOR_FRAMES  = 50
local BATTLE_STEP_FRAMES  = 10   -- frames between A presses while fighting
local FAINT_STEP_FRAMES   = 40   -- slower presses when sending out next Pokémon

local buttonHoldFrames = 0  -- keeps button pressed for multiple frames
local currentButton = nil  -- tracks which button is currently being held
local battleFrameCounter = 0  -- counts frames since battle started (resets on new battle)  


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
    {x=46, y=12}, {x=45, y=12}, {x=44, y=12}, {x=43, y=12}, {x=42, y=12},
    {x=41, y=12}, {x=40, y=12}, {x=39, y=12}, {x=38, y=12}, {x=37, y=12},
}

-- ─── Helpers ──────────────────────────────────────────────────────────────────



function log(fmt, ...)
    local msg = string.format(fmt, ...)
    if console and console.log then console:log(msg) else print(msg) end
end

local function every_n_frames(n)
    battleFrameCounter = battleFrameCounter + 1
    if battleFrameCounter >= n then
        battleFrameCounter = 0
        return true
    end
    return false
end

function control_cursors() 
    local top_cursor = emu:read8(TOP_MENU_CURSOR)
    local move_cursor = emu:read8(MOVE_MENU_CURSOR)
    local party_cursor = emu:read8(PARTY_MENU_CURSOR)
    local next_pokemon_cursor = emu:read8(NEXT_POKEMON_CURSOR)
    --log("Cursors - Top: %d, Move: %d, Party: %d, Next Pokémon: %d",
    --    top_cursor, move_cursor, party_cursor, next_pokemon_cursor)

    return {top = top_cursor, move = move_cursor, party = party_cursor, next_pokemon = next_pokemon_cursor}
end


function apply_input(btn)
   --og("→ Button: %s (bit=%s, key=%s)", btn.name, btn.bit, btn.key)
    if emu and emu.setKeys then emu:setKeys(btn.bit)
    elseif input  and input.set  then input.set({ [btn.key] = true })
    elseif joypad and joypad.set then joypad.set({ [btn.key] = true })
    end
    buttonHoldFrames = 5 -- hold button for 5 frames
    currentButton = btn
end

function clear_input()
    if emu and emu.setKeys then emu:setKeys(0)
    elseif input  and input.set  then input.set({})
    elseif joypad and joypad.set then joypad.set({})
    end
end

function get_position()
    return { x = emu:read16(X_ADDR), y = emu:read16(Y_ADDR) }
end

function positions_equal(a, b)
    return a and b and a.x == b.x and a.y == b.y
end

function reverse_route(r)
    local rev = {}
    for i = #r, 1, -1 do rev[#rev + 1] = r[i] end
    return rev
end

local function type_name(id)
    return TYPE_NAMES[id] or "?"
end

-- Safe RAM reads (return 0 if address not yet set)
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

-- Get current HP of a party Pokémon by slot (0-5).
local function get_party_hp(slot)
    local addr = PARTY_BASE + (slot * POKEMON_STRUCT_SIZE) + HP_CURRENT_OFFSET
    if not addr or addr <= 0 then return 0 end
    return emu:read16(addr) or 0
end

-- Find the first party slot (after current fainted one) that has HP > 0.
-- Starts from slot 1 (skip slot 0, the fainted pokemon).
local function find_next_awake_slot()
    for slot = 1, 5 do
        if get_party_hp(slot) > 0 then
            return slot
        end
    end
    return 0  -- fallback: all fainted (shouldn't happen in normal battle)
end

-- ─── Battle logic ─────────────────────────────────────────────────────────────

local inBattle       = false
-- Set to true when we see our pokemon HP = 0. Stays true until the new pokemon
-- is actively in battle (flag=1 + HP>0). This lets us detect the "Use next
-- Pokémon?" prompt even after the game pre-loads the next pokemon's HP.
local fainting = false

-- Multi-phase fight tracking:
-- "startup" = dismissing intro screens
-- "top" = on Fight/Bag/Pokemon/Run menu
-- "move" = on move-selection menu. Pressing A on "top" opens "move"
-- Faint sequence (only when cur_hp == 0):
-- "faint_message" = faint animation/message visible, press A to dismiss
-- "faint_menu_no" = cursor on No, move to Yes
-- "faint_menu_yes" = cursor on Yes, confirm selection
-- "faint_party" = navigating party menu to select next awake Pokémon
local fightPhase = "startup"  -- start with initial battle setup
local targetMove = 0   -- 0-3, which move slot to use this turn
local targetTopMenu = 0   -- 0=Fight (target for top menu)
local targetPartySlot = 0  -- which party slot to switch to during faint handling
local startupStep = 0
local battleIntro = 1   -- tracks progress through startup sequence

function battle_flag_is_set()
    if BATTLE_FLAG_ADDR then return emu:read16(BATTLE_FLAG_ADDR) ~= 0 end
    return false
end

function watch_battle_flag()
    local val = emu:read16(0x02024068)
    log("Battle flag: %d (inBattle=%s)", val, inBattle and "true" or "false")
end

function logFaintDebug()
    local prompt_active = emu:read8(FAINT_PROMPT_ACTIVE)

    local a82_8  = emu:read8(0x02024A82)
    local a82_16 = emu:read16(0x02024A82)

    local s32_8  = emu:read8(0x02024332)
    local s32_16 = emu:read16(0x02024332)

    log(
        "prompt=%d | A82: u8=%d u16=%d | 24332: u8=%d u16=%d",
        prompt_active, a82_8, a82_16, s32_8, s32_16
    )
end


-- Compact one-line battle status. Called once per turn so the console stays readable.
local function species_name(id)
    -- speciesNamesList[1] = "Treecko" = national dex #252, so offset by 251.
    if id >= 252 and speciesNamesList then return speciesNamesList[id - 251] or ("?#"..id) end
    return "?#"..id  -- Gen 1/2 not in list, or speciesNamesList not loaded
end

-- Score a move: damaging moves score by type effectiveness, non-damaging get 0
local function score_move(move_id, enemy_type1, enemy_type2)
    local move_info = moveData[move_id]
    if not move_info then return 0 end

    -- Non-damaging moves get 0 score (skip them)
    if not move_info.damage then return 0 end

    local move_type = move_info.type
    local eff = TYPE_EFFECTIVENESS[move_type] or {}

    -- Check effectiveness against both enemy types, multiply them together
    local eff1 = eff[enemy_type1] or 1.0
    local eff2 = eff[enemy_type2] or 1.0

    return eff1 * eff2
end

-- Returns 0-indexed slot of best move (by type effectiveness, with PP).
-- Fallback: first move with PP. Fallback: move 0 only if absolutely no PP anywhere.
-- TODO move must have PP. check pp and only have the moves with pp
local function best_move_slot()
    local enemy_type1 = emu:read8(ENEMY_TYPE1_ADDR)
    local enemy_type2 = emu:read8(ENEMY_TYPE2_ADDR)

    local best_score = -1
    local best_slot = -1  -- -1 = no valid move found yet

    -- First pass: find best move by type effectiveness (must have PP > 0)
    for i = 1, 4 do
        local pp = emu:read8(PP_ADDRS[i])
        if pp == 0 then
            log("  Move %d: PP=0 (skip)", i - 1)
        else
            local move_id = emu:read16(PLAYER_MOVE_ADDRS[i])
            local score = score_move(move_id, enemy_type1, enemy_type2)
            log("  Move %d: PP=%d, Score=%d", i - 1, pp, score)
            if score > best_score then
                best_score = score
                best_slot = i - 1
            end
        end
    end

    -- If we found ANY move with PP, return it (even if score is low)
    if best_slot >= 0 then
        log("Best move: slot %d (score=%d)", best_slot, best_score)
        return best_slot
    end

    -- Fallback: ALL moves have 0 PP (shouldn't happen in real battles)
    log("WARNING: All moves out of PP! Returning move 0 as last resort.")
    return 0
end

-- Press one directional step toward the target slot in the 2×2 move grid.
-- Returns true when already on target (no press needed).
local function move_cursor_step(target)
    local cur = emu:read8(MOVE_MENU_CURSOR)

    log("Move menu cursor: %d (need %d)", cur, target)

    if cur == target then return true end
    if cur % 2 ~= target % 2 then
        apply_input(target % 2 > cur % 2 and DIRECTIONS.Right or DIRECTIONS.Left)
    else
        apply_input(math.floor(target/2) > math.floor(cur/2) and DIRECTIONS.Down or DIRECTIONS.Up)
    end
    return false
end

-- Navigate party cursor in 2-column grid (slots 0-5 arranged as rows: [0,1], [2,3], [4,5]).
-- Returns true when on target, false otherwise.
local function party_cursor_step(target)
    local cur = emu:read8(PARTY_MENU_CURSOR)
    if cur == target then return true end
    -- Move left/right for column (cur%2 vs target%2), up/down for row (cur//2 vs target//2)
    if cur % 2 ~= target % 2 then
        apply_input(target % 2 > cur % 2 and DIRECTIONS.Right or DIRECTIONS.Left)
    else
        apply_input(math.floor(target/2) > math.floor(cur/2) and DIRECTIONS.Down or DIRECTIONS.Up)
    end
    return false
end

function debug_party_hp()
    log("=== PARTY HP DEBUG ===")
    for slot = 0, 5 do
        local hp = get_party_hp(slot)
        log("Slot %d: HP = %d", slot, hp)
    end
    log("Next awake slot: %d", find_next_awake_slot())
end

-- Handle "Use next Pokémon?" prompt and party selection (multi-phase state machine).
-- Phase 1 (faint_transition): Wait for menu to fully render
-- Phase 2 (faint_menu_no): Cursor on No, move Up to Yes
-- Phase 3 (faint_menu_yes): Cursor on Yes, press A to confirm
-- Phase 4 (faint_party): Navigate to first awake Pokémon slot and select it.
local function handle_fainted()
    local faint_state = detect_faint_menu_state()

    if fightPhase == "faint_message" then
        -- Faint message/animation is showing, press A to dismiss it
        log("[FAINT] Dismissing faint message, pressing A")
        apply_input(BUTTONS.A)
        -- Wait for next frame to detect if Yes/No prompt appeared
        return
    end

    if faint_state == "not_fainted" then
        -- Faint prompt disappeared, exit faint handling
        log("[FAINT] Prompt no longer active, exiting faint handling")
        fightPhase = "top"
        return
    end

    if faint_state == "faint_menu_no" then
        -- Cursor is on No, need to move to Yes
        apply_input(DIRECTIONS.Up)
        -- Don't change phase yet, let next frame detect the cursor moved
        return

    elseif faint_state == "faint_menu_yes" then
        -- Cursor is on Yes, confirm selection
        apply_input(BUTTONS.A)
        -- Transition to faint_party phase (will check if menu opened via detect_post_faint_menu_state)
        faint_state = "faint_party"
        targetPartySlot = 0  -- will be found once party menu confirms open
        log("[FAINT] Pressed A on YES, moving to FAINT_PARTY phase")
        return

    elseif faint_state == "faint_party" then
        debug_party_hp()
        -- Party menu should be open; detect current state to confirm
        local post_faint_state = detect_post_faint_menu_state()
        log("[FAINT] Post-faint menu state: %s", post_faint_state)

        -- If we're still in the Yes/No prompt, wait for party menu to appear
        if post_faint_state == "yes_no_prompt" then
            log("[FAINT] Still in Yes/No prompt, waiting for party menu to open")
            return
        end

        -- Party menu is open: navigate to targetPartySlot and confirm
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
                fightPhase = "top"  -- back to normal battle
                log("[FAINT_PARTY] Pokémon %d sent out, returning to TOP phase", targetPartySlot)
            end
        end
    end
end

-- ════════════════════════════════════════════════════════════════════════════
-- handle_fighting() — THREE PHASES: STARTUP → TOP MENU → MOVE NAVIGATION
-- ════════════════════════════════════════════════════════════════════════════
local function handle_fighting()
    local top_cursor = emu:read8(TOP_MENU_CURSOR)
    local move_cursor = emu:read8(MOVE_MENU_CURSOR)
    local ctl_curs = control_cursors() 
    local menu_state = emu:read8(MENU_STATE_ADDR)
    -- if ctl_curs > 0 then
    --     log("Cursor active, pressing A")
    --     apply_input(BUTTONS.A) 
    -- end


    -- ════ PHASE 1: STARTUP (dismiss screens before main menu) ════
    if fightPhase == "startup" then
        if startupStep == 0 then
            -- Step 0: Press A to dismiss "Wild Pokemon appears!" message
            log("[STARTUP STEP 0] next_pokemon=%d", ctl_curs.next_pokemon)
            if ctl_curs.next_pokemon == 5 then
                log("[STARTUP STEP 0] Wild pokemon dismissed, advancing to step 1")
                startupStep = 1
                return
            end
            if buttonHoldFrames == 0 then  -- Only press if not already holding a button
                log("[STARTUP STEP 0] Pressing A to dismiss wild pokemon screen")
                apply_input(BUTTONS.A)
            end
            return
        elseif startupStep == 1 then
            -- Step 1: After move menu renders, press A to confirm Fight
            log("[STARTUP STEP 1] Pressing A to dismiss encounter message")
            apply_input(BUTTONS.A)
            startupStep = 2
            return
        else
             log("[STARTUP STEP 2] Transitioning to TOP phase")
            -- Step 2: Startup complete, transition to top menu phase
            fightPhase = "top"
            startupStep = 0
            detect_battle_menu_state()
            return
        end
    end
    -- ════ PHASE 2: TOP MENU (navigate to Fight and confirm) ════
    -- TODO finding best move its not 0, 0 
    -- takes a lot of movments in tiop menu before 
    -- going to move menu
    if menu_state == 0 then
        -- Read which option cursor is on (0=Fight, 1=Bag, 2=Pokemon, 3=Run)
        local top_cursor = emu:read8(TOP_MENU_CURSOR)

        if top_cursor == targetTopMenu then
            -- Cursor is on target: press A to confirm and pick the best move
            log("[TOP MENU] Cursor at target (%d), pressing A", top_cursor)
            apply_input(BUTTONS.A)
            targetMove = best_move_slot()  -- returns 0-3 (best slot based on enemy type)
            local pp = emu:read8(PP_ADDRS[targetMove + 1])
            log("[TOP MENU] Selected move slot %d with PP=%d, transitioning to MOVE phase", targetMove, pp)

            -- Navigate and select move from move menu

            fightPhase = "move"
            detect_battle_menu_state()
            return
        else
            -- Cursor not on target: navigate to it using 2x2 grid logic
            log("[TOP MENU] Cursor at %d, target is %d - navigating", top_cursor, targetTopMenu)
            if top_cursor % 2 ~= targetTopMenu % 2 then
                apply_input(targetTopMenu % 2 > top_cursor % 2 and DIRECTIONS.Right or DIRECTIONS.Left)
            else
                apply_input(math.floor(targetTopMenu/2) > math.floor(top_cursor/2) and DIRECTIONS.Down or DIRECTIONS.Up)
            end
            return
        end
    end

    -- ════ PHASE 3: MOVE NAVIGATION (move cursor to target slot and confirm) ════
    if menu_state == 1 then
        detect_battle_menu_state()
        
        log("[MOVE PHASE] Navigating to move slot %d", targetMove, "menu_state: %d ", menu_state)
        -- move_cursor_step() returns true when cursor reaches targetMove, false while navigating
        local on_target = move_cursor_step(targetMove)
        if not on_target then
            -- Not at target yet, let move_cursor_step() navigate
            log("[MOVE PHASE] Still navigating to slot %d", targetMove)
            return
        end
        -- Reached target: press A to confirm the move
        if targetMove == move_cursor then
             log("[MOVE PHASE] Cursor already at target move slot %d, pressing A to confirm", targetMove)
            -- apply_input(BUTTONS.A)
             log("[MOVE PHASE] Move confirmed, transitioning back to TOP phase")
            fightPhase = "top"  -- return to top menu after move executes
            return
        end
        -- log("[MOVE PHASE] Reached target move slot %d, pressing A to confirm", targetMove)
        -- apply_input(BUTTONS.A)
        -- log("[MOVE PHASE] Move confirmed, transitioning back to TOP phase")
        -- fightPhase = "top"  -- return to top menu after move executes
        return
    end
end

-- Strategy: fight every turn. PP-aware move selection. Clean faint handling.
-- Whole party faints → blackout → auto-healed at Pokémon Center.
function handle_battle()
    local cur_hp = get_player_hp()
    local faint_state = detect_faint_menu_state()
    -- Primary check: did our Pokemon faint?
    if cur_hp == 0 then
        -- log("[BATTLE] Pokemon fainted (HP=0), faint menu state: %s", faint_state)
        fainting = true
        -- Determine which faint phase we're in
        if faint_state ~= "not_fainted" then
            -- Yes/No prompt is visible
            fightPhase = faint_state
        else
            -- Prompt not visible yet, we're in the faint message screen
            if fightPhase ~= "faint_message" then
                fightPhase = "faint_message"
            end
        end
        handle_fainted()
    else
        -- HP > 0: new pokemon is active (or we're back in normal battle).
        fainting = false
        -- log("[BATTLE] Pokemon active (HP=%d), handling fighting - phase=%s", cur_hp, fightPhase)
        handle_fighting()
    end
end

-- ─── Movement / route system ──────────────────────────────────────────────────

local runningRoute      = false
local routeDirection    = 1
local currentRouteIndex = 1
local routeToFollow     = nil
local movementTask      = nil

function start_movement(dirName, tx, ty)
    movementTask = { direction = dirName, targetX = tx, targetY = ty, frames = 0, timeout = 30 }
    apply_input(DIRECTIONS[dirName])
end

function stop_movement()
    movementTask = nil
    clear_input()
end

function set_route(r)
    routeToFollow     = r
    currentRouteIndex = 1
end

-- Returns true = leg done, false = error, nil = still walking
function follow_route()
    if not routeToFollow then return false, "no_route_set" end

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
            -- if LAST_BATTLE_POS ~= nil then
            --     if LAST_BATTLE_POS.x == pos.x and LAST_BATTLE_POS.y == pos.y then
            --         log("LAST_BATTLE_POS has not changed")
            --         log("Battle starts: %d", BATTLE_START )
            --         log("batttle detects: %d", BATTLE_DETECT)
            --     end
            -- end
            inBattle = true

            -- If HP is already 0 and battle flag is down, we're mid-faint-prompt
            -- (not a new encounter) — skip the intro wait so we press A immediately.
            local cur_hp = get_player_hp()
            if cur_hp == 0 and not battle_flag_is_set() and battleIntro < 1 then
                log("Faint prompt detected at (%d,%d)", pos.x, pos.y)
            else
                log("Battle detected at (%d,%d)", pos.x, pos.y)
                stop_movement()
            end
            BATTLE_DETECT = BATTLE_DETECT + 1
            LAST_BATTLE_POS = { x = pos.x, y = pos.y }
            return nil
        end
        apply_input(DIRECTIONS[movementTask.direction])
        return nil
    end

    -- Skip steps already at
    while currentRouteIndex <= #routeToFollow do
        local s = routeToFollow[currentRouteIndex]
        if pos.x == s.x and pos.y == s.y then
            currentRouteIndex = currentRouteIndex + 1
        else break end
    end

    if currentRouteIndex > #routeToFollow then return true end

    local step = routeToFollow[currentRouteIndex]
    local dx   = step.x - pos.x
    local dy   = step.y - pos.y

    if     dx ==  1 and dy ==  0 then start_movement("Right", step.x, step.y)
    elseif dx == -1 and dy ==  0 then start_movement("Left",  step.x, step.y)
    elseif dx ==  0 and dy ==  1 then start_movement("Down",  step.x, step.y)
    elseif dx ==  0 and dy == -1 then start_movement("Up",    step.x, step.y)
    else
        return false, string.format(
            "not_adjacent step %d (%d,%d) pos=(%d,%d)",
            currentRouteIndex, step.x, step.y, pos.x, pos.y)
    end
    return nil
end

function start_farming(direction)
    local r = direction == 1 and farming_route or reverse_route(farming_route)
    local pos = get_position()
    log("Starting farming route in direction %d from pos=(%d,%d)", direction, pos.x, pos.y)
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

-- ─── Main callback ────────────────────────────────────────────────────────────

function checkMap()
    if stop then return end
    frame = frame + 1
    battleFrameCounter = battleFrameCounter + 1

    local map = emu:read16(MAP_ADDR)
    if battle_flag_is_set() and not inBattle then
        log("[MAP CHECK] Current map: %d (expected %d for VR battles)", map, VICTORY_ROAD_MAP)
    end
    local pos = get_position()

    if buttonHoldFrames > 0 then
        buttonHoldFrames = buttonHoldFrames - 1
        -- Re-press button to keep it held
        if currentButton and emu and emu.setKeys then emu:setKeys(currentButton.bit)
        elseif currentButton and input and input.set then input.set({ [currentButton.key] = true })
        elseif currentButton and joypad and joypad.set then joypad.set({ [currentButton.key] = true })
        end
        return
    elseif currentButton then
        -- Release the button after hold is done
        if emu and emu.setKeys then emu:setKeys(0)
        elseif input and input.set then input.set({ [currentButton.key] = false })
        elseif joypad and joypad.set then joypad.set({ [currentButton.key] = false })
        end
        currentButton = nil
    end

    -- Reset battle state if we left Victory Road (blackout → Pokemon Center).
    if map ~= VICTORY_ROAD_MAP then
        if inBattle then
            inBattle = false; fainting = false
            log("Left VR mid-battle, resetting state")
        end
    end

    if map == VICTORY_ROAD_MAP and not runningRoute and not inBattle then
        start_farming(1)
    end

    if not runningRoute or map ~= VICTORY_ROAD_MAP then return end

    -- Battle active (RAM flag); set intro wait only on first detection.

    if battle_flag_is_set() and not inBattle and BATTLE_START == 0 then
        inBattle = true
        fightPhase = "startup"
        startupStep = 0
        battleIntro = 1
        fainting = false
        log("Battle started (flag)")
        BATTLE_START = BATTLE_START + 1
        log("Battle starts: %d", BATTLE_START )
    end 

    if inBattle then
        local enemy_cur, enemy_max = get_enemy_hp()
        -- log("[BATTLE STATUS] Enemy HP: %d/%d, Battle flag: %s", enemy_cur, enemy_max, battle_flag_is_set() and "SET" or "NOT_SET")

        if enemy_cur == enemy_max and battleIntro == 0 then
            battleIntro = 0
            log("Battle intro reset (enemy HP full)")
        end

        -- watch_battle_flag()
        if not battle_flag_is_set() then
            -- log("[BATTLE EXIT CHECK] Flag dropped, checking exit conditions")
            if fainting then
                -- Flag dropped during faint sequence — game pre-loads next pokemon so
                -- HP is already > 0, but we haven't confirmed "Yes" yet. Keep pressing.
                -- log("[BATTLE EXIT CHECK] In faint sequence, calling handle_fainted()")
                handle_fainted()
                return
            end
            if enemy_cur == 0 then
                -- log("[BATTLE EXIT] Enemy dead (HP=0)! Starting farming route")
                inBattle = false
                log("Battle ended: ", inBattle)
                start_farming(routeDirection)
                return
            end
            -- log("[BATTLE EXIT CHECK] Flag dropped but enemy still alive (HP=%d)", enemy_cur)
            return
        end
        if every_n_frames(30) then
           handle_battle()
        end
        return
    end
    
    local ok, err = follow_route()
    if ok == true then
        local next = routeDirection == 1 and -1 or 1
        log("Leg done, reversing")
        start_farming(next)
    elseif ok == false then
        runningRoute = false
        log("Route error: %s", err)
    end

    -- No periodic log while walking — battle_status() covers the battle side.
end

-- ─── Console helpers ──────────────────────────────────────────────────────────

-- Search for a species ID (national dex number) near the player battle struct.
-- Call while your pokemon is in battle: find_player_species(286) for Breloom.
-- The address that prints is PLAYER_SPECIES_ADDR.
function find_player_species(dex_id)
    log("Searching for species %d in 0x02024080-0x020240C0...", dex_id)
    for addr = 0x02024080, 0x020240C0, 2 do
        if emu:read16(addr) == dex_id then
            log("  FOUND at 0x%08X  (offset from PLAYER_STRUCT: 0x%02X)", addr, addr - PLAYER_STRUCT)
        end
    end
end

-- Search for a move ID near the player battle struct.
-- Call while that pokemon is in battle: find_move_addr(157) for Rock Slide.
-- Run for each unknown move to find the correct PLAYER_MOVE_ADDRS slots.
function find_move_addr(move_id)
    log("Searching for move ID %d in 0x02024080-0x020240C0...", move_id)
    for addr = 0x02024080, 0x020240C0, 2 do
        if emu:read16(addr) == move_id then
            log("  FOUND at 0x%08X  (offset from PLAYER_STRUCT: 0x%02X)", addr, addr - PLAYER_STRUCT)
        end
    end
end

function dump_words(start_addr, end_addr)
    for addr = start_addr, end_addr, 2 do
        log("0x%08X : %5d", addr, emu:read16(addr))
    end
end

function startRoute() start_farming(1)  end
function goBack()     start_farming(-1) end
function stopBot()    stop = true;  stop_movement(); log("Bot stopped") end
function resetBot()   stop = false; runningRoute = false; inBattle = false; stop_movement(); log("Bot reset") end
function logFaintCursor()
    local prompt_active = emu:read8(FAINT_PROMPT_ACTIVE)
    local cursor_pos = emu:read8(FAINT_CURSOR_POS)
    log("positition of faint cursor: %d (0=Yes, 1=No), prompt active: %s", cursor_pos, prompt_active)
end
function debug_faint_state()
    local prompt_active = emu:read8(0x02000418)
    local party_active = emu:read8(0x02021834)
    local menu_state = emu:read16(0x02024332)
    log("[DEBUG] prompt_active=%d, party_active=%d, menu_state=%d", prompt_active, party_active, menu_state)
end


-- Call this from the mGBA console while on any battle screen to dump all relevant state.
function dump_battle()
    local cur_hp, max_hp = get_player_hp()
    log("=== BATTLE DUMP ===")
    log("  BATTLE_FLAG     0x%08X = %d",  BATTLE_FLAG_ADDR,   emu:read16(BATTLE_FLAG_ADDR))
    log("  PLAYER_HP       %d / %d",      cur_hp, max_hp)
    log("  TOP_MENU_CURSOR 0x%08X = %d  (0=Fight 1=Bag 2=Mon 3=Run)", TOP_MENU_CURSOR, emu:read8(TOP_MENU_CURSOR))
    log("  MOVE_CURSOR     0x%08X = %d  (0-3 = move slot)", MOVE_MENU_CURSOR, emu:read8(MOVE_MENU_CURSOR))
    log("  PARTY_CURSOR    0x%08X = %d  (0-5 = party slot)", PARTY_MENU_CURSOR, emu:read8(PARTY_MENU_CURSOR))
    log("  NEXT_PKM_CURSOR 0x%08X = %d  (0=Yes 1=No, only valid when prompt showing)", NEXT_POKEMON_CURSOR, emu:read8(NEXT_POKEMON_CURSOR))
    log("  PP [1,2,3,4]    %d  %d  %d  %d",
        emu:read8(PP_ADDRS[1]), emu:read8(PP_ADDRS[2]),
        emu:read8(PP_ADDRS[3]), emu:read8(PP_ADDRS[4]))
    log("  ENEMY_SPECIES   0x%08X = %d", ENEMY_SPECIES_ADDR, emu:read16(ENEMY_SPECIES_ADDR))
    log("  fightPhase=%s  targetMove=%d", fightPhase, targetMove)
    log("===================")
end

-- Verify party HP addresses by checking all 6 slots.
-- Call during battle to confirm PARTY_BASE and HP_CURRENT_OFFSET are correct.
function verify_party_hp()
    log("=== PARTY HP VERIFICATION ===")
    log("Base: 0x%08X, struct size: 0x%X, HP offset: 0x%X", PARTY_BASE, POKEMON_STRUCT_SIZE, HP_CURRENT_OFFSET)
    for slot = 0, 5 do
        local hp = get_party_hp(slot)
        log("  Slot %d: HP = %d", slot, hp)
    end
    log("If all slots show 0, PARTY_BASE may be wrong. Use mGBA Memory Search to find gPlayerParty.")
    log("==============================")
end

-- ─── Memory diff tools (find RAM addresses) ──────────────────────────────────
-- Usage:
--   1. Outside battle:  mem_save()
--   2. Enter a battle
--   3. Inside battle:   mem_diff()
--   Results show every address that changed — battle flag candidates are in that list.
--
-- For HP specifically:
--   1. In battle, note your current HP visually
--   2. mem_find_hp(150)  ← replace 150 with your actual HP
--   3. Take damage, note new HP
--   4. mem_find_hp(120)  ← new HP value
--   Addresses appearing in BOTH searches are your HP address.

local mem_snapshot = {}

-- Scan range: full EWRAM (0x02000000–0x0203FFFF) in 16-bit steps.
-- Takes a few seconds — run it once.
local SCAN_START = 0x02000000
local SCAN_END   = 0x0203FFFE
local SCAN_STEP  = 2

function mem_save()
    mem_snapshot = {}
    local count = 0
    for addr = SCAN_START, SCAN_END, SCAN_STEP do
        mem_snapshot[addr] = emu:read16(addr)
        count = count + 1
    end
    log("mem_save: captured %d values from 0x%08X to 0x%08X", count, SCAN_START, SCAN_END)
end

function mem_diff()
    if next(mem_snapshot) == nil then
        log("mem_diff: no snapshot — run mem_save() first")
        return
    end
    log("mem_diff: scanning for changes...")
    local found = 0
    for addr = SCAN_START, SCAN_END, SCAN_STEP do
        local old = mem_snapshot[addr] or 0
        local cur = emu:read16(addr)
        if cur ~= old then
            log("  CHANGED 0x%08X: %d → %d", addr, old, cur)
            found = found + 1
            if found >= 50 then
                log("  (50 results — stopping, too many changes)")
                return
            end
        end
    end
    if found == 0 then
        log("  No changes found")
    else
        log("mem_diff: %d changed addresses", found)
    end
end

-- Search for a specific 16-bit value across all EWRAM.
function mem_find_hp(value)
    log("mem_find_hp: searching for value %d (0x%04X)...", value, value)
    local found = 0
    for addr = SCAN_START, SCAN_END, SCAN_STEP do
        if emu:read16(addr) == value then
            log("  0x%08X = %d", addr, value)
            found = found + 1
        end
    end
    log("mem_find_hp: found %d matches", found)
end

-- ─── PP / byte-level scan (battle struct area only) ──────────────────────────
-- PP is stored as u8 (single byte). The wide scan misses it because it reads u16.
-- These functions scan only the player+enemy battle struct area (0x02024000-0x020242FF)
-- using byte reads, which correctly finds PP changes.
--
-- Usage:
--   1. In battle, before using a move:  pp_save()
--   2. Use a move
--   3. pp_diff()   → shows every byte that decreased by 1 (PP use) in the struct area
-- 0x020240AA PP for move 3
-- 0x02024083 PP for move 2
-- 0x020240A8 PP for move 1

local pp_snap = {}

function pp_save()
    pp_snap = {}
    for addr = 0x02024000, 0x020242FF do
        pp_snap[addr] = emu:read8(addr)
    end
    log("pp_save: captured 0x02024000-0x020242FF (byte-level)")
end

function pp_diff()
    if next(pp_snap) == nil then
        log("pp_diff: no snapshot — run pp_save() first")
        return
    end
    log("pp_diff: looking for byte decreases (value 0-40)...")
    local found = 0
    for addr = 0x02024000, 0x020242FF do
        local old = pp_snap[addr] or 0
        local cur = emu:read8(addr)
        if cur < old and old <= 40 then
            log("  0x%08X: %d → %d", addr, old, cur)
            found = found + 1
        end
    end
    if found == 0 then log("  no matches") end
    log("pp_diff: found %d", found)
end

-- Find addresses where any value DECREASED and stayed in a reasonable HP range.
-- Use: mem_save() → attack enemy → mem_find_decreased()
-- Enemy HP will show up as one of the decreases.
function mem_find_decreased()
    if next(mem_snapshot) == nil then
        log("mem_find_decreased: no snapshot — run mem_save() first")
        return
    end
    log("mem_find_decreased: looking for HP-like decreases (1-999)...")
    local found = 0
    for addr = SCAN_START, SCAN_END, SCAN_STEP do
        local old = mem_snapshot[addr] or 0
        local cur = emu:read16(addr)
        if cur < old and old <= 999 and cur >= 1 then
            log("  0x%08X: %d → %d", addr, old, cur)
            found = found + 1
        end
    end
    if found == 0 then log("  no matches") end
    log("mem_find_decreased: found %d", found)
end

-- Find addresses where any value increased and stayed in a reasonable HP range.
-- Use: mem_save() → attack enemy → mem_find_increased()
function mem_find_increased()
    if next(mem_snapshot) == nil then
        log("mem_find_increased: no snapshot — run mem_save() first")
        return
    end
    log("mem_find_increased: looking for increased (1-999)...")
    local found = 0
    for addr = SCAN_START, SCAN_END, SCAN_STEP do
        local old = mem_snapshot[addr] or 0
        local cur = emu:read16(addr)
        if cur > old and old <= 999 and cur >= 1 then
            log("  0x%08X: %d → %d", addr, old, cur)
            found = found + 1
        end
    end
    if found == 0 then log("  no matches") end
    log("mem_find_increased: found %d", found)
end

-- Find addresses where value changed FROM old_val TO new_val since last mem_save().
-- Best tool for HP: mem_save() at known HP, take damage, mem_find_delta(new_hp, old_hp)
-- Best tool for battle flag: mem_save() outside battle, enter battle, mem_find_delta(1, 0)
function mem_find_delta(new_val, old_val)
    if next(mem_snapshot) == nil then
        log("mem_find_delta: no snapshot — run mem_save() first")
        return
    end
    log("mem_find_delta: looking for %d → %d ...", old_val, new_val)
    local found = 0
    for addr = SCAN_START, SCAN_END, SCAN_STEP do
        local snap = mem_snapshot[addr] or 0
        local cur  = emu:read16(addr)
        if snap == old_val and cur == new_val then
            log("  0x%08X: %d → %d", addr, old_val, new_val)
            found = found + 1
        end
    end
    if found == 0 then log("  no matches") end
    log("mem_find_delta: found %d", found)
end

local lastParty = nil
function watch_party_cursor()
    local cur = emu:read8(0x0203CED1)
    if cur ~= lastParty then
        log("Party cursor: %d", cur)
        lastParty = cur
    end
end

function dump_battle_mon(base, label)
    for off = 0, 0x30, 2 do
        local addr = base + off
        log("%s +0x%02X @ 0x%08X : %5d", label, off, addr, emu:read16(addr))
    end
end

function test_battle_flag(addr_list)
    log("=== BATTLE FLAG TEST ===")
    for i, addr in ipairs(addr_list) do
        local val = emu:read16(addr)
        log("  Address %d (0x%08X) = %d", i, addr, val)
    end
end


callbacks:add("frame", checkMap)
