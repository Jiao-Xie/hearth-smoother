-- Guard only discarded wait controllers/parents. Never relax Node:get_ctx().
local M = {}
local WAIT_PATH = 'stonehearth.services.server.game_master.controllers.encounters.wait_encounter'
local ARC_PATH = 'stonehearth.services.server.game_master.controllers.arc'
local WAIT_SOURCE = '@stonehearth/services/server/game_master/controllers/encounters/wait_encounter.lua'
local ARC_SOURCE = '@stonehearth/services/server/game_master/controllers/arc.lua'
local state = {
   applied = false, wait_normal_calls = 0, orphan_wait_callbacks = 0,
   duplicate_timers_cancelled = 0, discarded_wait_edges = 0
}
local wait_class, arc_class, originals, wrappers
local log = radiant.log.create_logger('hearth_smoother')

local function valid_source(fn, expected)
   if type(fn) ~= 'function' or not debug or type(debug.getinfo) ~= 'function' then return false end
   local ok, info = pcall(debug.getinfo, fn, 'S')
   return ok and type(info) == 'table' and info.source == expected
end

local function cancel_stored_timer(self)
   local sv = self._sv
   local timer = sv and sv.timer
   if not timer or type(timer.destroy) ~= 'function' then return false end
   -- Clear before destruction to avoid reentrant destruction of the same timer.
   sv.timer = nil
   timer:destroy()
   self.__saved_variables:mark_changed()
   return true
end

local function orphan_reason(self)
   local ctx = self._sv and self._sv.ctx
   if not ctx then return 'wait context missing' end
   local encounter_sv = ctx.encounter and ctx.encounter._sv
   if not encounter_sv or not encounter_sv.ctx then return 'encounter context missing' end
   -- Both stock and ACE store the script at _sv.script, not _sv._script.
   if encounter_sv.script and encounter_sv.script ~= self then return 'wait script replaced' end
   local arc_sv = ctx.arc and ctx.arc._sv
   if not arc_sv or not arc_sv.ctx then return 'arc context missing' end
end

function M.status()
   local active = state.applied and wait_class ~= nil and arc_class ~= nil
      and wait_class._timer_callback == wrappers.timer
      and wait_class.start == wrappers.start and wait_class.continue == wrappers.continue
      and arc_class._trigger_edge == wrappers.edge
   return {
      applied = state.applied, active = active,
      wait_normal_calls = state.wait_normal_calls, orphan_wait_callbacks = state.orphan_wait_callbacks,
      duplicate_timers_cancelled = state.duplicate_timers_cancelled,
      discarded_wait_edges = state.discarded_wait_edges, skipped_reason = state.skipped_reason
   }
end

function M.apply()
   if state.applied then
      if M.status().active then return true end
      return false, 'wait or arc method changed by another mod'
   end
   local require_module = radiant and radiant.mods and radiant.mods.require
   if type(require_module) ~= 'function' then
      state.skipped_reason = 'radiant.mods.require unavailable'
      return false, state.skipped_reason
   end
   local wait_ok, wait = pcall(require_module, WAIT_PATH)
   local arc_ok, arc = pcall(require_module, ARC_PATH)
   if not wait_ok or not arc_ok or not wait or not arc
      or not valid_source(wait._timer_callback, WAIT_SOURCE)
      or not valid_source(wait.start, WAIT_SOURCE)
      or not valid_source(wait.continue, WAIT_SOURCE)
      or not valid_source(arc._trigger_edge, ARC_SOURCE) then
      state.skipped_reason = 'unsupported wait/arc method ownership source'
      return false, state.skipped_reason
   end
   local captured = {
      timer = wait._timer_callback, start = wait.start,
      continue = wait.continue, edge = arc._trigger_edge
   }
   local installed = {}
   installed.timer = function(self, ...)
      if not state.applied or wrappers ~= installed then return captured.timer(self, ...) end
      local reason = orphan_reason(self)
      if reason then
         local ctx = self._sv and self._sv.ctx
         if not cancel_stored_timer(self) then
            if self._sv then self._sv.timer = nil end
            self.__saved_variables:mark_changed()
         end
         state.orphan_wait_callbacks = state.orphan_wait_callbacks + 1
         log:write(0, 'discarded wait callback encounter=%s reason=%s',
            tostring(ctx and ctx.encounter_name or '<missing>'), reason)
         return
      end
      state.wait_normal_calls = state.wait_normal_calls + 1
      return captured.timer(self, ...)
   end
   installed.start = function(self, ...)
      if state.applied and wrappers == installed and cancel_stored_timer(self) then
         state.duplicate_timers_cancelled = state.duplicate_timers_cancelled + 1
      end
      return captured.start(self, ...)
   end
   installed.continue = function(self, ...)
      if state.applied and wrappers == installed and cancel_stored_timer(self) then
         state.duplicate_timers_cancelled = state.duplicate_timers_cancelled + 1
      end
      return captured.continue(self, ...)
   end
   installed.edge = function(self, edge_name, parent_node, options, ...)
      if state.applied and wrappers == installed then
         local sv = self._sv
         local parent_sv = parent_node and parent_node._sv
         if sv and sv.ctx and parent_sv and not parent_sv.ctx and parent_sv.node_name
            and parent_sv._info and parent_sv._info.encounter_type == 'wait' then
            state.discarded_wait_edges = state.discarded_wait_edges + 1
            log:write(0, 'discarded wait parent edge encounter=%s edge=%s',
               tostring(parent_sv.node_name), tostring(edge_name))
            return
         end
      end
      return captured.edge(self, edge_name, parent_node, options, ...)
   end
   wait_class, arc_class, originals, wrappers = wait, arc, captured, installed
   wait._timer_callback, wait.start, wait.continue = installed.timer, installed.start, installed.continue
   arc._trigger_edge = installed.edge
   state.applied, state.skipped_reason = true, nil
   log:write(0, 'discarded wait callback/parent guards applied')
   return true
end

function M.restore()
   if wait_class then
      if wait_class._timer_callback == wrappers.timer then wait_class._timer_callback = originals.timer end
      if wait_class.start == wrappers.start then wait_class.start = originals.start end
      if wait_class.continue == wrappers.continue then wait_class.continue = originals.continue end
   end
   if arc_class and arc_class._trigger_edge == wrappers.edge then arc_class._trigger_edge = originals.edge end
   state.applied = false
   return M.status()
end

return M

