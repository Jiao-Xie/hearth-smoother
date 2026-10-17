-- Finite initialization-only replay; director cache sharing remains active when slicing is disabled.
local M = {}
local PATH = 'stonehearth.services.server.inventory.restock_director'
local SOURCE = '@stonehearth_ace/services/server/inventory/restock_director.lua'
local SLICE_SOURCE = '@hearth_smoother/restock_slice.lua'
local INVENTORY_SOURCE = '@stonehearth/services/server/inventory/inventory.lua'
local EVENTS_SOURCE = '@radiant/modules/events.lua'
local WEAK_VALUES = { __mode = 'v' }
local epochs = setmetatable({}, { __mode = 'k' })
local contexts = setmetatable({}, { __mode = 'k' })
local origins = setmetatable({}, { __mode = 'k' })
local state = { applied = false, enabled = true, generation = 0, max_items = 512, budget_ms = 2,
   detailed_replay_timing = false,
   max_age_seconds = 15, captured = 0, replayed = 0, completed = 0, cancelled = 0,
   timeouts = 0, fallback_handoffs = 0, guarded_generation = 0, global_dispatches = 0,
   clock_failures = 0, clock_disabled = false, max_pending_age_seconds = 0, max_processing_age_seconds = 0,
   seed_total = 0, seed_out_of_world = 0, seed_replaced = 0, seed_fast_captured = 0, seed_fast_fallbacks = 0,
   event_count = 0, events = {}, phases = {} }
local owner, records, helpers, deps, slice
local record_list, helper_list
local first, last, dispatcher, dispatcher_identity
local dispatching = false
local schedule, handoff, handoff_all
local deadline_install, deadline_stop
local deadline = { mode = 'wall_fallback', reason = 'not_applied', elapsed = 0, loading = true, running = false,
   transitions = 0, load_completions = 0, rebindings = 0, compatibility_fallbacks = 0, clock_failures = 0, listener_destroy_failures = 0 }
local speed_deps
local loaded_services = setmetatable({}, { __mode = 'k' })
local ranges = { __init = {52,111}, _ensure_started = {319,364}, _on_item_added = {404,436},
   _on_storage_added = {438,505}, _rate_item = {980,1057}, _make_is_restockable_predicate = {1217,1320},
   _mark_ready_to_generate_new_errands = {394,401} }
local function finite(value) return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge end
local function raw_clock() return _host:get_realtime() end
local function clock()
   local ok, now = pcall(raw_clock)
   if ok and finite(now) then return now end
end
local function observed_clock()
   local now = clock()
   if not now then state.clock_failures = state.clock_failures + 1; state.clock_disabled = true end
   return now
end
local function clock_backwards()
   state.clock_failures = state.clock_failures + 1
   state.clock_disabled = true
end
local function inspect(fn, source, range)
   if type(fn) ~= 'function' or not debug or type(debug.getinfo) ~= 'function' then return false end
   local ok, info = pcall(debug.getinfo, fn, 'S')
   return ok and type(info) == 'table' and info.what == 'Lua' and info.source == source
      and (not range or (info.linedefined == range[1] and info.lastlinedefined == range[2]))
end
local function native(fn)
   if type(fn) ~= 'function' or not debug or type(debug.getinfo) ~= 'function' then return false end
   local ok, info = pcall(debug.getinfo, fn, 'S')
   return ok and type(info) == 'table' and info.what == 'C'
end
local function constructor(value)
   if native(value) then return true end
   local mt = (type(value) == 'table' or type(value) == 'userdata') and getmetatable(value)
   return type(mt) == 'table' and native(mt.__call)
end
local function owns_record(record)
   return state.applied and record.generation == state.generation
      and (owner[record.method] == record.wrapper or (record.profiler and owner[record.method] == record.profiler))
end
local function owns()
   if not state.applied then return false end
   for _, record in pairs(records) do if not owns_record(record) then return false end end
   for method, fn in pairs(helpers) do if owner[method] ~= fn then return false end end
   return true
end
local function dependencies_valid()
   return deps and slice and slice.bootstrap_ready == deps.slice_ready and deps.slice_ready()
      and radiant and radiant.on_game_loop_once == deps.loop and radiant.events
      and radiant.events.listen == deps.listen and radiant.set_realtime_interval == deps.realtime_interval
      and radiant.entities and radiant.entities.exists_in_world == deps.exists_in_world
      and radiant.entities.get_world_location == deps.get_world_location
      and radiant.entities.create_entity == deps.create_entity and radiant.terrain
      and radiant.terrain.place_entity_at_exact_location == deps.place_entity
      and stonehearth and stonehearth.ai == deps.ai and stonehearth.ai.create_spatial_cache == deps.spatial_cache
      and stonehearth.ai.filter_from_key == deps.filter and stonehearth.calendar == deps.calendar
      and stonehearth.calendar.get_elapsed_time == deps.elapsed and stonehearth.constants
      and stonehearth.constants.inventory and stonehearth.constants.inventory.restock_director
      and stonehearth.constants.inventory.restock_director.ITEM_RATING_CACHE_RESET_INTERVAL_SEC == 60
      and stonehearth.constants.ai and stonehearth.constants.ai.RESERVATION_LEASE_NAME == 'ai_reservation'
      and _radiant and _radiant.sim and _radiant.sim.create_item_filter_finder == deps.finder
      and _radiant.queue and _radiant.queue.PriorityQueue == deps.queue
      and _radiant.csg and _radiant.csg.Point3 == deps.Point3
end
-- Only the deadline uses this pause-aware wall clock. Dispatcher budgets and
-- backwards/failure checks continue using the original host wall clock.
local function deadline_fallback(reason, expected)
   if deadline.mode == 'pause_aware' and not expected then deadline.compatibility_fallbacks = deadline.compatibility_fallbacks + 1 end
   deadline.mode, deadline.reason = 'wall_fallback', reason
   deadline.running, deadline.segment_started = false, nil
end
local function speed_valid()
   local d = speed_deps
   if not d or not d.live or not radiant or not radiant.events
      or radiant.events.listen ~= d.listen or radiant.events.trigger ~= d.trigger
      or not stonehearth or d.class.on_game_load_complete_command ~= d.wrapper
      or d.class.set_game_speed ~= d.set_speed or d.class._ace_old_set_game_speed ~= d.old_set
      or d.class.initialize ~= d.initialize or d.class.get_game_speed ~= d.get_speed then return false end
   local service = stonehearth.game_speed
   return not service or (type(service) == 'table'
      and service.on_game_load_complete_command == d.wrapper and service.set_game_speed == d.set_speed
      and service._ace_old_set_game_speed == d.old_set and service.initialize == d.initialize
      and service.get_game_speed == d.get_speed)
end
local function deadline_value(now, validate)
   if deadline.mode ~= 'pause_aware' then return now end
   -- Validate at dispatch/guard/event/hook boundaries, never per replay item.
   if validate and not speed_valid() then deadline_fallback('game_speed_dependency_changed'); return now end
   if not now then return nil end
   if validate then
      if deadline.last_observed and now < deadline.last_observed then
         deadline.clock_failures = deadline.clock_failures + 1
         clock_backwards(); return nil
      end
      deadline.last_observed = now
   elseif deadline.last_observed and now < deadline.last_observed then
      -- The passed budget sample can predate a reentrant speed event/status read.
      -- Its newer scalar observation is safe to reuse; this does not cap gaps.
      now = deadline.last_observed
   end
   return deadline.elapsed + (deadline.running and (now - deadline.segment_started) or 0)
end
local function deadline_boundary(now)
   deadline_value(now, true)
   if deadline.mode ~= 'pause_aware' or not deadline.loading then return end
   local service = stonehearth.game_speed
   -- Saved-game initialize sets this barrier before its one forced native tick.
   -- A processing entry without that barrier or an observed load completion is
   -- an unsupported late/new-game boundary: keep the original finite deadline.
   if not service or (not service._wait_for_game_loaded_command and not loaded_services[service]) then
      deadline_fallback('load_completion_not_observed')
   end
end
local function deadline_transition(speed, loading)
   if deadline.mode ~= 'pause_aware' then return end
   if not finite(speed) or speed < 0 then deadline_fallback('invalid_game_speed'); return end
   local now = observed_clock()
   if not now then deadline.clock_failures = deadline.clock_failures + 1; return end
   local value = deadline_value(now, true)
   if deadline.mode ~= 'pause_aware' or not value then return end
   local running = not loading and speed > 0
   deadline.elapsed, deadline.loading = value, loading
   deadline.running, deadline.segment_started = running, running and now or nil
   deadline.transitions = deadline.transitions + 1
end
local function deadline_loaded(service, remembered)
   if deadline.mode ~= 'pause_aware' or not speed_valid() or stonehearth.game_speed ~= service then
      if deadline.mode == 'pause_aware' then deadline_fallback('load_complete_dependency_changed') end
      return
   end
   if service._wait_for_game_loaded_command then return end
   local sv = service._sv
   if type(sv) ~= 'table' or not finite(sv.curr_speed) then deadline_fallback('load_complete_speed_unavailable'); return end
   loaded_services[service] = true
   if remembered then deadline.rebindings = deadline.rebindings + 1
   else deadline.load_completions = deadline.load_completions + 1 end
   deadline_transition(sv.curr_speed, false)
end
local function finish_load(service, ...)
   deadline_loaded(service)
   return ... -- preserve all original returns, including nil holes
end
local function deadline_age(epoch, now)
   local value = deadline_value(now)
   if not value then return nil end
   if deadline.mode ~= 'pause_aware' then
      return epoch.processing_started and now - epoch.processing_started or 0
   end
   if epoch.processing_active_started == nil then
      epoch.processing_active_started = value
      epoch.event.processing_started_active_seconds = value
   end
   local elapsed = value - epoch.processing_active_started
   epoch.event.processing_active_age_seconds = elapsed
   state.max_processing_active_age_seconds = math.max(state.max_processing_active_age_seconds or 0, elapsed)
   return elapsed
end
deadline_stop = function(reason)
   local d = speed_deps
   speed_deps = nil
   deadline_fallback(reason, reason == 'restored' or reason == 'reinstalling')
   if d then
      d.live = false -- invalidate any retained/reentrant callback before external cleanup
      if d.class.on_game_load_complete_command == d.wrapper then d.class.on_game_load_complete_command = d.original end
      local handle = d.listener
      d.listener = nil
      if handle and type(handle.destroy) == 'function' then
         local ok = pcall(handle.destroy, handle)
         if not ok then deadline.listener_destroy_failures = deadline.listener_destroy_failures + 1 end
      end
   end
end
deadline_install = function(require_module)
   deadline_stop('reinstalling')
   if speed_deps then return end -- external listener cleanup may have reentered apply
   local ok, class = pcall(require_module, 'stonehearth.services.server.game_speed.game_speed_service')
   local source = '@stonehearth/services/server/game_speed/game_speed_service.lua'
   local ace = '@stonehearth_ace/monkey_patches/ace_game_speed_service.lua'
   if not ok or type(class) ~= 'table'
      or not inspect(class.initialize, source, {10,54})
      or not inspect(class.get_game_speed, source, {105,107})
      or not inspect(class._ace_old_set_game_speed, source, {91,103})
      or not inspect(class.set_game_speed, ace, {25,35})
      or not inspect(class.on_game_load_complete_command, ace, {7,22})
      or type(radiant.events.trigger) ~= 'function' then
      deadline.reason = 'unsupported_game_speed_source'; return
   end
   local d = { class = class, original = class.on_game_load_complete_command, initialize = class.initialize,
      get_speed = class.get_game_speed, set_speed = class.set_game_speed, old_set = class._ace_old_set_game_speed,
      listen = radiant.events.listen, trigger = radiant.events.trigger, live = true }
   d.wrapper = function(self, ...)
      -- Original errors propagate unchanged. Cleanup/reapply during original work
      -- cannot activate a stale hook or a different clock generation.
      local function finished(...)
         if speed_deps == d and d.live then return finish_load(self, ...) end
         return ...
      end
      return finished(d.original(self, ...))
   end
   speed_deps = d
   class.on_game_load_complete_command = d.wrapper
   deadline.mode, deadline.reason = 'pause_aware', nil
   deadline.elapsed, deadline.last_observed, deadline.segment_started = 0, nil, nil
   deadline.running, deadline.loading = false, true
   local registered, handle = pcall(d.listen, stonehearth, 'stonehearth:game_speed:changed', function(event)
      if speed_deps ~= d or not d.live then return end
      if not speed_valid() then deadline_fallback('game_speed_dependency_changed'); return end
      local service = stonehearth.game_speed
      if not service or type(service._sv) ~= 'table' then deadline_fallback('game_speed_service_unavailable'); return end
      if type(event) ~= 'table' or not finite(event.speed) or event.speed ~= service._sv.curr_speed then
         deadline_fallback('invalid_game_speed_event'); return
      end
      if deadline.loading and not service._wait_for_game_loaded_command and not loaded_services[service] then
         deadline_fallback('load_completion_not_observed'); return
      end
      -- Loading's forced native pause bypasses ACE's speed-change event.
      deadline_transition(event.speed, deadline.loading or service._wait_for_game_loaded_command == true)
   end)
   if speed_deps ~= d or not d.live then
      if registered and handle and type(handle.destroy) == 'function' then pcall(handle.destroy, handle) end
      return
   end
   if not registered or not handle or type(handle.destroy) ~= 'function' then
      deadline_stop('speed_listener_registration_failed'); return
   end
   d.listener = handle
   if not speed_valid() then deadline_stop('game_speed_dependency_changed'); return end
   -- Remain unarmed until this installed hook observes successful load completion.
   -- Even initialized saved variables can predate native initialize's forced pause.
   local service = stonehearth.game_speed
   if service and loaded_services[service] and not service._wait_for_game_loaded_command then deadline_loaded(service, true) end
end
local function inventory_shape(inventory)
   if type(inventory) ~= 'table' then return false end
   for name, fn in pairs(deps.getters) do if inventory[name] ~= fn then return false end end
   return true
end
local function compatible(self)
   if not state.applied then return false end
   -- Both class and instance must still agree after every external invocation.
   -- Combine the former owns() and instance walks; never cache their result
   -- across item callbacks, inventory getters or loop boundaries.
   for i = 1, #record_list do
      local record = record_list[i]
      local class_fn, instance_fn = owner[record.method], self[record.method]
      local wrapper, profiler = record.wrapper, record.profiler
      if record.generation ~= state.generation
         or (class_fn ~= wrapper and (not profiler or class_fn ~= profiler))
         or (instance_fn ~= wrapper and (not profiler or instance_fn ~= profiler)) then return false end
   end
   for i = 1, #helper_list, 2 do
      local name, fn = helper_list[i], helper_list[i + 1]
      if owner[name] ~= fn or self[name] ~= fn then return false end
   end
   return dependencies_valid() and inventory_shape(self._inventory)
end
local function constructor_compatible(self, inventory)
   if not owns() or not dependencies_valid() or not inventory_shape(inventory) then return false end
   for name, fn in pairs(helpers) do if self[name] ~= fn then return false end end
   for name, record in pairs(records) do
      if self[name] ~= record.wrapper and self[name] ~= record.profiler then return false end
   end
   return true
end
local function add_measure(map, name, started, ended)
   local value = map[name]
   if not value then value = { calls = 0, total_ms = 0, max_ms = 0, untimed_calls = 0 }; map[name] = value end
   value.calls = value.calls + 1
   value.last_started_host_seconds, value.last_ended_host_seconds = started, ended
   if started and ended and ended >= started then
      local ms = (ended - started) * 1000
      value.last_ms, value.total_ms, value.max_ms = ms, value.total_ms + ms, math.max(value.max_ms, ms)
   else
      value.untimed_calls = value.untimed_calls + 1
      if started and ended then state.clock_failures = state.clock_failures + 1; state.clock_disabled = true end
   end
end
local function measure(name, started, event)
   local ended = observed_clock()
   add_measure(state.phases, name, started, ended)
   if event then add_measure(event.phases, name, started, ended) end
   return ended
end
local function event(kind, mode, started)
   state.event_count = state.event_count + 1
   local value = { sequence = state.event_count, kind = kind, mode = mode and 'sliced' or 'stock',
      sliced_mode = mode, enabled_requested = state.enabled, started_host_seconds = started, phases = {}, seed_total = 0,
      seed_out_of_world = 0, seed_fast_captured = 0, seed_fast_fallbacks = 0,
      captured = 0, replayed = 0, completed = false }
   state.events[(state.event_count - 1) % 32 + 1] = value
   return value
end
local function age(epoch, now)
   if now and epoch.started and now >= epoch.started then
      state.max_pending_age_seconds = math.max(state.max_pending_age_seconds, now - epoch.started)
   end
   if now and epoch.processing_started and now >= epoch.processing_started then
      state.max_processing_age_seconds = math.max(state.max_processing_age_seconds, now - epoch.processing_started)
   end
end
local function unlink(node)
   if not node or not node.linked then return end
   if node.prev then node.prev.next = node.next else first = node.next end
   if node.next then node.next.prev = node.prev else last = node.prev end
   node.prev, node.next, node.linked = nil, nil, false
end
local function enqueue(node)
   if node.linked then return end
   node.prev, node.next, node.linked = last, nil, true
   if last then last.next = node else first = node end
   last = node
end
local function stop_dispatcher()
   local handle = dispatcher
   dispatcher, dispatcher_identity = nil, nil
   if handle then handle:destroy() end
end
local function detach(self, epoch)
   if epochs[self] == epoch then epochs[self] = nil end
   unlink(epoch.node)
   age(epoch, clock())
end
local function discard_entries(epoch)
   epoch.items, epoch.first_flags, epoch.kinds, epoch.ids = nil, nil, nil, nil
end
local function cancel(self, reason)
   local epoch = epochs[self]
   if not epoch then return end
   detach(self, epoch)
   state.cancelled = state.cancelled + 1
   epoch.event.cancelled, epoch.event.cancel_reason = true, reason
   discard_entries(epoch) -- destruction/constructor failure intentionally discard private work
   if not first and not dispatching then stop_dispatcher() end
end
local function new_epoch(self, value, started)
   local epoch = { generation = state.generation, started = started, event = value,
      items = setmetatable({}, WEAK_VALUES), first_flags = {}, kinds = {}, ids = {},
      tail = 0, position = 1, constructing = 0 }
   epoch.node = { field = setmetatable({self}, { __mode = 'v' }), epoch = epoch }
   epochs[self] = epoch
   return epoch
end
local function append(self, epoch, item, first_time, kind, id)
   -- One weak item array per epoch instead of two tables for every event.
   -- Explicit tail preserves FIFO positions when weak values disappear or are consumed.
   local index = epoch.tail + 1
   epoch.tail = index
   epoch.items[index], epoch.first_flags[index], epoch.kinds[index], epoch.ids[index] = item, first_time, kind, id
   state.captured = state.captured + 1
   epoch.event.captured = epoch.event.captured + 1
end
local function replay(self, epoch, index, dispatch_timing)
   if self._hearth_smoother_retired then return end
   local item, first_time, kind, id = epoch.items[index], epoch.first_flags[index], epoch.kinds[index], epoch.ids[index]
   -- Consume before external calls: reentrant handoff/destroy cannot duplicate
   -- this event or leave consumed metadata retained until the entire queue drains.
   epoch.items[index], epoch.first_flags[index], epoch.kinds[index], epoch.ids[index] = nil, nil, nil, nil
   if kind == 'stored_seed' then
      local inventory = self._inventory
      if not item or not inventory or type(inventory.get_all_items) ~= 'function'
         or inventory:get_all_items()[id] ~= item then
         state.seed_replaced = state.seed_replaced + 1
         return
      end
   end
   local detailed = not dispatch_timing and state.detailed_replay_timing
   local started = detailed and observed_clock() or nil
   -- Original checks live validity/container/material/quality; never invent a filter.
   local ok, err = pcall(records._on_item_added.original, self, item, first_time)
   if detailed then measure('on_item_replay', started, epoch.event) end
   epoch.event.replayed = epoch.event.replayed + 1
   state.replayed = state.replayed + 1
   if not ok then error(err, 0) end
end
handoff = function(self, reason)
   if self._hearth_smoother_retired then cancel(self, 'retired'); return end
   local epoch = epochs[self]
   if not epoch then return end
   detach(self, epoch) -- remove the barrier before any original/native reentry
   epoch.event.handoff_reason = reason
   state.fallback_handoffs = state.fallback_handoffs + 1
   local started, failed, failure = observed_clock(), false, nil
   local last_item = epoch.tail -- finite cutoff; later arrivals go directly stock
   while epoch.position <= last_item do
      local index = epoch.position
      epoch.position = epoch.position + 1
      local ok, err = pcall(replay, self, epoch, index)
      if not ok and not failed then failed, failure = true, err end
   end
   measure('handoff', started, epoch.event)
   discard_entries(epoch)
   epoch.event.handoff_completed = not failed
   if self._started and last_item > 0 then
      local ok, err = pcall(self._mark_ready_to_generate_new_errands, self)
      if not ok and not failed then failed, failure = true, err end
   end
   if not first and not dispatching then stop_dispatcher() end
   if failed then error(failure, 0) end
end
handoff_all = function(reason)
   local failed, failure = false, nil
   for self in pairs(epochs) do
      local ok, err = pcall(handoff, self, reason)
      if not ok and not failed then failed, failure = true, err end
   end
   while first do
      local node = first
      unlink(node)
      state.cancelled = state.cancelled + 1
      node.epoch.event.cancelled, node.epoch.event.cancel_reason = true, 'collected'
      discard_entries(node.epoch)
   end
   if not dispatching then stop_dispatcher() end
   if failed then error(failure, 0) end
end
local function complete(self, epoch)
   detach(self, epoch)
   epoch.event.completed = true
   epoch.event.completed_host_seconds = clock()
   discard_entries(epoch)
   state.completed = state.completed + 1
   if epoch.event.captured > 0 or epoch.generation_wait then self:_mark_ready_to_generate_new_errands() end
end
local function seal(self, epoch)
   if epochs[self] ~= epoch or epoch.constructing > 0 then return end
   epoch.initial_end = epoch.tail
   epoch.event.initial_end = epoch.initial_end
   epoch.refs = setmetatable({self._inventory, self._item_filter_finder,
      self._restockable_items_queue, self._restockable_high_quality_items_queue}, { __mode = 'v' })
   if epoch.initial_end == 0 then complete(self, epoch)
   else enqueue(epoch.node); schedule() end
end
local function valid_epoch(self, epoch)
   local refs = epoch.refs
   return not self._hearth_smoother_retired and epochs[self] == epoch and epoch.generation == state.generation and epoch.constructing == 0
      and state.enabled and not state.clock_disabled and compatible(self) and self._started
      and refs and refs[1] and refs[1] == self._inventory and refs[2] and refs[2] == self._item_filter_finder
      and refs[3] and refs[3] == self._restockable_items_queue
      and refs[4] and refs[4] == self._restockable_high_quality_items_queue
end
local function step(self, epoch, now)
   if not valid_epoch(self, epoch) then handoff(self, 'source_or_lifecycle_changed'); return end
   if not now or now < epoch.started or (epoch.processing_started and now < epoch.processing_started) then
      if now then clock_backwards() end
      handoff(self, 'clock_failure'); return
   end
   if not epoch.processing_started then
      epoch.processing_started = now
      epoch.event.processing_started_host_seconds = now
   end
   age(epoch, now)
   local processing_age = deadline_age(epoch, now)
   if not processing_age or state.clock_disabled then handoff(self, 'clock_failure'); return end
   if processing_age >= state.max_age_seconds then
      state.timeouts = state.timeouts + 1; handoff(self, 'timeout'); return
   end
   local index = epoch.position
   epoch.position = epoch.position + 1 -- error/reentry cannot duplicate this invocation
   replay(self, epoch, index, true)
   if epochs[self] ~= epoch then return end
   if not epoch.cutoff and epoch.position > epoch.initial_end then
      epoch.cutoff = epoch.tail
      epoch.event.cutoff = epoch.cutoff
   end
   if epoch.cutoff and epoch.position > epoch.cutoff then complete(self, epoch) end
end
local function dispatch_body(started)
   local visits, now = 0, started
   while first and visits < state.max_items do
      local node = first
      unlink(node)
      local self, epoch = node.field[1], node.epoch
      visits = visits + 1
      -- Snapshot the option before callbacks: a reentrant configure affects
      -- the next visit, never half of this visit's timing protocol.
      local detailed = state.detailed_replay_timing
      local step_started, replayed_before = now, detailed and epoch.event.replayed
      if self and epochs[self] == epoch then
         local ok, err = pcall(step, self, epoch, now)
         if not ok then
            if detailed then
               local ended = observed_clock()
               if epoch.event.replayed ~= replayed_before then
                  add_measure(state.phases, 'replay_step', step_started, ended)
                  add_measure(epoch.event.phases, 'replay_step', step_started, ended)
               end
            end
            -- Try every remaining original invocation, then retain the first error.
            pcall(handoff, self, 'dispatch_error')
            error(err, 0)
         end
         if epochs[self] == epoch then enqueue(node) end
      else
         state.cancelled = state.cancelled + 1
         epoch.event.cancelled, epoch.event.cancel_reason = true, 'collected'
         discard_entries(epoch)
      end
      now = observed_clock()
      if detailed and epoch.event.replayed ~= replayed_before then
         -- Reuse the mandatory per-item budget observation. This inclusive
         -- replay-step phase also covers ownership checks and Lua bookkeeping;
         -- it is not a measurement of only the stock item callback.
         add_measure(state.phases, 'replay_step', step_started, now)
         add_measure(epoch.event.phases, 'replay_step', step_started, now)
      end
      if not now or now < started then
         if now then clock_backwards() end
         handoff_all('clock_failure'); return
      end
      if detailed then
         -- Detailed phase accounting is part of the current item's budget.
         local budget_now = observed_clock()
         if not budget_now or budget_now < now then
            if budget_now then clock_backwards() end
            handoff_all('clock_failure'); return
         end
         now = budget_now
      end
      if (now - started) * 1000 >= state.budget_ms then return end
   end
end
schedule = function()
   if dispatcher or dispatching or not first then return end
   local identity = setmetatable({}, { __mode = 'v' })
   local generation = state.generation
   local ok, handle = pcall(deps.loop, 'hearth_smoother restock bootstrap continuation', function()
      local current = identity[1]
      if not current or dispatcher ~= current or dispatcher_identity ~= identity or generation ~= state.generation then return end
      dispatcher, dispatcher_identity = nil, nil
      local started = observed_clock()
      if not started or not owns() or not dependencies_valid() or not state.enabled or state.clock_disabled then
         handoff_all('inactive_or_clock_failure'); return
      end
      deadline_boundary(started)
      if state.clock_disabled then handoff_all('clock_failure'); return end
      dispatching = true
      state.global_dispatches = state.global_dispatches + 1
      local dispatched, err = pcall(dispatch_body, started)
      dispatching = false
      local scheduled, scheduling_error = pcall(schedule)
      -- Registration failure can synchronously hand off remaining work: include
      -- that recovery and ordinary rescheduling in the complete callback cost.
      measure('dispatcher', started)
      if not dispatched then error(err, 0) end
      if not scheduled then error(scheduling_error, 0) end
   end)
   if not ok then pcall(handoff_all, 'scheduler_error'); error(handle, 0) end
   identity[1] = handle
   dispatcher, dispatcher_identity = handle, identity
end
local function finish_source(self, previous, ok, ...)
   origins[self] = previous
   if not ok then error((...), 0) end
   return ...
end
local function source_item(self, item, first_time, kind, id)
   local previous = origins[self]
   origins[self] = { kind = kind, id = id }
   return finish_source(self, previous, pcall(self._on_item_added, self, item, first_time))
end
local function seed_capture_valid(self, epoch, inventory, context)
   local record = records._on_item_added
   local current = self._on_item_added
   local class_current = owner._on_item_added
   return epochs[self] == epoch and epoch.constructing > 0 and state.applied
      and epoch.generation == state.generation and record.generation == state.generation
      and state.enabled and not state.clock_disabled and not epoch.cutoff
      and (current == record.wrapper or (record.profiler and current == record.profiler))
      and (class_current == record.wrapper or (record.profiler and class_current == record.profiler))
      and contexts[self] == context
      and self._inventory == inventory and inventory.get_all_items == deps.getters.get_all_items
      and radiant.entities.exists_in_world == deps.exists_in_world
      and radiant.entities.get_world_location == deps.get_world_location
end
local function ensure_body(self)
   -- Exact ACE 319--364 control flow and native operations; only phase clocks
   -- and source tags around original on-item dispatch are inserted.
   if self._started then return end
   assert(not self._item_spatial_cache)
   assert(not self._item_filter_finder_src_entity)
   assert(not self._item_filter_finder)
   assert(not self._lease_release_listener)
   local value, started = contexts[self], observed_clock()
   self._item_spatial_cache = stonehearth.ai:create_spatial_cache(self._is_restockable_predicate, self._is_restockable_predicate_key, 'restock_director')
   measure('spatial_cache', started, value)
   started = observed_clock()
   self._item_filter_finder_src_entity = radiant.entities.create_entity('stonehearth:object:anchor', { debug_text = 'restock director search source' })
   radiant.terrain.place_entity_at_exact_location(self._item_filter_finder_src_entity, deps.Point3(0, 0, 0))
   measure('anchor', started, value)
   started = observed_clock()
   self._item_filter_finder = _radiant.sim.create_item_filter_finder(self._item_filter_finder_src_entity, self._is_restockable_predicate_key)
      :set_added_cb(function(e) source_item(self, e, true, 'finder_added') end)
      :set_reappraise_cb(function(e) source_item(self, e, nil, 'finder_reappraise') end)
      :start()
   measure('finder', started, value)
   started = observed_clock()
   self._lease_release_listener = radiant.events.listen(radiant, 'stonehearth:lease_released', function(e)
      local entity = radiant.entities.get_entity(e.entity_id)
      if entity and entity:is_valid() and e.lease_name == deps.reservation_lease_name and stonehearth.ai:fast_call_filter_fn(self._is_restockable_predicate, entity) then
         source_item(self, entity, nil, 'lease_released')
      end
   end)
   measure('lease_listener', started, value)
   started = observed_clock()
   local inventory, seed_epoch = self._inventory, epochs[self]
   local collect_seeds = seed_epoch and seed_epoch.constructing > 0 and compatible(self)
   if seed_epoch and not collect_seeds then handoff(self, 'seed_source_changed') end
   for id, item in pairs(inventory:get_all_items()) do
      state.seed_total = state.seed_total + 1
      if value then value.seed_total = value.seed_total + 1 end
      local in_world = deps.exists_in_world(item)
      local capture_seed = collect_seeds and seed_capture_valid(self, seed_epoch, inventory, value)
      if collect_seeds and not capture_seed then
         state.seed_fast_fallbacks = state.seed_fast_fallbacks + 1
         if value then value.seed_fast_fallbacks = value.seed_fast_fallbacks + 1 end
         handoff(self, 'seed_source_changed')
         collect_seeds = false
      end
      if not in_world then
         state.seed_out_of_world = state.seed_out_of_world + 1
         if value then value.seed_out_of_world = value.seed_out_of_world + 1 end
         if capture_seed then
            append(self, seed_epoch, item, true, 'stored_seed', id)
            state.seed_fast_captured = state.seed_fast_captured + 1
            if value then value.seed_fast_captured = value.seed_fast_captured + 1 end
         else
            source_item(self, item, true, 'stored_seed', id)
         end
      end
   end
   if seed_epoch and epochs[self] == seed_epoch and not compatible(self) then
      handoff(self, 'seed_source_changed')
   end
   measure('inventory_seed', started, value)
   started = observed_clock()
   self._item_rating_cache_clear_interval = radiant.set_realtime_interval('clear item rating cache', 60 * 1000.0, function()
      self._item_rating_cache = {}
   end)
   self._started = true
   measure('rating_timer', started, value)
end
local function finish_scope(self, previous, epoch, value, kind, started, ok, ...)
   contexts[self] = previous
   if epoch then epoch.constructing = epoch.constructing - 1 end
   if type(self) == 'table' then
      local player, name = rawget(self, '_player_id'), rawget(self, '_director_name')
      if type(player) == 'string' or type(player) == 'number' then value.player_id = player end
      if type(name) == 'string' then value.director_name = name end
   end
   if not ok then
      value.error_type = type((...))
      value.completed = false
      pcall(cancel, self, 'constructor_error')
      measure(kind, started, value)
      value.ended_host_seconds = clock()
      error((...), 0)
   end
   local sealed, seal_error = true, nil
   if epoch and epochs[self] == epoch then sealed, seal_error = pcall(seal, self, epoch) end
   measure(kind, started, value)
   value.ended_host_seconds = clock()
   if not sealed then value.error_type = type(seal_error); error(seal_error, 0) end
   if not epoch and not previous then value.completed = true end
   return ...
end
local function construct(record, self, inventory, allow_stored, storage_predicate)
   local cache = hearth_smoother_director_cache
   if type(cache) == 'table' and type(cache.construct) == 'function' then
      return cache.construct(self, inventory, allow_stored, storage_predicate, record.original)
   end
   return record.original(self, inventory, allow_stored, storage_predicate)
end
local function safety_required()
   for _, module in pairs({hearth_smoother_director_cache, hearth_smoother_director_lifetime}) do
      if type(module) == 'table' and type(module.status) == 'function' then
         local ok, status = pcall(module.status)
         if ok and type(status) == 'table' and status.active then return true end
      end
   end
   return false
end
local function make_wrapper(record)
   return function(self, ...)
      if self._hearth_smoother_retired and record.method ~= 'destroy' and record.method ~= '_ensure_stopped' then
         cancel(self, 'retired'); return
      end
      if record.method == '__init' then self._hearth_smoother_shared_director_cache = nil end
      if record.method == 'destroy' then
         cancel(self, 'destroy')
         return record.original(self, ...)
      elseif record.method == '_ensure_stopped' then
         local ok, err = pcall(handoff, self, 'stop')
         local stopped, stop_error = pcall(record.original, self, ...)
         if not ok then error(err, 0) end
         if not stopped then error(stop_error, 0) end
         return
      elseif record.method == '_on_item_added' then
         local epoch = epochs[self]
         local first_time = select(2, ...)
         if epoch and (record.generation ~= state.generation or not state.enabled or state.clock_disabled
            or (first_time ~= nil and type(first_time) ~= 'boolean')
            or not compatible(self)) then handoff(self, 'disabled_or_foreign'); epoch = nil end
         if epoch and not epoch.cutoff then
            local origin = origins[self]
            append(self, epoch, (...), first_time, origin and origin.kind or 'direct', origin and origin.id)
            return
         end
         local value = contexts[self]
         if value then
            local detailed = state.detailed_replay_timing
            local started = detailed and observed_clock() or nil
            local ok, err = pcall(record.original, self, ...)
            if detailed then measure('on_item_inline', started, value) end
            value.inline_items = (value.inline_items or 0) + 1
            if not ok then error(err, 0) end
            return
         end
         return record.original(self, ...)
      end
      if not owns_record(record) or not dependencies_valid() then return record.original(self, ...) end
      if record.method == '__init' and not constructor_compatible(self, (...)) then return record.original(self, ...) end
      if record.method == '_ensure_started' and (self._started or not compatible(self)) then return record.original(self, ...) end
      local started = observed_clock()
      local previous = contexts[self]
      local enabled = state.enabled and not state.clock_disabled and started ~= nil
      local value = previous or event(record.method == '__init' and 'constructor' or 'ensure_started', enabled, started)
      contexts[self] = value
      local epoch = epochs[self]
      if enabled and not epoch then epoch = new_epoch(self, value, started) end
      if epoch then epoch.constructing = epoch.constructing + 1 end
      if record.method == '__init' then
         return finish_scope(self, previous, epoch, value, 'constructor', started, pcall(construct, record, self, ...))
      end
      return finish_scope(self, previous, epoch, value, 'ensure_started', started, pcall(ensure_body, self))
   end
end
function M.guard_generation(self)
   local epoch = epochs[self]
   if not epoch then return false end
   state.guarded_generation = state.guarded_generation + 1
   epoch.generation_wait = true
   if epoch.constructing > 0 then return true end
   local now = observed_clock()
   deadline_boundary(now)
   local processing_age = now and epoch.processing_started and deadline_age(epoch, now)
   local timed_out = processing_age and processing_age >= state.max_age_seconds
   local backwards = now and ((epoch.started and now < epoch.started)
      or (epoch.processing_started and now < epoch.processing_started))
   if not now or state.clock_disabled or not epoch.started or backwards or timed_out
      or not valid_epoch(self, epoch) then
      if backwards then clock_backwards() end
      if timed_out then state.timeouts = state.timeouts + 1 end
      handoff(self, 'generation_fallback'); return false
   end
   enqueue(epoch.node); schedule()
   return epochs[self] ~= nil
end
function M.before_slice_restore() handoff_all('slice_restore') end
function M.apply()
   if state.applied then
      if not speed_deps and radiant and radiant.mods and type(radiant.mods.require) == 'function' then
         deadline_install(radiant.mods.require)
      end
      return owns() and dependencies_valid(), M.status()
   end
   local function reject(reason) state.skipped_reason = reason; return false, reason end
   local require_module = radiant and radiant.mods and radiant.mods.require
   if type(require_module) ~= 'function' then return reject('require API unavailable') end
   if not radiant.entities or not radiant.terrain or not radiant.events or not stonehearth or not stonehearth.ai
      or not stonehearth.calendar or not stonehearth.constants or not stonehearth.constants.ai
      or not _radiant or not _radiant.csg or not _radiant.queue or not _radiant.sim then return reject('startup APIs unavailable') end
   local ok, class = pcall(require_module, PATH)
   if not ok or type(class) ~= 'table' then return reject('director class unavailable') end
   for name, range in pairs(ranges) do
      if not inspect(class[name], SOURCE, range) then return reject('unsupported director source/line: ' .. name) end
   end
   local inventory_ok, inventory = pcall(require_module, 'stonehearth.services.server.inventory.inventory')
   local slice_ok, module = pcall(require_module, 'hearth_smoother.restock_slice')
   if not inventory_ok or type(inventory) ~= 'table' or not slice_ok or type(module) ~= 'table'
      or type(module.register_profiler) ~= 'function' or not inspect(module.bootstrap_ready, SLICE_SOURCE)
      or not module.bootstrap_ready() then return reject('inventory/slice ownership unavailable') end
   local getters = {}
   for name, range in pairs({get_all_items={508,510}, get_all_public_storage={504,506}, get_player_id={331,333}, get_item_tracker={694,696}}) do
      if not inspect(inventory[name], INVENTORY_SOURCE, range) then return reject('unsupported inventory getter: ' .. name) end
      getters[name] = inventory[name]
   end
   if not inspect(radiant.on_game_loop_once, EVENTS_SOURCE, {75,77})
      or not inspect(radiant.entities.exists_in_world, '@radiant/modules/entities.lua', {87,89})
      or not inspect(radiant.entities.get_world_location, '@radiant/modules/entities.lua', {367,370})
      or not inspect(stonehearth.ai.filter_from_key, '@stonehearth/services/server/ai/ai_service.lua', {548,565})
      or not (inspect(stonehearth.ai.create_spatial_cache, '@stonehearth/services/server/ai/ai_service.lua', {632,642})
         or inspect(stonehearth.ai.create_spatial_cache, '@stonehearth/services/server/ai/ai_service.lua', {597,630}))
      or not constructor(_radiant.csg.Point3) or not constructor(_radiant.queue.PriorityQueue)
      or not native(_radiant.sim.create_item_filter_finder) or type(radiant.events.listen) ~= 'function'
      or type(radiant.set_realtime_interval) ~= 'function' or type(radiant.entities.create_entity) ~= 'function'
      or type(radiant.terrain.place_entity_at_exact_location) ~= 'function' then return reject('unsupported native startup dependency') end
   for name, range in pairs({_ensure_stopped={366,392}, destroy={113,135}}) do
      if not inspect(class[name], SLICE_SOURCE) and not inspect(class[name], SOURCE, range) then return reject('unsupported lifecycle chain: ' .. name) end
   end
   slice = module
   deps = { getters = getters, slice_ready = module.bootstrap_ready,
      loop = radiant.on_game_loop_once, listen = radiant.events.listen,
      realtime_interval = radiant.set_realtime_interval, exists_in_world = radiant.entities.exists_in_world,
      get_world_location = radiant.entities.get_world_location,
      create_entity = radiant.entities.create_entity, place_entity = radiant.terrain.place_entity_at_exact_location,
      ai = stonehearth.ai, spatial_cache = stonehearth.ai.create_spatial_cache, filter = stonehearth.ai.filter_from_key,
      calendar = stonehearth.calendar, elapsed = stonehearth.calendar.get_elapsed_time,
      finder = _radiant.sim.create_item_filter_finder, queue = _radiant.queue.PriorityQueue, Point3 = _radiant.csg.Point3,
      reservation_lease_name = stonehearth.constants.ai.RESERVATION_LEASE_NAME }
   if not dependencies_valid() then return reject('unsupported startup constants/dependency identity') end
   owner, slice, helpers, records = class, module, {}, {}
   state.generation = state.generation + 1
   for name in pairs(ranges) do helpers[name] = class[name] end
   for _, name in ipairs({'__init','_ensure_started','_on_item_added','_ensure_stopped','destroy'}) do
      helpers[name] = nil
      local record = { method = name, original = class[name], generation = state.generation }
      record.wrapper = make_wrapper(record)
      records[name], class[name] = record, record.wrapper
   end
   record_list, helper_list = {}, {}
   for _, record in pairs(records) do record_list[#record_list + 1] = record end
   for name, fn in pairs(helpers) do
      helper_list[#helper_list + 1], helper_list[#helper_list + 2] = name, fn
   end
   state.applied = true
   for _, name in ipairs({'_ensure_stopped','destroy'}) do
      local record = records[name]
      if inspect(record.original, SLICE_SOURCE) and not slice.register_profiler(name, record.wrapper, record.original) then
         for method, value in pairs(records) do if class[method] == value.wrapper then class[method] = value.original end end
         state.applied = false
         return reject('lifecycle ownership registration failed: ' .. name)
      end
   end
   deadline_install(require_module)
   state.skipped_reason = nil
   return true, M.status()
end
function M.register_profiler(method, outer, inner)
   local record = records and records[method]
   if not state.applied or not record or record.generation ~= state.generation or inner ~= record.wrapper
      or type(outer) ~= 'function' or owner[method] ~= outer then return false, 'profiler ownership mismatch' end
   if (method == 'destroy' or method == '_ensure_stopped') and inspect(record.original, SLICE_SOURCE)
      and not slice.register_profiler(method, outer, record.original) then return false, 'slice lifecycle ownership mismatch' end
   record.profiler = outer
   return true
end
function M.set_enabled(enabled)
   if type(enabled) ~= 'boolean' then return false, 'bootstrap enabled must be boolean' end
   if enabled and not state.applied then local ok, err = M.apply(); if not ok then return false, err end end
   state.enabled, state.clock_disabled = enabled, false
   if enabled then
      state.safety_wrappers_retained, state.restore_mode = false, nil
      if not speed_deps and radiant and radiant.mods and type(radiant.mods.require) == 'function' then
         deadline_install(radiant.mods.require)
      end
   end
   if not enabled then handoff_all('disabled') end
   return true, M.status()
end
function M.configure(options)
   if type(options) ~= 'table' then return false, 'options required' end
   local max, budget, age_limit = options.max_items, options.budget_ms, options.max_age_seconds
   local detailed = options.detailed_replay_timing
   if detailed == nil then detailed = state.detailed_replay_timing end
   if type(detailed) ~= 'boolean' then return false, 'detailed_replay_timing must be boolean' end
   if max == nil then max = state.max_items end
   if budget == nil then budget = state.budget_ms end
   if age_limit == nil then age_limit = state.max_age_seconds end
   if not finite(max) or max < 1 or max > 1000000 or max ~= math.floor(max)
      or not finite(budget) or budget < 0 or budget > 1000000
      or not finite(age_limit) or age_limit <= 0 or age_limit > 15 then return false, 'invalid bootstrap budget' end
   state.max_items, state.budget_ms, state.max_age_seconds = max, budget, age_limit
   state.detailed_replay_timing = detailed
   return true, M.status()
end
local function copy(value)
   if type(value) ~= 'table' then return value end
   local result = {}; for key, item in pairs(value) do result[key] = copy(item) end; return result
end
function M.status()
   local pending, buffered, now = 0, 0, clock()
   for _, epoch in pairs(epochs) do pending = pending + 1; buffered = buffered + epoch.tail - epoch.position + 1; age(epoch, now) end
   local active_now = deadline_value(now, true)
   local deadline_status = { mode = deadline.mode, reason = deadline.reason, active = deadline.mode == 'pause_aware' and not state.clock_disabled,
      active_seconds = deadline.mode == 'pause_aware' and active_now or nil, running = deadline.running, loading = deadline.loading,
      transitions = deadline.transitions, load_completions = deadline.load_completions, rebindings = deadline.rebindings, compatibility_fallbacks = deadline.compatibility_fallbacks,
      clock_failures = deadline.clock_failures, listener_destroy_failures = deadline.listener_destroy_failures }
   local events = {}
   for index = math.max(1, state.event_count - 31), state.event_count do events[#events + 1] = copy(state.events[(index - 1) % 32 + 1]) end
   return { applied = state.applied, enabled = state.enabled, active = owns() and dependencies_valid() and not state.clock_disabled or false,
      safety_wrappers_retained = state.safety_wrappers_retained or false, restore_mode = state.restore_mode,
      source = SOURCE, generation = state.generation, skipped_reason = state.skipped_reason,
      clock_disabled = state.clock_disabled, clock_failures = state.clock_failures, deadline_clock = deadline_status,
      max_processing_active_age_seconds = state.max_processing_active_age_seconds or 0,
      pending_directors = pending, buffered_items = buffered, captured = state.captured, replayed = state.replayed,
      seed_fast_captured = state.seed_fast_captured, seed_fast_fallbacks = state.seed_fast_fallbacks,
      seed_fast_counter_scope = 'Fast captured counts stored-seed entries appended by the private collector. Fast fallbacks counts the first per-entry cheap-guard failure causing finite handoff; later rows using the dynamic stock path are not counted. Counters show path use, not time saved.',
      processed_items = state.replayed, completed = state.completed, cancelled = state.cancelled,
      timeouts = state.timeouts, fallback_handoffs = state.fallback_handoffs, guarded_generation = state.guarded_generation,
      global_dispatches = state.global_dispatches, seed_total = state.seed_total, seed_out_of_world = state.seed_out_of_world,
      seed_replaced = state.seed_replaced, max_pending_age_seconds = state.max_pending_age_seconds,
      max_processing_age_seconds = state.max_processing_age_seconds,
      max_items = state.max_items, budget_ms = state.budget_ms, max_age_seconds = state.max_age_seconds,
      detailed_replay_timing = state.detailed_replay_timing,
      phases = copy(state.phases), constructor_event_count = state.event_count, constructor_events = events,
      replay_timing_scope = 'Detailed per-item timing defaults off: replay counts and complete dispatcher/constructor/handoff phases remain, with one budget clock per normal visit. When enabled, replay_step retains v110 scope (validation, stock replay, queue bookkeeping, completion) and a second clock includes phase-accounting cost in the budget; on_item_replay measures synchronous handoff callbacks and on_item_inline constructor inline callbacks. Existing detailed phase values remain cumulative when disabled, not zero-cost observations. Option changes apply to each invocation starting after the change.',
      timing_scope = 'Inclusive low-frequency phase totals/maxima accumulate since module load in enabled and disabled modes. Per-item phases are recorded only while detailed_replay_timing is enabled. Ordinary post-constructor items add no clocks. Bounded 32 scalar events identify modes/windows. Do not sum nested phases or interpret cumulative high-water marks as window maxima.',
      semantics = 'Native cache/finder/anchor startup and O(N) inventory traversal remain synchronous. Supported constructors use director_cache complete-context predicate/key sharing even when slicing is disabled. Initial FIFO plus one sealed increment cutoff gate generation; later events call stock directly. Stored seeds revalidate membership; finder events do not require inventory membership. FIFO stores weak item references in one shared array per epoch with explicit indices, and consumes metadata before replay. Default 512-item ceiling uses the same per-item 2ms global time check and round-robin fairness; explicit max_items settings still apply. Global CPP-loop soft budget cannot preempt a native call; with verified ACE game-speed lifecycle the 15s deadline uses accumulated unpaused wall time from the first valid dispatch step; loading and paused intervals are excluded. Unsupported or changed speed dependencies explicitly retain original wall deadline semantics. Total pending and processing host ages remain wall-time diagnostics; processing_active_age_seconds is the separate deadline age. Unpaused inter-dispatch gaps still count in full. Deadline/disable/restore/stop hand off remaining valid invocations synchronously; retired directors cancel private work. Active cache/lifetime safety retains synchronous wrappers on restore. Watchdog conditions, priorities and task limits are unchanged.' }
end
function M.restore()
   state.enabled = false
   local ok, err = pcall(handoff_all, 'restore')
   deadline_stop('restored')
   if state.applied and safety_required() then
      state.safety_wrappers_retained, state.restore_mode = true, 'disabled_slicing_retained_safety'
      if not ok then error(err, 0) end
      return M.status()
   end
   if records then for method, record in pairs(records) do
      if owner[method] == record.wrapper or owner[method] == record.profiler then owner[method] = record.original end
   end end
   state.applied = false
   state.safety_wrappers_retained, state.restore_mode = false, 'fully_restored'
   state.generation = state.generation + 1
   if not ok then error(err, 0) end
   return M.status()
end
return M

