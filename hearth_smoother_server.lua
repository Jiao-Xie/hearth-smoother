-- Runtime-only global: no saved variables, services, controllers or entity components.
if hearth_smoother then return hearth_smoother end
hearth_smoother = require 'hearth_smoother.scheduler'
hearth_smoother_grid_trace = require 'hearth_smoother.grid_trace'
hearth_smoother_death_guard = require 'hearth_smoother.death_guard'
hearth_smoother_event_guard = require 'hearth_smoother.event_guard'
hearth_smoother_component_cache = require 'hearth_smoother.component_cache'
hearth_smoother_restock_guard = require 'hearth_smoother.restock_guard'
hearth_smoother_timer_dispatch = require 'hearth_smoother.timer_dispatch'
hearth_smoother_restock_slice = require 'hearth_smoother.restock_slice'
hearth_smoother_farm_sunlight_slice = require 'hearth_smoother.farm_sunlight_slice'
hearth_smoother_restock_bootstrap = require 'hearth_smoother.restock_bootstrap'
hearth_smoother_function_timing = require 'hearth_smoother.function_timing'
hearth_smoother_healing_target_guard = require 'hearth_smoother.healing_target_guard'
hearth_smoother_healing_observer_lifetime = require 'hearth_smoother.healing_observer_lifetime'
hearth_smoother_restock_search_lifetime = require 'hearth_smoother.restock_search_lifetime'
hearth_smoother_pasture_feed_filter = require 'hearth_smoother.pasture_feed_filter'
hearth_smoother_director_cache = require 'hearth_smoother.director_cache'
hearth_smoother_carried_target_guard = require 'hearth_smoother.carried_target_guard'
hearth_smoother_director_lifetime = require 'hearth_smoother.director_lifetime'
hearth_smoother_entity_validity_guards = require 'hearth_smoother.entity_validity_guards'
hearth_smoother_restock_actor_lifetime = require 'hearth_smoother.restock_actor_lifetime'
hearth_smoother_reachability_wake = require 'hearth_smoother.reachability_wake'
hearth_smoother_bulletin_lifetime = require 'hearth_smoother.bulletin_lifetime'
hearth_smoother_astar_callback = require 'hearth_smoother.astar_callback'
hearth_smoother_astar_start_stagger = require 'hearth_smoother.astar_start_stagger'
hearth_smoother_pathfinding_timing = require 'hearth_smoother.pathfinding_timing'
local ready, ace_ready = false, false
local required_listener, ace_listener, loaded_listener
local log = radiant.log.create_logger('hearth_smoother')

local function load_options()
   local options = {
      enabled = radiant.util.get_global_config('mods.hearth_smoother.enabled', true),
      batch_size = radiant.util.get_global_config('mods.hearth_smoother.batch_size', 64),
      max_delay_seconds = radiant.util.get_global_config('mods.hearth_smoother.max_delay_seconds', 0.4)
   }
   local ok, err = hearth_smoother.configure(options)
   if not ok then log:write(0, 'not applied: %s', tostring(err)) end
   local grid_ok, grid_err = hearth_smoother_grid_trace.apply()
   if not grid_ok then log:write(0, 'grid trace not applied: %s', tostring(grid_err)) end
   local death_ok, death_err = hearth_smoother_death_guard.apply()
   if not death_ok then log:write(0, 'death effect guard not applied: %s', tostring(death_err)) end
   local event_ok, event_err = hearth_smoother_event_guard.apply()
   if not event_ok then log:write(0, 'event guard not applied: %s', tostring(event_err)) end
   -- Resource reloads may replace blueprints; cache only this loaded generation.
   hearth_smoother_component_cache.clear()
   local cache_ok, cache_err = hearth_smoother_component_cache.apply()
   if not cache_ok then log:write(0, 'component data cache not applied: %s', tostring(cache_err)) end
   -- Missing own flag defaults cleanup OFF; profiling is never enabled on load.
   -- get_config adds mods.<caller>. itself; these are already complete paths.
   local cleanup_enabled = radiant.util.get_global_config('mods.hearth_smoother.restock_cleanup_enabled', false)
   if type(cleanup_enabled) ~= 'boolean' then
      log:write(0, 'restock cleanup configuration rejected: enabled must be boolean')
      cleanup_enabled = false
   end
   local carried_ok, carried_err = hearth_smoother_carried_target_guard.apply()
   if not carried_ok then log:write(0, 'carried target guard not applied: %s', tostring(carried_err)) end
   local cache_ok2, cache_err2 = hearth_smoother_director_cache.apply()
   if not cache_ok2 then log:write(0, 'director cache not applied: %s', tostring(cache_err2)) end
   local lifetime_ok2, lifetime_err2 = hearth_smoother_director_lifetime.apply()
   if not lifetime_ok2 then log:write(0, 'director retirement not applied: %s', tostring(lifetime_err2)) end
   local validity_ok, validity_err = hearth_smoother_entity_validity_guards.apply()
   if not validity_ok then log:write(0, 'entity validity guards not applied: %s', tostring(validity_err)) end
   local bulletin_ok, bulletin_err = hearth_smoother_bulletin_lifetime.apply()
   if not bulletin_ok then log:write(0, 'bulletin lifetime not applied: %s', tostring(bulletin_err)) end
   local actor_ok, actor_err = hearth_smoother_restock_actor_lifetime.apply()
   if not actor_ok then log:write(0, 'restock actor lifetime not applied: %s', tostring(actor_err)) end
   local wake_ok, wake_err = hearth_smoother_reachability_wake.apply()
   if not wake_ok then log:write(0, 'reachability wake not applied: %s', tostring(wake_err)) end
   local enabled_ok, enabled_err = hearth_smoother_restock_guard.set_enabled(cleanup_enabled)
   if not enabled_ok then log:write(0, 'restock cleanup configuration rejected: %s', tostring(enabled_err)) end
   local restock_ok, restock_err = hearth_smoother_restock_guard.apply()
   if not restock_ok then log:write(0, 'restock cleanup not applied: %s', tostring(restock_err)) end
   local timer_enabled = radiant.util.get_global_config('mods.hearth_smoother.timer_dispatch_enabled', true)
   local slice_enabled = radiant.util.get_global_config('mods.hearth_smoother.restock_slice_enabled', true)
   if type(timer_enabled) ~= 'boolean' then timer_enabled = false end
   if type(slice_enabled) ~= 'boolean' then slice_enabled = false end
   local timer_ok, timer_err = hearth_smoother_timer_dispatch.apply()
   if timer_ok then timer_ok, timer_err = hearth_smoother_timer_dispatch.set_enabled(timer_enabled) end
   if not timer_ok then log:write(0, 'timer dispatch optimization not applied: %s', tostring(timer_err)) end
   local slice_ok, slice_err = hearth_smoother_restock_slice.apply()
   if slice_ok then slice_ok, slice_err = hearth_smoother_restock_slice.set_enabled(slice_enabled) end
   if not slice_ok then log:write(0, 'restock slicing not applied: %s', tostring(slice_err)) end
   local farm_enabled = radiant.util.get_global_config('mods.hearth_smoother.farm_sunlight_slice_enabled', true)
   if type(farm_enabled) ~= 'boolean' then
      log:write(0, 'farm sunlight slicing configuration rejected: enabled must be boolean')
      farm_enabled = false
   end
   local farm_ok, farm_err = hearth_smoother_farm_sunlight_slice.apply()
   if farm_ok then farm_ok, farm_err = hearth_smoother_farm_sunlight_slice.set_enabled(farm_enabled) end
   if not farm_ok then log:write(0, 'farm sunlight slicing not applied: %s', tostring(farm_err)) end
   local bootstrap_enabled = radiant.util.get_global_config('mods.hearth_smoother.restock_bootstrap_enabled', true)
   if type(bootstrap_enabled) ~= 'boolean' then
      log:write(0, 'restock bootstrap configuration rejected: enabled must be boolean')
      bootstrap_enabled = false
   end
   local bootstrap_ok, bootstrap_err = hearth_smoother_restock_bootstrap.apply()
   if bootstrap_ok then bootstrap_ok, bootstrap_err = hearth_smoother_restock_bootstrap.set_enabled(bootstrap_enabled) end
   if not bootstrap_ok then log:write(0, 'restock bootstrap not applied: %s', tostring(bootstrap_err)) end
   local search_ok, search_err = hearth_smoother_restock_search_lifetime.apply()
   if not search_ok then log:write(0, 'nearby search lifetime not applied: %s', tostring(search_err)) end
   local pasture_ok, pasture_err = hearth_smoother_pasture_feed_filter.apply()
   if not pasture_ok then log:write(0, 'pasture feed filter not applied: %s', tostring(pasture_err)) end
   local lifetime_ok, lifetime_err = hearth_smoother_healing_observer_lifetime.apply()
   if not lifetime_ok then log:write(0, 'healing observer lifetime not applied: %s', tostring(lifetime_err)) end
   local healing_ok, healing_err = hearth_smoother_healing_target_guard.apply()
   if not healing_ok then log:write(0, 'healing location guard not applied: %s', tostring(healing_err)) end
   local astar_enabled = radiant.util.get_global_config('mods.hearth_smoother.astar_callback_enabled', true)
   if type(astar_enabled) ~= 'boolean' then astar_enabled = false end
   local astar_ok, astar_err = hearth_smoother_astar_callback.apply()
   if astar_ok then astar_ok, astar_err = hearth_smoother_astar_callback.set_enabled(astar_enabled) end
   if not astar_ok then log:write(0, 'astar callback optimization not applied: %s', tostring(astar_err)) end
   local stagger_enabled = radiant.util.get_global_config('mods.hearth_smoother.astar_start_stagger_enabled', true)
   if type(stagger_enabled) ~= 'boolean' then stagger_enabled = false end
   local stagger_ok, stagger_err = hearth_smoother_astar_start_stagger.apply()
   if stagger_ok then stagger_ok, stagger_err = hearth_smoother_astar_start_stagger.set_enabled(stagger_enabled) end
   if not stagger_ok then log:write(0, 'astar start stagger not applied: %s', tostring(stagger_err)) end
   -- Install dormant diagnostic wrappers only; collection requires explicit host RPC.
   local path_timing_ok, path_timing_err = hearth_smoother_pathfinding_timing.apply()
   if not path_timing_ok then log:write(0, 'pathfinding timing not applied: %s', tostring(path_timing_err)) end
   local timing_ok, timing_err = hearth_smoother_function_timing.apply()
   if not timing_ok then log:write(0, 'function timing not applied: %s', tostring(timing_err)) end
end

required_listener = radiant.events.listen_once(radiant, 'radiant:required_loaded', function()
   ready = true
   required_listener = nil
   -- ACE monkey patches inside its required_loaded handler and emits its own completion event.
   if ace_ready or not stonehearth_ace then load_options() end
end)
ace_listener = radiant.events.listen_once(radiant, 'stonehearth_ace:server:required_loaded', function()
   ace_ready = true
   ace_listener = nil
   if ready then load_options() end
end)
loaded_listener = radiant.events.listen_once(radiant, 'radiant:game_loaded', function()
   loaded_listener = nil
   -- Covers existing-save service initialization and arbitrary required-event listener order.
   load_options()
   local sweep_ok, sweep_err = hearth_smoother_bulletin_lifetime.sweep_orphans()
   if not sweep_ok then log:write(0, 'bulletin orphan sweep not applied: %s', tostring(sweep_err)) end
end)

return hearth_smoother

