-- Release 949 healing scores can run while a mob is temporarily unparented.
-- Keep unavailable actors at score 0; existing observer events re-evaluate them.
local M = {}
local CLASS_PATH = 'stonehearth.ai.observers.find_healable_target_observer'
local EXPECTED_SOURCE = '@stonehearth/ai/observers/find_healable_target_observer.lua'
local METHOD = '_calculate_target_cost_benefit'
local state = {
   applied = false, normal_calls = 0, skipped_invalid_healer = 0,
   skipped_missing_healer_location = 0, skipped_missing_target_location = 0
}
local owner, original, wrapper

local function calculate(self, entity_location, target, heal_score, bindings)
   if not self._entity or not self._entity:is_valid() then
      state.skipped_invalid_healer = state.skipped_invalid_healer + 1
      return 0
   end
   if not entity_location then
      state.skipped_missing_healer_location = state.skipped_missing_healer_location + 1
      return 0
   end
   if not target or not target:is_valid() then return 0 end
   if not self._sight_sensor:contains_contents(target:get_id()) then
      local is_primary_target = target == self._combat_state:get_primary_target(self._entity)
      if not is_primary_target then return 0 end
   end
   local target_mob = target:get_component('mob')
   if not target_mob then return 0 end
   if bindings.is_entity_suspended(target) then return 0 end
   local target_location = target_mob:get_world_grid_location()
   if not target_location then
      state.skipped_missing_target_location = state.skipped_missing_target_location + 1
      return 0
   end
   -- Below is the original arithmetic, including its minimum distance of 8.
   local leash_penalty
   local leash = self._combat_state:get_leash_data()
   if leash then
      local projected_point = bindings.Point3(target_location)
      projected_point.y = leash.center.y
      local closest_point = leash.cube:get_closest_point(projected_point)
      leash_penalty = closest_point:distance_to(target_location) * bindings.NOT_WITHIN_LEASH_PENALTY_MULTIPLIER
   else
      leash_penalty = 0
   end
   local score = heal_score - leash_penalty
   if score < 0 then return 0 end
   local distance = entity_location:distance_to(target_location)
   if distance < 8 then distance = 8 end
   if distance ~= 0 then score = score / distance end
   state.normal_calls = state.normal_calls + 1
   return score
end

function M.status()
   return {
      applied = state.applied, active = state.applied and owner ~= nil and owner[METHOD] == wrapper,
      normal_calls = state.normal_calls, skipped_invalid_healer = state.skipped_invalid_healer,
      skipped_missing_healer_location = state.skipped_missing_healer_location,
      skipped_missing_target_location = state.skipped_missing_target_location,
      skipped_reason = state.skipped_reason, expected_source = EXPECTED_SOURCE,
      binding_source = state.binding_source
   }
end

function M.apply()
   if state.applied then
      if owner[METHOD] == wrapper then return true end
      return false, 'healing score changed by another mod'
   end
   local require_class = radiant and radiant.mods and radiant.mods.require
   local getinfo = debug and debug.getinfo
   local getupvalue = debug and debug.getupvalue
   if type(require_class) ~= 'function' or type(getinfo) ~= 'function' then
      state.skipped_reason = 'required class inspection APIs unavailable'
      return false, state.skipped_reason
   end
   local loaded, observer = pcall(require_class, CLASS_PATH)
   local candidate = loaded and observer and observer[METHOD]
   if type(candidate) ~= 'function' then
      state.skipped_reason = 'healing observer unavailable'
      return false, state.skipped_reason
   end
   local inspected, info = pcall(getinfo, candidate, 'S')
   if not inspected or type(info) ~= 'table' or info.source ~= EXPECTED_SOURCE or
         info.linedefined ~= 558 or info.lastlinedefined ~= 613 then
      state.skipped_reason = 'unsupported healing score source layout'
      return false, state.skipped_reason
   end
   local bindings = {}
   local binding_source
   if type(getupvalue) == 'function' then
      -- Prefer the captured values when the runtime exposes closure inspection.
      local wanted = { Point3 = true, is_entity_suspended = true, NOT_WITHIN_LEASH_PENALTY_MULTIPLIER = true }
      local index = 1
      while true do
         local name, value = getupvalue(candidate, index)
         if not name then break end
         if wanted[name] then bindings[name] = value end
         index = index + 1
      end
      binding_source = 'stock_closure'
   else
      -- Release builds omit getupvalue. These are the source-confirmed stock
      -- expressions; stonehearth_server.lua:4-6 exports require 'constants'.
      local combat = stonehearth and stonehearth.constants and stonehearth.constants.combat
      bindings.Point3 = _radiant and _radiant.csg and _radiant.csg.Point3
      bindings.is_entity_suspended = radiant.entities and radiant.entities.is_entity_suspended
      bindings.NOT_WITHIN_LEASH_PENALTY_MULTIPLIER = combat and combat.NOT_WITHIN_LEASH_PENALTY_MULTIPLIER
      binding_source = 'stock_exports'
   end
   local point_type = type(bindings.Point3)
   if (point_type ~= 'function' and point_type ~= 'table' and point_type ~= 'userdata') or
         type(bindings.is_entity_suspended) ~= 'function' or
         type(bindings.NOT_WITHIN_LEASH_PENALTY_MULTIPLIER) ~= 'number' then
      state.skipped_reason = 'unsupported healing score ' .. binding_source .. ' bindings'
      return false, state.skipped_reason
   end
   local captured_original = candidate
   local installed
   installed = function(self, entity_location, target, heal_score)
      if not state.applied or wrapper ~= installed then
         return captured_original(self, entity_location, target, heal_score)
      end
      return calculate(self, entity_location, target, heal_score, bindings)
   end
   owner, original, wrapper = observer, candidate, installed
   observer[METHOD] = installed
   state.applied, state.skipped_reason, state.binding_source = true, nil, binding_source
   return true
end

function M.restore()
   if owner and owner[METHOD] == wrapper then owner[METHOD] = original end
   state.applied = false
   return M.status()
end

return M

