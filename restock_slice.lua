-- Resumable ACE candidate selection. Queue objects and space leases stay stock.
-- Epochs consume at most the initial HQ/LQ sizes from the live priority queues.
-- New arrivals may participate; there is no task-fairness or hard wall-time promise.
local M = {}
local PATH = 'stonehearth.services.server.inventory.restock_director'
local SOURCE = '@stonehearth_ace/services/server/inventory/restock_director.lua'
local PENDING = {} -- internal only; never passed into the stock generation body
local epochs = setmetatable({}, { __mode = 'k' })
local retry_epochs = setmetatable({}, { __mode = 'k' })
local retry_continuations = setmetatable({}, { __mode = 'k' })
local fallback_generating = setmetatable({}, { __mode = 'k' })
local state = { applied = false, enabled = true, generation = 0, max_candidates = 16,
   budget_ms = 2, slices = 0, max_slice_ms = 0, evaluated = 0, selected = 0,
   completed = 0, cancelled = 0, restored_entries = 0, clock_failures = 0,
   clock_disabled = false, max_phase_age_seconds = 0, revalidation_rejected = 0,
   retry_slices = 0, retry_max_slice_ms = 0, retry_evaluated = 0, retry_transferred = 0,
   retry_invalid = 0, retry_replaced = 0, retry_completed = 0, retry_cancelled = 0,
   retry_handoffs = 0, retry_clock_failures = 0, retry_snapshot_count = 0,
   retry_snapshot_items = 0, retry_max_snapshot_ms = 0, retry_max_phase_age_seconds = 0 }
local owner, records, helpers, NearbyItemSearch, MAX_EXTRA_ITEMS, get_world_location, get_item_quality, log
local RETRY_SHORT, RETRY_LONG
local cancel_retry
local function lifetime()
   local m=hearth_smoother_director_lifetime
   return m and type(m.is_active)=='function' and m.is_active() and m or nil
end
local bounds = {
   _get_next_restockable_item = { 611, 694 }, _generate_next_errand = { 743, 857 },
   _ensure_stopped = { 366, 392 }, destroy = { 113, 135 },
   _eval_item_for_restocking = { 696, 740 }, _rate_item = { 980, 1057 },
   _is_storage_higher_priority_for_item = { 861, 886 }, _are_reachable = { 1189, 1215 },
   _mark_ready_to_generate_new_errands = { 394, 401 },
   _request_process_failed_items = { 577, 604 },
   _transfer_failed_items_into_reconsider_queues = { 559, 575 },
   _transfer_reconsider_items_into_restockable_queue = { 540, 557 }
}
local function clock_call() return _host:get_realtime() end
local function clock()
   local ok, value = pcall(clock_call)
   if ok and type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge then return value end
end
local function plain_map(value) return type(value) == 'table' and getmetatable(value) == nil end
local function read_queue_shape(queue)
   local kind = type(queue)
   return (kind == 'table' or kind == 'userdata') and type(queue.get_size) == 'function'
      and type(queue.top) == 'function' and type(queue.pop) == 'function' and type(queue.push) == 'function'
end
local function queue_shape(queue)
   local ok, valid = pcall(read_queue_shape, queue)
   return ok and valid
end
local function owns_record(record)
   return state.applied and record.generation == state.generation and
      (owner[record.method] == record.wrapper or (record.registered_owners and record.registered_owners[owner[record.method]]) or false)
end
local function owns_scan()
   return owns_record(records._get_next_restockable_item) and owns_record(records._generate_next_errand)
      and owns_record(records._request_process_failed_items)
      and owns_record(records._transfer_failed_items_into_reconsider_queues)
      and owns_record(records._transfer_reconsider_items_into_restockable_queue)
end
local function compatible(self)
   for method, expected in pairs(helpers) do if self[method] ~= expected then return false end end
   return queue_shape(self._restockable_high_quality_items_queue) and queue_shape(self._restockable_items_queue)
      and queue_shape(self._reconsider_high_quality_items_queue) and queue_shape(self._reconsider_items_queue)
      and plain_map(self._failed_items) and plain_map(self._reconsidering_items)
      and plain_map(self._covered_items) and plain_map(self._item_quality_cache)
      and plain_map(self._storages_by_filter) and plain_map(self._storage_filters)
      and plain_map(self._errands) and type(self._inventory) == 'table'
      and type(self._inventory.container_for) == 'function'
      and type(self._is_restockable_predicate) == 'function'
end
local function update_age(epoch, now)
   if now and epoch.started and now >= epoch.started then
      state.max_phase_age_seconds = math.max(state.max_phase_age_seconds, now - epoch.started)
   end
end
local function committed(epoch, id)
   epoch.committed_ids[id] = true
end
local function cancel(self, cancel_timer)
   local epoch = epochs[self]
   if not epoch then return end
   epochs[self] = nil -- invalidate before any native queue operation can reenter
   local continuation = epoch.continuation and epoch.continuation[1]
   if cancel_timer and continuation and self._generate_on_next_frame_timer == continuation then
      continuation:destroy()
      self._generate_on_next_frame_timer = nil
   end
   state.cancelled = state.cancelled + 1
   update_age(epoch, clock())
   for index = 1, #epoch.items do
      local item, high = epoch.items[index], epoch.lanes[index]
      if not epoch.committed_ids[epoch.ids[index]] and item:is_valid() then
         local current = high and self._restockable_high_quality_items_queue or self._restockable_items_queue
         -- If another mod replaced a queue, restoring only into the detached
         -- old object would make the item invisible to future stock scans.
         local destination = queue_shape(current) and current or (high and epoch.high or epoch.normal)
         destination:push(epoch.scores[index], item)
         state.restored_entries = state.restored_entries + 1
      end
   end
end
local function cancel_all()
   -- Cancelling deletes only existing keys; never retain directors in a module list.
   for self in pairs(epochs) do cancel(self) end
   for self in pairs(retry_epochs) do cancel_retry(self, false) end
end
local function clock_failure(self)
   state.clock_failures = state.clock_failures + 1
   state.clock_disabled = true
   cancel(self)
   cancel_retry(self, false)
end
local function remember(epoch, queue, score, item, high)
   local index = #epoch.items + 1
   epoch.items[index], epoch.scores[index], epoch.lanes[index] = item, score, high
   epoch.ids[index] = item:is_valid() and item:get_id() or false
end
local function new_epoch(self, now)
   local high, normal = self._restockable_high_quality_items_queue, self._restockable_items_queue
   local hn, ln = high:get_size(), normal:get_size()
   if type(hn) ~= 'number' or type(ln) ~= 'number' or hn < 0 or ln < 0 or hn ~= math.floor(hn) or ln ~= math.floor(ln) then return nil end
   local epoch = { phase = 'high', high = high, normal = normal, high_left = hn, normal_left = ln,
      requeuable = {}, failed = {}, items = {}, scores = {}, lanes = {}, ids = {}, committed_ids = {}, started = now }
   epochs[self] = epoch
   return epoch
end
local function select_primary(self, epoch, item, storage, filter)
   epoch.primary = { item, storage, filter }
   epoch.filter_key = self._storage_filters[storage:get_id()]
   epoch.item_quality = self._item_quality_cache[item:get_id()]
   local entry = self._storages_by_filter[epoch.filter_key]
   epoch.storage_high_quality = entry and entry.high_quality_storages and entry.high_quality_storages[storage:get_id()] == storage or false
   epoch.phase = 'failed'
end
local function live_fallback(tuple)
   return tuple and tuple[1]:is_valid() and tuple[2]:is_valid() and tuple
end
local function choose_fallback(self, epoch)
   -- Backup tuples survive between slices; never ask a destroyed entity for ID.
   -- A stale HQ backup must not suppress a still-live LQ backup.
   local fallback = live_fallback(epoch.high_fallback) or live_fallback(epoch.normal_fallback)
   if fallback then
      local id = fallback[1]:get_id()
      epoch.requeuable[id], epoch.failed[id] = nil, nil
      select_primary(self, epoch, unpack(fallback))
   else epoch.phase = 'failed' end
end
local function valid_selection(self, epoch)
   local tuple = epoch.primary
   if not tuple then return true end
   local item, storage, filter = tuple[1], tuple[2], tuple[3]
   if not item:is_valid() or not storage:is_valid() then return false end
   local id, storage_id = item:get_id(), storage:get_id()
   if self._failed_items[id] or self._reconsidering_items[id] or self._covered_items[id] then return false end
   if self._item_quality_cache[id] ~= epoch.item_quality then return false end
   if self._storage_filters[storage_id] ~= epoch.filter_key then return false end
   local entry = self._storages_by_filter[epoch.filter_key]
   if not entry or entry.filter_fn ~= filter or
      not ((entry.storages and entry.storages[storage_id] == storage) or
           (entry.high_quality_storages and entry.high_quality_storages[storage_id] == storage)) then return false end
   if (entry.high_quality_storages and entry.high_quality_storages[storage_id] == storage or false) ~= epoch.storage_high_quality then return false end
   local ai, component = stonehearth.ai, storage:get('stonehearth:storage')
   return component and component:can_reserve_space()
      and ai:fast_call_filter_fn(self._is_restockable_predicate, item)
      and ai:fast_call_filter_fn(filter, item)
      and self:_is_storage_higher_priority_for_item(item, component)
      and self:_are_reachable(item, storage) or false
end
local function run_slice(self, epoch, started)
   local units = 0
   while true do
      if epochs[self] ~= epoch or not state.enabled or not owns_scan() or not compatible(self) then return 'ownership_changed' end
      if units > 0 then
         local now = clock()
         if not now or now < started then return 'clock_failure' end
         if units >= state.max_candidates or (state.budget_ms > 0 and (now - started) * 1000 >= state.budget_ms) then return PENDING end
      end
      if epoch.phase == 'high' or epoch.phase == 'normal' then
         local high = epoch.phase == 'high'
         local queue, left = high and epoch.high or epoch.normal, high and epoch.high_left or epoch.normal_left
         if left == 0 or queue:get_size() == 0 then
            if high then epoch.phase = 'normal' else choose_fallback(self, epoch) end
         else
            local score, item = queue:top()
            queue:pop()
            if high then epoch.high_left = left - 1 else epoch.normal_left = left - 1 end
            remember(epoch, queue, score, item, high)
            units = units + 1
            state.evaluated = state.evaluated + 1
            local storage, filter = self:_eval_item_for_restocking(item, true, epoch.requeuable)
            if epochs[self] ~= epoch or not state.enabled or not owns_scan() then return 'ownership_changed' end
            if storage then
               select_primary(self, epoch, item, storage, filter)
            elseif not (high and epoch.high_fallback or not high and epoch.normal_fallback) then
               storage, filter = self:_eval_item_for_restocking(item, false, epoch.failed)
               if epochs[self] ~= epoch or not state.enabled or not owns_scan() then return 'ownership_changed' end
               if storage then
                  if high then epoch.high_fallback = { item, storage, filter }
                  else epoch.normal_fallback = { item, storage, filter } end
               end
            end
         end
      elseif epoch.phase == 'failed' then
         -- Resume only a private, no-longer-growing map. Lua next permits
         -- clearing an existing key; no keys are inserted during this phase.
         local id, item = next(epoch.failed, epoch.failed_cursor)
         if id == nil then epoch.phase = 'requeuable'
         else
            epoch.failed_cursor = id
            self._reconsidering_items[id] = nil
            self._failed_items[id] = item
            epoch.requeuable[id] = nil
            committed(epoch, id)
            epoch.failed[id] = nil
            units = units + 1
         end
      elseif epoch.phase == 'requeuable' then
         local id, item = next(epoch.requeuable, epoch.requeuable_cursor)
         if id == nil then epoch.phase = 'validate'
         else
            epoch.requeuable_cursor = id
            -- The ID is already a private-map key; invalid entities must not
            -- enter rating/get_id APIs or native reconsider queues.
            if item:is_valid() then
               local rating = self:_rate_item(item)
               if epochs[self] ~= epoch or not state.enabled or not owns_scan() then return 'ownership_changed' end
               if self._item_quality_cache[id] then self._reconsider_high_quality_items_queue:push(rating, item)
               else self._reconsider_items_queue:push(rating, item) end
               self._reconsidering_items[id] = item
            end
            committed(epoch, id)
            epoch.requeuable[id] = nil
            units = units + 1
         end
      else
         local selection_valid = valid_selection(self, epoch)
         if epochs[self] ~= epoch or not state.enabled or not owns_scan() then return 'ownership_changed' end
         if not selection_valid then
            state.revalidation_rejected = state.revalidation_rejected + 1
            cancel(self)
            return PENDING -- preserve the candidate for a fresh live epoch
         end
         epoch.done = true -- retire only after the slice's final clock succeeds
         return epoch.primary -- nil is exhausted; unpack later preserves original arity
      end
   end
end

local function sliced_get_next(self)
   if not compatible(self) then cancel(self); return records._get_next_restockable_item.original(self) end
   local started = clock()
   if not started then clock_failure(self); return records._get_next_restockable_item.original(self) end
   local epoch = epochs[self] or new_epoch(self, started)
   if not epoch then return records._get_next_restockable_item.original(self) end
   if epoch.running then return PENDING end
   if self._restockable_high_quality_items_queue ~= epoch.high or self._restockable_items_queue ~= epoch.normal then
      cancel(self); return records._get_next_restockable_item.original(self)
   end
   state.slices = state.slices + 1
   -- Selection helpers are synchronous. Cleanup and rethrow retain native errors;
   -- no pcall encloses the stock nearby callback, leases or generation body.
   epoch.running = true
   local ok, result = pcall(run_slice, self, epoch, started)
   epoch.running = false
   if not ok then cancel(self); error(result, 0) end
   if result == 'ownership_changed' then
      cancel(self)
      return records._get_next_restockable_item.original(self)
   end
   local ended = clock()
   if not ended or ended < started or result == 'clock_failure' then
      clock_failure(self); return records._get_next_restockable_item.original(self)
   end
   state.max_slice_ms = math.max(state.max_slice_ms, (ended - started) * 1000)
   if result == PENDING then return PENDING end
   update_age(epoch, ended)
   epochs[self] = nil
   state.completed = state.completed + 1
   if result then state.selected = state.selected + 1 end
   if result then return unpack(result) end
end

-- Stock ACE generation body, with one pending branch before its nil-item branch.
-- Keep reservation/search/callback order and all existing errand lifecycle intact.
local function sliced_generate(self, synchronous)
   if self._hearth_smoother_retired then return end
   if not next(self._storages_by_filter) then cancel(self); return end
   if self._active_nearby_item_search then return end
   local num_errands, max_errands = 0, self:_get_max_errands()
   for _ in pairs(self._errands) do
      num_errands = num_errands + 1
      if num_errands >= max_errands then return end
   end
   local target_item, best_storage, filter_fn=self:_get_next_restockable_item()
   if self._hearth_smoother_retired then return end
   if target_item == PENDING then
      self:_mark_ready_to_generate_new_errands()
      local epoch = epochs[self]
      if epoch then
         -- A native timer's callback closes over the director; a strong timer
         -- reference would defeat weak director keys on Lua 5.1.
         epoch.continuation = setmetatable({ self._generate_on_next_frame_timer }, { __mode = 'v' })
      end
      return
   end
   if not target_item then
      if next(self._failed_items) then self:_request_process_failed_items() end
      -- A finite epoch can exhaust its allowance while new arrivals remain.
      if not synchronous and (self._restockable_high_quality_items_queue:get_size() > 0 or self._restockable_items_queue:get_size() > 0) then
         self:_mark_ready_to_generate_new_errands()
      end
      return
   end
   local search_src_entity
   if get_world_location(target_item) then search_src_entity = target_item
   else search_src_entity = self._inventory:container_for(target_item) end
   local best_storage_component = best_storage:get('stonehearth:storage')
   local storage_priority = best_storage_component:get_input_bin_priority()
   local best_filter_fn = function(item)
      if self:_is_higher_priority_for_item(item, search_src_entity, storage_priority) then return filter_fn(item)
      else return false end
   end
   local prioritize_high_quality = best_storage_component:get_prioritize_restocking_high_quality()
   local rating_fn = function(item)
      local item_quality = get_item_quality(item)
      if prioritize_high_quality then return item_quality - 1
      elseif item_quality == stonehearth.constants.item_quality.NORMAL then return 1
      else return 0 end
   end
   local errand_id, target_item_id = self._current_errand_id, target_item:get_id()
   self._covered_items[target_item_id] = errand_id
   local storage_space_lease = best_storage:get_component('stonehearth:storage'):reserve_space(nil, 'restock errand')
   if not storage_space_lease then
      if not self._hearth_smoother_retired then
         self._covered_items[target_item_id]=nil
         self._failed_items[target_item_id]=target_item
         self:_request_process_failed_items()
         self:_mark_ready_to_generate_new_errands()
      end
      return
   end
   local retirement=lifetime()
   local pending=retirement and retirement.track_pending_lease(self,storage_space_lease)
   local function release_initial()
      if pending then retirement.release_pending_lease(pending)
      elseif storage_space_lease then local lease=storage_space_lease;storage_space_lease=nil;lease:destroy() end
   end
   if self._hearth_smoother_retired then release_initial();return end
   local completed=false
   local search_ok,search = pcall(NearbyItemSearch,self._player_id, search_src_entity, best_filter_fn,
      self._is_restockable_predicate, self._covered_items, MAX_EXTRA_ITEMS, function(extra_items)
         if completed then return end
         completed=true
         if self._hearth_smoother_retired then release_initial();return end
         local item_location = get_world_location(search_src_entity)
         if item_location and get_world_location(best_storage) then
            release_initial()
            if self._hearth_smoother_retired then return end
            local best_storage_component = best_storage:get_component('stonehearth:storage')
            if best_storage_component then
               for i, extra_item in ipairs(extra_items) do
                  if extra_item and extra_item:is_valid() then
                     if self._covered_items[extra_item:get_id()] then extra_items[i] = nil end
                  else extra_items[i] = nil end
               end
               storage_space_lease = best_storage_component:reserve_space(nil, 'restock errand', 1 + radiant.size(extra_items))
               if self._hearth_smoother_retired then
                  if storage_space_lease then storage_space_lease:destroy() end
                  return
               end
               if storage_space_lease then
                  self._errands[errand_id] = { id = errand_id, filter_fn = filter_fn,
                     filter_key = self._storage_filters[best_storage:get_id()], main_item = target_item,
                     item_location = item_location, extra_items = extra_items, storage = best_storage,
                     storage_space_lease = storage_space_lease }
                  for _, extra_item in ipairs(extra_items) do self._covered_items[extra_item:get_id()] = errand_id end
                  local errand=self._errands[errand_id]
                  local score=self:_rate_errand(errand)
                  if self._hearth_smoother_retired then return end
                  errand.score=score
                  self._current_errand_id = (self._current_errand_id + 1) % 999999
                  radiant.events.trigger_async(self, 'stonehearth:restock:errand_available', errand_id)
               end
            end
         else
            release_initial()
            if self._hearth_smoother_retired then return end
            log:debug('Item/storage %s or destination storage %s not in world, marking %s as failed', search_src_entity, best_storage, target_item)
            self._failed_items[target_item_id] = target_item
         end
         self._active_nearby_item_search = nil
         self:_mark_ready_to_generate_new_errands()
      end, rating_fn)
   if not search_ok then
      completed=true
      -- Constructor/callback errors remain visible; the local reservation must
      -- not survive the failed call. Preserve the original error if release fails.
      pcall(release_initial)
      if not self._hearth_smoother_retired and not self._errands[errand_id] then
         self._covered_items[target_item_id]=nil
         self._failed_items[target_item_id]=target_item
      end
      error(search,0)
   end
   if self._hearth_smoother_retired or completed then
      if search then search:destroy() end
   else self._active_nearby_item_search=search end
end

-- The original failed-transfer method is never replaced. Only callbacks made
-- by the guarded request wrapper use this private, resumable transfer.
local function stock_retry_body(self)
   local next_delay = next(self._errands) and RETRY_LONG or RETRY_SHORT
   if self:_transfer_reconsider_items_into_restockable_queue(self._reconsider_high_quality_items_queue, self._restockable_high_quality_items_queue) or
      self:_transfer_reconsider_items_into_restockable_queue(self._reconsider_items_queue, self._restockable_items_queue) then
      self:_mark_ready_to_generate_new_errands()
   elseif self:_transfer_failed_items_into_reconsider_queues() then next_delay = RETRY_SHORT
   else return end
   self:_request_process_failed_items(next_delay)
end
local function retry_age(epoch, now)
   if now and epoch.started and now >= epoch.started then
      state.retry_max_phase_age_seconds = math.max(state.retry_max_phase_age_seconds, now - epoch.started)
   end
end
cancel_retry = function(self, destroy_timer)
   local epoch = retry_epochs[self]
   if epoch then
      retry_epochs[self] = nil
      epoch.handoff = not destroy_timer
      state.retry_cancelled = state.retry_cancelled + 1
      retry_age(epoch, clock())
      -- An already scheduled continuation is the one stock handoff. Pending
      -- failed entries were never removed, so nothing needs to be restored.
   end
   if destroy_timer then
      local timer = self._hearth_smoother_retry_slice_timer
      if timer then timer:destroy(); self._hearth_smoother_retry_slice_timer = nil end
      retry_continuations[self] = nil
   end
end
local function retry_shape(self, epoch)
   return compatible(self) and owns_scan() and state.enabled and not state.clock_disabled
      and (not epoch or (epoch.failed == self._failed_items
         and epoch.high == self._reconsider_high_quality_items_queue
         and epoch.normal == self._reconsider_items_queue))
end
local function start_retry(self, started)
   if not next(self._failed_items) then return nil end
   local ids, items = {}, {}
   -- Pure Lua O(N) snapshot: not a hard-budget operation and not a native scan.
   -- Keep the live failed map intact until each matching snapshot entry commits.
   for id, item in pairs(self._failed_items) do
      ids[#ids + 1], items[#items + 1] = id, item
   end
   local ended = clock()
   if not ended or ended < started then
      state.retry_clock_failures = state.retry_clock_failures + 1
      clock_failure(self)
      return 'stock'
   end
   state.retry_snapshot_count = state.retry_snapshot_count + 1
   state.retry_snapshot_items = state.retry_snapshot_items + #ids
   state.retry_max_snapshot_ms = math.max(state.retry_max_snapshot_ms, (ended - started) * 1000)
   local epoch = { ids = ids, items = items, position = 1, failed = self._failed_items,
      high = self._reconsider_high_quality_items_queue, normal = self._reconsider_items_queue,
      started = started, generation = state.generation }
   retry_epochs[self] = epoch
   return epoch
end
local function retry_slice(self, epoch, started)
   local count = 0
   while epoch.position <= #epoch.ids do
      if retry_epochs[self] ~= epoch then return epoch.handoff == false and 'terminal' or 'stock' end
      if not retry_shape(self, epoch) then return 'stock' end
      if count > 0 then
         local now = clock()
         if not now or now < started then return 'clock_failure' end
         if count >= state.max_candidates or (state.budget_ms > 0 and (now - started) * 1000 >= state.budget_ms) then return PENDING end
      end
      local index = epoch.position
      local id, item = epoch.ids[index], epoch.items[index]
      count = count + 1
      state.retry_evaluated = state.retry_evaluated + 1
      if epoch.failed[id] == item then
         if item:is_valid() then
            local rating = self:_rate_item(item)
            if retry_epochs[self] ~= epoch then return epoch.handoff == false and 'terminal' or 'stock' end
            if not retry_shape(self, epoch) then return 'stock' end
            -- Rating/native callbacks can replace the live entry. Never erase
            -- its replacement or enqueue a stale item after such a callback.
            if epoch.failed[id] == item then
               if item:is_valid() then
                  if self._item_quality_cache[id] then epoch.high:push(rating, item)
                  else epoch.normal:push(rating, item) end
                  self._reconsidering_items[id] = item
                  epoch.failed[id] = nil
                  state.retry_transferred = state.retry_transferred + 1
               else
                  epoch.failed[id] = nil
                  state.retry_invalid = state.retry_invalid + 1
               end
            else state.retry_replaced = state.retry_replaced + 1 end
         else
            epoch.failed[id] = nil -- known private snapshot ID; no get_id/rating
            state.retry_invalid = state.retry_invalid + 1
         end
      else state.retry_replaced = state.retry_replaced + 1 end
      epoch.position = index + 1
   end
   return true
end
local function advance_retry(self)
   local started = clock()
   if not started then
      state.retry_clock_failures = state.retry_clock_failures + 1
      clock_failure(self)
      return 'stock'
   end
   local epoch = retry_epochs[self] or start_retry(self, started)
   if not epoch or epoch == 'stock' then return epoch end
   if epoch.running then return PENDING end
   state.retry_slices = state.retry_slices + 1
   epoch.running = true
   local ok, result = pcall(retry_slice, self, epoch, started)
   epoch.running = false
   if not ok then cancel_retry(self, true); error(result, 0) end
   if result == 'terminal' then return 'terminal' end
   local ended = clock()
   if not ended or ended < started or result == 'clock_failure' then
      state.retry_clock_failures = state.retry_clock_failures + 1
      clock_failure(self)
      return 'stock'
   end
   state.retry_max_slice_ms = math.max(state.retry_max_slice_ms, (ended - started) * 1000)
   if result == 'stock' then cancel_retry(self, false); return 'stock' end
   if result == PENDING then return PENDING end
   retry_age(epoch, ended)
   retry_epochs[self] = nil
   state.retry_completed = state.retry_completed + 1
   return true
end
local function finish_retry(self, result)
   if result == 'terminal' then return
   elseif result == 'stock' then
      state.retry_handoffs = state.retry_handoffs + 1
      stock_retry_body(self)
   elseif result then self:_request_process_failed_items(RETRY_SHORT) end
end
local function schedule_retry(self, epoch)
   if self._hearth_smoother_retry_slice_timer then return end
   local identity = setmetatable({}, { __mode = 'v' })
   local timer = radiant.on_game_loop_once('hearth_smoother failed restock continuation', function()
      local current = identity[1]
      if current == nil or self._hearth_smoother_retry_slice_timer ~= current then return end
      self._hearth_smoother_retry_slice_timer = nil
      retry_continuations[self] = nil
      if retry_epochs[self] ~= epoch or epoch.generation ~= state.generation or not retry_shape(self, epoch) then
         if epoch.handoff == false then return end
         cancel_retry(self, false)
         state.retry_handoffs = state.retry_handoffs + 1
         stock_retry_body(self)
         return
      end
      local result = advance_retry(self)
      if result == PENDING then schedule_retry(self, epoch)
      else finish_retry(self, result) end
   end)
   identity[1] = timer -- callback identity is weak; director owns the live timer
   self._hearth_smoother_retry_slice_timer = timer
   retry_continuations[self] = true
end
local function sliced_request(self, delay)
   if self._failed_item_requeue_timer or retry_epochs[self] or self._hearth_smoother_retry_slice_timer then return end
   delay = delay or (next(self._errands) and RETRY_LONG) or RETRY_SHORT
   local generation = state.generation
   local identity = setmetatable({}, { __mode = 'v' })
   local timer = stonehearth.calendar:set_timer('requeue failed restock items', delay, function()
      local current = identity[1]
      if current == nil or self._failed_item_requeue_timer ~= current then return end
      self._failed_item_requeue_timer = nil
      if not self._started or generation ~= state.generation or not retry_shape(self) then stock_retry_body(self); return end
      local next_delay = next(self._errands) and RETRY_LONG or RETRY_SHORT
      if self:_transfer_reconsider_items_into_restockable_queue(self._reconsider_high_quality_items_queue, self._restockable_high_quality_items_queue) or
         self:_transfer_reconsider_items_into_restockable_queue(self._reconsider_items_queue, self._restockable_items_queue) then
         self:_mark_ready_to_generate_new_errands()
         self:_request_process_failed_items(next_delay)
         return
      end
      local result = advance_retry(self)
      if result == PENDING then schedule_retry(self, retry_epochs[self])
      else finish_retry(self, result) end
   end)
   identity[1] = timer
   self._failed_item_requeue_timer = timer
end

local function finish_original_generate(self, ok, ...)
   local depth = fallback_generating[self] - 1
   fallback_generating[self] = depth > 0 and depth or nil
   if not ok then error((...), 0) end
   return ...
end
local function original_generate(original, self, ...)
   if self._hearth_smoother_retired then return end
   -- Retirement needs ownership of the initial local reservation in fallback mode too.
   -- Captured stock generation dynamically calls the current class getter.
   -- Suppress pending results only for that synchronous original invocation,
   -- including stale references invoked after reapply. No result-pack table or
   -- additional callback closure; pcall is solely for clearing this guard when
   -- original generation raises. The original error is immediately rethrown.
   fallback_generating[self] = (fallback_generating[self] or 0) + 1
   if lifetime() then return finish_original_generate(self,pcall(sliced_generate,self,true)) end
   return finish_original_generate(self, pcall(original, self, ...))
end
local function make_wrapper(record)
   local original = record.original
   return function(self, ...)
      if self._hearth_smoother_retired and record.method~='_ensure_stopped' then return end
      if record.method=='destroy' and lifetime() then
         -- Invalidate private work before per-instance tombstones change compatibility.
         if epochs[self] then epochs[self]=nil;state.cancelled=state.cancelled+1 end
         if retry_epochs[self] then retry_epochs[self]=nil;state.retry_cancelled=state.retry_cancelled+1 end
         retry_continuations[self]=nil
         return lifetime().with_destroy(self,original,...)
      end
      -- All captured generation callbacks (including stock fallback references)
      -- retain a real timer but cannot consume an incomplete bootstrap queue.
      if record.method == '_generate_next_errand' then
         local bootstrap = hearth_smoother_restock_bootstrap
         if bootstrap and type(bootstrap.guard_generation) == 'function' and bootstrap.guard_generation(self) then return end
      end
      -- Old-generation references cannot cancel or charge a newer scan.
      if not state.applied or record.generation ~= state.generation then
         if record.method == '_ensure_stopped' or record.method == 'destroy' then
            local retry_pending = retry_epochs[self] ~= nil or self._hearth_smoother_retry_slice_timer ~= nil
            cancel_retry(self, true)
            if retry_pending and record.method == '_ensure_stopped' and records and records._request_process_failed_items then
               records._request_process_failed_items.original(self, RETRY_SHORT)
            end
         end
         if record.method == '_generate_next_errand' then return original_generate(original, self, ...) end
         return original(self, ...)
      end
      if record.method == '_ensure_stopped' or record.method == 'destroy' then
         local retry_pending = retry_epochs[self] ~= nil or self._hearth_smoother_retry_slice_timer ~= nil
         cancel(self, true); cancel_retry(self, true)
         -- Stock stop keeps its calendar watchdog. Replace a partial private
         -- transfer with the original failed-refill 5m retry before stopping.
         -- Destroy does not rebuild; its stock body clears any existing timer.
         if retry_pending and record.method == '_ensure_stopped' then records._request_process_failed_items.original(self, RETRY_SHORT) end
         return original(self, ...)
      end
      -- The existing continuation also serves a disabled/foreign stock handoff.
      -- Do not create a second calendar timer before it gets that one chance.
      if record.method == '_request_process_failed_items' and self._hearth_smoother_retry_slice_timer then return end
      if record.method == '_request_process_failed_items' and not self._started then return original(self, ...) end
      if record.method == '_get_next_restockable_item' and fallback_generating[self] then return original(self, ...) end
      if not owns_record(record) or not owns_scan() or not state.enabled or state.clock_disabled then
         cancel(self)
         cancel_retry(self, false)
         if record.method == '_generate_next_errand' then return original_generate(original, self, ...) end
         return original(self, ...)
      end
      if not compatible(self) then
         cancel(self)
         cancel_retry(self, false)
         if record.method == '_generate_next_errand' then return original_generate(original, self, ...) end
         return original(self, ...)
      end
      if record.method == '_get_next_restockable_item' then return sliced_get_next(self) end
      if record.method == '_request_process_failed_items' then return sliced_request(self, ...) end
      return sliced_generate(self)
   end
end
local function inspect(candidate, range)
   if type(candidate) ~= 'function' or not debug or type(debug.getinfo) ~= 'function' then return false end
   local ok, info = pcall(debug.getinfo, candidate, 'S')
   return ok and type(info) == 'table' and info.what == 'Lua' and info.source == SOURCE
      and info.linedefined == range[1] and info.lastlinedefined == range[2]
end
function M.apply()
   if state.applied then return owns_scan(), M.status() end
   local require_module = radiant and radiant.mods and radiant.mods.require
   if type(require_module) ~= 'function' then state.skipped_reason = 'require API unavailable'; return false, state.skipped_reason end
   local ok, class = pcall(require_module, PATH)
   if not ok or type(class) ~= 'table' then state.skipped_reason = 'director class unavailable'; return false, state.skipped_reason end
   for method, range in pairs(bounds) do
      if not inspect(class[method], range) then state.skipped_reason = 'unsupported source/line shape: ' .. method; return false, state.skipped_reason end
   end
   for _, method in ipairs({ '_get_max_errands', '_is_higher_priority_for_item', '_rate_errand' }) do
      local candidate = class[method]
      if type(candidate) ~= 'function' then state.skipped_reason = 'missing helper: ' .. method; return false, state.skipped_reason end
      local inspected, info = pcall(debug.getinfo, candidate, 'S')
      if not inspected or info.source ~= SOURCE then state.skipped_reason = 'foreign helper: ' .. method; return false, state.skipped_reason end
   end
   local nearby_ok, nearby = pcall(require_module, 'stonehearth.services.server.inventory.nearby_item_search')
   local constants_ok, constants = pcall(require_module, 'stonehearth.constants')
   local mt = type(nearby) == 'table' and getmetatable(nearby)
   if not nearby_ok or not (type(nearby) == 'function' or (mt and type(mt.__call) == 'function')) or
      not constants_ok or type(constants) ~= 'table' or not constants.inventory or not constants.inventory.restock_director or
      type(constants.inventory.restock_director.MAX_EXTRA_ITEMS) ~= 'number' or not radiant.entities or
      type(radiant.entities.get_world_location) ~= 'function' or type(radiant.entities.get_item_quality) ~= 'function' or
      not stonehearth or not stonehearth.ai or type(stonehearth.ai.fast_call_filter_fn) ~= 'function' or
      not stonehearth.constants or not stonehearth.constants.item_quality or
      not radiant.log or type(radiant.log.create_logger) ~= 'function' or
      constants.inventory.restock_director.FAILED_ITEM_REQUEUE_SHORT_DELAY ~= '5m' or
      constants.inventory.restock_director.FAILED_ITEM_REQUEUE_DELAY ~= '10m' or
      constants.inventory.restock_director.FAILED_ITEM_REQUEUE_BATCH_SIZE ~= 30 or
      not stonehearth.calendar or type(stonehearth.calendar.set_timer) ~= 'function' or
      type(radiant.on_game_loop_once) ~= 'function' then
      state.skipped_reason = 'stock generation dependencies unavailable'; return false, state.skipped_reason
   end
   local logger_ok, logger = pcall(radiant.log.create_logger, 'restock_director')
   if not logger_ok or not logger or type(logger.debug) ~= 'function' then state.skipped_reason = 'stock logger unavailable'; return false, state.skipped_reason end
   owner, NearbyItemSearch, MAX_EXTRA_ITEMS, log = class, nearby, constants.inventory.restock_director.MAX_EXTRA_ITEMS, logger
   RETRY_SHORT, RETRY_LONG = constants.inventory.restock_director.FAILED_ITEM_REQUEUE_SHORT_DELAY, constants.inventory.restock_director.FAILED_ITEM_REQUEUE_DELAY
   get_world_location, get_item_quality = radiant.entities.get_world_location, radiant.entities.get_item_quality
   state.generation = state.generation + 1
   helpers, records = {}, {}
   for method in pairs(bounds) do
      if method ~= '_get_next_restockable_item' and method ~= '_generate_next_errand' and method ~= '_ensure_stopped' and method ~= 'destroy'
         and method ~= '_request_process_failed_items' and method ~= '_transfer_failed_items_into_reconsider_queues' then helpers[method] = class[method] end
   end
   for _, method in ipairs({ '_get_max_errands', '_is_higher_priority_for_item', '_rate_errand' }) do helpers[method] = class[method] end
   -- Passive ownership record: do not replace the original synchronous transfer.
   -- Its existing outer profiler can register without a new native/AI hook.
   for _, method in ipairs({ '_transfer_failed_items_into_reconsider_queues', '_transfer_reconsider_items_into_restockable_queue' }) do
      helpers[method] = nil
      local transfer = class[method]
      records[method] = { method = method, original = transfer, wrapper = transfer, generation = state.generation, passive = true }
   end
   for _, method in ipairs({ '_get_next_restockable_item', '_generate_next_errand', '_ensure_stopped', 'destroy', '_request_process_failed_items' }) do
      local record = { method = method, original = class[method], generation = state.generation }
      record.wrapper = make_wrapper(record)
      records[method] = record
      class[method] = record.wrapper
   end
   state.applied, state.skipped_reason = true, nil
   if lifetime() then lifetime().register_slice(M) end
   return true, M.status()
end
function M.retirement_ready()
   return state.applied and records and owns_record(records.destroy) and owns_record(records._generate_next_errand) or false
end
function M.register_profiler(method, outer_wrapper, captured_inner)
   local record = records and records[method]
   if not state.applied or not record or record.generation ~= state.generation or
      captured_inner ~= record.wrapper or type(outer_wrapper) ~= 'function' or owner[method] ~= outer_wrapper then
      return false, 'profiler ownership registration mismatch'
   end
   record.profiler = outer_wrapper
   record.registered_owners=record.registered_owners or setmetatable({}, {__mode='k'})
   record.registered_owners[outer_wrapper]=true
   return true
end
-- Pure ownership check for the optional initialization generation barrier.
function M.bootstrap_ready() return state.applied and owns_scan() or false end
function M.has_pending(self)
   if (epochs[self] or retry_epochs[self]) and (not state.enabled or state.clock_disabled or not owns_scan()) then
      cancel(self); cancel_retry(self, false)
   end
   return epochs[self] ~= nil or retry_epochs[self] ~= nil or self._hearth_smoother_retry_slice_timer ~= nil
end
function M.set_enabled(enabled)
   if type(enabled) ~= 'boolean' then return false, 'restock slicing enabled must be boolean' end
   if enabled and not state.applied then local ok, err = M.apply(); if not ok then return false, err end end
   if not enabled then cancel_all() end
   state.enabled, state.clock_disabled = enabled, false
   if enabled then state.safety_wrappers_retained=false end
   return true, M.status()
end
function M.configure(options)
   if type(options) ~= 'table' then return false, 'options required' end
   local max, budget = options.max_candidates or state.max_candidates, options.budget_ms
   if budget == nil then budget = state.budget_ms end
   if type(max) ~= 'number' or max ~= max or max < 1 or max > 1000000000 or max ~= math.floor(max) or
      type(budget) ~= 'number' or budget ~= budget or budget < 0 or budget > 1000000000 then return false, 'invalid scan budget' end
   state.max_candidates, state.budget_ms = max, budget
   return true, M.status()
end
function M.status()
   local pending, consumed, now = 0, 0, clock()
   for _, epoch in pairs(epochs) do pending = pending + 1; consumed = consumed + #epoch.items; update_age(epoch, now) end
   local retry_pending, retry_items = 0, 0
   for _, epoch in pairs(retry_epochs) do
      retry_pending = retry_pending + 1
      retry_items = retry_items + #epoch.ids - epoch.position + 1
      retry_age(epoch, now)
   end
   return { applied = state.applied, enabled = state.enabled, active = state.applied and owns_scan() or false,
      safety_wrappers_retained=state.safety_wrappers_retained or false,
      restore_mode=state.safety_wrappers_retained and 'optimization disabled; retirement safety wrappers retained' or 'normal',
      source = SOURCE, skipped_reason = state.skipped_reason, max_candidates = state.max_candidates,
      budget_ms = state.budget_ms, pending_directors = pending, inflight_entries = consumed,
      slices = state.slices, max_slice_ms = state.max_slice_ms, evaluated = state.evaluated,
      selected = state.selected, completed = state.completed, cancelled = state.cancelled,
      restored_entries = state.restored_entries, clock_failures = state.clock_failures,
      clock_disabled = state.clock_disabled, revalidation_rejected = state.revalidation_rejected,
      max_phase_age_seconds = state.max_phase_age_seconds,
      retry_pending_directors = retry_pending, retry_pending_items = retry_items,
      retry_slices = state.retry_slices, retry_max_slice_ms = state.retry_max_slice_ms,
      retry_evaluated = state.retry_evaluated, retry_transferred = state.retry_transferred,
      retry_invalid = state.retry_invalid, retry_replaced = state.retry_replaced,
      retry_completed = state.retry_completed, retry_cancelled = state.retry_cancelled,
      retry_handoffs = state.retry_handoffs, retry_clock_failures = state.retry_clock_failures,
      retry_snapshot_count = state.retry_snapshot_count, retry_snapshot_items = state.retry_snapshot_items,
      retry_max_snapshot_ms = state.retry_max_snapshot_ms, retry_max_phase_age_seconds = state.retry_max_phase_age_seconds,
      retry_semantics = 'Only new guarded request callbacks slice failed-map transfer. The initial pure-Lua snapshot is O(N); it is not a hard time budget. Entries commit only when their live identity still matches. Old callbacks keep synchronous stock transfer; watchdog delays remain 5m/10m and valid reconsider batches remain 30.',
      semantics = 'Finite initial-size epochs on live queues; new high-priority arrivals may displace older entries until the next epoch. No task fairness. Soft wall budget cannot preempt one native candidate evaluation.' }
end
function M.restore()
   if lifetime() then
      -- Ownership remains installed to retire future objects and own pending leases.
      cancel_all();state.enabled=false;state.clock_disabled=false
      state.safety_wrappers_retained=true
      return M.status()
   end
   -- Flush finite initialization work before removing the generation barrier.
   local bootstrap = hearth_smoother_restock_bootstrap
   if bootstrap and type(bootstrap.before_slice_restore) == 'function' then bootstrap.before_slice_restore() end
   for self in pairs(epochs) do cancel(self) end
   local watchdogs = {}
   for self in pairs(retry_epochs) do watchdogs[self] = true end
   for self in pairs(retry_continuations) do watchdogs[self] = true end
   for self in pairs(watchdogs) do cancel_retry(self, true) end
   local original_request = records and records._request_process_failed_items.original
   if records then for _, record in pairs(records) do
      if owner[record.method] == record.wrapper or (record.profiler ~= nil and owner[record.method] == record.profiler) then owner[record.method] = record.original end
   end end
   state.applied, state.enabled = false, false
   state.generation = state.generation + 1
   -- Restored stock lifecycle methods do not know the private frame timer.
   -- Rebuild a deduplicated normal calendar watchdog instead of leaving that
   -- timer alive after the wrappers which could destroy it have been removed.
   if original_request then for self in pairs(watchdogs) do original_request(self) end end
   return M.status()
end
return M

