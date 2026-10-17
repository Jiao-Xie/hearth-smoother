-- Share ACE pasture-feed predicates by their complete immutable inputs.
local M = {}
local PATH = 'stonehearth_ace.components.pasture_item.pasture_item_component'
local SOURCE = '@stonehearth_ace/components/pasture_item/pasture_item_component.lua'
local NAMESPACE = 'hearth_smoother:pasture_feed_filter:v102'
local RESTOCK_ACTION = 'stonehearth_ace:feed_pasture_trough'
local owner, original, replacement
local state = {applied=false, calls=0, shared_requests=0, fallback_requests=0, tasks_created=0}

local function make_feed_filter_fn(material, player_id)
   -- Same live entity queries as ACE. No component, task, or entity is captured.
   return function(item)
      if not radiant.entities.is_material(item, material) then return false end
      if player_id ~= '' and radiant.entities.get_player_id(item) ~= player_id then return false end
      return true
   end
end
local function feed_filter(material, player_id)
   if type(material) == 'string' and type(player_id) == 'string' then
      state.shared_requests = state.shared_requests + 1
      local key = 'm' .. #material .. ':' .. material .. 'o' .. #player_id .. ':' .. player_id
      return stonehearth.ai:filter_from_key(NAMESPACE, key, make_feed_filter_fn(material, player_id))
   end
   -- Preserve ACE semantics for unsupported/mutable argument types; never
   -- rerun the original method after its task-destruction side effects.
   state.fallback_requests = state.fallback_requests + 1
   return make_feed_filter_fn(material, player_id)
end
function M.status()
   return {applied=state.applied, active=state.applied and owner._create_restock_tasks == replacement,
      expected_source=SOURCE, namespace=NAMESPACE, skipped_reason=state.skipped_reason,
      calls=state.calls, shared_requests=state.shared_requests,
      fallback_requests=state.fallback_requests, tasks_created=state.tasks_created}
end
function M.apply()
   if state.applied then
      if owner._create_restock_tasks == replacement then return true, M.status() end
      return false, 'pasture task method ownership changed'
   end
   if not radiant or not radiant.mods or type(radiant.mods.require) ~= 'function'
      or type(debug) ~= 'table' or type(debug.getinfo) ~= 'function' then
      state.skipped_reason = 'module/source inspection unavailable'; return false, state.skipped_reason
   end
   local ok, cls = pcall(radiant.mods.require, PATH)
   if not ok or type(cls) ~= 'table' then
      state.skipped_reason = 'ACE pasture component unavailable'; return false, state.skipped_reason
   end
   local fn = cls._create_restock_tasks
   local inspected, info = pcall(debug.getinfo, fn, 'S')
   if type(fn) ~= 'function' or not inspected or type(info) ~= 'table' or info.source ~= SOURCE
      or info.linedefined ~= 53 or info.lastlinedefined ~= 83
      or type(cls._destroy_restock_tasks) ~= 'function'
      or type(cls.is_trough) ~= 'function' or type(cls.is_empty) ~= 'function' then
      state.skipped_reason = 'unsupported ACE pasture task method'; return false, state.skipped_reason
   end
   if not stonehearth or not stonehearth.ai or type(stonehearth.ai.filter_from_key) ~= 'function'
      or type(stonehearth.ai.reconsider_entity) ~= 'function'
      or not stonehearth.town or type(stonehearth.town.get_town) ~= 'function'
      or not radiant.entities or type(radiant.entities.is_material) ~= 'function'
      or type(radiant.entities.get_player_id) ~= 'function'
      or not radiant.events or type(radiant.events.trigger_async) ~= 'function' then
      state.skipped_reason = 'pasture dependencies unavailable'; return false, state.skipped_reason
   end
   owner, original = cls, fn
   local captured_original = fn
   local installed
   installed = function(self)
      -- A caller may retain this wrapper after restoration or a later install.
      -- Such references must return to their own original implementation.
      if not state.applied or replacement ~= installed then return captured_original(self) end
      state.calls = state.calls + 1
      self:_destroy_restock_tasks()

      if self._pasture and self:is_trough() then
         if self:is_empty() then
            local feed_material = self._pasture:add_component('stonehearth:shepherd_pasture'):get_animal_feed_material()

            if feed_material then
               local town = stonehearth.town:get_town(self._entity)

               local args = {
                  pasture = self._pasture,
                  trough = self._entity,
                  feed_filter_fn = feed_filter(feed_material, self._entity:get_player_id())
               }

               local restock_task = town:create_task_for_group(
                  'stonehearth:task_groups:herding', RESTOCK_ACTION, args)
                     :set_source(self._entity)
                     :start()
               table.insert(self._added_restock_tasks, restock_task)
               state.tasks_created = state.tasks_created + 1
            end
         else
            radiant.events.trigger_async(self._pasture, 'stonehearth_ace:shepherd_pasture:trough_feed_changed', {trough = self._entity})
         end
      end
      stonehearth.ai:reconsider_entity(self._entity)
   end
   replacement = installed
   cls._create_restock_tasks = replacement
   state.applied, state.skipped_reason = true, nil
   return true, M.status()
end
function M.restore()
   if state.applied and owner._create_restock_tasks == replacement then
      owner._create_restock_tasks = original
   end
   state.applied = false
   return M.status()
end
return M

