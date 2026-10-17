-- Opt-in cleanup of dead reconsider-map entries, only when both main queues are empty.
-- Keep all queues, valid entities, failed items, errands, search and watchdog policy intact.
local M = {}
local DIRECTOR_PATH = 'stonehearth.services.server.inventory.restock_director'
local EXPECTED_SOURCE = '@stonehearth_ace/services/server/inventory/restock_director.lua'
local state = { applied = false, enabled = false, calls = 0, removed_invalid = 0, prevented_false_busy = 0 }
local owner, original, wrapper
local generation = 0

local function plain_map(value)
   return type(value) == 'table' and getmetatable(value) == nil
end

local function read_validity_method(entity)
   return entity.is_valid
end

local function entity_shape(entity)
   local kind = type(entity)
   if kind == 'table' then
      return getmetatable(entity) == nil and type(rawget(entity, 'is_valid')) == 'function'
   elseif kind == 'userdata' then
      -- Inspect only method availability defensively; calling native is_valid is unprotected.
      local ok, method = pcall(read_validity_method, entity)
      return ok and type(method) == 'function'
   end
   return false
end

local function queue_shape(queue)
   local kind = type(queue)
   return (kind == 'userdata' or kind == 'table') and type(queue.get_size) == 'function'
end

local function cleanup(self)
   local reconsidering, failed = self._reconsidering_items, self._failed_items
   local high, normal = self._restockable_high_quality_items_queue, self._restockable_items_queue
   if not plain_map(reconsidering) or not plain_map(failed) or not queue_shape(high) then return 0 end
   local high_size = high:get_size()
   if type(high_size) ~= 'number' or high_size ~= 0 then return 0 end
   if not queue_shape(normal) then return 0 end
   local normal_size = normal:get_size()
   if type(normal_size) ~= 'number' or normal_size ~= 0 then return 0 end
   -- Validate every record before mutation: unknown records leave the whole map untouched.
   for _, entity in pairs(reconsidering) do if not entity_shape(entity) then return 0 end end
   local removed = 0
   for key, entity in pairs(reconsidering) do
      if not entity:is_valid() then
         reconsidering[key] = nil -- A dead entity must never be asked for its ID.
         removed = removed + 1
         state.removed_invalid = state.removed_invalid + 1
      end
   end
   return removed
end

function M.status()
   return { applied = state.applied, enabled = state.enabled,
      active = state.applied and owner ~= nil and owner.has_items_in_queue == wrapper,
      calls = state.calls, removed_invalid = state.removed_invalid,
      prevented_false_busy = state.prevented_false_busy,
      expected_source = EXPECTED_SOURCE, skipped_reason = state.skipped_reason }
end

function M.apply()
   if state.applied then
      if owner.has_items_in_queue == wrapper then return true end
      return false, 'restock queue query changed by another mod'
   end
   local require_director = radiant and radiant.mods and radiant.mods.require
   local getinfo = debug and debug.getinfo
   if type(require_director) ~= 'function' or type(getinfo) ~= 'function' then
      state.skipped_reason = 'radiant.mods.require or debug.getinfo unavailable'
      return false, state.skipped_reason
   end
   local loaded, class = pcall(require_director, DIRECTOR_PATH)
   local candidate = loaded and class and class.has_items_in_queue
   if type(candidate) ~= 'function' then
      state.skipped_reason = 'ACE restock queue query unavailable'
      return false, state.skipped_reason
   end
   local inspected, info = pcall(getinfo, candidate, 'S')
   if not inspected or type(info) ~= 'table' or info.source ~= EXPECTED_SOURCE then
      state.skipped_reason = 'restock query ownership source is not ' .. EXPECTED_SOURCE
      return false, state.skipped_reason
   end
   generation = generation + 1
   local token, captured_original = generation, candidate
   local installed
   installed = function(self, ...)
      if not state.applied or generation ~= token or owner ~= class or class.has_items_in_queue ~= installed then
         return captured_original(self, ...)
      end
      state.calls = state.calls + 1
      -- A sliced scan can have consumed its last queue entry while finalizing.
      -- Treat that transient work as busy and leave its maps untouched.
      if hearth_smoother_restock_slice and hearth_smoother_restock_slice.has_pending(self) then
         return true
      end
      local removed = state.enabled and cleanup(self) or 0
      -- Original boolean and native errors are never substituted or swallowed.
      local result = captured_original(self, ...)
      if removed > 0 and result == false then state.prevented_false_busy = state.prevented_false_busy + 1 end
      return result
   end
   owner, original, wrapper = class, candidate, installed
   class.has_items_in_queue = installed
   state.applied, state.skipped_reason = true, nil
   return true
end

function M.set_enabled(enabled)
   if type(enabled) ~= 'boolean' then return false, 'restock cleanup enabled must be boolean' end
   if enabled then
      local ok, err = M.apply()
      if not ok then return false, err end
   end
   state.enabled = enabled
   return true, M.status()
end

function M.restore()
   if owner and owner.has_items_in_queue == wrapper then owner.has_items_in_queue = original end
   state.applied, state.enabled = false, false
   return M.status()
end

local function map_count(map)
   if not plain_map(map) then return nil end
   local count = 0
   for _ in pairs(map) do count = count + 1 end
   return count
end

local function item_counts(map)
   if not plain_map(map) then return { available = false } end
   local result = { available = true, total = 0, valid = 0, invalid = 0, unknown = 0 }
   for _, entity in pairs(map) do
      result.total = result.total + 1
      if not entity_shape(entity) then
         result.unknown = result.unknown + 1
      elseif entity:is_valid() then
         result.valid = result.valid + 1
      else
         result.invalid = result.invalid + 1
      end
   end
   return result
end

local function queue_count(queue)
   if not queue_shape(queue) then return nil end
   local size = queue:get_size()
   if type(size) == 'number' and size >= 0 then return size end
end

function M.snapshot(inventory)
   if not inventory or type(inventory.get_restock_director) ~= 'function' then
      return { available = false, reason = 'current player inventory unavailable', directors = {} }
   end
   local now
   if stonehearth and stonehearth.calendar and type(stonehearth.calendar.get_elapsed_time) == 'function' then
      now = stonehearth.calendar:get_elapsed_time()
   end
   local result = { available = true, game_elapsed_seconds = now, directors = {} }
   for _, kind in ipairs({ 'restock', 'input_bin' }) do
      local director = inventory:get_restock_director(kind)
      local summary = { kind = kind, available = director ~= nil }
      if director then
         summary.name = type(director._director_name) == 'string' and director._director_name or kind
         summary.queues = {
            restock = queue_count(director._restockable_items_queue),
            restock_high_quality = queue_count(director._restockable_high_quality_items_queue),
            reconsider = queue_count(director._reconsider_items_queue),
            reconsider_high_quality = queue_count(director._reconsider_high_quality_items_queue)
         }
         summary.failed_items = item_counts(director._failed_items)
         summary.reconsidering_items = item_counts(director._reconsidering_items)
         summary.errands_count = map_count(director._errands)
         summary.storages_count = map_count(director._storage_filters)
         summary.storage_filter_groups_count = map_count(director._storages_by_filter)
         local last = director._last_success_time
         if type(last) == 'number' then
            summary.last_success_game_seconds = last
            if type(now) == 'number' then summary.game_seconds_since_success = now - last end
         end
      end
      result.directors[#result.directors + 1] = summary
   end
   return result
end

return M

