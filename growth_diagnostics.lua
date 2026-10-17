-- Explicit scalar-only read-only diagnostics; no GC collection or new traces.
local M = {}
function M.snapshot()
   local ai = stonehearth.ai
   -- Snapshot-local only: never retain a function or entity after returning.
   local source_for_function, source_groups = {}, {}
   local source_info = type(debug) == 'table' and type(debug.getinfo) == 'function' and debug.getinfo or nil
   local unique_functions, source_lookup_failures = 0, 0
   local function add_storage_slot(fn)
      local label, first
      if type(fn) == 'function' then
         label = source_for_function[fn]
         if not label then
            first = true
            unique_functions = unique_functions + 1
            label = '<debug unavailable>'
            if source_info then
               local ok, info = pcall(source_info, fn, 'S')
               if ok and type(info) == 'table' and type(info.source) == 'string' then
                  -- Include the definition line to distinguish factories in one file.
                  label = info.source:sub(1, 240) .. ':' ..
                     (type(info.linedefined) == 'number' and tostring(info.linedefined) or '?')
               else
                  label = '<source unavailable>'
                  source_lookup_failures = source_lookup_failures + 1
               end
            end
            source_for_function[fn] = label
         end
      else
         label = '<non-function:' .. type(fn) .. '>'
      end
      local group = source_groups[label]
      if not group then
         group = {label=label, slots=0, functions=0}
         source_groups[label] = group
      end
      group.slots = group.slots + 1
      if first then group.functions = group.functions + 1 end
   end
   local function size(t)
      if type(t) ~= 'table' then return -1 end
      local n = 0
      for _ in pairs(t) do n = n + 1 end
      return n
   end
   local function up(fn, wanted, depth, seen)
      if type(fn) ~= 'function' or not debug or not debug.getupvalue or depth < 0 or seen[fn] then return nil end
      seen[fn] = true
      local children = {}
      for i = 1, 128 do
         local name, value = debug.getupvalue(fn, i)
         if not name then break end
         if name == wanted and type(value) == 'table' then return value end
         if type(value) == 'function' then children[#children + 1] = value end
      end
      for _, child in ipairs(children) do
         local value = up(child, wanted, depth - 1, seen)
         if value then return value end
      end
   end
   local function registry(method, name)
      if not ai then return nil end
      local ok, value = pcall(up, ai[method], name, 4, {})
      return ok and value or nil
   end
   local filters = registry('filter_from_key', 'ALL_FILTERS')
   local spatial = registry('create_spatial_cache', 'SPATIAL_CACHES')
   local fast = registry('fast_call_filter_fn', 'FAST_CALL_CACHES')
   local frc = registry('create_filter_result_cache', 'FILTER_RESULT_CACHES')
   local reverse = registry('filter_from_key', 'REVERSE_FILTER_LOOKUP')
   local out = {
      spatial = size(spatial), fast_call = size(fast), filter_results = size(frc),
      filter_namespaces = size(filters), reverse_filters = size(reverse),
      registered_filters = filters and 0 or -1,
      director_filters = filters and size(rawget(filters, 'restock_director')) or -1,
      storage_count = 0, storage_cache_slots = 0, storage_cache_slots_max = 0,
      storage_items = 0, directors = 0, active_directors = 0,
      director_quality_ids = 0, director_should_restock_ids = 0,
      director_fullness_listeners = 0, director_errand_listeners = 0,
      inventory_count = 0, director_errands = 0, director_claimed_errands = 0,
      active_restock_last_success = -1, active_input_bin_last_success = -1,
      active_restock_next_errand_id = -1, active_input_bin_next_errand_id = -1
   }
   if filters then
      for _, ns in pairs(filters) do out.registered_filters = out.registered_filters + math.max(0, size(ns)) end
   end
   local inventories = stonehearth.inventory and stonehearth.inventory._sv and stonehearth.inventory._sv.inventories
   -- Source-confirmed inventory_service.lua:26-34,57; expose absence instead of assuming a player ID.
   if type(inventories) ~= 'table' then
      inventories = {}
      out.inventory_count = -1
   end
   for _, inv in pairs(inventories) do
      if type(inv.get_all_public_storage) == 'function' then
         out.inventory_count = out.inventory_count + 1
         for _, entity in pairs(inv:get_all_public_storage()) do
            local sc = entity:get_component('stonehearth:storage')
            if sc then
               out.storage_count = out.storage_count + 1
               local n = 0
               if type(sc._storage_filter_cache) == 'table' then
                  for fn in pairs(sc._storage_filter_cache) do
                     n = n + 1
                     add_storage_slot(fn)
                  end
               end
               out.storage_cache_slots = out.storage_cache_slots + n
               out.storage_cache_slots_max = math.max(out.storage_cache_slots_max, n)
               out.storage_items = out.storage_items + ((sc._sv and sc._sv.num_items) or 0)
            end
         end
         for _, d in pairs(inv._restock_directors or {}) do
            out.directors = out.directors + 1
            if d._started then out.active_directors = out.active_directors + 1 end
            -- Source-confirmed scalar state only. Initialization also sets the
            -- success time, so compare it only while constructor count is stable.
            if d._started and (d._director_name == 'RESTOCK' or d._director_name == 'INPUT_BIN') then
               local prefix = d._director_name == 'RESTOCK' and 'active_restock_' or 'active_input_bin_'
               if type(d._last_success_time) == 'number' then
                  out[prefix .. 'last_success'] = math.max(out[prefix .. 'last_success'], d._last_success_time)
               end
               if type(d._current_errand_id) == 'number' then
                  out[prefix .. 'next_errand_id'] = math.max(out[prefix .. 'next_errand_id'], d._current_errand_id)
               end
            end
            out.director_quality_ids = out.director_quality_ids + math.max(0, size(d._item_quality_cache))
            out.director_should_restock_ids = out.director_should_restock_ids + math.max(0, size(d._item_should_restock_cache))
            for _, entry in pairs(d._storages_by_filter or {}) do
               out.director_fullness_listeners = out.director_fullness_listeners + math.max(0, size(entry.fullness_listeners))
            end
            for _, errand in pairs(d._errands or {}) do
               out.director_errands = out.director_errands + 1
               if errand.executor then out.director_claimed_errands = out.director_claimed_errands + 1 end
               out.director_errand_listeners = out.director_errand_listeners + math.max(0, size(errand.should_restock_listeners))
            end
         end
      end
   end
   local groups = {}
   for _, group in pairs(source_groups) do groups[#groups + 1] = group end
   table.sort(groups, function(a, b)
      if a.slots ~= b.slots then return a.slots > b.slots end
      return a.label < b.label
   end)
   out.storage_cache_unique_functions = unique_functions
   out.storage_cache_source_info_available = source_info ~= nil
   out.storage_cache_source_lookup_failures = source_lookup_failures
   out.storage_cache_source_groups_total = #groups
   out.storage_cache_source_groups = math.min(24, #groups)
   out.storage_cache_other_slots, out.storage_cache_other_functions = 0, 0
   for i, group in ipairs(groups) do
      if i <= 24 then
         local prefix = 'storage_cache_source_' .. string.format('%02d', i)
         out[prefix .. '_label'] = group.label
         out[prefix .. '_slots'] = group.slots
         out[prefix .. '_functions'] = group.functions
      else
         out.storage_cache_other_slots = out.storage_cache_other_slots + group.slots
         out.storage_cache_other_functions = out.storage_cache_other_functions + group.functions
      end
   end
   out.lua_heap_kb = collectgarbage("count")
   out.native_destroy_spatial_type = type(_radiant.sim.destroy_spatial_cache)
   return out
end

return M

