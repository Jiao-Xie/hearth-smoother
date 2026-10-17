local SmootherCallHandler = class()

function SmootherCallHandler:get_status(session, response)
   local status = hearth_smoother.status()
   if hearth_smoother_restock_guard then
      local inventory
      if session and session.player_id and stonehearth and stonehearth.inventory then
         inventory = stonehearth.inventory:get_inventory(session.player_id)
      end
      status.restock_snapshot = hearth_smoother_restock_guard.snapshot(inventory)
   end
   if hearth_smoother_healing_target_guard then status.healing_target_guard = hearth_smoother_healing_target_guard.status() end
   if hearth_smoother_healing_observer_lifetime then status.healing_observer_lifetime = hearth_smoother_healing_observer_lifetime.status() end
   if hearth_smoother_restock_search_lifetime then status.restock_search_lifetime = hearth_smoother_restock_search_lifetime.status() end
   if hearth_smoother_pasture_feed_filter then status.pasture_feed_filter = hearth_smoother_pasture_feed_filter.status() end
   if hearth_smoother_director_cache then status.director_cache = hearth_smoother_director_cache.status() end
   if hearth_smoother_director_lifetime then status.director_lifetime = hearth_smoother_director_lifetime.status() end
   if hearth_smoother_entity_validity_guards then status.entity_validity_guards = hearth_smoother_entity_validity_guards.status() end
   if hearth_smoother_restock_actor_lifetime then status.restock_actor_lifetime = hearth_smoother_restock_actor_lifetime.status() end
   if hearth_smoother_reachability_wake then status.reachability_wake = hearth_smoother_reachability_wake.status() end
   if hearth_smoother_carried_target_guard then status.carried_target_guard = hearth_smoother_carried_target_guard.status() end
   if hearth_smoother_bulletin_lifetime then status.bulletin_lifetime = hearth_smoother_bulletin_lifetime.status() end
   if hearth_smoother_astar_callback then status.astar_callback = hearth_smoother_astar_callback.status() end
   if hearth_smoother_astar_start_stagger then status.astar_start_stagger = hearth_smoother_astar_start_stagger.status() end
   if hearth_smoother_pathfinding_timing then status.pathfinding_timing = hearth_smoother_pathfinding_timing.status() end
   response:resolve(status)
end

local function require_host(session, response)
   if radiant.validator.is_host_player(session) then return true end
   response:reject('Only the host may configure Hearth Smoother.')
   return false
end

function SmootherCallHandler:get_idle_status(session, response)
   if not require_host(session, response) then return end
   response:resolve(require('hearth_smoother.idle_snapshot').snapshot({player_id=session.player_id}))
end

function SmootherCallHandler:get_growth_status(session, response)
   if not require_host(session, response) then return end
   response:resolve(require('hearth_smoother.growth_diagnostics').snapshot())
end

function SmootherCallHandler:set_enabled(session, response, enabled)
   if not require_host(session, response) then return end
   if type(enabled) ~= 'boolean' then
      response:reject('enabled must be boolean')
      return
   end
   local ok, result = hearth_smoother.configure({ enabled = enabled })
   if ok then response:resolve(result) else response:reject(result) end
end

function SmootherCallHandler:configure(session, response, options)
   if not require_host(session, response) then return end
   local ok, result = hearth_smoother.configure(options)
   if ok then response:resolve(result) else response:reject(result) end
end

function SmootherCallHandler:set_restock_cleanup(session, response, enabled)
   if not require_host(session, response) then return end
   if type(enabled) ~= 'boolean' then response:reject('enabled must be boolean'); return end
   local ok, result = hearth_smoother_restock_guard.set_enabled(enabled)
   if ok then response:resolve(result) else response:reject(result) end
end

function SmootherCallHandler:profile_functions(session, response, duration_seconds)
   if not require_host(session, response) then return end
   if type(duration_seconds) ~= 'number' or duration_seconds ~= math.floor(duration_seconds)
      or duration_seconds < 0 or duration_seconds > 180 then
      response:reject('profile duration must be an integer from 0 to 180 seconds')
      return
   end
   local ok, result = hearth_smoother_function_timing.start(duration_seconds)
   if ok then response:resolve(result) else response:reject(result) end
end

function SmootherCallHandler:set_work_optimization(session, response, enabled)
   if not require_host(session, response) then return end
   if type(enabled) ~= 'boolean' then response:reject('enabled must be boolean'); return end
   local previous_timer_enabled = hearth_smoother_timer_dispatch.status().enabled
   local timer_ok, timer_result = hearth_smoother_timer_dispatch.set_enabled(enabled)
   if not timer_ok then response:reject(timer_result); return end
   local slice_ok, slice_result = hearth_smoother_restock_slice.set_enabled(enabled)
   if not slice_ok then
      hearth_smoother_timer_dispatch.set_enabled(previous_timer_enabled)
      response:reject(slice_result)
      return
   end
   response:resolve({ timer_dispatch = timer_result, restock_slice = slice_result })
end

function SmootherCallHandler:set_farm_sunlight_slice(session, response, enabled)
   if not require_host(session, response) then return end
   if type(enabled) ~= 'boolean' then response:reject('enabled must be boolean'); return end
   local ok, result = hearth_smoother_farm_sunlight_slice.set_enabled(enabled)
   if ok then response:resolve(result) else response:reject(result) end
end

function SmootherCallHandler:set_restock_bootstrap(session, response, enabled)
   if not require_host(session, response) then return end
   if type(enabled) ~= 'boolean' then response:reject('enabled must be boolean'); return end
   local ok, result = hearth_smoother_restock_bootstrap.set_enabled(enabled)
   if ok then response:resolve(result) else response:reject(result) end
end

function SmootherCallHandler:set_astar_callback(session, response, enabled)
   if not require_host(session, response) then return end
   if type(enabled) ~= 'boolean' then response:reject('enabled must be boolean'); return end
   local ok, result = hearth_smoother_astar_callback.set_enabled(enabled)
   if ok then response:resolve(result) else response:reject(result) end
end

function SmootherCallHandler:set_astar_start_stagger(session, response, enabled)
   if not require_host(session, response) then return end
   if type(enabled) ~= 'boolean' then response:reject('enabled must be boolean'); return end
   local ok, result = hearth_smoother_astar_start_stagger.set_enabled(enabled)
   if ok then response:resolve(result) else response:reject(result) end
end

function SmootherCallHandler:profile_pathfinding(session, response, duration_seconds)
   if not require_host(session, response) then return end
   if type(duration_seconds) ~= 'number' or duration_seconds ~= math.floor(duration_seconds)
      or duration_seconds < 0 or duration_seconds > 180 then
      response:reject('profile duration must be an integer from 0 to 180 seconds')
      return
   end
   local ok, result = hearth_smoother_pathfinding_timing.start(duration_seconds)
   if ok then response:resolve(result) else response:reject(result) end
end

function SmootherCallHandler:get_pathfinder_status(session, response, options)
   if not require_host(session, response) then return end
   if options ~= nil then
      if type(options) ~= 'table' or getmetatable(options) ~= nil then
         response:reject('options must be a plain table or omitted'); return
      end
      for key, value in pairs(options) do
         if key ~= 'all_entities' or type(value) ~= 'boolean' then
            response:reject('only boolean all_entities is supported'); return
         end
      end
   end
   response:resolve(require('hearth_smoother.pathfinder_diagnostics').snapshot(options))
end

return SmootherCallHandler

