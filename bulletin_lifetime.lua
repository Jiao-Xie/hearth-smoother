-- Retire exact board references before bulletin controller teardown.
-- Unknown malformed objects and real setter/cleanup errors remain visible.
local M={}
local SERVICE_PATH='stonehearth.services.server.bulletin_board.bulletin_board_service'
local BULLETIN_PATH='stonehearth.services.server.bulletin_board.bulletin'
local SERVICE_SOURCE='@stonehearth/services/server/bulletin_board/bulletin_board_service.lua'
local BULLETIN_SOURCE='@stonehearth/services/server/bulletin_board/bulletin.lua'
local ACE_CLASS_SOURCE='@stonehearth_ace/radiant/lib/unclasslib.lua'
local state={applied=false,generation=0,mark_calls=0,marked=0,missing=0,stale_ignored=0,
   unlink_attempts=0,unlinked=0,unlinked_slots=0,unlink_failures=0,
   destroy_attempts=0,destroyed=0,destroy_failures=0,duplicate_destroys=0,
   orphan_checks=0,orphan_entries_removed=0,sweep_attempts=0,sweep_runs=0,
   sweep_removed=0,sweep_failures=0,sweep_completed=false,sweep_running=false}
local board_class,bulletin_class,original_mark,original_destroy,mark_wrapper,destroy_wrapper
local destroy_slot,outer_destroy
local retired=setmetatable({}, {__mode='k'}) -- boolean values; no retained controllers
local gate_diagnostics={}

local function inspect(name,fn,source,first,last)
   local prefix='gate_'..name..'_'
   local ok,info=false,nil
   if type(fn)=='function' then ok,info=pcall(debug.getinfo,fn,'S') end
   local inspected=ok and type(info)=='table'
   local matches=inspected and info.source==source and info.linedefined==first and info.lastlinedefined==last
   gate_diagnostics[prefix..'type']=type(fn)
   gate_diagnostics[prefix..'inspection_ok']=not not inspected
   gate_diagnostics[prefix..'source']=inspected and type(info.source)=='string' and info.source or ''
   gate_diagnostics[prefix..'what']=inspected and type(info.what)=='string' and info.what or ''
   gate_diagnostics[prefix..'linedefined']=inspected and type(info.linedefined)=='number' and info.linedefined or -1
   gate_diagnostics[prefix..'lastlinedefined']=inspected and type(info.lastlinedefined)=='number' and info.lastlinedefined or -1
   gate_diagnostics[prefix..'matches']=not not matches
   return matches
end
local function owns()
   return state.applied and board_class.mark_shown==mark_wrapper
      and bulletin_class[destroy_slot]==destroy_wrapper
      and (destroy_slot~='__user_destroy' or bulletin_class.destroy==outer_destroy)
end
local function known_dead(bulletin)
   if type(bulletin)~='table' then return false end
   if retired[bulletin] or rawget(bulletin,'__destroyed')==true then return true end
   local tracking=rawget(bulletin,'__lifetime_tracking')
   return type(tracking)=='table' and (rawget(tracking,'destroyed')==true or rawget(tracking,'is_destroyed')==true)
end
local function is_datastore(value)
   return type(value)=='userdata' and radiant.util.is_datastore(value)==true
end
local function is_orphan(bulletin,id)
   if type(id)~='number' or not is_datastore(bulletin) then return false end
   state.orphan_checks=state.orphan_checks+1
   -- A native datastore reference can outlive its Lua controller. Require the
   -- proven datastore contract, exact controller name and matching saved ID.
   local get_controller=bulletin.get_controller
   if type(get_controller)~='function' or get_controller(bulletin)~=nil then return false end
   local get_name=bulletin.get_controller_name
   if type(get_name)~='function' or get_name(bulletin)~='stonehearth:bulletin' then return false end
   local get_data=bulletin.get_data
   if type(get_data)~='function' then return false end
   local data=get_data(bulletin)
   return type(data)=='table' and rawget(data,'id')==id
end
local function same_bulletin(candidate,bulletin,saved)
   return candidate==bulletin or (saved~=nil and candidate==saved)
end
local function unlink(board,id,bulletin)
   state.unlink_attempts=state.unlink_attempts+1
   -- Use only already-existing board storage; never allocate a player's datastore
   -- during destruction, and never remove a different object that reused the id.
   if not board or type(id)~='number' then return end
   local sv=board._sv
   if type(sv)~='table' or type(sv.bulletin_to_player_map)~='table' or type(sv.datastores)~='table' then return end
   local player=sv.bulletin_to_player_map[id]
   local datastore=player and sv.datastores[player]
   if not datastore then return end
   local data=datastore:get_data()
   if type(data)~='table' or type(data.alerts)~='table' or type(data.bulletins)~='table' then return end
   local saved=type(bulletin)=='table' and rawget(bulletin,'__saved_variables')
   if not is_datastore(saved) then saved=nil end
   local normal,alert=same_bulletin(data.bulletins[id],bulletin,saved),same_bulletin(data.alerts[id],bulletin,saved)
   if not normal and not alert then return end
   if normal then data.bulletins[id]=nil;state.unlinked_slots=state.unlinked_slots+1 end
   if alert then data.alerts[id]=nil;state.unlinked_slots=state.unlinked_slots+1 end
   -- A different object in the other slot still owns its player mapping.
   if data.bulletins[id]==nil and data.alerts[id]==nil and sv.bulletin_to_player_map[id]==player then
      sv.bulletin_to_player_map[id]=nil
   end
   state.unlinked=state.unlinked+1
   datastore:mark_changed()
   board.__saved_variables:mark_changed()
   return true
end
function M.apply()
   if state.applied then
      if owns() then return true,M.status() end
      return false,'bulletin method ownership changed'
   end
   if not radiant or not radiant.mods or type(radiant.mods.require)~='function'
      or not radiant.util or type(radiant.util.is_datastore)~='function'
      or not debug or type(debug.getinfo)~='function' then
      state.skipped_reason='module/source inspection unavailable';return false,state.skipped_reason
   end
   local ok,service=pcall(radiant.mods.require,SERVICE_PATH)
   local ok2,bulletin=pcall(radiant.mods.require,BULLETIN_PATH)
   if not ok or not ok2 or type(service)~='table' or type(bulletin)~='table' then
      state.skipped_reason='bulletin classes unavailable';return false,state.skipped_reason
   end
   local checks={
      {'service_mark_shown',service.mark_shown,SERVICE_SOURCE,158,164},
      {'service_get_bulletin',service.get_bulletin,SERVICE_SOURCE,131,139},
      {'service_remove_bulletin',service.remove_bulletin,SERVICE_SOURCE,101,129},
      {'service_add_bulletin',service._add_bulletin,SERVICE_SOURCE,200,216},
      {'controller_set_shown',bulletin.set_shown,BULLETIN_SOURCE,58,61}}
   local failures={}
   gate_diagnostics={}
   for _,check in ipairs(checks) do
      if not inspect(unpack(check)) then failures[#failures+1]=check[1] end
   end
   local selected_slot='destroy'
   local direct=inspect('controller_destroy',bulletin.destroy,BULLETIN_SOURCE,31,34)
   if not direct then
      selected_slot='__user_destroy'
      local mt=getmetatable(bulletin)
      local ace_outer=inspect('ace_destroy',bulletin.destroy,ACE_CLASS_SOURCE,285,295)
      local ace_assignment=inspect('ace_class_assignment',type(mt)=='table' and mt.__newindex,ACE_CLASS_SOURCE,112,135)
      local user_destroy=inspect('controller_user_destroy',rawget(bulletin,'__user_destroy'),BULLETIN_SOURCE,31,34)
      if not ace_outer then failures[#failures+1]='ace_destroy' end
      if not ace_assignment then failures[#failures+1]='ace_class_assignment' end
      if not user_destroy then failures[#failures+1]='controller_user_destroy' end
   end
   gate_diagnostics.gate_failures=table.concat(failures,',')
   if #failures>0 then
      state.skipped_reason='unsupported bulletin source: '..gate_diagnostics.gate_failures
      return false,state.skipped_reason
   end
   board_class,bulletin_class=service,bulletin
   destroy_slot=selected_slot
   outer_destroy=bulletin.destroy
   original_mark,original_destroy=service.mark_shown,bulletin[destroy_slot]
   state.generation=state.generation+1
   local generation=state.generation
   local captured_mark,captured_destroy=original_mark,original_destroy
   mark_wrapper=function(self,id,...)
      if not state.applied or generation~=state.generation then return captured_mark(self,id,...) end
      state.mark_calls=state.mark_calls+1
      local value=self:get_bulletin(id) -- exactly one lookup, matching stock
      if not value then state.missing=state.missing+1;return end
      local orphan=is_orphan(value,id)
      if known_dead(value) or orphan then
         state.stale_ignored=state.stale_ignored+1
         local ok,removed=pcall(unlink,self,id,value)
         if not ok then state.unlink_failures=state.unlink_failures+1;error(removed,0) end
         if orphan and removed then state.orphan_entries_removed=state.orphan_entries_removed+1 end
         return
      end
      value:set_shown(true) -- no protected call or fallback for unknown objects
      state.marked=state.marked+1
   end
   destroy_wrapper=function(self,...)
      if not state.applied or generation~=state.generation then return captured_destroy(self,...) end
      if retired[self] then state.duplicate_destroys=state.duplicate_destroys+1;return end
      retired[self]=true
      state.destroy_attempts=state.destroy_attempts+1
      local sv=rawget(self,'_sv')
      local id=type(sv)=='table' and rawget(sv,'id')
      local board=stonehearth and stonehearth.bulletin_board
      local unlinked,unlink_error=pcall(unlink,board,id,self)
      if not unlinked then state.unlink_failures=state.unlink_failures+1 end
      -- Controller resources must still be released if board notification throws.
      local destroyed,destroy_error=pcall(captured_destroy,self,...)
      if destroyed then state.destroyed=state.destroyed+1
      else state.destroy_failures=state.destroy_failures+1 end
      if not unlinked then error(unlink_error,0) end
      if not destroyed then error(destroy_error,0) end
   end
   service.mark_shown=mark_wrapper
   -- ACE caches its factory destroy method and dynamically dispatches this hook.
   -- Keep its death flag and base destruction chain intact; never capture the
   -- outer factory method as the hook's original (which would recurse).
   bulletin[destroy_slot]=destroy_wrapper
   state.applied=true;state.skipped_reason=nil
   return true,M.status()
end
function M.sweep_orphans()
   state.sweep_attempts=state.sweep_attempts+1
   if not owns() then return false,'bulletin guard inactive' end
   if state.sweep_completed then return true,M.status() end
   if state.sweep_running then return false,'bulletin sweep already running' end
   local board=stonehearth and stonehearth.bulletin_board
   local sv=board and board._sv
   if type(sv)~='table' or sv.initialized~=true or type(sv.datastores)~='table'
      or type(sv.bulletin_to_player_map)~='table' then
      return false,'bulletin board not ready'
   end
   state.sweep_running=true
   state.sweep_runs=state.sweep_runs+1
   local ok,result=pcall(function()
      local entries={}
      for player,datastore in pairs(sv.datastores) do
         local data=datastore:get_data()
         if type(data)~='table' or type(data.bulletins)~='table' or type(data.alerts)~='table' then
            return false
         end
         for _,slots in ipairs({data.bulletins,data.alerts}) do
            for id,value in pairs(slots) do
               if sv.bulletin_to_player_map[id]==player then
                  entries[#entries+1]={id=id,value=value}
               end
            end
         end
      end
      for _,entry in ipairs(entries) do
         if is_orphan(entry.value,entry.id) then
            local removed_ok,removed=pcall(unlink,board,entry.id,entry.value)
            if not removed_ok then state.unlink_failures=state.unlink_failures+1;error(removed,0) end
            if removed then
               state.orphan_entries_removed=state.orphan_entries_removed+1
               state.sweep_removed=state.sweep_removed+1
            end
         end
      end
      return true
   end)
   state.sweep_running=false
   if not ok then state.sweep_failures=state.sweep_failures+1;error(result,0) end
   if not result then return false,'bulletin datastores not ready' end
   state.sweep_completed=true
   return true,M.status()
end
function M.status()
   local result={applied=state.applied,active=owns(),generation=state.generation,skipped_reason=state.skipped_reason,
      mark_calls=state.mark_calls,marked=state.marked,missing=state.missing,stale_ignored=state.stale_ignored,
      unlink_attempts=state.unlink_attempts,unlinked=state.unlinked,unlinked_slots=state.unlinked_slots,
      unlink_failures=state.unlink_failures,destroy_attempts=state.destroy_attempts,destroyed=state.destroyed,
      destroy_failures=state.destroy_failures,duplicate_destroys=state.duplicate_destroys,
      orphan_checks=state.orphan_checks,orphan_entries_removed=state.orphan_entries_removed,
      sweep_attempts=state.sweep_attempts,sweep_runs=state.sweep_runs,sweep_removed=state.sweep_removed,
      sweep_failures=state.sweep_failures,sweep_completed=state.sweep_completed,sweep_running=state.sweep_running,
      expected_service_source=SERVICE_SOURCE,expected_bulletin_source=BULLETIN_SOURCE,
      destroy_hook=destroy_slot or '',expected_ace_class_source=ACE_CLASS_SOURCE}
   for key,value in pairs(gate_diagnostics) do result[key]=value end
   return result
end
function M.restore()
   if board_class and board_class.mark_shown==mark_wrapper then board_class.mark_shown=original_mark end
   if bulletin_class and bulletin_class[destroy_slot]==destroy_wrapper then bulletin_class[destroy_slot]=original_destroy end
   state.applied=false;state.generation=state.generation+1
   return M.status()
end
return M

