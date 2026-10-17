-- Complete-context sharing for ACE watchdog director inclusion predicates.
-- This module installs no class or global service wrappers; bootstrap owns init.
local M = {}
local PATH = 'stonehearth.services.server.inventory.restock_director'
local SOURCE = '@stonehearth_ace/services/server/inventory/restock_director.lua'
local AI_SOURCE = '@stonehearth/services/server/ai/ai_service.lua'
local ALLOCATOR = '__hearth_smoother_director_cache_ids_v103'
local MAX_ID = 9007199254740991
local pools = setmetatable({}, {__mode='k'})
local state = {applied=false, generation=0, next_id=0, created=0, reused=0,
   fallback=0, inventory_pools_created=0}
local function inspect(fn, source, first, last)
   if type(fn) ~= 'function' or type(debug) ~= 'table' or type(debug.getinfo) ~= 'function' then return false end
   local ok, info = pcall(debug.getinfo, fn, 'S')
   return ok and type(info) == 'table' and info.what == 'Lua' and info.source == source
      and info.linedefined == first and info.lastlinedefined == last
end
local function dependencies()
   return radiant and radiant.entities and type(radiant.entities.get_player_id) == 'function'
      and type(radiant.entities.exists_in_world) == 'function'
      and radiant.events and type(radiant.events.listen) == 'function'
      and stonehearth and stonehearth.catalog and type(stonehearth.catalog.get_catalog_data) == 'function'
      and stonehearth.ai and inspect(stonehearth.ai.filter_from_key, AI_SOURCE, 548, 565)
      and stonehearth.constants and stonehearth.constants.item_quality
      and stonehearth.calendar and type(stonehearth.calendar.get_elapsed_time) == 'function'
      and _radiant and _radiant.queue and _radiant.queue.PriorityQueue ~= nil
end
local function valid_id(n)
   return type(n) == 'number' and n >= 0 and n < MAX_ID and n == math.floor(n)
end
function M.apply()
   if state.applied then return true, M.status() end
   local function reject(reason) state.skipped_reason=reason; return false,reason end
   if not radiant or not radiant.mods or type(radiant.mods.require) ~= 'function' then return reject('require API unavailable') end
   local ok, cls = pcall(radiant.mods.require, PATH)
   if not ok or type(cls) ~= 'table' or not inspect(cls.__init, SOURCE, 52, 111)
      or not inspect(cls._make_is_restockable_predicate, SOURCE, 1217, 1320) then
      return reject('unsupported ACE director constructor/maker')
   end
   if not dependencies() then return reject('unsupported director cache dependencies') end
   local allocator = rawget(_G, ALLOCATOR)
   if allocator == nil then
      allocator = {tag='hearth_smoother/director_cache/v103', generation=0}
      rawset(_G, ALLOCATOR, allocator)
   end
   if type(allocator) ~= 'table' or allocator.tag ~= 'hearth_smoother/director_cache/v103'
      or not valid_id(allocator.generation) then return reject('unsupported/exhausted director cache ID allocator') end
   allocator.generation = allocator.generation + 1
   state.generation = allocator.generation
   state.applied, state.skipped_reason = true, nil
   return true, M.status()
end
local function shared_filter(self, allow_stored)
   local inventory, player = self._inventory, self._player_id
   local get_player_id, exists_in_world = radiant.entities.get_player_id, radiant.entities.exists_in_world
   local catalog = stonehearth.catalog
   local get_catalog_data, maker = catalog.get_catalog_data, self._make_is_restockable_predicate
   local ai, filter_from_key = stonehearth.ai, stonehearth.ai.filter_from_key
   local carried = hearth_smoother_carried_target_guard
   if not carried or not carried.is_active() then carried = nil end
   local wrap = carried and carried.wrap_filter
   local get_parent = carried and radiant.entities.get_parent
   local get_carrying = carried and radiant.entities.get_carrying
   local entries = pools[inventory]
   if entries then
      for _, entry in ipairs(entries) do
         if entry.player == player and entry.allow_stored == allow_stored
            and entry.get_player_id == get_player_id and entry.exists_in_world == exists_in_world
            and entry.catalog == catalog and entry.get_catalog_data == get_catalog_data
            and entry.maker == maker and entry.ai == ai and entry.filter_from_key == filter_from_key
            and entry.carried == carried and entry.wrap == wrap
            and entry.get_parent == get_parent and entry.get_carrying == get_carrying then
            state.reused = state.reused + 1
            return entry.key, entry.predicate, entry.base_predicate, carried
         end
      end
   end
   -- No function/table address is used as an ID. Generation survives module
   -- reload via a scalar-only runtime allocator; semantic IDs never recycle.
   state.next_id = state.next_id + 1
   local key = 'hearth_smoother:director_cache:v103:g' .. string.format('%.0f', state.generation)
      .. ':s' .. string.format('%.0f', state.next_id)
   local base_predicate = self:_make_is_restockable_predicate(allow_stored)
   local predicate = ai:filter_from_key('restock_director', key,
      carried and wrap(base_predicate, get_parent, get_carrying) or base_predicate)
   if not entries then
      entries={};pools[inventory]=entries
      state.inventory_pools_created=state.inventory_pools_created+1
   end
   entries[#entries+1] = {player=player, allow_stored=allow_stored,
      get_player_id=get_player_id, exists_in_world=exists_in_world,
      catalog=catalog, get_catalog_data=get_catalog_data, maker=maker,
      ai=ai, filter_from_key=filter_from_key, key=key, predicate=predicate,
      carried=carried, wrap=wrap, get_parent=get_parent, get_carrying=get_carrying, base_predicate=base_predicate}
   state.created=state.created+1
   return key,predicate,base_predicate,carried
end
function M.construct(self, inventory, allow_stored, storage_predicate, original)
   if not state.applied or not inspect(original, SOURCE, 52, 111)
      or type(self) ~= 'table' or type(inventory) ~= 'table' or type(allow_stored) ~= 'boolean'
      or type(inventory.get_player_id) ~= 'function' or type(inventory.get_item_tracker) ~= 'function'
      or type(inventory.get_all_public_storage) ~= 'function'
      or not inspect(self._make_is_restockable_predicate, SOURCE, 1217, 1320)
      or not dependencies() or state.next_id >= MAX_ID then
      state.fallback=state.fallback+1
      if type(self) == 'table' then self._hearth_smoother_shared_director_cache = nil end
      return original(self, inventory, allow_stored, storage_predicate)
   end
   -- Exact ACE __init 52--111 body; only its two filter/key assignments change.
   -- Errors after construction starts propagate; never rerun side effects.
   self._player_id = inventory:get_player_id()
   self._inventory = inventory
   self._director_name = allow_stored and 'INPUT_BIN' or 'RESTOCK'
   self._restocked_item_tracker = self._inventory:get_item_tracker('stonehearth:restocked_item_tracker')
   self._is_storage_predicate = storage_predicate
   local base_predicate, carried
   self._is_restockable_predicate_key, self._is_restockable_predicate, base_predicate, carried = shared_filter(self, allow_stored)
   self._hearth_smoother_shared_director_cache = true
   self._normal_item_quality = stonehearth.constants.item_quality.NORMAL

   self._restockable_items_queue = _radiant.queue.PriorityQueue()
   self._restockable_high_quality_items_queue = _radiant.queue.PriorityQueue()
   self._failed_items = {}
   self._reconsider_high_quality_items_queue = _radiant.queue.PriorityQueue()
   self._reconsider_items_queue = _radiant.queue.PriorityQueue()
   self._reconsidering_items = {}
   self._covered_items = {}
   self._storages_by_filter = {}
   self._storage_filters = {}
   self._errands = {}

   self._started = false
   self._current_errand_id = 1
   self._generate_on_next_frame_timer = nil
   self._lease_release_listener = nil
   self._storage_listeners = {}
   self._failed_item_requeue_timer = nil
   self._item_spatial_cache = nil
   self._item_filter_finder_src_entity = nil
   self._item_filter_finder = nil
   self._active_nearby_item_search = nil
   self._item_quality_cache = {}
   self._item_should_restock_cache = {}
   self._item_rating_cache = {}
   self._item_rating_cache_clear_interval = nil
   self._errand_last_validated = {}
   self._last_success_time = stonehearth.calendar:get_elapsed_time()
   if carried then carried.bind_director(self, base_predicate) end

   table.insert(self._storage_listeners, radiant.events.listen(self._inventory, 'stonehearth:inventory:storage_added', function(e)
      self:_on_storage_added(e.storage)
   end))
   table.insert(self._storage_listeners, radiant.events.listen(self._inventory, 'stonehearth:inventory:storage_removed', function(e)
      self:_on_storage_removed(e.storage_id)
   end))
   table.insert(self._storage_listeners, radiant.events.listen(self._inventory, 'stonehearth:inventory:storage_filter_changed', function(e)
      self:_on_storage_filter_changed(e.storage)
   end))
   for _, storage in pairs(self._inventory:get_all_public_storage()) do
      self:_on_storage_added(storage)
   end
end
function M.status()
   local current_pools,current_entries=0,0
   for _,entries in pairs(pools) do current_pools=current_pools+1;current_entries=current_entries+#entries end
   return {applied=state.applied, active=state.applied and not not dependencies(),
      generation=state.generation, next_id=state.next_id, created=state.created, reused=state.reused,
      fallback=state.fallback, inventory_pools_created=state.inventory_pools_created,
      pools=current_pools, semantic_contexts=current_entries, skipped_reason=state.skipped_reason}
end
return M

