-- Source-gated restock eligibility for actual hand-carried items. No polling.
local M={}
local DIRECTOR='stonehearth.services.server.inventory.restock_director'
local DS='@stonehearth_ace/services/server/inventory/restock_director.lua'
local CARRY='stonehearth.components.carry_block.carry_block_component'
local CS='@stonehearth_ace/monkey_patches/ace_carry_block_component.lua'
local state={applied=false,skipped=0,reconsidered=0,drop_notices=0,rejected=0,cleanup_failures=0}
local pending=setmetatable({}, {__mode='k'}) -- one loop, weak item keys only
local loop,carry_class,original_set,original_remove,set_wrapper,remove_wrapper
local original_take,original_valid
local function release(handle)
   local ok,err=pcall(handle.destroy,handle)
   if not ok then state.cleanup_failures=state.cleanup_failures+1;error(err,0)end
end
local function inspect(fn,source,first,last)
   if type(fn)~='function' then return false end
   local ok,info=pcall(debug.getinfo,fn,'S')
   return ok and info.source==source and info.linedefined==first and info.lastlinedefined==last
end
local function carrier(item,get_parent,get_carrying)
   if not item or not item:is_valid() then return nil end
   local parent=get_parent(item)
   if parent and parent:is_valid() and get_carrying(parent)==item then return parent end
end
function M.carrier(item)
   return carrier(item,radiant.entities.get_parent,radiant.entities.get_carrying)
end
function M.wrap_filter(base,get_parent,get_carrying)
   return function(item,...)
      if carrier(item,get_parent,get_carrying) then return false end
      return base(item,...)
   end
end
local function drain()
   loop=nil
   local batch=pending;pending=setmetatable({}, {__mode='k'})
   local notified={}
   for item in pairs(batch)do
      if item:is_valid() then
         local inventory=stonehearth.inventory:get_inventory(item)
         local directors=inventory and inventory._restock_directors
         local types=stonehearth.constants.inventory.restock_director.types
         -- A carry transition can end in private storage, not just on ground.
         -- Expire only this main item's pending errand validation before waking.
         for _,kind in ipairs({types.RESTOCK,types.INPUT_BIN})do
            local director=directors and directors[kind]
            local id=director and director._covered_items and director._covered_items[item:get_id()]
            local errand=id and not director._hearth_smoother_retired and director._errands and director._errands[id]
            if errand and errand.main_item==item and (not errand.executor or errand.lease_expiry)then
               director._errand_last_validated[id]=nil
            end
         end
         stonehearth.ai:reconsider_entity(item,'hand-carry transition')
         state.reconsidered=state.reconsidered+1
         if not M.carrier(item) then
            for _,kind in ipairs({types.RESTOCK,types.INPUT_BIN})do
               local director=directors and directors[kind]
               local id=director and director._covered_items and director._covered_items[item:get_id()]
               local errand=id and not director._hearth_smoother_retired and director._errands and director._errands[id]
               if errand and errand.main_item==item and (not errand.executor or errand.lease_expiry)
                  and director._is_restockable_predicate(item)then
                  if not notified[director] then
                     notified[director]=true
                     radiant.events.trigger_async(director,'stonehearth:restock:errand_available',id)
                     state.drop_notices=state.drop_notices+1
                  end
               end
            end
         end
      end
   end
end
local function reconsider_later(item)
   if not item or not item:is_valid() then return end
   pending[item]=true
   if loop then return end
   local fired=false
   local handle=radiant.on_game_loop_once('hand-carry eligibility changed',function()fired=true;drain()end)
   if not fired then loop=handle elseif handle then release(handle)end
end
-- Exact ACE validity checks (940--960), with the uncensored base predicate only
-- for a running executor carrying its own main item. Never unconditional true.
local function running_self_valid(self,id,errand)
   local last=rawget(self,'_errand_last_validated')
   local timestamp=rawget(last,id)
   local now=radiant.gamestate.now()
   if timestamp and now-timestamp<=stonehearth.constants.inventory.restock_director.ERRAND_VALIDITY_CACHE_EXPIRY_SEC then return true end
   local item=rawget(errand,'main_item');local storage=rawget(errand,'storage')
   local ai=stonehearth.ai;local fast=ai.fast_call_filter_fn
   local result=fast(ai,self._hearth_smoother_base_restock_predicate,item)
      and self:_are_reachable(item,storage)
      and self._storage_filters[storage:get_id()]==rawget(errand,'filter_key')
      and fast(ai,rawget(errand,'filter_fn'),item)
   if result then rawset(last,id,now)end
   return result
end
-- ACE take 141--189: only pre-validation carried exclusion and running-self
-- base predicate choice differ. Other eligibility/scoring/lease semantics stay.
local function take(self,entity,maybe_errand_id)
   if self._hearth_smoother_retired then return end
   local entity_location=radiant.entities.get_world_location(entity)
   local best_errand_id,best_score
   local consider_errand=function(id,errand)
      local is_leased=errand.executor and errand.executor~=entity and (not errand.lease_expiry or errand.lease_expiry>radiant.gamestate.now())
      if not is_leased then
         local holder=M.carrier(errand.main_item)
         local running_self=holder==entity and errand.executor==entity and not errand.lease_expiry
         if holder and not running_self then
            state.skipped=state.skipped+1;return
         end
         local valid
         if running_self then valid=running_self_valid(self,id,errand) else valid=self:_is_errand_valid(id,errand)end
         if valid then
            if self:_are_reachable(errand.main_item,entity)then
               local score=self:_rate_errand_for_entity_location(errand,entity_location)
               if not best_errand_id or score>best_score then best_errand_id=id;best_score=score end
            end
         else self:_on_errand_failed(id)end
      end
   end
   if maybe_errand_id then
      local errand=self._errands[maybe_errand_id]
      if not errand then return nil end
      consider_errand(maybe_errand_id,errand)
   else for id,errand in pairs(self._errands)do consider_errand(id,errand)end end
   if best_errand_id then
      local errand=self._errands[best_errand_id]
      errand.executor=entity
      errand.lease_expiry=radiant.gamestate.now()+stonehearth.constants.inventory.restock_director.ERRAND_CONSIDER_LEASE_DURATION_MS
      return best_errand_id,errand,best_score
   end
end
function M.bind_director(self,base)
   assert(state.applied and inspect(self.take_errand_to_consider,DS,141,189)
      and inspect(self._is_errand_valid,DS,940,960),'unsupported carried-target director')
   self._hearth_smoother_base_restock_predicate=base
   self.take_errand_to_consider=take
end
-- One parent trace per held, not-yet-started candidate. Caller fences its epoch.
function M.watch_candidate(item,actor,reject)
   local mob=item and item:is_valid() and item:get_component('mob')
   if not mob then return nil end
   local watch={live=true,item=item,actor=actor,reject=reject}
   function watch:destroy()
      if not self.live then return end
      self.live=false
      local trace,timer=self.trace,self.timer
      self.trace,self.timer,self.item,self.actor,self.reject=nil,nil,nil,nil,nil
      local ok,err=true
      if trace then ok,err=pcall(release,trace)end
      local ok2,err2=true
      if timer then ok2,err2=pcall(release,timer)end
      if not ok then error(err,0)end;if not ok2 then error(err2,0)end
   end
   local function notify(parent)
      if not watch.live then return end
      -- SYNC_TRACE supplies the authoritative parent transition even if the
      -- mob getter has not published its new value during the callback yet.
      local holder
      if parent and parent:is_valid() and radiant.entities.get_carrying(parent)==watch.item then holder=parent
      else holder=M.carrier(watch.item)end
      if holder and holder~=watch.actor then watch.saw_other_carrier=true end
      if watch.timer then return end
      local fired=false
      local timer=radiant.on_game_loop_once('restock candidate carrier changed',function()
         fired=true;if not watch.live then return end;watch.timer=nil
         local holder=M.carrier(watch.item)
         if watch.saw_other_carrier or (holder and holder~=watch.actor)then
            local callback=watch.reject;watch:destroy();state.rejected=state.rejected+1;callback()
         end
      end)
      if watch.live and not fired then watch.timer=timer elseif timer then release(timer)end
   end
   local ok,err=pcall(function()
      local trace=mob:trace_parent('restock candidate carrier',_radiant.dm.TraceCategories.SYNC_TRACE)
      if watch.live then watch.trace=trace else release(trace);return end
      trace:on_changed(notify)
      notify() -- closes initial check/registration race
   end)
   if not ok then pcall(watch.destroy,watch);error(err,0)end
   return watch
end
function M.apply()
   if state.applied then return true,M.status()end
   local director=radiant.mods.require(DIRECTOR);local carry=radiant.mods.require(CARRY)
   if not inspect(director.take_errand_to_consider,DS,141,189) or not inspect(director._is_errand_valid,DS,940,960)
      or not inspect(carry.set_carrying,CS,7,63) or not inspect(carry._remove_carrying,CS,66,76)
      or not inspect(radiant.entities.get_parent,'@radiant/modules/entities.lua',170,173)
      or not inspect(radiant.entities.get_carrying,'@radiant/modules/entities.lua',736,742)
      or type(stonehearth.ai.reconsider_entity)~='function' or type(radiant.on_game_loop_once)~='function'
      or not _radiant.dm.TraceCategories.SYNC_TRACE then return false,'unsupported carried-target sources/APIs'end
   original_take,original_valid=director.take_errand_to_consider,director._is_errand_valid
   carry_class=carry;original_set,original_remove=carry.set_carrying,carry._remove_carrying
   set_wrapper=function(self,item,...)
      local old=self:get_carrying();original_set(self,item,...)
      local new=self:get_carrying()
      if old~=new then reconsider_later(old);reconsider_later(new)end
   end
   remove_wrapper=function(self,...)
      local old=self:get_carrying();original_remove(self,...)
      if old~=self:get_carrying() then reconsider_later(old)end
   end
   carry.set_carrying,carry._remove_carrying=set_wrapper,remove_wrapper
   state.applied=true;return true,M.status()
end
function M.status()
   local waiting=0
   for _ in pairs(pending)do waiting=waiting+1 end
   return {applied=state.applied,active=state.applied and carry_class.set_carrying==set_wrapper and carry_class._remove_carrying==remove_wrapper,
      skipped=state.skipped,reconsidered=state.reconsidered,drop_notices=state.drop_notices,rejected=state.rejected,
      pending_items=waiting,cleanup_failures=state.cleanup_failures,restore_mode='restart required',
      rejected_semantics='other-carrier callback attempts; actor epoch may suppress stale attempts'}
end
function M.is_active()
   return state.applied and carry_class.set_carrying==set_wrapper and carry_class._remove_carrying==remove_wrapper
end
return M

