--- Shared constants and a live snapshot of this mod's settings.
--
-- Everything tunable lives here, so no other file reads `settings` directly
-- and no value is duplicated as a file-local upvalue. Runtime settings are
-- re-read by refresh(), wired to on_runtime_mod_setting_changed in control.
--
-- @module script.config

local config = {
    ---- Constants ----

    -- Bounds on how long one pass over everything takes. The period adapts to
    -- the workload between them (see scheduler.global_period); because
    -- recovery is elapsed-based it is purely a granularity/UPS knob and can
    -- move freely between ticks.
    PERIOD_MIN = 20,     -- fastest refresh, for small bases

    -- Half-width of the Bezier fillet, as a fraction of the workload at which
    -- the flat-budget line would reach PERIOD_MAX. 0.5 lets the per-tick
    -- budget drift to 1.5x SLOT_BUDGET across the bend rather than
    -- overshooting the cap.
    BEND = 0.5,

    -- A visit walks its whole range, so the worst tick would otherwise grow
    -- with the biggest container in the game - a modded ten-thousand-slot
    -- chest would stall however carefully everything else is budgeted. An
    -- inventory larger than this is tracked as several entries, one per slot
    -- range, each an ordinary queue member with its own deadline. A visit then
    -- costs at most this many slots whatever the container's size; a small
    -- container is one entry and looks unchanged.
    MAX_ENTRY_SLOTS = 50,

    -- A preservation warehouse only cools while its power proxy holds this.
    WAREHOUSE_ENERGY = 1200000,

    -- Items are never pushed closer than this to brand new.
    FRESHNESS_MARGIN = 3,

    -- While the large-factory optimisation skips a container, its freshness
    -- display drifts. Bound that drift to 1/SKIP_DRIFT of the life its
    -- contents had left when they were last read.
    SKIP_DRIFT = 20,

    PROXY_NAME = "warehouse-power-proxy",
}

-- How far ahead of spoiling an entry is brought back. Wide enough to absorb a
-- backlog, so a container that promises its contents do not spoil is revisited
-- with time in hand rather than exactly on the deadline.
config.SAFETY = 3 * config.PERIOD_MIN

---- Settings snapshot ----

--- Re-read every setting this mod consults. Cheap enough to run on any
-- on_runtime_mod_setting_changed without filtering; startup settings cannot
-- change within a load but re-reading them is harmless.
function config.refresh()
    config.freeze_rates = settings.global["fridge-freeze-rate"].value
    config.SLOT_BUDGET = settings.global["fridge-slot-budget"].value

    local period_max = settings.global["fridge-max-refresh-gap"].value
    if period_max < config.PERIOD_MIN then period_max = config.PERIOD_MIN end
    config.PERIOD_MAX = period_max   -- slowest refresh: 5 s of game time

    config.platform_capacity =
        settings.startup["fridge-space-plantform-capacity"].value

    -- Skip re-walking a container whose item count has not moved. Off by
    -- default; the setting description spells out the trade. See executor.
    config.skip_unchanged =
        settings.startup["fridge-large-factory-optimization"].value
end

config.refresh()

return config
