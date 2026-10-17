-- Runtime director retirement. No native cache unregister or saved fields.
local M = {}
local PATH = 'stonehearth.services.server.inventory.restock_director'
local SOURCE = '@stonehearth_ace/services/server/inventory/restock_director.lua'
local state = {applied=false, retired=0, native_destroys=0, canceled_errands=0,
   listeners_destroyed=0, leases_destroyed=0, native_handles_destroyed=0, anchors_destroyed=0,
   pending_leases_created=0, pending_leases_released=0}
local owner
local integrated_slice
local retired_alive=setmetatable({}, {__mode='k'})
local bounds = {
   destroy={113,135}, _ensure_stopped={366,392}, _destroy_should_restock_status_trackers={265,272},
   get_errand={137,139}, take_errand_to_consider={141,189}, give_up_on_errand={191,198},
   mark_errand_failed={200,204}, try_start_errand={207,222}, finish_errand={275,308},
   has_items_in_queue={310,313}, _ensure_started={319,364},
   _mark_ready_to_generate_new_errands={394,401}, _on_item_added={404,436},
   _on_storage_added={438,505}, _on_storage_removed={507,527}, _on_storage_filter_changed={529,538},
   _transfer_reconsider_items_into_restockable_queue={540,557},
   _transfer_failed_items_into_reconsider_queues={559,575}, _request_process_failed_items={577,604},
   _get_next_restockable_item={611,694}, _generate_next_errand={743,857},
   _on_errand_failed={909,938}, _track_should_restock_status={224,263},
   set_item_quality={1326,1331}, set_should_restock={1333,1338},
   _is_higher_priority_for_item={888,907}, _is_errand_valid={940,960},
   _is_storage_higher_priority_for_item={861,886}, _are_reachable={1189,1215},
   _eval_item_for_restocking={696,740}, _rate_item={980,1057},
   _rate_storage_for_item={1062,1090}, _rate_errand={971,977},
   _rate_errand_for_entity_location={962,969}
}
local blocked_late_calls=0
local function noop() blocked_late_calls=blocked_late_calls+1 end
local function no() blocked_late_calls=blocked_late_calls+1;return false end
local function fence(self)
   for name in pairs(bounds) do
      if name ~= '_ensure_stopped' and name ~= '_destroy_should_restock_status_trackers' then self[name] = noop end
   end
   self.try_start_errand, self.has_items_in_queue = no, no
end
function M.status()
   local alive=0;for _ in pairs(retired_alive) do alive=alive+1 end
   local integrated=integrated_slice and integrated_slice.retirement_ready() or false
   return {applied=state.applied, active=state.applied and integrated, integrated=integrated, expected_source=SOURCE,
      skipped_reason=state.skipped_reason, retired=state.retired, retired_total=state.retired,
      retired_alive=alive, blocked_late_calls=blocked_late_calls, native_destroys=state.native_destroys,
      canceled_errands=state.canceled_errands, listeners_destroyed=state.listeners_destroyed,
      native_handles_destroyed=state.native_handles_destroyed, anchors_destroyed=state.anchors_destroyed,
      unmanaged_stock_destroys=state.unmanaged_stock_destroys or 0,
      retirement_notice_attempts=state.retirement_notice_attempts or 0,
      retirement_notices=state.retirement_notices or 0, retirement_notice_failures=state.retirement_notice_failures or 0,
      leases_destroyed=state.leases_destroyed, pending_leases_created=state.pending_leases_created,
      pending_leases_released=state.pending_leases_released,
      release_attempts=state.release_attempts or 0, release_failures=state.release_failures or 0,
      native_destroy_attempts=state.native_destroy_attempts or 0, native_destroy_failures=state.native_destroy_failures or 0,
      cancellation_attempts=state.cancellation_attempts or 0, cancellation_failures=state.cancellation_failures or 0,
      restore_mode='retirement safety hooks require process restart to remove'}
end
function M.apply()
   if state.applied then return true, M.status() end
   if not radiant or not radiant.mods or type(radiant.mods.require) ~= 'function'
      or not debug or type(debug.getinfo) ~= 'function' then
      state.skipped_reason='source inspection unavailable'; return false,state.skipped_reason
   end
   local ok,cls=pcall(radiant.mods.require,PATH)
   if not ok or type(cls) ~= 'table' then state.skipped_reason='director unavailable';return false,state.skipped_reason end
   for name,range in pairs(bounds) do
      local fn=cls[name]
      local inspected,info
      if type(fn)=='function' then inspected,info=pcall(debug.getinfo,fn,'S') end
      if not inspected or info.source~=SOURCE or info.linedefined~=range[1] or info.lastlinedefined~=range[2] then
         state.skipped_reason='unsupported director source: '..name;return false,state.skipped_reason
      end
   end
   if not radiant.events or type(radiant.events.trigger_async)~='function'
      or not radiant.entities or type(radiant.entities.destroy_entity)~='function' then
      state.skipped_reason='cancellation event API unavailable';return false,state.skipped_reason
   end
   owner=cls;state.applied=true;state.skipped_reason=nil;return true,M.status()
end
function M.is_active() return state.applied end
function M.register_slice(module)
   assert(type(module)=='table' and type(module.retirement_ready)=='function','invalid slice integration')
   integrated_slice=module
end
function M.track_pending_lease(self,lease)
   assert(lease and type(lease.destroy)=='function','restock initial lease unavailable')
   assert(not self._hearth_smoother_pending_lease,'duplicate pending restock lease')
   local token={lease=lease,owner=self}
   self._hearth_smoother_pending_lease=token
   state.pending_leases_created=state.pending_leases_created+1
   if self._hearth_smoother_retired then M.release_pending_lease(token) end
   return token
end
function M.release_pending_lease(token)
   if not token or not token.lease then return end
   local lease,self=token.lease,token.owner
   token.lease,token.owner=nil,nil
   if self and self._hearth_smoother_pending_lease==token then self._hearth_smoother_pending_lease=nil end
   state.release_attempts=(state.release_attempts or 0)+1
   local ok,err=pcall(lease.destroy,lease)
   if not ok then state.release_failures=(state.release_failures or 0)+1;error(err,0) end
   state.pending_leases_released=state.pending_leases_released+1
   state.leases_destroyed=state.leases_destroyed+1
end
function M.with_destroy(self,original,...)
   if self._hearth_smoother_retired then blocked_late_calls=blocked_late_calls+1;return end
   if not state.applied then return original(self,...) end
   if not self._hearth_smoother_shared_director_cache then
      -- Unsupported constructors retain stock pointer-derived immortal keys.
      -- Do not force collection of that lifetime; release only our local lease.
      state.unmanaged_stock_destroys=(state.unmanaged_stock_destroys or 0)+1
      local released,release_error=pcall(M.release_pending_lease,self._hearth_smoother_pending_lease)
      local destroyed,destroy_error=pcall(original,self,...)
      if not released then error(release_error,0) end
      if not destroyed then error(destroy_error,0) end
      return
   end
   self._hearth_smoother_retired=true
   retired_alive[self]=true
   state.retired=state.retired+1
   -- Remove director ownership before calling out: reentrant fullness/actors see no errands.
   local errands,groups=self._errands,self._storages_by_filter
   self._errands,self._storages_by_filter={},{}
   self._covered_items,self._errand_last_validated,self._storage_filters={},{},{}
   fence(self)
   local released={}
   local first_error,failed
   local function attempt(fn,...)
      local ok,err=pcall(fn,...)
      if not ok and not failed then first_error,failed=err,true end
      return ok
   end
   local function release(handle,kind)
      if handle and not released[handle] then
         released[handle]=true
         state.release_attempts=(state.release_attempts or 0)+1
         if attempt(handle.destroy,handle) then state[kind]=state[kind]+1
         else state.release_failures=(state.release_failures or 0)+1 end
      end
   end
   for _,entry in pairs(groups or {}) do
      local handles=entry.fullness_listeners
      entry.fullness_listeners={}
      for _,handle in pairs(handles or {}) do release(handle,'listeners_destroyed') end
   end
   for id,errand in pairs(errands or {}) do
      local listeners=errand.should_restock_listeners
      errand.should_restock_listeners=nil
      for _,handle in pairs(listeners or {}) do release(handle,'listeners_destroyed') end
      local lease=errand.storage_space_lease
      errand.storage_space_lease=nil
      release(lease,'leases_destroyed')
      state.cancellation_attempts=(state.cancellation_attempts or 0)+1
      if attempt(radiant.events.trigger_async,self,'stonehearth:restock:errand_canceled',id) then
         state.canceled_errands=state.canceled_errands+1
      else state.cancellation_failures=(state.cancellation_failures or 0)+1 end
   end
   state.retirement_notice_attempts=(state.retirement_notice_attempts or 0)+1
   if attempt(radiant.events.trigger_async,self,'hearth_smoother:restock_director_retired') then
      state.retirement_notices=(state.retirement_notices or 0)+1
   else state.retirement_notice_failures=(state.retirement_notice_failures or 0)+1 end
   attempt(M.release_pending_lease,self._hearth_smoother_pending_lease)
   -- Exact ownership from stock destroy (113-135) and stop (366-392).
   -- Detach first, then release independently: a throwing early handle must not
   -- prevent later releases, and no failing handle is retried by native destroy.
   self._started=false
   local native_fields={'_lease_release_listener','_item_filter_finder','_item_spatial_cache',
      '_item_rating_cache_clear_interval','_active_nearby_item_search','_failed_item_requeue_timer',
      '_generate_on_next_frame_timer','_hearth_smoother_retry_slice_timer'}
   local native_handles={}
   for _,name in ipairs(native_fields) do
      native_handles[#native_handles+1]=self[name] or false;self[name]=nil
   end
   local storage_listeners=self._storage_listeners;self._storage_listeners={}
   local anchor=self._item_filter_finder_src_entity;self._item_filter_finder_src_entity=nil
   for _,handle in ipairs(native_handles) do release(handle,'native_handles_destroyed') end
   for _,handle in pairs(storage_listeners or {}) do release(handle,'native_handles_destroyed') end
   if anchor then
      state.release_attempts=(state.release_attempts or 0)+1
      if attempt(radiant.entities.destroy_entity,anchor) then state.anchors_destroyed=state.anchors_destroyed+1
      else state.release_failures=(state.release_failures or 0)+1 end
   end
   -- Keep the captured native lifecycle invocation and wrapper ownership chain.
   state.native_destroy_attempts=(state.native_destroy_attempts or 0)+1
   if attempt(original,self,...) then state.native_destroys=state.native_destroys+1
   else state.native_destroy_failures=(state.native_destroy_failures or 0)+1 end
   self._ensure_stopped=noop
   self._started=false
   self._restockable_items_queue,self._restockable_high_quality_items_queue=nil,nil
   self._reconsider_items_queue,self._reconsider_high_quality_items_queue=nil,nil
   self._failed_items,self._reconsidering_items={},{}
   self._item_quality_cache,self._item_should_restock_cache,self._item_rating_cache={},{},{}
   self._inventory,self._restocked_item_tracker,self._is_storage_predicate=nil,nil,nil
   self._is_restockable_predicate=nil
   if failed then error(first_error,0) end
end
return M

