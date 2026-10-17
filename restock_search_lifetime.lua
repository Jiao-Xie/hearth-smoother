-- Keep ACE's per-search best predicate out of immortal AI/storage registries.
-- Native candidate discovery uses a shared forwarding inclusion predicate;
-- the exact source/destination predicate stays owned by the finite search.
local M = {}
local PATH = 'stonehearth.services.server.inventory.nearby_item_search'
local SOURCE = '@stonehearth_ace/services/server/inventory/nearby_item_search.lua'
local bounds = { __init = {7,33}, _search = {75,92},
   _exhausted_ground_item_finder = {39,73}, _add_result = {94,112},
   _done_searching = {114,132}, _cleanup = {134,147} }
local owner, original, wrappers
local searches = setmetatable({}, {__mode = 'k'}) -- scalar values; no owner backreferences
local state = {applied=false, enabled=true, restore_pending=false, ground_searches=0, ground_rejected=0,
   storage_visits=0, storage_items_tested=0, storage_rejected=0, cleaned=0}

local function owns()
   if not state.applied or not owner then return false end
   for name, fn in pairs(wrappers) do if owner[name] ~= fn then return false end end
   return owner._add_result == original._add_result
end
local function compatible(self)
   return owns() and self._search == wrappers._search
      and self._exhausted_ground_item_finder == wrappers._exhausted_ground_item_finder
      and self._cleanup == wrappers._cleanup and self._add_result == original._add_result
      and self._done_searching == wrappers._done_searching
      and type(self._filter_fn) == 'function' and type(self._inclusion_filter_fn) == 'function'
end
local function live_count()
   local n = 0
   for _, active in pairs(searches) do if active then n = n + 1 end end
   return n
end
local function finish_restore()
   if owner and wrappers then
      for name, fn in pairs(wrappers) do if owner[name] == fn then owner[name] = original[name] end end
   end
   state.applied, state.restore_pending = false, false
end

function M.apply()
   if state.applied then
      if owns() then return true, M.status() end
      return false, 'nearby search ownership changed'
   end
   local require_module = radiant and radiant.mods and radiant.mods.require
   if type(require_module) ~= 'function' or not debug or type(debug.getinfo) ~= 'function' then
      state.skipped_reason = 'module/source inspection unavailable'; return false, state.skipped_reason
   end
   local ok, cls = pcall(require_module, PATH)
   if not ok or type(cls) ~= 'table' then
      state.skipped_reason = 'ACE nearby search class unavailable'; return false, state.skipped_reason
   end
   local methods = {}
   for name, expected in pairs(bounds) do
      local fn = cls[name]
      local inspected, info = pcall(debug.getinfo, fn, 'S')
      if type(fn) ~= 'function' or not inspected or not info or info.source ~= SOURCE
         or info.linedefined ~= expected[1] or info.lastlinedefined ~= expected[2] then
         state.skipped_reason = 'unsupported nearby search method: ' .. name
         return false, state.skipped_reason
      end
      methods[name] = fn
   end
   if type(radiant.shallow_copy) ~= 'function' or not stonehearth or not stonehearth.ai
      or type(stonehearth.ai.filter_from_key) ~= 'function'
      or type(stonehearth.ai.fast_call_filter_fn) ~= 'function' then
      state.skipped_reason = 'nearby search dependencies unavailable'; return false, state.skipped_reason
   end
   owner, original, wrappers = cls, methods, {}
   wrappers.__init = function(self, ...)
      methods.__init(self, ...)
      -- A missing source location can finish synchronously inside __init,
      -- before ACE assigns its timeout or finder fields.
      if searches[self] == false then methods._cleanup(self) end
   end
   wrappers._search = function(self, src_entity, filter_fn, found_cb, exhausted_cb)
      if state.enabled and compatible(self) and filter_fn == self._filter_fn then
         searches[self] = true
         state.ground_searches = state.ground_searches + 1
         local transient = filter_fn
         local direct_found = function(item)
            if not searches[self] then return true end
            if not item or not item:is_valid() then return false end
            -- Explicit false is required by ItemSearch to continue finding items.
            local passes = transient(item)
            if not searches[self] then return true end
            if not passes or not item:is_valid() then
               state.ground_rejected = state.ground_rejected + 1
               return false
            end
            local stop = found_cb(item)
            return stop or not searches[self]
         end
         -- A director already registered inclusion under tostring(director).
         -- AI deduplicates spatial registrations by function, not supplied key;
         -- directly reusing it with Nearby's tostring(fn) key would miss that
         -- native cache. Register one shared forwarding predicate per inclusion
         -- so Nearby always uses a consistent key, bounded by director count.
         local inclusion = self._inclusion_filter_fn
         local candidates = stonehearth.ai:filter_from_key('hearth_smoother_nearby_restock',
            tostring(inclusion), function(item) return inclusion(item) end)
         -- _add_result itself requires inclusion; accepted original results are
         -- therefore a subset of these native candidates.
         return methods._search(self, src_entity, candidates, direct_found, exhausted_cb)
      end
      return methods._search(self, src_entity, filter_fn, found_cb, exhausted_cb)
   end
   wrappers._exhausted_ground_item_finder = function(self)
      -- Keep existing finite searches safe even if future searches are disabled.
      if searches[self] == false then return end
      if searches[self] == nil or not compatible(self) then
         return methods._exhausted_ground_item_finder(self)
      end
      if self._ground_item_finder then
         self._ground_item_finder:destroy()
         self._ground_item_finder = nil
      end
      local is_valid_storage_predicate = stonehearth.ai:filter_from_key('is_nonempty_public_storage', '', function(entity)
         local storage = entity:get_component('stonehearth:storage')
         return storage and storage:is_public() and not storage:is_empty()
      end)
      local process_storage = function(entity)
         if not searches[self] then return true end
         if not entity or not entity:is_valid() then return false end
         local storage = entity:get_component('stonehearth:storage')
         -- Actual ACE storage owns this current item map. A fresh local snapshot
         -- matches a newly-created ACE filter cache without registering its key.
         if not storage or not storage._sv or type(storage._sv.items) ~= 'table' then return false end
         local items = radiant.shallow_copy(storage._sv.items)
         state.storage_visits = state.storage_visits + 1
         for id, item in pairs(items) do
            if not searches[self] then return true end
            if not entity:is_valid() or entity:get_component('stonehearth:storage') ~= storage then return false end
            -- Callbacks may remove/move an item. Only current membership is usable.
            if item and item:is_valid() and storage._sv.items[id] == item then
               state.storage_items_tested = state.storage_items_tested + 1
               local passes = self._filter_fn(item)
               if not searches[self] then return true end
               if not entity:is_valid() or entity:get_component('stonehearth:storage') ~= storage then return false end
               if passes and item:is_valid() and storage._sv.items[id] == item then
                  if self:_add_result(item) or not searches[self] then return true end
               else state.storage_rejected = state.storage_rejected + 1 end
            end
         end
         return false
      end
      if #self._results >= self._max_results then return end
      if stonehearth.ai:fast_call_filter_fn(is_valid_storage_predicate, self._entity) then
         if process_storage(self._entity) then return end
      end
      if not searches[self] then return end
      -- Original source-storage-first, radius16, distance sort and exhaustion.
      local finder = self:_search(self._entity, is_valid_storage_predicate,
         process_storage, function() self:_done_searching() end)
      if searches[self] then self._storage_item_finder = finder
      elseif finder then finder:destroy() end
   end
   wrappers._done_searching = function(self)
      -- Cleanup runs before the user callback. A reentrant completion must not
      -- invoke ACE's callback a second time while its field is still non-nil.
      if searches[self] == false then return end
      if searches[self] and self._done_cb then
         local done = self._done_cb
         self._done_cb = function(results)
            -- Clear before calling out, including when deferred restore has
            -- restored the original method during cleanup.
            self._done_cb = nil
            return done(results)
         end
      end
      return methods._done_searching(self)
   end
   wrappers._cleanup = function(self)
      if searches[self] then searches[self] = false; state.cleaned = state.cleaned + 1 end
      methods._cleanup(self)
      if state.restore_pending and live_count() == 0 then finish_restore() end
   end
   for name, fn in pairs(wrappers) do cls[name] = fn end
   state.applied, state.skipped_reason = true, nil
   return true, M.status()
end
function M.status()
   return {applied=state.applied, enabled=state.enabled, active=owns(),
      expected_source=SOURCE, skipped_reason=state.skipped_reason, live_searches=live_count(),
      restore_pending=state.restore_pending,
      ground_searches=state.ground_searches, ground_rejected=state.ground_rejected,
      storage_visits=state.storage_visits, storage_items_tested=state.storage_items_tested,
      storage_rejected=state.storage_rejected, cleaned=state.cleaned}
end
function M.set_enabled(enabled)
   if type(enabled) ~= 'boolean' then return false, 'enabled must be boolean' end
   if enabled and not state.applied then local ok, err = M.apply(); if not ok then return false, err end end
   state.enabled = enabled
   if enabled then state.restore_pending = false end
   return true, M.status()
end
function M.restore()
   state.enabled = false
   -- Existing finite searches finish with their guarded storage path. Future
   -- searches immediately use stock behavior. Never cancel somebody's errand.
   state.restore_pending = live_count() > 0
   if not state.restore_pending then finish_restore() end
   return M.status()
end
return M

