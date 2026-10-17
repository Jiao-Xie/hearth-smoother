-- Cache only static blueprint component data, never live entity component state.
-- Assumption: blueprint component keys are not replaced during a loaded game.
-- Clear on resource/game reload; restore also clears all cached data and metrics.
local M = {}
local EXPECTED_SOURCE = '@radiant/modules/entities.lua'
local MAX_URIS, MAX_ENTRIES = 1024, 8192
local ZERO_VALUES, ONE_NIL = {}, {}
local cache = {}
local owner, original, wrapper
local generation = 0
local state = { applied = false, hits = 0, misses = 0, bypasses = 0, cached_uris = 0, cached_entries = 0 }

-- by_uri is an existing bucket, or the URI string for a not-yet-created bucket.
-- Called only after the original completes: throwing calls consume no capacity.
local function record_result(by_uri, key, ...)
   local count = select('#', ...)
   if count <= 1 then
      if type(by_uri) == 'string' then
         local uri = by_uri
         by_uri = {}
         cache[uri] = by_uri
         state.cached_uris = state.cached_uris + 1
      end
      local value = ...
      by_uri[key] = count == 0 and ZERO_VALUES or (value == nil and ONE_NIL or value)
      state.cached_entries = state.cached_entries + 1
   end
   return ...
end

local function get_component_data(candidate, arg0, key)
   local argument_type = type(arg0)
   if type(key) ~= 'string' or (argument_type ~= 'string' and argument_type ~= 'userdata') then
      state.bypasses = state.bypasses + 1
      return candidate(arg0, key)
   end
   local uri = argument_type == 'string' and arg0 or arg0:get_uri()
   -- Keep the stock #uri contract, including errors for unexpected URI types.
   if not uri or #uri == 0 then
      state.bypasses = state.bypasses + 1
      return
   end
   if type(uri) ~= 'string' then
      -- A malformed userdata URI with a supported length is not cacheable.
      -- Complete the exact stock tail without resolving the entity a second time.
      state.bypasses = state.bypasses + 1
      local json = radiant.resources.load_json(uri, true, false)
      if json and json.components then return json.components[key] end
      return
   end
   local by_uri = cache[uri]
   if by_uri then
      local value = by_uri[key]
      if value ~= nil then
         state.hits = state.hits + 1
         if value == ZERO_VALUES then return end
         if value == ONE_NIL then return nil end
         return value
      end
   end
   state.misses = state.misses + 1
   if state.cached_entries >= MAX_ENTRIES or (not by_uri and state.cached_uris >= MAX_URIS) then
      state.bypasses = state.bypasses + 1
      return candidate(uri, key)
   end
   return record_result(by_uri or uri, key, candidate(uri, key))
end

-- Allocate a closure only when applying, never on lookup or cache hit.
-- Each retained wrapper owns its original helper and generation permanently.
local function make_wrapper(candidate, candidate_owner, token)
   local this_wrapper
   this_wrapper = function(arg0, key)
      if not state.applied or generation ~= token or owner ~= candidate_owner
         or not radiant or radiant.entities ~= candidate_owner
         or candidate_owner.get_component_data ~= this_wrapper then
         return candidate(arg0, key)
      end
      return get_component_data(candidate, arg0, key)
   end
   return this_wrapper
end

function M.status()
   return { applied = state.applied,
      active = state.applied and owner ~= nil and radiant and radiant.entities == owner and owner.get_component_data == wrapper,
      hits = state.hits, misses = state.misses, bypasses = state.bypasses,
      cached_uris = state.cached_uris, cached_entries = state.cached_entries,
      max_uris = MAX_URIS, max_entries = MAX_ENTRIES,
      expected_source = EXPECTED_SOURCE, skipped_reason = state.skipped_reason,
      assumption = 'Static blueprint component keys; clear on game/resource reload.' }
end

function M.clear()
   cache = {}
   state.hits, state.misses, state.bypasses = 0, 0, 0
   state.cached_uris, state.cached_entries = 0, 0
   return M.status()
end

function M.apply()
   local entities = radiant and radiant.entities
   if state.applied then
      if owner == entities and owner.get_component_data == wrapper then return true end
      return false, 'component data helper changed by another mod'
   end
   local candidate = entities and entities.get_component_data
   local getinfo = debug and debug.getinfo
   if type(candidate) ~= 'function' or type(getinfo) ~= 'function' then
      state.skipped_reason = 'stock helper or debug.getinfo unavailable'
      return false, state.skipped_reason
   end
   local ok, info = pcall(getinfo, candidate, 'S')
   if not ok or type(info) ~= 'table' or info.source ~= EXPECTED_SOURCE then
      state.skipped_reason = 'helper ownership source is not ' .. EXPECTED_SOURCE
      return false, state.skipped_reason
   end
   generation = generation + 1
   owner, original = entities, candidate
   wrapper = make_wrapper(candidate, entities, generation)
   entities.get_component_data = wrapper
   state.applied, state.skipped_reason = true, nil
   return true
end

function M.restore()
   if owner and owner.get_component_data == wrapper then owner.get_component_data = original end
   state.applied = false
   M.clear()
   owner, original, wrapper = nil, nil, nil
   return M.status()
end

return M

