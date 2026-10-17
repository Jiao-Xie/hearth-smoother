-- Source-gated actor handoff for retired ACE restock directors.
local M={}
local PATH='stonehearth.ai.actions.execute_restock_errand_action'
local SOURCE='@stonehearth_ace/ai/actions/execute_restock_errand_action.lua'
local EVENT='hearth_smoother:restock_director_retired'
local FIELD='_hearth_smoother_restock_actor_epoch'
local bounds={start_thinking={47,77},_try_take_errand={79,142},start={144,154},stop_thinking={156,176},stop={178,189}}
local state={applied=false,enabled=true,refreshed=0,notices=0,notice_failures=0,deferred=0,unresolved=0,late_callbacks=0}
local instances=setmetatable({}, {__mode='k'}) -- boolean values only
local owner,original,wrappers
local bind,finish_restore
local function owns()
   if not state.applied or not owner then return false end
   for name,fn in pairs(wrappers) do if owner[name]~=fn then return false end end
   return true
end
local function current(self,expected)
   local ctx=self[FIELD]
   if ctx and ctx.live and (not expected or ctx==expected) then return ctx end
end
local function release_field(object,name)
   local h=object[name];object[name]=nil
   if h then h:destroy() end
end
local function detach_waiting(self,ctx)
   ctx.waiting=false
   local handles={self._errand_created_listener or false,ctx.retirement_listener or false,ctx.rebind_timer or false}
   self._errand_created_listener,ctx.retirement_listener,ctx.rebind_timer=nil,nil,nil
   local failed,first_error
   for _,handle in ipairs(handles)do if handle then
      local ok,err=pcall(handle.destroy,handle)
      if not ok then state.cleanup_failures=(state.cleanup_failures or 0)+1;if not failed then failed=true;first_error=err end end
   end end
   if failed then error(first_error,0)end
end
local function install_listener(self,ctx,field,source,event,fn)
   if not current(self,ctx) then return end
   local handle=radiant.events.listen(source,event,fn)
   if current(self,ctx) and ctx.bound==source and (field~='_errand_created_listener' or ctx.waiting) then self[field]=handle else handle:destroy() end
end
local function clear_context(self,ctx)
   if self[FIELD]==ctx then self[FIELD]=nil end
   ctx.live=false;ctx.thinking=false;ctx.waiting=false
   instances[self]=nil
   local timer,listener,watch=ctx.rebind_timer,ctx.retirement_listener,ctx.carried_watch
   ctx.rebind_timer,ctx.retirement_listener,ctx.carried_watch=nil,nil,nil
   ctx.ai,ctx.entity,ctx.args,ctx.bound=nil,nil,nil,nil
   local ok,err=true
   if timer then ok,err=pcall(timer.destroy,timer) end
   local ok2,err2=true
   if listener then ok2,err2=pcall(listener.destroy,listener) end
   local ok3,err3=true
   if watch then ok3,err3=pcall(watch.destroy,watch)end
   if not ok then error(err,0) end;if not ok2 then error(err2,0) end;if not ok3 then error(err3,0)end
end
local function live_count()
   local n=0;for action in pairs(instances)do if current(action)then n=n+1 end end;return n
end
local function on_retired(self,ctx)
   if not current(self,ctx) or not ctx.thinking or not ctx.waiting or self._started then state.late_callbacks=state.late_callbacks+1;return end
   state.notices=state.notices+1
   local ok,err=pcall(function()
      detach_waiting(self,ctx)
      if current(self,ctx) then bind(self,ctx,true) end
   end)
   if not ok then state.notice_failures=state.notice_failures+1;error(err,0) end
end
bind=function(self,ctx,allow_defer)
   if not current(self,ctx) or not ctx.thinking or self._started then return end
   local ai,entity,args=ctx.ai,ctx.entity,ctx.args
   if not radiant.entities.exists_in_world(entity) then return end
   local player=radiant.entities.get_work_player_id(entity)
   local inventory=stonehearth.inventory:get_inventory(player)
   local director=inventory and inventory:get_restock_director(args.type_id)
   if not director or director._hearth_smoother_retired then
      ctx.bound=nil
      if director and director._hearth_smoother_retired and allow_defer and not ctx.rebind_timer then
         state.deferred=state.deferred+1
         local fired=false
         local timer=radiant.on_game_loop_once('restock actor replacement handoff',function()
            fired=true
            if not current(self,ctx) then state.late_callbacks=state.late_callbacks+1;return end
            ctx.rebind_timer=nil
            bind(self,ctx,false)
         end)
         if fired or not current(self,ctx) then timer:destroy() else ctx.rebind_timer=timer end
      else state.unresolved=state.unresolved+1 end
      return
   end
   if ctx.bound and ctx.bound~=director then state.refreshed=state.refreshed+1
   elseif ctx.rebinding then state.refreshed=state.refreshed+1 end
   ctx.rebinding=false;ctx.bound=director
   if self:_try_take_errand(ai,entity,director,player) then return end
   if not current(self,ctx) or self._started or ctx.bound~=director then return end
   if director._hearth_smoother_retired then ctx.rebinding=true;return bind(self,ctx,allow_defer) end
   ctx.waiting=true
   ai:set_debug_progress('waiting for an errand')
   install_listener(self,ctx,'_errand_created_listener',director,'stonehearth:restock:errand_available',function()
      if not current(self,ctx) or not ctx.thinking or not ctx.waiting or ctx.bound~=director or self._started then state.late_callbacks=state.late_callbacks+1;return end
      if director._hearth_smoother_retired then ctx.rebinding=true;return on_retired(self,ctx) end
      if self:_try_take_errand(ai,entity,director,player) then return radiant.events.UNLISTEN end
   end)
   if not current(self,ctx) or not ctx.waiting or ctx.bound~=director then return end
   local handle=radiant.events.listen(director,EVENT,function()
      if not current(self,ctx) or ctx.bound~=director then state.late_callbacks=state.late_callbacks+1;return end
      ctx.rebinding=true
      return on_retired(self,ctx)
   end)
   if current(self,ctx) and ctx.waiting and ctx.bound==director then ctx.retirement_listener=handle else handle:destroy() end
   if current(self,ctx) and ctx.waiting and director._hearth_smoother_retired then on_retired(self,ctx) end
end

local _no_fill_backpack_predicate = function() return true end

local function make_fill_backpack_predicate(player_id, bin)
   if not radiant.entities.exists(bin) then
      return _no_fill_backpack_predicate
   end

   local storage = bin:get_component('stonehearth:storage')
   if storage:get_type() == 'input_crate' then
      local content_valid_function = storage:get_filter_function()
      local inventory = stonehearth.inventory:get_inventory(player_id)
      local exists = radiant.entities.exists
      local priority = storage:get_input_bin_priority()
      return stonehearth.ai:filter_from_key('item_for_input_bin', player_id .. ';' .. priority .. ';' .. storage:get_filter_key(), function(item)
         if not exists(item) then  -- TODO: Why is this even happening?
            return false
         end

         local source = inventory:container_for(item)
         if source then
            local source_storage = source:get_component('stonehearth:storage')
            if source_storage:get_type() == 'input_crate' and source_storage:get_input_bin_priority() >= priority then
               -- if the filter was changed/removed, we do want to move its items to other input bins
               if source_storage:passes(item) then
                  return false
               end
            end
         end

         return content_valid_function(item)
      end)
   end

   return _no_fill_backpack_predicate
end

local function try_take(self,ai, entity, restock_director, work_player_id, maybe_errand_id)
   local ctx=current(self)
   if not ctx then return original._try_take_errand(self,ai,entity,restock_director,work_player_id,maybe_errand_id) end
   if not ctx.thinking or self._started or restock_director._hearth_smoother_retired then return false end
   local errand_id, errand, score = restock_director:take_errand_to_consider(entity, maybe_errand_id)
   if not errand_id then
      return false
   end

   local function abandon_consideration()
      local newer=current(self)
      -- Reentry may already have transferred this exact claim to a new epoch.
      if newer and newer~=ctx and newer.entity==entity and self._restock_director==restock_director and self._errand_id==errand_id then return end
      restock_director:give_up_on_errand(entity,errand_id)
   end
   if not current(self,ctx) or not ctx.thinking or self._started or ctx.bound~=restock_director or restock_director._hearth_smoother_retired then
      abandon_consideration();return false
   end
   local detached,detach_error=pcall(detach_waiting,self,ctx)
   if not detached then pcall(abandon_consideration);error(detach_error,0)end
   if not current(self,ctx) or not ctx.thinking or self._started or ctx.bound~=restock_director or restock_director._hearth_smoother_retired then
      abandon_consideration();return false
   end
   ctx.bound=restock_director
   self._started = false
   self._restock_director = restock_director
   self._errand_id = errand_id

   if self._errand_created_listener then
      self._errand_created_listener:destroy()
      self._errand_created_listener = nil
   end

   install_listener(self,ctx,'_errand_canceled_reject_listener',restock_director, 'stonehearth:restock:errand_canceled', function(errand_id)
         if current(self,ctx) and ctx.thinking and self._restock_director==restock_director and self._errand_id == errand_id then
            ai:reject()
         end
      end)
   install_listener(self,ctx,'_errand_started_reject_listener',restock_director, 'stonehearth:restock:errand_started', function(errand_id, starting_entity)
         if current(self,ctx) and ctx.thinking and self._restock_director==restock_director and self._errand_id == errand_id and starting_entity ~= entity then
            -- Someone else successfully started it.
            ai:reject()
         end
      end)

   -- Errands fail if they are valid but thinking doesn't finish in some time.
   -- Ideally, this would never happen, but this should catch unexpected issues with reachability or races.
   if not current(self,ctx) then return false end
   local timeout = stonehearth.calendar:set_timer('errand consider timeout', stonehearth.constants.inventory.restock_director.MAX_CONSIDER_DURATION_MS, function()
         if current(self,ctx) and ctx.thinking and self._restock_director==restock_director and self._errand_id==errand_id then
            restock_director:mark_errand_failed(errand_id)
         end
      end)

   if not current(self,ctx) then timeout:destroy();return false end
   self._errand_timeout_timer=timeout

   local carried=hearth_smoother_carried_target_guard
   if carried and carried.is_active() then
      local watch=carried.watch_candidate(errand.main_item,entity,function()
         if current(self,ctx) and ctx.thinking and not self._started
            and self._restock_director==restock_director and self._errand_id==errand_id then
            -- Reject can synchronously restart planning before the global
            -- carry-transition loop. Do not reuse a pre-pickup positive cache.
            restock_director._errand_last_validated[errand_id]=nil
            ai:reject()
         end
      end)
      if current(self,ctx) and ctx.thinking and not self._started then ctx.carried_watch=watch
      elseif watch then watch:destroy()end
      if not current(self,ctx) then return false end
   end

   -- if the main item is pretty far away from the storage, don't cap the max items
   -- they may be getting brought from far out of town, and it's better they drop them in town to get restocked further
   -- also, by the time they bring them into town, there might be extra space in the destination storage
   -- nearby items (e.g., fuel or input bins getting stocked from containers) will still be capped to avoid excessive hauling
   local max_items = errand.storage_space_lease.quantity
   local inventory = stonehearth.inventory:get_inventory(errand.main_item)
   local container = inventory and inventory:container_for(errand.main_item)
   local main_item_location = container and radiant.entities.get_world_grid_location(container) or radiant.entities.get_world_grid_location(errand.main_item)
   local storage_location = radiant.entities.get_world_grid_location(errand.storage)
   local min_distance_sq = stonehearth.constants.inventory.MAX_IGNORE_MAX_ITEMS_DISTANCE * stonehearth.constants.inventory.MAX_IGNORE_MAX_ITEMS_DISTANCE
   if main_item_location and storage_location and main_item_location:distance_to_squared(storage_location) >= min_distance_sq then
      max_items = stonehearth.constants.inventory.restock_director.MAX_EXTRA_ITEMS
   end

   ai:set_utility(score)
   if not current(self,ctx) then return false end
   ai:set_think_output({
      errand_id = errand_id,
      restock_director = restock_director,
      filter_fn = errand.filter_fn,
      storage = errand.storage,
      main_item = errand.main_item,
      extra_items = errand.extra_items,
      max_items = max_items,
      owner_player_id = work_player_id,
      fill_backpack_filter_fn = make_fill_backpack_predicate(work_player_id, errand.storage),
   })

   if not current(self,ctx) then return false end
   ai:set_debug_progress('executing errand ' .. errand_id)

   return true
end

local function start_thinking(self,ai,entity,args)
   if not state.enabled then return original.start_thinking(self,ai,entity,args) end
   local prior=current(self)
   if prior then error('restock actor started thinking twice without cleanup') end
   self._restock_director=nil;self._errand_id=nil;self._started=false
   local ctx={live=true,thinking=true,ai=ai,entity=entity,args=args}
   self[FIELD]=ctx;instances[self]=true
   return bind(self,ctx,true)
end
local function start(self,ai,entity,args)
   local ctx=current(self)
   if not ctx then return original.start(self,ai,entity,args) end
   local carried=hearth_smoother_carried_target_guard
   if carried and carried.is_active() then
      local errand=self._restock_director and self._restock_director:get_errand(self._errand_id)
      local holder=errand and carried.carrier(errand.main_item)
      if holder and holder~=entity then
         ai:abort('restock target is carried by another entity');return
      end
   end
   release_field(ctx,'carried_watch')
   if not current(self,ctx) then return end
   if not self._restock_director or not self._restock_director:try_start_errand(entity,self._errand_id) then
      ai:abort('errand already taken')
      return
   end
   if not current(self,ctx) then return end
   local director=self._restock_director
   install_listener(self,ctx,'_errand_canceled_abort_listener',director,'stonehearth:restock:errand_canceled',function(id)
      if current(self,ctx) and self._restock_director==director and self._errand_id==id then ai:abort('errand canceled') end
   end)
   if current(self,ctx) then self._started=true end
end
local thinking_handles={'_errand_created_listener','_errand_canceled_reject_listener','_errand_started_reject_listener','_errand_timeout_timer'}
local running_handles={'_errand_canceled_abort_listener'}
local function detach_cleanup(self,thinking)
   -- Exact fields consumed by ACE stop_thinking/stop. Detach before give_up or
   -- native handle destruction can synchronously start a newer action epoch.
   local view={started=self._started,director=self._restock_director,id=self._errand_id,handles={}}
   for _,name in ipairs(thinking and thinking_handles or running_handles)do
      view.handles[#view.handles+1]=self[name] or false;self[name]=nil
   end
   if not thinking or not self._started then self._restock_director=nil;self._errand_id=nil end
   if not thinking then self._started=false end
   return view
end
local function cleanup_detached(view,thinking,entity)
   local failed,first_error
   local function attempt(fn,...)
      local ok,err=pcall(fn,...)
      if not ok then state.cleanup_failures=(state.cleanup_failures or 0)+1;if not failed then failed=true;first_error=err end end
   end
   if view.id and ((thinking and not view.started) or (not thinking and view.started)) then
      attempt(view.director.give_up_on_errand,view.director,entity,view.id)
   end
   for _,handle in ipairs(view.handles)do if handle then attempt(handle.destroy,handle)end end
   if failed then error(first_error,0)end
end
local function stop_thinking(self,ai,entity,args)
   local ctx=current(self);local started=self._started
   local view=detach_cleanup(self,true)
   if ctx then ctx.thinking=false end
   local ok,err=true
   if ctx and not started then ok,err=pcall(clear_context,self,ctx)
   elseif ctx then
      ok,err=pcall(function()release_field(ctx,'rebind_timer');release_field(ctx,'retirement_listener');release_field(ctx,'carried_watch')end)
   end
   local cleaned,cleanup_error=pcall(cleanup_detached,view,true,entity)
   if state.restore_pending and live_count()==0 then finish_restore() end
   if not ok then error(err,0) end;if not cleaned then error(cleanup_error,0) end
end
local function stop(self,ai,entity,args)
   local ctx=current(self);local ok,err=true
   local view=detach_cleanup(self,false)
   if ctx then ok,err=pcall(clear_context,self,ctx) end
   local cleaned,cleanup_error=pcall(cleanup_detached,view,false,entity)
   if state.restore_pending and live_count()==0 then finish_restore() end
   if not ok then error(err,0) end;if not cleaned then error(cleanup_error,0) end
end
finish_restore=function()
   if owner then for name,fn in pairs(wrappers)do if owner[name]==fn then owner[name]=original[name]end end end
   state.applied=false;state.restore_pending=false
end
function M.apply()
   if state.applied then if owns()then state.enabled=true;state.restore_pending=false;return true,M.status()end;return false,'actor ownership changed' end
   if not radiant or not radiant.mods or type(radiant.mods.require)~='function' or not debug or type(debug.getinfo)~='function' then return false,'source inspection unavailable'end
   local ok,factory=pcall(radiant.mods.require,PATH)
   local cls=ok and type(factory)=='table' and factory._base_action
   if type(cls)~='table' then state.skipped_reason='compound action base unavailable';return false,state.skipped_reason end
   for name,range in pairs(bounds)do
      local fn=cls[name];local good,info
      if type(fn)=='function'then good,info=pcall(debug.getinfo,fn,'S')end
      if not good or not info or info.source~=SOURCE or info.linedefined~=range[1] or info.lastlinedefined~=range[2] then state.skipped_reason='unsupported actor method: '..name;return false,state.skipped_reason end
   end
   if not radiant.events or type(radiant.events.listen)~='function' or type(radiant.on_game_loop_once)~='function' then return false,'actor event APIs unavailable'end
   owner=cls;original={};for name in pairs(bounds)do original[name]=cls[name]end
   wrappers={start_thinking=start_thinking,_try_take_errand=try_take,start=start,stop_thinking=stop_thinking,stop=stop}
   for name,fn in pairs(wrappers)do cls[name]=fn end
   state.applied=true;state.enabled=true;state.restore_pending=false;state.skipped_reason=nil
   return true,M.status()
end
function M.status()
   local waiting=0;for action in pairs(instances)do local ctx=current(action);if ctx and ctx.waiting then waiting=waiting+1 end end
   return {applied=state.applied,enabled=state.enabled,active=owns(),waiters=waiting,tracked_actions=live_count(),
      refreshed=state.refreshed,notices=state.notices,notice_failures=state.notice_failures,deferred=state.deferred,
      unresolved=state.unresolved,late_callbacks=state.late_callbacks,restore_pending=state.restore_pending or false,
      cleanup_failures=state.cleanup_failures or 0,
      retirement_event=EVENT,expected_source=SOURCE,skipped_reason=state.skipped_reason}
end
function M.restore()
   state.enabled=false;state.restore_pending=live_count()>0
   if not state.restore_pending then finish_restore()end
   return M.status()
end

-- Explicit read-only diagnostic. No new state, callback, or native AI probing.
function M.snapshot(options)
   local result={available=true,complete=true,scanned=0,limit=512,actors={},
      ready_output_available=false,rejection_reason_available=false,cooldown_deadline_available=false}
   if type(options)~='table' or type(options.player_id)~='string' or type(options.citizen_ids)~='table' then
      result.available=false;result.complete=false;return result
   end
   local wanted={};local n=0
   for id,yes in next,options.citizen_ids do
      n=n+1;if n>8 then result.available=false;result.complete=false;return result end
      if yes==true and (type(id)=='number' or type(id)=='string') then wanted[tostring(id)]=true end
   end
   local function scalar(v)
      if type(v)=='string' then return v:sub(1,160) end
      if type(v)=='boolean' or (type(v)=='number' and v==v and v~=math.huge and v~=-math.huge) then return v end
   end
   local function field(v,k)return type(v)=='table' and rawget(v,k) or nil end
   local action
   while true do
      action=next(instances,action);if action==nil then break end
      if result.scanned>=result.limit then result.complete=false;break end
      result.scanned=result.scanned+1
      local ctx=current(action)
      if ctx then
         local entity=ctx.entity
         local ok,id=pcall(function()if entity and entity:is_valid() then return entity:get_id() end end)
         if ok and id and wanted[tostring(id)] then
            local work_ok,work=pcall(entity.get_component,entity,'stonehearth:work_order')
            local wsv=work_ok and field(work,'_sv')
            local player=field(wsv,'working_for') or field(work,'_player_id')
            if player==options.player_id then
               local inventories=field(field(stonehearth.inventory,'_sv'),'inventories')
               local inventory=field(inventories,player)
               local kind=field(ctx.args,'type_id')
               local expected=field(field(inventory,'_restock_directors'),kind)
               result.actors[#result.actors+1]={citizen_id=scalar(id),work_player_id=scalar(player),
                  type_id=scalar(kind),live=ctx.live==true,thinking=ctx.thinking==true,waiting=ctx.waiting==true,
                  started=action._started==true,errand_id=scalar(action._errand_id),
                  bound_present=ctx.bound~=nil,bound_retired=field(ctx.bound,'_hearth_smoother_retired')==true,
                  current_director_available=expected~=nil,bound_matches_current=expected~=nil and ctx.bound==expected,
                  considered_director_matches_current=expected~=nil and action._restock_director==expected,
                  available_listener_present=action._errand_created_listener~=nil,
                  consider_timeout_present=action._errand_timeout_timer~=nil,
                  cancellation_listener_present=action._errand_canceled_reject_listener~=nil,
                  ready_output_available=false,rejection_reason_available=false,cooldown_deadline_available=false}
            end
         elseif not ok then result.complete=false end
      end
   end
   return result
end
return M

