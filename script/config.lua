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

--- Derive the guarantee bounds from the shortest spoil life in this game.
--
-- Nothing tells a mod that a machine inserted an item, so discovery has two
-- carriers, and correctness rides only on the unconditional one. The
-- heartbeat sees every change - including the count-neutral swaps no cheaper
-- signal can catch - so its period is capped at the widest window the
-- no-spoil promise tolerates for an item entering with half its life:
-- `min_spoil/2 - SAFETY - PERIOD_MIN`. With vanilla items that window (1720
-- ticks) exceeds any refresh-gap setting and the cap never binds; a mod with
-- faster-spoiling items pays a tighter heartbeat, which is that mod's fair
-- price. Count probes are the fast path on top: one cheap question per
-- entity per reaction window catches the common arrival - an inserter or
-- robot putting something in - roughly ten times sooner than a heartbeat,
-- for a cost the budget barely notices, so they run whenever anything in the
-- game can spoil at all. Bulk-arrival staggering is clamped to the same
-- window. Items entering with less than `PERIOD_MIN + queue latency` of life
-- are beyond any polling design; that floor is documented, not defended.
local function derive()
    local min_spoil = config.min_spoil
    if not min_spoil then
        -- Nothing spoils: nothing to discover, nothing to clamp.
        config.discovery_window = nil
        config.probes_on = false
        config.STAGGER_MAX = math.huge
        config.reaction_window = config.PERIOD_MIN
        return
    end

    local window = math.floor(min_spoil / 2) - config.SAFETY - config.PERIOD_MIN
    if window < config.PERIOD_MIN then window = config.PERIOD_MIN end
    config.discovery_window = window
    config.probes_on = true
    config.STAGGER_MAX = window
    if config.PERIOD_MAX > window then config.PERIOD_MAX = window end
    local reaction = settings.global["fridge-reaction-window"].value
    config.reaction_window = reaction < window and reaction or window
end

--- Record the shortest spoil life among this game's item prototypes,
-- quality-adjusted. Called from the executor's prototype scan on every load.
function config.set_min_spoil(min_spoil)
    config.min_spoil = min_spoil
    derive()
end

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

    derive()
end

config.refresh()

return config
