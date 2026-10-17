-- Event-driven wake for stock WaitUntilReachable. No periodic polling and no
-- permissive reachability fallback. This candidate is not installed by itself.
local M={}
local PATH='stonehearth.ai.actions.wait_until_reachable'
local SOURCE='@stonehearth/ai/actions/wait_until_reachable.lua'
local FIELD='_hearth_smoother_reachability_wait'
local GENERATION='_hearth_smoother_reachability_generation'
local ranges={start_thinking={12,28},stop={30,36},stop_thinking={38,43}}
local state={applied=false,enabled=true,checks=0,events=0,coalesced=0,completed=0,invalidated=0,cleanup_failures=0}
local notify_counts={topology=0,actor_move=0,target_move=0,initial=0}
local wakes={}
local waits=setmetatable({}, {__mode='k'})
local owner,original,wrappers
local finish_restore
local function current(self,ctx)return self[FIELD]==ctx and ctx.live end
local function count()local n=0;for _ in pairs(waits)do n=n+1 end;return n end
local function cleanup(self,ctx)
   if not ctx or not ctx.live then return end
   ctx.live=false
   if self[FIELD]==ctx then self[FIELD]=nil;waits[self]=nil end
   local handles={ctx.pending or false,ctx.guard or false,ctx.actor_trace or false,ctx.target_trace or false}
   ctx.pending,ctx.guard,ctx.actor_trace,ctx.target_trace=nil,nil,nil,nil
   ctx.ai,ctx.actor,ctx.target=nil,nil,nil
   local first_error,failed
   for _,handle in ipairs(handles)do if handle then
      local ok,err=pcall(handle.destroy,handle)
      if not ok then state.cleanup_failures=state.cleanup_failures+1;if not failed then first_error=err;failed=true end end
   end end
   if state.restore_pending and count()==0 then finish_restore()end
   if failed then error(first_error,0)end
end
local function install(self,ctx,name,handle)
   if current(self,ctx)then ctx[name]=handle elseif handle then handle:destroy()end
end
local function check(self,ctx,reason)
   if not current(self,ctx)then return end
   local ai,actor,target=ctx.ai,ctx.actor,ctx.target
   if not actor:is_valid() or not target:is_valid() then
      cleanup(self,ctx)
      if self[GENERATION]~=ctx.generation then return end
      state.invalidated=state.invalidated+1
      ai:reject();return
   end
   state.checks=state.checks+1
   local connected=_radiant.sim.topology.are_connected(actor,target)
   if not current(self,ctx)then return end
   if connected then
      local function id(entity)
         local ok,value=pcall(entity.get_id,entity)
         if ok and type(value)=='number' and value==value and value~=math.huge and value~=-math.huge then return value end
         if ok and type(value)=='string' then return value:sub(1,160)end
      end
      local record={actor_id=id(actor),target_id=id(target),reason=reason,initial_connected=false}
      cleanup(self,ctx)
      if self[GENERATION]~=ctx.generation then return end
      state.completed=state.completed+1
      if #wakes==16 then table.remove(wakes,1)end
      wakes[#wakes+1]=record
      ai:set_think_output({})
   end
end
local function notify(self,ctx,reason)
   if not current(self,ctx)then return end
   state.events=state.events+1
   notify_counts[reason]=notify_counts[reason]+1
   ctx.pending_reasons=ctx.pending_reasons or {};ctx.pending_reasons[reason]=true
   if ctx.pending then state.coalesced=state.coalesced+1;return end
   local fired=false
   local handle=radiant.on_game_loop_once('reachability event wake',function()
      fired=true
      if not current(self,ctx)then return end
      ctx.pending=nil
      local reasons={}
      for _,name in ipairs({'topology','actor_move','target_move','initial'})do
         if ctx.pending_reasons and ctx.pending_reasons[name]then reasons[#reasons+1]=name end
      end
      ctx.pending_reasons=nil
      check(self,ctx,table.concat(reasons,'+'))
   end)
   if not fired then install(self,ctx,'pending',handle) elseif handle then handle:destroy()end
end
local function start_thinking(self,ai,entity,args)
   local generation={};self[GENERATION]=generation
   if not state.enabled then return original.start_thinking(self,ai,entity,args)end
   local prior=self[FIELD];if prior then cleanup(self,prior)end
   if self[GENERATION]~=generation then return end
   -- Preserve the normal already-connected fast path without any new trace.
   local connected=_radiant.sim.topology.are_connected(entity,args.entity)
   if self[GENERATION]~=generation then return end
   if connected then ai:set_think_output({});return end
   -- The source-confirmed trace helper calls add_component internally. Require
   -- existing mob components before invoking it, avoiding component creation.
   if not entity:get_component('mob') or not args.entity:get_component('mob')then
      return original.start_thinking(self,ai,entity,args)
   end
   local ctx={live=true,ai=ai,actor=entity,target=args.entity,generation=generation};self[FIELD]=ctx;waits[self]=true
   local ok,err=pcall(function()
      local guard=_radiant.sim.topology.on_topology_processed(0,function()notify(self,ctx,'topology')end)
      install(self,ctx,'guard',guard)
      if not current(self,ctx)then return end
      local actor_trace=radiant.entities.trace_grid_location(entity,'reachability actor wake')
      install(self,ctx,'actor_trace',actor_trace)
      if not current(self,ctx)then return end
      actor_trace:on_changed(function()notify(self,ctx,'actor_move')end)
      if not current(self,ctx)then return end
      local target_trace=radiant.entities.trace_grid_location(args.entity,'reachability target wake')
      install(self,ctx,'target_trace',target_trace)
      if not current(self,ctx)then return end
      target_trace:on_changed(function()notify(self,ctx,'target_move')end)
      -- One event-loop check closes initial-check/registration races, including
      -- a synchronous topology callback before its returned handle is assigned.
      notify(self,ctx,'initial')
   end)
   if not ok then pcall(cleanup,self,ctx);error(err,0)end
end
local function stop_thinking(self,ai,entity,args)
   self[GENERATION]=nil
   local ctx=self[FIELD]
   if ctx then cleanup(self,ctx)end
   return original.stop_thinking(self,ai,entity,args)
end
local function stop(self,ai,entity,args)
   self[GENERATION]=nil
   local ctx=self[FIELD]
   if ctx then cleanup(self,ctx)end
   return original.stop(self,ai,entity,args)
end
local function owns()
   if not state.applied or not owner then return false end
   for name,fn in pairs(wrappers)do if owner[name]~=fn then return false end end
   return true
end
finish_restore=function()
   if owner then for name,fn in pairs(wrappers)do if owner[name]==fn then owner[name]=original[name]end end end
   state.applied=false;state.restore_pending=false
end
function M.apply()
   if state.applied then return owns(),M.status()end
   if not radiant or not radiant.mods or type(radiant.mods.require)~='function' or not debug or type(debug.getinfo)~='function' then
      return false,'source inspection unavailable'
   end
   if not radiant.entities or type(radiant.entities.trace_grid_location)~='function' or type(radiant.on_game_loop_once)~='function'
      or not _radiant or not _radiant.sim or not _radiant.sim.topology
      or type(_radiant.sim.topology.are_connected)~='function' or type(_radiant.sim.topology.on_topology_processed)~='function' then
      return false,'reachability APIs unavailable'
   end
   local ok,cls=pcall(radiant.mods.require,PATH)
   if not ok or type(cls)~='table'then return false,'wait action unavailable'end
   for name,range in pairs(ranges)do
      local fn=cls[name];local good,info=pcall(debug.getinfo,fn,'S')
      if type(fn)~='function' or not good or info.source~=SOURCE or info.linedefined~=range[1] or info.lastlinedefined~=range[2]then
         return false,'unsupported wait method: '..name
      end
   end
   owner=cls;original={};for name in pairs(ranges)do original[name]=cls[name]end
   wrappers={start_thinking=start_thinking,stop=stop,stop_thinking=stop_thinking}
   for name,fn in pairs(wrappers)do cls[name]=fn end
   state.applied=true;state.enabled=true;return true,M.status()
end
function M.status()
   local counts={};for name,n in pairs(notify_counts)do counts[name]=n end
   local recent={};for i,row in ipairs(wakes)do
      recent[i]={actor_id=row.actor_id,target_id=row.target_id,reason=row.reason,initial_connected=row.initial_connected}
   end
   return {applied=state.applied,active=owns(),enabled=state.enabled,active_waits=count(),checks=state.checks,
      events=state.events,coalesced=state.coalesced,completed=state.completed,invalidated=state.invalidated,
      cleanup_failures=state.cleanup_failures,restore_pending=state.restore_pending or false,
      notify_counts=counts,recent_wakes=recent,wake_record_limit=16}
end
function M.restore()
   state.enabled=false;state.restore_pending=count()>0
   if not state.restore_pending then finish_restore()end
   return M.status()
end
return M

