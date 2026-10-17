-- Only guard the death visual. Do not alter dying, drops or memorialization.
local M = {}
local ACTION_PATH = 'stonehearth.ai.actions.run_death_effect_action'
local EXPECTED_SOURCE = '@stonehearth/ai/actions/run_death_effect_action.lua'
local state = {
   applied = false, death_normal_calls = 0, proxies_created = 0,
   skipped_missing_location = 0, skipped_invalid_entity = 0, skipped_invalid_proxy = 0
}
local owner, original, wrapper

local function run(self, ai, entity, args)
   if not entity or not entity:is_valid() then
      state.skipped_invalid_entity = state.skipped_invalid_entity + 1
      return
   end
   -- Snapshot a real death location BEFORE proxy creation can detach the actor.
   local location = radiant.entities.get_world_grid_location(entity)
   if not location then
      state.skipped_missing_location = state.skipped_missing_location + 1
      return
   end
   local proxy = radiant.entities.create_entity('stonehearth:object:transient', { debug_text = 'running death effect' })
   if not proxy or not proxy:is_valid() then
      state.skipped_invalid_proxy = state.skipped_invalid_proxy + 1
      return
   end
   state.proxies_created = state.proxies_created + 1
   radiant.terrain.place_entity(proxy, location)
   local effect = radiant.effects.run_effect(proxy, 'stonehearth:effects:death')
   effect:set_finished_cb(function()
      radiant.entities.destroy_entity(proxy)
   end)
   state.death_normal_calls = state.death_normal_calls + 1
end

function M.status()
   return {
      applied = state.applied, active = state.applied and owner ~= nil and owner.run == wrapper,
      death_normal_calls = state.death_normal_calls, proxies_created = state.proxies_created,
      skipped_missing_location = state.skipped_missing_location,
      skipped_invalid_entity = state.skipped_invalid_entity,
      skipped_invalid_proxy = state.skipped_invalid_proxy,
      skipped_reason = state.skipped_reason, expected_source = EXPECTED_SOURCE
   }
end

function M.apply()
   if state.applied then
      if owner.run == wrapper then return true end
      return false, 'death action changed by another mod'
   end
   local require_action = radiant and radiant.mods and radiant.mods.require
   local getinfo = debug and debug.getinfo
   if type(require_action) ~= 'function' or type(getinfo) ~= 'function' then
      state.skipped_reason = 'radiant.mods.require or debug.getinfo unavailable'
      return false, state.skipped_reason
   end
   local loaded, action = pcall(require_action, ACTION_PATH)
   local candidate = loaded and action and action.run
   if type(candidate) ~= 'function' then
      state.skipped_reason = 'death action unavailable'
      return false, state.skipped_reason
   end
   local inspected, info = pcall(getinfo, candidate, 'S')
   if not inspected or type(info) ~= 'table' or info.source ~= EXPECTED_SOURCE then
      state.skipped_reason = 'death action ownership source is not ' .. EXPECTED_SOURCE
      return false, state.skipped_reason
   end
   local captured_original = candidate
   local installed
   installed = function(self, ai, entity, args)
      if not state.applied or wrapper ~= installed then
         return captured_original(self, ai, entity, args)
      end
      return run(self, ai, entity, args)
   end
   owner, original, wrapper = action, candidate, installed
   action.run = installed
   state.applied, state.skipped_reason = true, nil
   radiant.log.create_logger('hearth_smoother'):write(0, 'death effect location snapshot guard applied')
   return true
end

function M.restore()
   if owner and owner.run == wrapper then owner.run = original end
   state.applied = false
   return M.status()
end

return M

