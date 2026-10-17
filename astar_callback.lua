-- Avoid a temporary callback array only for a plain one-key solved callback set.
-- This changes Lua result dispatch allocation, not native A* search behavior.
local M = {}
local PATH = 'stonehearth.components.pathfinder.astar_search'
local SOURCE = '@stonehearth/components/pathfinder/astar_search.lua'
local owner, original, replacement, helpers, dependencies
local state = {applied=false, enabled=true, calls=0, single_callback_fast_paths=0,
   multi_callback_fallbacks=0, empty_callback_fallbacks=0,
   unsupported_callback_sets=0, compatibility_fallbacks=0}

local function source_is(fn, first, last)
   if type(fn) ~= 'function' then return false end
   local ok, info = pcall(debug.getinfo, fn, 'S')
   return ok and type(info) == 'table' and info.source == SOURCE
      and info.linedefined == first and info.lastlinedefined == last
end

local function compatible()
   return owner and owner._on_solved == replacement
      and owner.add_destination == helpers.add_destination
      and owner.remove_destination == helpers.remove_destination
      and owner._start_pathfinder == helpers._start_pathfinder
      and owner._stop_pathfinder == helpers._stop_pathfinder
      and pairs == dependencies.pairs and ipairs == dependencies.ipairs
      and next == dependencies.next and getmetatable == dependencies.getmetatable
      and tostring == dependencies.tostring and type(table) == 'table'
      and table.insert == dependencies.insert
end

function M.status()
   return {applied=state.applied, enabled=state.enabled,
      active=state.applied and state.enabled and compatible() or false,
      expected_source=SOURCE, skipped_reason=state.skipped_reason,
      calls=state.calls, single_callback_fast_paths=state.single_callback_fast_paths,
      multi_callback_fallbacks=state.multi_callback_fallbacks,
      empty_callback_fallbacks=state.empty_callback_fallbacks,
      unsupported_callback_sets=state.unsupported_callback_sets,
      compatibility_fallbacks=state.compatibility_fallbacks,
      scope='Lua solved-result dispatch only; no native search requests, paths, priorities or heuristics are changed.'}
end

function M.apply()
   if state.applied then
      if compatible() then return true, M.status() end
      return false, 'AStarSearch method/dependency ownership changed'
   end
   if not radiant or not radiant.mods or type(radiant.mods.require) ~= 'function'
      or type(debug) ~= 'table' or type(debug.getinfo) ~= 'function' then
      state.skipped_reason = 'module/source inspection unavailable'; return false, state.skipped_reason
   end
   local ok, cls = pcall(radiant.mods.require, PATH)
   if not ok or type(cls) ~= 'table' then
      state.skipped_reason = 'stock AStarSearch unavailable'; return false, state.skipped_reason
   end
   if not source_is(cls._on_solved, 120, 142)
      or not source_is(cls.add_destination, 39, 61)
      or not source_is(cls.remove_destination, 68, 88)
      or not source_is(cls._start_pathfinder, 93, 118)
      or not source_is(cls._stop_pathfinder, 160, 169) then
      state.skipped_reason = 'unsupported AStarSearch methods'; return false, state.skipped_reason
   end
   if type(table) ~= 'table' then
      state.skipped_reason = 'standard Lua table unavailable'; return false, state.skipped_reason
   end
   local function is_native(fn)
      local inspected, info = pcall(debug.getinfo, fn, 'S')
      return type(fn) == 'function' and inspected and type(info) == 'table' and info.what == 'C'
   end
   if not is_native(pairs) or not is_native(ipairs) or not is_native(next)
      or not is_native(getmetatable) or not is_native(tostring) or not is_native(table.insert) then
      state.skipped_reason = 'unsupported Lua traversal dependency'; return false, state.skipped_reason
   end
   local builtins = {pairs=pairs, ipairs=ipairs, next=next, getmetatable=getmetatable,
      tostring=tostring, insert=table.insert}
   owner, original, dependencies = cls, cls._on_solved, builtins
   helpers = {add_destination=cls.add_destination, remove_destination=cls.remove_destination,
      _start_pathfinder=cls._start_pathfinder, _stop_pathfinder=cls._stop_pathfinder}
   local captured_original = original
   local installed
   installed = function(self, path)
      if not state.applied or not state.enabled or replacement ~= installed then
         return captured_original(self, path)
      end
      if not compatible() then
         state.compatibility_fallbacks = state.compatibility_fallbacks + 1
         return captured_original(self, path)
      end
      state.calls = state.calls + 1
      local dst = path:get_destination()
      local id = dst:get_id()
      local solved_cbs = self._destinations[id].solved_cbs
      if type(solved_cbs) == 'table' and getmetatable(solved_cbs) == nil then
         local cb = next(solved_cbs)
         if cb ~= nil and next(solved_cbs, cb) == nil then
            state.single_callback_fast_paths = state.single_callback_fast_paths + 1
            -- The local key is the same one-entry snapshot as the stock array.
            -- Read the live value again, as stock does before invoking the callback.
            if solved_cbs[cb] then
               self._log:info('calling solved callback for destination %s', tostring(path:get_destination()))
               cb(path)
               self:remove_destination(id, cb)
            end
            return not next(self._destinations)
         end
         if cb == nil then state.empty_callback_fallbacks = state.empty_callback_fallbacks + 1
         else state.multi_callback_fallbacks = state.multi_callback_fallbacks + 1 end
      else
         state.unsupported_callback_sets = state.unsupported_callback_sets + 1
      end
      -- Verbatim stock snapshot/dispatch ordering for all other sets. Do not
      -- call captured_original here: that would query the destination twice.
      local local_solved_cbs = {}
      for cb, _ in pairs(solved_cbs) do
         table.insert(local_solved_cbs, cb)
      end
      for _, cb in ipairs(local_solved_cbs) do
         if solved_cbs[cb] then
            self._log:info('calling solved callback for destination %s', tostring(path:get_destination()))
            cb(path)
            self:remove_destination(id, cb)
         end
      end
      return not next(self._destinations)
   end
   replacement = installed
   cls._on_solved = installed
   state.applied, state.skipped_reason = true, nil
   return true, M.status()
end

function M.set_enabled(value)
   if type(value) ~= 'boolean' then return false, 'enabled must be boolean' end
   state.enabled = value
   return true, M.status()
end

function M.restore()
   if state.applied and owner._on_solved == replacement then owner._on_solved = original end
   state.applied = false
   return M.status()
end

return M

