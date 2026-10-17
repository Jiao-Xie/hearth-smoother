-- On-demand bounded read-only snapshot. No retained entities, tracing or timers.
local M = {}
local ASTAR_SOURCE = '@stonehearth/components/pathfinder/astar_search.lua'
local MAX_POPULATIONS, MAX_CITIZENS, MAX_JOB_SLOTS = 64, 1024, 2048
local MAX_RESULTS, MAX_TARGETS, MAX_TOTAL_TARGETS = 256, 64, 4096
local MAX_PROGRESS, MAX_TEXT = 256, 128
local MAX_CALLBACK_SOURCES, MAX_CALLBACK_QUERIES = 8, 256
local MAX_CALLBACK_SLOTS, MAX_TOTAL_CALLBACK_SLOTS, MAX_SOURCE_TEXT = 64, 1024, 240
local MAX_WORLD_ENTITIES = 65536

local function get(object, key)
   if object == nil then return nil, false end
   local ok, value = pcall(function() return object[key] end)
   if ok then return value, true end
   return nil, false
end

local function scalar(value)
   if type(value) == 'number' then
      if value == value and value ~= math.huge and value ~= -math.huge then return value end
   elseif type(value) == 'string' then return value:sub(1, MAX_TEXT)
   elseif type(value) == 'boolean' then return value end
end

local function stock_method(object, key, first, last)
   local fn = get(object, key)
   if type(fn) ~= 'function' or type(debug) ~= 'table' or type(debug.getinfo) ~= 'function' then return nil end
   local ok, info = pcall(debug.getinfo, fn, 'S')
   if ok and type(info) == 'table' and info.source == ASTAR_SOURCE
      and info.linedefined == first and info.lastlinedefined == last then return fn end
end

local function limits()
   return {populations=MAX_POPULATIONS, citizens=MAX_CITIZENS, job_slots=MAX_JOB_SLOTS, world_entities=MAX_WORLD_ENTITIES,
      results=MAX_RESULTS, targets_per_job=MAX_TARGETS, total_targets=MAX_TOTAL_TARGETS,
      progress_characters=MAX_PROGRESS, scalar_text_characters=MAX_TEXT,
      callback_sources_per_job=MAX_CALLBACK_SOURCES, callback_source_queries=MAX_CALLBACK_QUERIES,
      callback_slots_per_job=MAX_CALLBACK_SLOTS, total_callback_slots=MAX_TOTAL_CALLBACK_SLOTS,
      callback_source_characters=MAX_SOURCE_TEXT}
end

function M.status()
   return {available=true, module_version='v113', mode='explicit_snapshot_only', limits=limits(),
      scope='Existing pathfinder components of registered player and NPC population citizens; shared Lua AStarSearch only.',
      omissions='Unregistered entities, animals/monsters outside population citizen maps, synchronous native pathfinders, BFS and IPF are not enumerated. A listed job is not proof it is currently running.',
      source_contract='release-949 population_service.lua 49-51; population_faction.lua 899-901; pathfinder_component.lua 127-140; astar_search.lua 171-183'}
end

function M.snapshot(options)
   local out = M.status()
   local world = type(options) == 'table' and options.all_entities == true
   out.selection = world and 'all_entities' or 'population_citizens'
   out.world_entities_scanned, out.invalid_world_entities = 0, 0
   out.world_entity_limit_hit, out.full_table_allocation, out.full_table_allocation_attempted = false, false, false
   if world then
      out.scope = 'Opt-in world entity table; existing components and shared Lua AStarSearch only, without player/NPC/animal filtering.'
      out.omissions = 'Synchronous native pathfinders, BFS and IPF are not enumerated. Lua scan/result limits may omit entities. A listed job is not proof it is running.'
      out.unpreemptible_cost = 'Native get_all_entities builds the entire entity table once before the bounded Lua scan; that allocation/call cannot be preempted or bounded by these scan caps.'
      out.native_enumeration_unpreemptible = true
      out.world_source_contract = 'ACE cunning_town_bonus.lua initialize_bonus 40-51 calls pairs(_radiant.sim.get_all_entities()); radiant/modules/entities.lua get_world_grid_location 373-376 only reads existing mob.'
   end
   out.available = false
   out.jobs = {}
   out.result_count, out.partial = 0, false
   out.populations_scanned, out.citizens_scanned, out.components_found = 0, 0, 0
   out.job_slots_scanned, out.targets_scanned = 0, 0
   out.player_populations, out.npc_populations, out.unknown_populations = 0, 0, 0
   out.probe_failures, out.invalid_citizens, out.duplicate_searches = 0, 0, 0
   out.metadata_unavailable, out.progress_unavailable = 0, 0
   out.callback_slots_scanned, out.callback_source_queries, out.callback_source_failures = 0, 0, 0
   out.callback_limit_hit = false
   out.population_limit_hit, out.citizen_limit_hit, out.job_slot_limit_hit = false, false, false
   out.result_limit_hit, out.target_limit_hit = false, false
   -- All references and deduplication keys exist only during this invocation.
   local seen = {}
   local callback_info = {}
   local population_service = stonehearth and get(stonehearth, 'population')
   local sv = get(population_service, '_sv')
   local populations = get(sv, 'populations')
   if not world and type(populations) ~= 'table' then
      out.unavailable_reason = 'population _sv.populations unavailable'
      out.partial = true
      return out
   end
   out.available = true
   -- Separate bounded read-only count pass: job/result limits cannot hide citizens.
   -- This reflects existing population membership, not UI trace freshness.
   if not world then
      out.population_citizens = {}
      out.population_counts_complete = true
      out.population_count_limit_hit = false
      out.population_count_per_population_limit = MAX_CITIZENS
      local population_key
      while true do
         local ok, key, population = pcall(next, populations, population_key)
         if not ok then out.population_counts_complete=false;break end
         population_key = key
         if key == nil then break end
         if #out.population_citizens >= MAX_POPULATIONS then
            out.population_counts_complete=false;out.population_count_limit_hit=true;break
         end
         local data = get(population, '_sv')
         local row = {player_id=scalar(key), is_npc=scalar(get(data, 'is_npc')),
            citizens_scanned=0, complete=false, limit_hit=false}
         out.population_citizens[#out.population_citizens+1] = row
         local citizens = get(data, 'citizens')
         local each = get(citizens, 'each')
         local passed, iterator, state, control = false, nil, nil, nil
         if type(each)=='function' then passed, iterator, state, control=pcall(each,citizens) end
         if not passed or type(iterator)~='function' then
            row.unavailable_reason='citizens iterator unavailable'
         else
            while true do
               local advanced, id = pcall(iterator, state, control)
               if not advanced then row.unavailable_reason='citizens iterator failed';break end
               if id==nil then row.complete=true;break end
               if row.citizens_scanned>=MAX_CITIZENS then row.limit_hit=true;break end
               row.citizens_scanned=row.citizens_scanned+1;control=id
            end
         end
         if not row.complete then out.population_counts_complete=false end
      end
   end
   local function failed()out.probe_failures = out.probe_failures + 1 end
   local function inspect_search(search, population_id, citizen_id, is_npc, source_key, actor)
      if seen[search] then out.duplicate_searches = out.duplicate_searches + 1;return end
      if type(search) ~= 'table' then failed();return end
      seen[search] = true
      local row = {population_id=scalar(population_id), citizen_id=scalar(citizen_id),
         is_npc=scalar(is_npc), source_key=scalar(source_key), target_ids={},
         metadata_available=false, progress_available=false, targets_truncated=false,
         callback_sources={}, callback_sources_truncated=false, callback_slots_scanned=0}
      for _, field in ipairs({'entity_uri', 'player_id'}) do
         local method = get(actor, field == 'entity_uri' and 'get_uri' or 'get_player_id')
         if type(method) == 'function' then
            local ok, value = pcall(method, actor)
            if ok then row[field] = scalar(value) else failed() end
         end
      end
      if world then
         -- Call the verified stock helper; it obtains only an existing mob.
         local entities = radiant and get(radiant, 'entities')
         local location_fn = get(entities, 'get_world_grid_location')
         local inspect = type(debug)=='table' and get(debug, 'getinfo')
         if type(location_fn)=='function' and type(inspect)=='function' then
            local ok, info = pcall(inspect, location_fn, 'S')
            if ok and type(info)=='table' and info.source=='@radiant/modules/entities.lua'
               and info.linedefined==373 and info.lastlinedefined==376 then
               local located, position = pcall(location_fn, actor)
               if located and position then
                  local coordinates = {}
                  for _, axis in ipairs({'x','y','z'}) do
                     local value = scalar(get(position, axis))
                     if type(value)=='number' then coordinates[axis]=value end
                  end
                  if next(coordinates) then row.world_grid_location=coordinates end
               elseif not located then failed() end
            end
         end
         row.world_grid_location_available = row.world_grid_location ~= nil
      end
      local source_seen = {}
      local function inspect_callbacks(dst_info, kind)
         if type(dst_info) ~= 'table' then return end
         local callbacks = rawget(dst_info, kind)
         if type(callbacks) ~= 'table' then return end
         local fn
         while true do
            fn = next(callbacks, fn)
            if fn == nil then return end
            if row.callback_slots_scanned >= MAX_CALLBACK_SLOTS
               or out.callback_slots_scanned >= MAX_TOTAL_CALLBACK_SLOTS
               or #row.callback_sources >= MAX_CALLBACK_SOURCES then
               row.callback_sources_truncated, out.callback_limit_hit = true, true;return
            end
            row.callback_slots_scanned = row.callback_slots_scanned + 1
            out.callback_slots_scanned = out.callback_slots_scanned + 1
            if type(fn) == 'function' then
               local info = callback_info[fn]
               if info == nil then
                  if out.callback_source_queries >= MAX_CALLBACK_QUERIES then
                     row.callback_sources_truncated, out.callback_limit_hit = true, true;return
                  end
                  out.callback_source_queries = out.callback_source_queries + 1
                  local ok, result = false, nil
                  if type(debug) == 'table' and type(debug.getinfo) == 'function' then
                     ok, result = pcall(debug.getinfo, fn, 'S')
                  end
                  if ok and type(result) == 'table' then
                     info = {source=type(result.source)=='string' and result.source:sub(1, MAX_SOURCE_TEXT) or '<unavailable>',
                        linedefined=scalar(result.linedefined), what=scalar(result.what)}
                  else
                     info = false;out.callback_source_failures = out.callback_source_failures + 1
                  end
                  callback_info[fn] = info
               end
               if info then
                  local identity = kind..':'..info.source..':'..tostring(info.linedefined)..':'..tostring(info.what)
                  if not source_seen[identity] then
                     source_seen[identity] = true
                     row.callback_sources[#row.callback_sources+1] = {callback_kind=kind,
                        source=info.source, linedefined=info.linedefined, what=info.what}
                  end
               end
            end
         end
      end
      local location = rawget(search, '_start_location')
      local xyz = {}
      for _, axis in ipairs({'x','y','z'}) do
         local coordinate = scalar(get(location, axis))
         if type(coordinate) == 'number' then xyz[axis] = coordinate end
      end
      if next(xyz) then row.source_location = xyz end
      row.managed = scalar(rawget(search, '_managed'))
      row.native_handle_present = rawget(search, '_pathfinder') ~= nil
      local metadata = stock_method(search, 'get_pathfinder_metadata', 178, 183)
      if metadata then
         local ok, value = pcall(metadata, search)
         if ok and type(value) == 'table' then
            row.entity_id, row.job_id = scalar(value.entity_id), scalar(value.job_id)
            row.metadata_available = row.entity_id ~= nil and row.job_id ~= nil
         else failed() end
      end
      if not row.metadata_available then out.metadata_unavailable = out.metadata_unavailable + 1 end
      local progress = stock_method(search, 'get_progress', 171, 176)
      if progress then
         local ok, value = pcall(progress, search)
         if ok and type(value) == 'string' then
            row.progress = value:sub(1, MAX_PROGRESS)
            row.progress_truncated = #value > MAX_PROGRESS
            row.progress_available = true
         elseif not ok then failed() end
      end
      if not row.progress_available then out.progress_unavailable = out.progress_unavailable + 1 end
      local destinations = rawget(search, '_destinations')
      if type(destinations) == 'table' then
         local key
         local scanned = 0
         while true do
            local dst_info
            key, dst_info = next(destinations, key)
            if key == nil then break end
            if scanned >= MAX_TARGETS or out.targets_scanned >= MAX_TOTAL_TARGETS then
               row.targets_truncated, out.target_limit_hit = true, true;break
            end
            scanned = scanned + 1;out.targets_scanned = out.targets_scanned + 1
            local id = scalar(key)
            if id ~= nil then row.target_ids[#row.target_ids+1] = id end
            inspect_callbacks(dst_info, 'solved_cbs')
            inspect_callbacks(dst_info, 'exhausted_cbs')
         end
         row.target_slots_scanned = scanned
      else row.targets_unavailable = true end
      out.jobs[#out.jobs+1] = row
   end
   local function inspect_citizen(entity, population_id, citizen_id, is_npc)
      local method = get(entity, 'get_component')
      if type(method) ~= 'function' then
         if world then out.invalid_world_entities=out.invalid_world_entities+1
         else out.invalid_citizens=out.invalid_citizens+1 end
         return
      end
      local ok, component = pcall(method, entity, 'stonehearth:pathfinder')
      if not ok then failed();return end
      if component == nil then return end
      out.components_found = out.components_found + 1
      local searches = get(component, '_astar_pathfinders')
      if type(searches) ~= 'table' then failed();return end
      local key
      while true do
         local search
         key, search = next(searches, key)
         if key == nil then break end
         if out.job_slots_scanned >= MAX_JOB_SLOTS then out.job_slot_limit_hit = true;return end
         if #out.jobs >= MAX_RESULTS then out.result_limit_hit = true;return end
         out.job_slots_scanned = out.job_slots_scanned + 1
         local passed = pcall(inspect_search, search, population_id, citizen_id, is_npc, key, entity)
         if not passed then failed() end
      end
   end
   local function inspect_population(population, population_id)
      local data = get(population, '_sv')
      local is_npc = get(data, 'is_npc')
      if is_npc == true then out.npc_populations = out.npc_populations + 1
      elseif is_npc == false then out.player_populations = out.player_populations + 1
      else out.unknown_populations = out.unknown_populations + 1 end
      local citizens = get(data, 'citizens')
      local each = get(citizens, 'each')
      if type(each) ~= 'function' then failed();return end
      local ok, iterator, iterator_state, control = pcall(each, citizens)
      if not ok or type(iterator) ~= 'function' then failed();return end
      while true do
         -- Bound even a damaged iterator that repeats the same entity forever.
         if out.citizens_scanned >= MAX_CITIZENS then out.citizen_limit_hit = true;return end
         if out.job_slots_scanned >= MAX_JOB_SLOTS then out.job_slot_limit_hit = true;return end
         if #out.jobs >= MAX_RESULTS then out.result_limit_hit = true;return end
         local iter_ok, citizen_id, entity = pcall(iterator, iterator_state, control)
         if not iter_ok then failed();return end
         if citizen_id == nil then break end
         control = citizen_id
         out.citizens_scanned = out.citizens_scanned + 1
         local passed = pcall(inspect_citizen, entity, population_id, citizen_id, is_npc)
         if not passed then failed() end
      end
   end
   if world then
      local sim = _radiant and get(_radiant, 'sim')
      local enumerate = get(sim, 'get_all_entities')
      if type(enumerate) ~= 'function' then
         out.available=false;out.partial=true;out.unavailable_reason='native get_all_entities unavailable';return out
      end
      out.full_table_allocation_attempted = true
      local ok, entities = pcall(enumerate)
      if not ok or type(entities)~='table' then
         out.available=false;out.partial=true;out.unavailable_reason='native get_all_entities failed or returned non-table';failed();return out
      end
      out.full_table_allocation = true
      local key
      while true do
         local traversed, new_key, entity = pcall(next, entities, key)
         if not traversed then failed();out.unavailable_reason='world entity traversal failed';break end
         key = new_key
         if key == nil then break end
         if out.world_entities_scanned >= MAX_WORLD_ENTITIES then out.world_entity_limit_hit=true;break end
         if out.job_slots_scanned >= MAX_JOB_SLOTS then out.job_slot_limit_hit=true;break end
         if #out.jobs >= MAX_RESULTS then out.result_limit_hit=true;break end
         out.world_entities_scanned = out.world_entities_scanned + 1
         -- Native map keys are not assumed to be entity IDs or citizen IDs.
         local inspected = pcall(inspect_citizen, entity, nil, nil, nil)
         if not inspected then failed() end
      end
   else
    local key
    while true do
      local traversed, new_key, population = pcall(next, populations, key)
      if not traversed then
         failed();out.unavailable_reason = 'population traversal failed';break
      end
      key = new_key
      if key == nil then break end
      if out.populations_scanned >= MAX_POPULATIONS then out.population_limit_hit = true;break end
      if out.citizens_scanned >= MAX_CITIZENS then out.citizen_limit_hit = true;break end
      if out.job_slots_scanned >= MAX_JOB_SLOTS then out.job_slot_limit_hit = true;break end
      if #out.jobs >= MAX_RESULTS then out.result_limit_hit = true;break end
      out.populations_scanned = out.populations_scanned + 1
      local ok = pcall(inspect_population, population, key)
      if not ok then failed() end
    end
   end
   out.result_count = #out.jobs
   out.partial = out.probe_failures > 0 or out.invalid_citizens > 0
      or out.metadata_unavailable > 0 or out.progress_unavailable > 0
      or out.population_limit_hit or out.citizen_limit_hit or out.job_slot_limit_hit
      or out.result_limit_hit or out.target_limit_hit
      or out.callback_limit_hit or out.callback_source_failures > 0
      or out.world_entity_limit_hit or out.invalid_world_entities > 0
   return out
end

return M

