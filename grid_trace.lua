-- Specialize the stock one-value FilteredTrace without a per-event results table.
-- Existing traces keep their implementation when this factory is restored.
local M = {}
local EXPECTED_SOURCE = '@radiant/modules/entities.lua'
local state = {
   applied = false, traces_created = 0, transform_events = 0,
   forwarded_events = 0, suppressed_events = 0, avoided_result_tables = 0
}
local owner, original, wrapper
local GridLocationTrace = {}
GridLocationTrace.__index = GridLocationTrace

function GridLocationTrace:on_changed(changed_cb)
   self._changed_cb = changed_cb
   return self
end

function GridLocationTrace:on_destroyed(destroyed_cb)
   self._trace_impl:on_destroyed(destroyed_cb)
   return self
end

function GridLocationTrace:push_object_state()
   self._trace_impl:push_object_state()
   return self
end

function GridLocationTrace:destroy()
   if self._trace_impl then
      self._trace_impl:destroy()
      self._trace_impl = nil
   end
end

local function trace_grid_location(entity, reason)
   local mob = entity:add_component('mob')
   -- Keep stock ordering: initial location is read before tracing the transform.
   local last_location = mob:get_world_grid_location()
   local trace_impl = mob:trace_transform(reason)
   local trace = setmetatable({ _trace_impl = trace_impl }, GridLocationTrace)
   trace_impl:on_changed(function()
      state.transform_events = state.transform_events + 1
      if trace._changed_cb then
         state.avoided_result_tables = state.avoided_result_tables + 1
         local current_location = mob:get_world_grid_location()
         if current_location == last_location then
            state.suppressed_events = state.suppressed_events + 1
         else
            last_location = current_location
            if current_location then
               state.forwarded_events = state.forwarded_events + 1
               -- Read the callback after get_world_grid_location, like FilteredTrace.
               -- This preserves callback replacement and reentrant observation.
               trace._changed_cb(current_location)
            else
               state.suppressed_events = state.suppressed_events + 1
            end
         end
      else
         -- Stock FilteredTrace doesn't read/advance location without a callback.
         state.suppressed_events = state.suppressed_events + 1
      end
   end)
   state.traces_created = state.traces_created + 1
   return trace
end

function M.status()
   return {
      applied = state.applied,
      active = state.applied and owner ~= nil and owner.trace_grid_location == wrapper,
      traces_created = state.traces_created, transform_events = state.transform_events,
      forwarded_events = state.forwarded_events, suppressed_events = state.suppressed_events,
      avoided_result_tables = state.avoided_result_tables,
      skipped_reason = state.skipped_reason, expected_source = EXPECTED_SOURCE
   }
end

function M.apply()
   local entities = radiant and radiant.entities
   if state.applied then
      if entities == owner and entities.trace_grid_location == wrapper then return true end
      return false, 'grid trace factory changed by another mod'
   end
   local candidate = entities and entities.trace_grid_location
   local getinfo = debug and debug.getinfo
   if type(candidate) ~= 'function' or type(getinfo) ~= 'function' then
      state.skipped_reason = 'stock factory or debug.getinfo unavailable'
      return false, state.skipped_reason
   end
   local ok, info = pcall(getinfo, candidate, 'S')
   if not ok or type(info) ~= 'table' or info.source ~= EXPECTED_SOURCE then
      state.skipped_reason = 'factory ownership source is not ' .. EXPECTED_SOURCE
      return false, state.skipped_reason
   end
   owner, original, wrapper = entities, candidate, trace_grid_location
   entities.trace_grid_location = wrapper
   state.applied, state.skipped_reason = true, nil
   radiant.log.create_logger('hearth_smoother'):write(0, 'grid trace single-value forwarding applied')
   return true
end

function M.restore()
   if owner and owner.trace_grid_location == wrapper then
      owner.trace_grid_location = original
   end
   state.applied = false
   return M.status()
end

return M

