-- ════════════════════════════════════════════════════════════════════════════
-- MAIN BOT ORCHESTRATOR
-- Coordinates between fighting.lua and leveling_bot.lua
-- ════════════════════════════════════════════════════════════════════════════

-- Load scripts at startup
console:log("[MAIN] Loading scripts...")
dofile("d:/Projekt/monLevler/mon-bot/scripts/fighting.lua")
dofile("d:/Projekt/monLevler/mon-bot/scripts/levling_bot.lua")
console:log("[MAIN] Scripts loaded and running")
console:log("[MAIN] - Fighting script active on map 70 (Victory Road)")
console:log("[MAIN] - Leveling script active on map 15")

