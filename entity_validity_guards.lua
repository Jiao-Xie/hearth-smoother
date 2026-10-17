-- Narrow ACE guards for dead fuel users/items and unavailable combat centers.
local M = {}
local CONSUMER_PATH = 'stonehearth_ace.components.consumer.consumer_component'
local CONSUMER_SOURCE = '@stonehearth_ace/components/consumer/consumer_component.lua'
local COMBAT_PATH = 'stonehearth.services.server.combat.combat_service'
local COMBAT_SOURCE = '@stonehearth_ace/monkey_patches/ace_combat_service.lua'
local state = {applied=false, reserve_calls=0, invalid_users=0, invalid_consumers=0,
   invalid_fuel_items=0, nearby_calls=0, missing_enemy_centers=0,
   missing_ally_centers=0, no_spatial_centers=0}
local consumer, combat, original_reserve, original_nearby, reserve_wrapper, nearby_wrapper

local function valid(entity)
   local kind = type(entity)
   return (kind == 'table' or kind == 'userdata') and type(entity.is_valid) == 'function'
      and entity:is_valid()
end

local function reserve_fuel(self, user)
   state.reserve_calls = state.reserve_calls + 1
   -- The observed exception is user:get_id() (ACE line 157), before fuel lookup.
   if not valid(user) then state.invalid_users = state.invalid_users + 1; return false end
   if not valid(self._entity) then state.invalid_consumers = state.invalid_consumers + 1; return false end
   local reserved = self._reserved_fuel
   local reserved_items = self._reserved_fuel_items
   local user_id = user:get_id()
   if reserved[user_id] then return true end

   local expendable_resources = self._entity:get_component('stonehearth:expendable_resources')
   if not expendable_resources then return false end
   if not expendable_resources:get_value('fuel_level') or not expendable_resources:get_value('reserved_fuel_level') then
      return false
   end
   local fuel_per_use = self:get_fuel_per_use()
   if expendable_resources:get_value('fuel_level') >= fuel_per_use then
      expendable_resources:modify_value('fuel_level', -fuel_per_use)
      expendable_resources:modify_value('reserved_fuel_level', fuel_per_use)
      self:_reserve_user_fuel_consumer(user)
      reserved[user_id] = fuel_per_use
      return true
   end

   local storage = self._entity:get_component('stonehearth:storage')
   local items = storage and storage:get_items()
   if items then
      for _, item in pairs(items) do
         if valid(item) then
            local item_id = item:get_id()
            if not reserved_items[item_id] and radiant.entities.get_entity_data(item, 'stonehearth_ace:fuel') then
               self:_reserve_user_fuel_consumer(user)
               reserved[user_id] = item
               reserved_items[item_id] = user_id
               return true
            end
         else
            state.invalid_fuel_items = state.invalid_fuel_items + 1
         end
      end
   end
   -- Preserve ACE's nil return when no stored candidate is usable.
end

local function get_nearby_units(self, target, attacker, player_id)
   state.nearby_calls = state.nearby_calls + 1
   local radius = stonehearth.constants.exp.EXP_REWARD_RADIUS
   local target_valid = valid(target)
   local enemy_location = target_valid and radiant.entities.get_world_grid_location(target) or nil
   local ally_location = valid(attacker) and radiant.entities.get_world_grid_location(attacker) or nil
   if not enemy_location then state.missing_enemy_centers = state.missing_enemy_centers + 1 end
   if not ally_location then state.missing_ally_centers = state.missing_ally_centers + 1 end
   if not enemy_location and not ally_location then state.no_spatial_centers = state.no_spatial_centers + 1 end

   local units, count = {}, 0
   local friendly_players = stonehearth.player:get_friendly_players(player_id)
   for friendly_player, _ in pairs(friendly_players) do
      local population = stonehearth.population:get_population(friendly_player)
      if population then
         for id, citizen in population:get_citizens():each() do
            if citizen and citizen:is_valid() then
               local job_component = citizen:get_component('stonehearth:job')
               local location = radiant.entities.get_world_grid_location(citizen)
               if location then
                  local target_table = radiant.entities.get_target_table(citizen, 'aggro')
                  -- Each existing center is an independent legitimate test.
                  -- With neither center, aggro participants still qualify.
                  if (target_valid and target_table and target_table:contains(target)) or
                     (enemy_location and radiant.math.point_within_sphere(location, enemy_location, radius)) or
                     (ally_location and radiant.math.point_within_sphere(location, ally_location, radius)) then
                     units[id] = citizen
                     count = count + 1
                  end
               end
            end
         end
      end
   end
   return units, count
end

local function source_matches(fn, source, first, last)
   if type(fn) ~= 'function' then return false end
   local ok, info = pcall(debug.getinfo, fn, 'S')
   return ok and type(info) == 'table' and info.what == 'Lua' and info.source == source
      and info.linedefined == first and info.lastlinedefined == last
end

function M.status()
   return {applied=state.applied, active=state.applied and
      consumer.reserve_fuel == reserve_wrapper and combat._get_nearby_units == nearby_wrapper or false,
      consumer_source=CONSUMER_SOURCE, combat_source=COMBAT_SOURCE, skipped_reason=state.skipped_reason,
      reserve_calls=state.reserve_calls, invalid_users=state.invalid_users,
      invalid_consumers=state.invalid_consumers, invalid_fuel_items=state.invalid_fuel_items,
      nearby_calls=state.nearby_calls, missing_enemy_centers=state.missing_enemy_centers,
      missing_ally_centers=state.missing_ally_centers, no_spatial_centers=state.no_spatial_centers}
end

function M.apply()
   if state.applied then
      if M.status().active then return true, M.status() end
      return false, 'entity guard method ownership changed'
   end
   local function reject(reason) state.skipped_reason = reason; return false, reason end
   if not radiant or not radiant.mods or type(radiant.mods.require) ~= 'function'
      or not debug or type(debug.getinfo) ~= 'function' then return reject('module/source inspection unavailable') end
   local ok_consumer, consumer_class = pcall(radiant.mods.require, CONSUMER_PATH)
   local ok_combat, combat_class = pcall(radiant.mods.require, COMBAT_PATH)
   if not ok_consumer or type(consumer_class) ~= 'table' or not ok_combat or type(combat_class) ~= 'table' then
      return reject('ACE consumer/combat class unavailable')
   end
   local reserve, nearby = consumer_class.reserve_fuel, combat_class._get_nearby_units
   if not source_matches(reserve, CONSUMER_SOURCE, 153, 198)
      or not source_matches(nearby, COMBAT_SOURCE, 274, 311) then return reject('unsupported ACE method source layout') end
   if type(consumer_class.get_fuel_per_use) ~= 'function' or type(consumer_class._reserve_user_fuel_consumer) ~= 'function'
      or not radiant.entities or type(radiant.entities.get_entity_data) ~= 'function'
      or type(radiant.entities.get_world_grid_location) ~= 'function' or type(radiant.entities.get_target_table) ~= 'function'
      or not radiant.math or type(radiant.math.point_within_sphere) ~= 'function'
      or not stonehearth or not stonehearth.constants or not stonehearth.constants.exp
      or type(stonehearth.constants.exp.EXP_REWARD_RADIUS) ~= 'number'
      or not stonehearth.player or type(stonehearth.player.get_friendly_players) ~= 'function'
      or not stonehearth.population or type(stonehearth.population.get_population) ~= 'function' then
      return reject('required entity/consumer/combat dependencies unavailable')
   end
   local captured_reserve, captured_nearby = reserve, nearby
   local installed_reserve, installed_nearby
   installed_reserve = function(self, user)
      if not state.applied or reserve_wrapper ~= installed_reserve then return captured_reserve(self, user) end
      return reserve_fuel(self, user)
   end
   installed_nearby = function(self, target, attacker, player_id)
      if not state.applied or nearby_wrapper ~= installed_nearby then
         return captured_nearby(self, target, attacker, player_id)
      end
      return get_nearby_units(self, target, attacker, player_id)
   end
   consumer, combat = consumer_class, combat_class
   original_reserve, original_nearby = reserve, nearby
   reserve_wrapper, nearby_wrapper = installed_reserve, installed_nearby
   consumer.reserve_fuel, combat._get_nearby_units = installed_reserve, installed_nearby
   state.applied, state.skipped_reason = true, nil
   return true, M.status()
end

function M.restore()
   if consumer and consumer.reserve_fuel == reserve_wrapper then consumer.reserve_fuel = original_reserve end
   if combat and combat._get_nearby_units == nearby_wrapper then combat._get_nearby_units = original_nearby end
   state.applied = false
   return M.status()
end

return M

