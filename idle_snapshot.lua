-- Explicit read-only, bounded snapshot of existing state. No hooks, timers,
-- listeners, get_debug_info, entity creation, AI rejection, or task claiming.
local M = {}
local LIMITS = { populations = 16, citizens = 64, inventories = 16,
   errands = 256, map_entries = 8192, activities_per_citizen = 24,
   text = 160 }

local function raw(object, key)
   if type(object) == 'table' then return rawget(object, key) end
end
local function finite(v)
   return type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge
end

function M.snapshot(options)
   local out = { schema = 'idle_snapshot_v122', available = false,
      mode = 'explicit_read_only', limits = {}, citizens = {}, inventories = {},
      coverage = { complete = true, probe_failures = 0, unavailable_fields = 0,
         string_truncations = 0, map_entries_scanned = 0, errands_scanned = 0,
         citizens_scanned = 0 },
      semantics = 'Claim availability is not task eligibility. No reachability, filters, needs or priority evaluation. Activities are a bounded current run-stack sample, not all thinking alternatives. Queue counts and map samples are observations, not measured durations. Native getters cannot be preempted by these Lua caps.' }
   for k,v in pairs(LIMITS) do out.limits[k] = v end
   local c = out.coverage
   local selected_player = raw(options, 'player_id')
   if (options ~= nil and type(options) ~= 'table') or
      (selected_player ~= nil and (type(selected_player) ~= 'string' or #selected_player == 0 or #selected_player > LIMITS.text)) then
      out.error = 'player_id must be a nonempty string no longer than 160 bytes'
      c.complete = false;return out
   end
   out.selection = selected_player and 'selected_player' or 'bounded_all_populations'
   out.player_id = selected_player
   local function unavailable()
      c.unavailable_fields = c.unavailable_fields + 1;c.complete = false
   end
   local function failed()
      c.probe_failures = c.probe_failures + 1;c.complete = false
   end
   local function scalar(v)
      if type(v) == 'string' then
         if #v > LIMITS.text then c.string_truncations = c.string_truncations + 1;c.complete = false end
         return v:sub(1, LIMITS.text)
      elseif type(v) == 'boolean' or finite(v) then return v end
   end
   -- Only source-confirmed observational API names below are invoked. Values
   -- from Lua fields are read with rawget, never arbitrary computed properties.
   local function call(object, name, ...)
      if object == nil then unavailable();return nil, false end
      local ok, fn = pcall(function() return object[name] end)
      if not ok then failed();return nil, false end
      if type(fn) ~= 'function' then unavailable();return nil, false end
      local success, value, b, d = pcall(fn, object, ...)
      if not success then failed();return nil, false end
      return value, true, b, d
   end
   local function entity_summary(entity)
      local row = { present = entity ~= nil }
      if entity == nil then return row end
      local valid, ok = call(entity, 'is_valid')
      row.validity_available = ok and type(valid) == 'boolean'
      if row.validity_available then row.valid = valid else unavailable() end
      if valid == true then
         local id, got = call(entity, 'get_id')
         row.id = scalar(id);row.id_available = got and row.id ~= nil
         if not row.id_available then unavailable() end
      end
      return row
   end
   -- Map limits are shared across ALL traversals, including empty/population
   -- containers. No pairs metamethod or full-map allocation is used.
   local function scan(map, maximum, visit)
      local meta = { available = type(map) == 'table', complete = false, scanned = 0, limit_hit = false }
      if not meta.available then unavailable();return meta end
      local key
      while true do
         local next_key, value = next(map, key)
         if next_key == nil then meta.complete = true;return meta end
         if meta.scanned >= maximum or c.map_entries_scanned >= LIMITS.map_entries then
            meta.limit_hit = true;c.complete = false;return meta
         end
         key = next_key;meta.scanned = meta.scanned + 1
         c.map_entries_scanned = c.map_entries_scanned + 1
         if visit then visit(key, value) end
      end
   end
   local function map_count(map)
      local result = scan(map, LIMITS.map_entries)
      result.count_is_exact = result.complete
      result.count_lower_bound = result.scanned
      if result.complete then result.count = result.scanned end
      return result
   end
   local function queue_count(queue)
      local n, ok = call(queue, 'get_size')
      local available = ok and finite(n) and n >= 0 and n == math.floor(n)
      if not available then unavailable() end
      return {available = available, count = available and n or nil}
   end
   local function selected_map(map)
      if not selected_player then return map end
      local value = raw(map, selected_player)
      if value ~= nil then return {[selected_player] = value} end
   end
   local sh = type(stonehearth) == 'table' and stonehearth or nil
   local rad = type(radiant) == 'table' and radiant or nil
   local calendar = raw(sh, 'calendar')
   local game_time, got_time = call(calendar, 'get_elapsed_time')
   out.game_seconds_available = got_time and finite(game_time)
   if out.game_seconds_available then out.game_seconds = game_time else unavailable() end
   -- radiant.gamestate.now is a module function, not a colon method.
   local gs = raw(rad, 'gamestate')
   local now_fn = raw(gs, 'now')
   local ok_now, now = false, nil
   if type(now_fn) == 'function' then ok_now, now = pcall(now_fn) end
   out.gamestate_now_available = ok_now and finite(now)
   if out.gamestate_now_available then out.gamestate_now = now else unavailable() end

   local function activity_sample(ai)
      local result = { available = false, complete = false, values = {}, scanned = 0 }
      local stack = raw(ai, '_run_stack')
      local n, ok = call(stack, 'get_size')
      if not ok or not finite(n) or n < 0 or n ~= math.floor(n) then unavailable();return result end
      result.available = true;result.reported_size = n;result.complete = n <= LIMITS.activities_per_citizen
      if not result.complete then c.complete = false;result.limit_hit = true end
      for i = 0, math.min(n, LIMITS.activities_per_citizen) - 1 do
         local frame, got = call(stack, 'get', i)
         local activity, read
         if got then activity, read = call(frame, 'get_activity') end
         local value = scalar(activity)
         result.scanned = result.scanned + 1
         if read and value ~= nil then result.values[#result.values+1] = {index=i, activity=value}
         else result.complete = false;unavailable() end
      end
      return result
   end
   local function inspect_citizen(pop_id, is_npc, key, entity)
      local row = { population_key = scalar(pop_id), is_npc = scalar(is_npc),
         citizen_key = scalar(key), entity = entity_summary(entity) }
      out.citizens[#out.citizens+1] = row
      if row.entity.valid ~= true then unavailable();return end
      local ai, got_ai = call(entity, 'get_component', 'stonehearth:ai')
      row.ai_available = got_ai and type(ai) == 'table'
      if row.ai_available then
         local sv = raw(ai, '_sv')
         row.status_text_key = scalar(raw(sv, 'status_text_key'))
         row.status_available = type(row.status_text_key) == 'string'
         if not row.status_available then unavailable() end
         row.spin_count = scalar(raw(sv, 'spin_count'))
         row.unyielded_spins = scalar(raw(ai, '_num_unyielded_spins'))
         row.entity_state_stale = scalar(raw(ai, '_entity_state_is_stale'))
         row.abort_backoff_timer_present = raw(ai, '_abort_backoff_timer') ~= nil
         row.activities = activity_sample(ai)
      else unavailable() end
      local work, got_work = call(entity, 'get_component', 'stonehearth:work_order')
      local wsv = got_work and raw(work, '_sv')
      row.work_orders_available = type(wsv) == 'table'
      if row.work_orders_available then
         row.working_for = scalar(raw(wsv, 'working_for'))
         row.work_order_statuses = {}
         local statuses = raw(wsv, 'work_order_statuses')
         for _, name in ipairs({'haul','mine','gather','build','job'}) do
            row.work_order_statuses[name] = scalar(raw(statuses, name))
         end
         row.work_order_statuses_available = type(statuses) == 'table'
         if not row.work_order_statuses_available then unavailable() end
      end
      local job, got_job = call(entity, 'get_component', 'stonehearth:job')
      local jsv = got_job and raw(job, '_sv')
      row.job_uri = scalar(raw(jsv, 'job_uri'))
      row.job_available = type(row.job_uri) == 'string'
   end
   local population_map = raw(raw(raw(sh, 'population'), '_sv'), 'populations')
   out.population_coverage = scan(selected_map(population_map), LIMITS.populations, function(pop_id, population)
      local psv = raw(population, '_sv')
      local citizens = raw(psv, 'citizens')
      local iterator, passed, state, control = call(citizens, 'each')
      local section = { population_key = scalar(pop_id), complete = false, scanned = 0 }
      out.population_sections = out.population_sections or {}
      out.population_sections[#out.population_sections+1] = section
      if not passed or type(iterator) ~= 'function' then unavailable();return end
      while true do
         local advanced, key, entity = pcall(iterator, state, control)
         if not advanced then failed();return end
         if key == nil then section.complete = true;return end
         if c.citizens_scanned >= LIMITS.citizens then section.limit_hit = true;c.complete = false;return end
         control = key;section.scanned = section.scanned + 1;c.citizens_scanned = c.citizens_scanned + 1
         inspect_citizen(pop_id, raw(psv, 'is_npc'), key, entity)
      end
   end)

   local function storage_summary(entity)
      local row = entity_summary(entity)
      if row.valid ~= true then return row end
      local storage, ok = call(entity, 'get_component', 'stonehearth:storage')
      local sv = ok and raw(storage, '_sv')
      row.fields_available = type(sv) == 'table'
      if row.fields_available then
         row.num_items = scalar(raw(sv, 'num_items'));row.capacity = scalar(raw(sv, 'capacity'))
         row.reserved_count = scalar(raw(storage, '_reserved_count'))
         row.storage_type = scalar(raw(storage, '_type'))
      end
      return row
   end
   local function inspect_director(director, kind)
      local result = { kind = kind, available = type(director) == 'table', errands = {},
         claim_counts = {unclaimed=0, consideration_expired=0, consideration_leased=0, running_claim=0, unknown=0},
         potentially_available_by_claim_only = 0 }
      if not result.available then unavailable();return result end
      result.name = scalar(raw(director, '_director_name'))
      result.started = scalar(raw(director, '_started'))
      result.retired = raw(director, '_hearth_smoother_retired') == true
      result.last_success_game_seconds = scalar(raw(director, '_last_success_time'))
      result.next_errand_id = scalar(raw(director, '_current_errand_id'))
      result.generation_callback_present = raw(director, '_generate_on_next_frame_timer') ~= nil
      result.failed_requeue_timer_present = raw(director, '_failed_item_requeue_timer') ~= nil
      local search = raw(director, '_active_nearby_item_search')
      result.nearby_search = {present = search ~= nil, fields_available = type(search) == 'table',
         age_available = false, age_reason = 'No verified start timestamp in current NearbyItemSearch.'}
      if type(search) == 'table' then
         result.nearby_search.source = entity_summary(raw(search, '_entity'))
         result.nearby_search.timeout_present = raw(search, '_timeout_timer') ~= nil
         result.nearby_search.ground_finder_present = raw(search, '_ground_item_finder') ~= nil
         result.nearby_search.storage_finder_present = raw(search, '_storage_item_finder') ~= nil
         result.nearby_search.max_results = scalar(raw(search, '_max_results'))
         result.nearby_search.results = map_count(raw(search, '_results'))
         result.nearby_search.backup_results = map_count(raw(search, '_backup_results'))
      end
      result.queues = {}
      for _, pair in ipairs({{'restock','_restockable_items_queue'}, {'restock_high_quality','_restockable_high_quality_items_queue'},
         {'reconsider','_reconsider_items_queue'}, {'reconsider_high_quality','_reconsider_high_quality_items_queue'}}) do
         result.queues[pair[1]] = queue_count(raw(director,pair[2]))
      end
      -- Errand records take precedence over potentially large failed maps.
      result.errand_coverage = scan(raw(director, '_errands'), LIMITS.errands - c.errands_scanned, function(key, errand)
         c.errands_scanned = c.errands_scanned + 1
         local row = { key = scalar(key), fields_available = type(errand) == 'table', claim_state = 'unknown' }
         result.errands[#result.errands+1] = row
         if row.fields_available then
            row.id = scalar(raw(errand, 'id'))
            local executor = raw(errand, 'executor')
            local expiry = raw(errand, 'lease_expiry')
            row.executor = entity_summary(executor)
            row.lease_expiry = finite(expiry) and expiry or nil
            if executor == nil then row.claim_state = 'unclaimed'
            elseif expiry == nil then row.claim_state = 'running_claim'
            elseif finite(expiry) and out.gamestate_now_available then
               row.claim_state = expiry <= now and 'consideration_expired' or 'consideration_leased'
            else unavailable() end
            row.main_item = entity_summary(raw(errand, 'main_item'))
            row.storage = storage_summary(raw(errand, 'storage'))
         else unavailable() end
         row.available_by_claim_only = row.claim_state == 'unclaimed' or row.claim_state == 'consideration_expired'
         result.claim_counts[row.claim_state] = result.claim_counts[row.claim_state] + 1
         if row.available_by_claim_only then result.potentially_available_by_claim_only = result.potentially_available_by_claim_only + 1 end
      end)
      result.failed_items = map_count(raw(director, '_failed_items'))
      result.reconsidering_items = map_count(raw(director, '_reconsidering_items'))
      result.storage_filters = map_count(raw(director, '_storage_filters'))
      return result
   end
   local inventories = raw(raw(raw(sh, 'inventory'), '_sv'), 'inventories')
   out.inventory_coverage = scan(selected_map(inventories), LIMITS.inventories, function(key, inventory)
      local row = { key = scalar(key), directors = {} }
      out.inventories[#out.inventories+1] = row
      local directors = raw(inventory, '_restock_directors')
      for _,kind in ipairs({'restock','input_bin'}) do
         row.directors[#row.directors+1] = inspect_director(raw(directors,kind), kind)
      end
   end)
   out.available = out.population_coverage.available or out.inventory_coverage.available
   return out
end

local basic_snapshot=M.snapshot
function M.snapshot(options)
   local out=basic_snapshot(options)
   if out.error then return out end
   local detail={schema='idle_detail_v123',complete=true,workers={},errands={},pairs={},
      limits={workers=8,errands=16,citizens_scanned=64,errands_scanned=512,frames_per_activity=16},
      citizens_scanned=0,errands_scanned=0,connectivity_queries=0,probe_failures=0,
      query_connectivity=raw(options,'query_connectivity')~=false,
      semantics='Observational fields and optional topology connectivity only; not complete eligibility. False connectivity retains wall-hanging and proxy exceptions. No pathfinding, filters, claim, failure, or AI rejection. Ready output/rejection cause/cooldown deadline are unavailable.'}
   out.detailed=detail
   local function value(v)
      if type(v)=='string' then return v:sub(1,160) end
      if type(v)=='boolean' or finite(v) then return v end
   end
   local function get(object,name,...)
      if object==nil then return nil,false end
      local ok,fn=pcall(function()return object[name]end)
      if not ok or type(fn)~='function' then return nil,false end
      local success,result=pcall(fn,object,...)
      if not success then detail.probe_failures=detail.probe_failures+1;detail.complete=false;return nil,false end
      return result,true
   end
   local function point(p)
      if p==nil then return nil end
      local ok,x,y,z=pcall(function()return p.x,p.y,p.z end)
      if ok and finite(x) and finite(y) and finite(z) then return {x=x,y=y,z=z} end
   end
   local function describe(entity)
      local r={present=entity~=nil}
      local valid,ok=get(entity,'is_valid');r.validity_available=ok and type(valid)=='boolean'
      if not r.validity_available then return r end
      r.valid=valid;if not valid then return r end
      r.id=value(get(entity,'get_id'))
      local mob,got=get(entity,'get_component','mob');r.mob_available=got and mob~=nil
      if r.mob_available then
         local location,read=get(mob,'get_world_grid_location')
         r.location_available=read;r.in_world=read and location~=nil or false;r.location=point(location)
      end
      return r
   end
   local player=raw(options,'player_id')
   if type(player)~='string' then detail.complete=false;detail.reason='selected player required';return out end
   local pops=raw(raw(raw(stonehearth,'population'),'_sv'),'populations')
   local population=raw(pops,player)
   local citizens=raw(raw(population,'_sv'),'citizens')
   local selected={};local requested=raw(options,'citizen_id')
   if requested~=nil and type(requested)~='number' and type(requested)~='string' then
      detail.complete=false;detail.reason='citizen_id must be scalar';return out
   end
   for _,row in ipairs(out.citizens)do
      local id=row.entity and row.entity.id
      local fire=row.status_text_key=='stonehearth:ai.actions.status_text.resting_by_fire'
      if id and ((requested~=nil and tostring(id)==tostring(requested)) or
         (requested==nil and fire and row.job_uri=='stonehearth:jobs:worker')) then
         selected[#selected+1]={id=id,basic=row}
      end
   end
   table.sort(selected,function(a,b)return tostring(a.id)<tostring(b.id)end)
   while #selected>8 do table.remove(selected);detail.worker_limit_hit=true;detail.complete=false end
   local wanted={};for _,s in ipairs(selected)do wanted[tostring(s.id)]=s end
   -- Existing native iterator only; no creation through get_population.
   local ok,iterator,state,control=pcall(function()return citizens:each()end)
   if ok and type(iterator)=='function' then
      while detail.citizens_scanned<64 do
         local advanced,key,entity=pcall(iterator,state,control)
         if not advanced then detail.complete=false;break end
         if key==nil then detail.citizen_scan_complete=true;break end
         control=key;detail.citizens_scanned=detail.citizens_scanned+1
         local valid=get(entity,'is_valid')
         local id=valid==true and get(entity,'get_id') or nil
         if id and wanted[tostring(id)] then wanted[tostring(id)].entity=entity end
      end
      if not detail.citizen_scan_complete then detail.complete=false end
   else detail.complete=false end
   local actor_module=raw(_G,'hearth_smoother_restock_actor_lifetime')
   local actor_fn=raw(actor_module,'snapshot')
   local actor_ids={};for id in pairs(wanted)do actor_ids[id]=true end
   if type(actor_fn)=='function' then
      local success,report=pcall(actor_fn,{player_id=player,citizen_ids=actor_ids})
      if success and type(report)=='table' then
         detail.actors=report;if report.complete~=true then detail.complete=false end
      else detail.complete=false;detail.actor_snapshot_failed=true end
   else detail.actor_snapshot_available=false;detail.complete=false end
   local actors=detail.actors and detail.actors.actors or {}
   for _,s in ipairs(selected)do
      local e=s.entity;local row={entity=describe(e),status_text_key=s.basic.status_text_key,
         is_fire=s.basic.status_text_key=='stonehearth:ai.actions.status_text.resting_by_fire',frames={},actors={}}
      detail.workers[#detail.workers+1]=row;s.row=row
      local work=get(e,'get_component','stonehearth:work_order');local wsv=raw(work,'_sv')
      local statuses=raw(wsv,'work_order_statuses');local owner=raw(work,'_player_id')
      row.work_player_id=value(raw(wsv,'working_for') or owner);row.owner_player_id=value(owner)
      row.haul_status=value(raw(statuses,'haul'));row.work_statuses_available=type(statuses)=='table'
      local faction=raw(pops,owner);local suspended=raw(raw(faction,'_sv'),'suspended_work_orders')
      row.faction_status_available=type(suspended)=='table'
      row.faction_haul_suspended=not not raw(suspended,'haul')
      if row.work_statuses_available and row.faction_status_available then
         row.haul_enabled=row.haul_status~='disabled' and not row.faction_haul_suspended
      elseif row.haul_status=='disabled' then row.haul_enabled=false end
      local ai=get(e,'get_component','stonehearth:ai')
      row.abort_backoff_timer_present=raw(ai,'_abort_backoff_timer')~=nil
      row.ready_output_available=false;row.rejection_reason_available=false;row.cooldown_deadline_available=false
      local frame_map=raw(ai,'_all_execution_frames')
      for _,activity in ipairs({'stonehearth:execute_restock_errand','stonehearth:restock','stonehearth:fill_input_bin'})do
         local frames=raw(frame_map,activity);local section={activity=activity,available=type(frames)=='table',frames={},complete=true}
         row.frames[#row.frames+1]=section
         if type(frames)=='table' then
            local key;local count=0
            while true do
               local k,frame=next(frames,key);if k==nil then break end
               if count>=16 then section.complete=false;detail.complete=false;break end
               key=k;count=count+1
               local status,got=get(frame,'get_state')
               section.frames[#section.frames+1]={id=value(k),state=value(status),state_available=got}
            end
         end
      end
      for _,a in ipairs(actors)do if tostring(a.citizen_id)==tostring(s.id)then row.actors[#row.actors+1]=a end end
   end
   local inventory=raw(raw(raw(raw(stonehearth,'inventory'),'_sv'),'inventories'),player)
   local directors=raw(inventory,'_restock_directors')
   local candidates={}
   for _,kind in ipairs({'restock','input_bin'})do
      local d=raw(directors,kind);local errands=raw(d,'_errands');local key
      if type(errands)=='table' then
         while true do
            local k,errand=next(errands,key);if k==nil then break end
            if detail.errands_scanned>=512 then detail.complete=false;detail.errand_scan_limit_hit=true;break end
            key=k;detail.errands_scanned=detail.errands_scanned+1
            local executor=raw(errand,'executor');local expiry=raw(errand,'lease_expiry')
            local unclaimed=executor==nil
            local expired=executor~=nil and finite(expiry) and finite(out.gamestate_now) and expiry<=out.gamestate_now
            if type(errand)=='table' and (unclaimed or expired) then
               candidates[#candidates+1]={kind=kind,key=k,errand=errand,director=d,claim_state=unclaimed and 'unclaimed' or 'consideration_expired'}
            end
         end
      end
   end
   table.sort(candidates,function(a,b)
      if a.kind~=b.kind then return a.kind<b.kind end
      return tostring(a.key)<tostring(b.key)
   end)
   if #candidates>16 then detail.errand_sample_limited=true;detail.complete=false end
   local topology=raw(raw(raw(_G,'_radiant'),'sim'),'topology')
   local connected=raw(topology,'are_connected')
   local function connection(a,b)
      if not detail.query_connectivity then return {available=false,reason='disabled'} end
      if type(connected)~='function' then return {available=false,reason='topology API unavailable'} end
      if get(a,'is_valid')~=true or get(b,'is_valid')~=true then return {available=false,reason='invalid endpoint'} end
      local source,destination=describe(a),describe(b)
      if not source.location_available or not destination.location_available or not source.in_world or not destination.in_world then
         return {available=false,reason='endpoint world location unavailable'}
      end
      detail.connectivity_queries=detail.connectivity_queries+1
      local success,result=pcall(connected,a,b)
      if not success then detail.probe_failures=detail.probe_failures+1;detail.complete=false end
      local r={available=success and type(result)=='boolean',negative_is_ineligibility=false,wall_support_fallback_checked=false}
      if r.available then r.connected=result end
      return r
   end
   for i=1,math.min(#candidates,16)do
      local c=candidates[i];local item=raw(c.errand,'main_item');local box=raw(c.errand,'storage')
      local item_row=describe(item);local target=item
      local r={kind=c.kind,key=value(c.key),claim_state=c.claim_state,main_item=item_row,storage=describe(box),
         director_player_id=value(raw(c.director,'_player_id')),director_retired=raw(c.director,'_hearth_smoother_retired')==true,
         cached_item_location=point(raw(c.errand,'item_location')),
         last_validated_gamestate=value(raw(raw(c.director,'_errand_last_validated'),c.key))}
      detail.errands[#detail.errands+1]=r
      if item_row.valid==true and item_row.location_available and not item_row.in_world then
         target=raw(raw(raw(c.director,'_inventory'),'_container_for'),item_row.id)
         r.container=describe(target)
      end
      if get(target,'is_valid')==true then
         local forms=get(target,'get_component','stonehearth:entity_forms')
         local proxy=raw(raw(forms,'_sv'),'_interaction_proxy')
         if proxy~=nil then target=proxy;r.interaction_proxy=describe(proxy)end
      end
      r.connectivity_source=describe(target)
      local filter_key=raw(c.errand,'filter_key');local storage_id=r.storage.id
      local filters=raw(c.director,'_storage_filters')
      r.storage_filter_registration_available=storage_id~=nil and type(filters)=='table' and filter_key~=nil
      if r.storage_filter_registration_available then r.storage_filter_registration_matches=raw(filters,storage_id)==filter_key end
      local storage_query=false
      for _,s in ipairs(selected)do
         local pair={citizen_id=s.id,kind=c.kind,errand_key=value(c.key),full_eligibility_available=false}
         detail.pairs[#detail.pairs+1]=pair
         pair.work_player_matches=s.row.work_player_id==r.director_player_id
         pair.haul_enabled=s.row.haul_enabled
         pair.waiting_actor_matches=false
         for _,a in ipairs(s.row.actors)do
            if a.type_id==c.kind and a.thinking and a.waiting and a.bound_matches_current then pair.waiting_actor_matches=true end
         end
         if pair.work_player_matches and pair.waiting_actor_matches and not r.director_retired then
            pair.item_to_worker=connection(target,s.entity)
            if not storage_query then r.item_to_storage=connection(target,box);storage_query=true end
         else pair.item_to_worker={available=false,reason='no matching current waiting actor'}end
      end
   end
   return out
end
return M

