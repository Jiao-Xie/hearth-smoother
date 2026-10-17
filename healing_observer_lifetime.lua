-- Release 949: remove target traces by their real IDs and own the work-order listener.
local M = {}
local CLASS_PATH = 'stonehearth.ai.observers.find_healable_target_observer'
local EXPECTED_SOURCE = '@stonehearth/ai/observers/find_healable_target_observer.lua'
local FIELD = '_hearth_smoother_work_order_trace'
local GATES = {
   _initialize_running = {85, 102},
   _remove_all_entities_traces = {104, 114},
   _unsubscribe_from_events = {134, 155},
   _remove_entity_traces = {201, 211},
   _trace_entity_location = {436, 441},
   _destroy_entity_location_trace = {443, 448}
}
local state = {applied=false, listeners_created=0, listeners_destroyed=0,
   initializations_reused=0, target_entries_removed=0, cleanup_calls=0}
local owner, originals, installed

local function set_running_from_work_order(self)
   local work_order = self._sv._entity:get('stonehearth:work_order')
   if work_order and not work_order:is_work_order_enabled('job') then
      self._running = false
   else
      self._running = true
      if self._entity then self:_check_for_target() end
   end
end

local function owns_methods()
   if not owner or not installed then return false end
   for name, fn in pairs(installed) do
      if owner[name] ~= fn then return false end
   end
   return owner._remove_entity_traces == originals._remove_entity_traces and
      owner._trace_entity_location == originals._trace_entity_location
end

function M.status()
   return {
      applied=state.applied, active=state.applied and owns_methods(),
      listeners_created=state.listeners_created, listeners_destroyed=state.listeners_destroyed,
      listener_handles_owned=state.listeners_created-state.listeners_destroyed,
      initializations_reused=state.initializations_reused,
      target_entries_removed=state.target_entries_removed, cleanup_calls=state.cleanup_calls,
      skipped_reason=state.skipped_reason, expected_source=EXPECTED_SOURCE
   }
end

function M.apply()
   if state.applied then
      if owns_methods() then return true end
      return false, 'healing lifecycle changed by another mod'
   end
   local require_class = radiant and radiant.mods and radiant.mods.require
   local getinfo = debug and debug.getinfo
   if type(require_class) ~= 'function' or type(getinfo) ~= 'function' then
      state.skipped_reason = 'required class inspection APIs unavailable'
      return false, state.skipped_reason
   end
   local loaded, observer = pcall(require_class, CLASS_PATH)
   if not loaded or type(observer) ~= 'table' then
      state.skipped_reason = 'healing observer unavailable'
      return false, state.skipped_reason
   end
   local candidates = {}
   for name, lines in pairs(GATES) do
      local candidate = observer[name]
      local inspected, info
      if type(candidate) == 'function' then inspected, info = pcall(getinfo, candidate, 'S') end
      if not inspected or type(info) ~= 'table' or info.source ~= EXPECTED_SOURCE or
            info.linedefined ~= lines[1] or info.lastlinedefined ~= lines[2] then
         state.skipped_reason = 'unsupported healing lifecycle source layout: ' .. name
         return false, state.skipped_reason
      end
      candidates[name] = candidate
   end
   local replacements = {}
   replacements._initialize_running = function(self)
      -- Re-evaluate on every initialization, as stock does, but own only one listener.
      set_running_from_work_order(self)
      if self[FIELD] then
         state.initializations_reused = state.initializations_reused + 1
      else
         self[FIELD] = radiant.events.listen(self._sv._entity,
            'stonehearth:work_order:status_changed', function() set_running_from_work_order(self) end)
         state.listeners_created = state.listeners_created + 1
      end
   end
   replacements._remove_all_entities_traces = function(self)
      local trace_ids = {}
      for id in pairs(self._entity_traces) do table.insert(trace_ids, id) end
      for _, id in ipairs(trace_ids) do
         self:_remove_entity_traces(id)
         state.target_entries_removed = state.target_entries_removed + 1
      end
      state.cleanup_calls = state.cleanup_calls + 1
   end
   replacements._unsubscribe_from_events = function(self)
      if self[FIELD] then
         self[FIELD]:destroy()
         self[FIELD] = nil
         state.listeners_destroyed = state.listeners_destroyed + 1
      end
      return candidates._unsubscribe_from_events(self)
   end
   replacements._destroy_entity_location_trace = function(self)
      -- Once cleared (or before activation), lookup resolves to the stock
      -- creation method, not a trace handle. Every real handle uses stock cleanup.
      if self._trace_entity_location == candidates._trace_entity_location then return end
      return candidates._destroy_entity_location_trace(self)
   end
   owner, originals, installed = observer, candidates, replacements
   for name, fn in pairs(replacements) do observer[name] = fn end
   state.applied, state.skipped_reason = true, nil
   return true
end

-- No live restore: stock teardown cannot release handles created by this patch.
-- Normal observer destruction owns teardown; restarting with the mod disabled removes it.
return M

