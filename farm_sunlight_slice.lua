-- Only the ACE periodic sunlight scan is sliced. Initial checks remain stock.
-- Runtime weak epochs contain no component, crop, or saved-variable references.
local M = {}
local PATH = 'stonehearth.components.farmer_field.farmer_field_component'
local SOURCE = '@stonehearth_ace/monkey_patches/ace_farmer_field_component.lua'
local TERRAIN_SOURCE = '@stonehearth_ace/monkey_patches/ace_terrain_service.lua'
local CALENDAR_SOURCE = '@stonehearth/services/server/calendar/calendar_service.lua'
local EVENTS_SOURCE = '@radiant/modules/events.lua'
local RAYCAST_PATH = 'stonehearth.ai.lib.raycast_lib'
local RAYCAST_SOURCE = '@stonehearth_ace/monkey_patches/ace_raycast_lib.lua'
local FILTERED_RAY_SOURCE = '@stonehearth/ai/lib/raycast_lib.lua'
local epochs = setmetatable({}, { __mode = 'k' })
local state = { applied = false, enabled = true, generation = 0, max_positions = 8, max_rays = 40, budget_ms = 2,
   requests = 0, coalesced = 0, global_dispatches = 0, query_count = 0, completed = 0,
   cancelled = 0, clock_failures = 0, clock_disabled = false, max_pending_age_seconds = 0,
   max_dispatch_ms = 0, max_helper_ms = 0, max_commit_ms = 0, ray_count = 0,
   positions_completed = 0, max_ray_ms = 0 }
local bounds = {
   _create_climate_listeners = {739, 761}, _destroy_climate_listeners = {763, 776},
   _check_sky_visibility = {823, 839}, _update_climate = {841, 874},
   _update_weather = {778, 801}, _update_season = {803, 821}, _set_growth_factors = {876, 902},
   suspend_entity = {134, 137}, continue_entity = {139, 142}, _on_destroy = {1111, 1121}
}
local owner, records, helpers, dependencies
local first, last, dispatcher, dispatcher_identity
local dispatching = false
local request, schedule
local floor, abs = math.floor, math.abs
local sin, cos, pi = math.sin, math.cos, math.pi
local function ignore_crop(entity) return entity:get_component('stonehearth:crop') ~= nil end
local function finite(n) return type(n) == 'number' and n == n and n ~= math.huge and n ~= -math.huge end
local function clock_call() return _host:get_realtime() end
local function clock()
   local ok, now = pcall(clock_call)
   if ok and finite(now) then return now end
end
local function inspect(fn, source, range)
   if type(fn) ~= 'function' or not debug or type(debug.getinfo) ~= 'function' then return false end
   local ok, info = pcall(debug.getinfo, fn, 'S')
   return ok and type(info) == 'table' and info.what == 'Lua' and info.source == source
      and (not range or (info.linedefined == range[1] and info.lastlinedefined == range[2]))
end
local function native(fn)
   if type(fn) ~= 'function' or not debug or type(debug.getinfo) ~= 'function' then return false end
   local ok, info = pcall(debug.getinfo, fn, 'S')
   return ok and type(info) == 'table' and info.what == 'C'
end
local function native_constructor(value)
   if native(value) then return true end
   if type(value) ~= 'table' and type(value) ~= 'userdata' then return false end
   local mt = getmetatable(value)
   return type(mt) == 'table' and native(mt.__call)
end
local function point_shape(point)
   if type(point) ~= 'userdata' then return false end
   local mt = getmetatable(point)
   return type(mt) == 'table' and native(mt.__add)
      and native(mt.__mul)
      and finite(point.x) and finite(point.y) and finite(point.z)
end
local function owns()
   if not state.applied then return false end
   for method, record in pairs(records) do
      if record.generation ~= state.generation or owner[method] ~= record.wrapper then return false end
   end
   for method, fn in pairs(helpers) do if owner[method] ~= fn then return false end end
   return true
end
local function dependencies_valid()
   return dependencies and radiant and radiant.on_game_loop_once == dependencies.loop
      and radiant.events and radiant.events.listen == dependencies.listen
      and stonehearth and stonehearth.terrain == dependencies.terrain
      and stonehearth.terrain.get_sky_visibility == dependencies.sky
      and stonehearth.calendar == dependencies.calendar
      and stonehearth.calendar.set_interval == dependencies.interval
      and stonehearth.constants and stonehearth.constants.farming
      and stonehearth.constants.farming.SUNLIGHT_CHECK_FREQUENCY == '3h'
      and stonehearth.constants.terrain and stonehearth.constants.terrain.NUM_SUNLIGHT_CHECK_ANGLES == 6
      and _radiant and _radiant.csg and _radiant.csg.Point3 == dependencies.Point3
      and dependencies.raycast.is_sight_blocked == dependencies.blocked
      and dependencies.raycast.shoot_ray_filtered == dependencies.filtered
      and _physics == dependencies.physics and _physics.walk_line == dependencies.walk_line
      and _physics.is_blocked == dependencies.is_blocked
      and radiant.terrain == dependencies.radiant_terrain
      and radiant.terrain.get_entities_at_point == dependencies.entities_at_point
      and radiant.terrain.get_entities_in_cube == dependencies.entities_in_cube
      and radiant._root_entity_id == dependencies.root_entity_id
      and math.floor == floor and math.abs == abs and math.sin == sin and math.cos == cos and math.pi == pi
end
local function active() return owns() and dependencies_valid() end
local function live(self)
   return self and self._entity and type(self._entity.is_valid) == 'function'
      and self._entity:is_valid() and not self._is_suspended and self._sv and self._sv.contents ~= nil
end
local function compatible(self)
   if not active() or not live(self) then return false end
   for method, fn in pairs(helpers) do if self[method] ~= fn then return false end end
   for method, record in pairs(records) do if self[method] ~= record.wrapper then return false end end
   local size = self._sv.size
   local size_type = type(size)
   return (size_type == 'table' or size_type == 'userdata') and finite(size.x) and finite(size.y) and size.x >= 1 and size.y >= 1
      and size.x == floor(size.x) and size.y == floor(size.y) and point_shape(self._location)
end
local function age(epoch, now)
   if now and epoch.started and now >= epoch.started then
      state.max_pending_age_seconds = math.max(state.max_pending_age_seconds, now - epoch.started)
   end
end
local function unlink(node)
   if not node.linked then return end
   if node.prev then node.prev.next = node.next else first = node.next end
   if node.next then node.next.prev = node.prev else last = node.prev end
   node.prev, node.next, node.linked = nil, nil, false
end
local function enqueue(node)
   node.prev, node.next, node.linked = last, nil, true
   if last then last.next = node else first = node end
   last = node
end
local function cancel(self, now)
   local epoch = epochs[self]
   if not epoch then return end
   epochs[self] = nil
   unlink(epoch.node)
   epoch.cancelled = true
   state.cancelled = state.cancelled + 1
   age(epoch, now or clock())
end
local function cancel_epoch(self, epoch, now)
   if epochs[self] == epoch then return cancel(self, now) end
   -- A native callback may retire this scan and start another before returning.
   -- The stale continuation owns only its old node, never the replacement scan.
   unlink(epoch.node)
   if not epoch.cancelled then
      epoch.cancelled = true
      state.cancelled = state.cancelled + 1
      age(epoch, now or clock())
   end
end
local function stop_dispatcher()
   local handle = dispatcher
   dispatcher, dispatcher_identity = nil, nil
   if handle then handle:destroy() end
end
local function cancel_all()
   for self in pairs(epochs) do cancel(self) end
   -- Weak keys can have vanished before their queue holder is visited.
   while first do
      local node = first
      unlink(node)
      if not node.epoch.cancelled then
         node.epoch.cancelled = true
         state.cancelled = state.cancelled + 1
         age(node.epoch, clock())
      end
   end
   if not dispatching then stop_dispatcher() end
end
local function clock_failure()
   state.clock_failures = state.clock_failures + 1
   state.clock_disabled = true
   cancel_all()
end
local function valid_epoch(self, epoch)
   if epochs[self] ~= epoch or epoch.generation ~= state.generation or not compatible(self) then return false end
   local refs = epoch.refs
   local size, location = self._sv.size, self._location
   return refs[1] ~= nil and self._sv == refs[1] and refs[2] ~= nil and self._sv.contents == refs[2]
      and refs[3] ~= nil and size == refs[3] and refs[4] ~= nil and location == refs[4]
      and refs[5] ~= nil and self._entity == refs[5]
      and size.x == epoch.width and size.y == epoch.length
      and location.x == epoch.lx and location.y == epoch.ly and location.z == epoch.lz
end
local function step(self, epoch)
   if not valid_epoch(self, epoch) then cancel_epoch(self, epoch); return end
   local started = clock()
   if not started then clock_failure(); return end
   if not epoch.angle then
      epoch.position = self._location + dependencies.Point3(epoch.x, 2, epoch.z)
      epoch.angle, epoch.vis_weight, epoch.total_weight, epoch.helper_ms = 1, 0, 0, 0
      state.query_count = state.query_count + 1
   end
   -- Exact ACE angle arithmetic and accumulation order. Keep the original
   -- sight/voxel helper intact: one native walk_line is the indivisible unit.
   local coefficient = epoch.angle / 6
   local x = cos(coefficient * pi)
   local y = sin(coefficient * pi)
   local ray = dependencies.Point3(x, y, 0) * 100
   local target = epoch.position + ray
   if not valid_epoch(self, epoch) then cancel_epoch(self, epoch); return end
   local ray_start = clock()
   if not ray_start or ray_start < started then clock_failure(); return end
   state.ray_count = state.ray_count + 1
   local blocked = dependencies.blocked(epoch.position, target, ignore_crop)
   local ended = clock()
   if not ended or ended < ray_start then clock_failure(); return end
   state.max_ray_ms = math.max(state.max_ray_ms, (ended - ray_start) * 1000)
   epoch.helper_ms = epoch.helper_ms + (ended - started) * 1000
   state.max_helper_ms = math.max(state.max_helper_ms, epoch.helper_ms)
   -- Native/helper reentry may suspend, destroy, replace ownership, or disable.
   if not valid_epoch(self, epoch) then cancel_epoch(self, epoch, ended); return end
   if not blocked then epoch.vis_weight = epoch.vis_weight + y end
   epoch.total_weight = epoch.total_weight + y
   epoch.angle = epoch.angle + 1
   if epoch.angle < 6 then return false end
   epoch.sum = epoch.sum + epoch.vis_weight / epoch.total_weight -- preserve stock ascending-z addition order
   epoch.angle, epoch.position = nil, nil
   state.positions_completed = state.positions_completed + 1
   epoch.z = epoch.z + 1
   if epoch.z < epoch.length then return true end
   local vis = epoch.sum / epoch.length
   if not valid_epoch(self, epoch) then cancel_epoch(self, epoch, ended); return end
   local commit_start = ended
   -- Commit is indivisible, with live weather/season and the original growth loop.
   if not self._sky_visibility or abs(vis - self._sky_visibility) > 0.001 then
      self._sky_visibility = vis
      self:_update_climate()
   end
   local commit_end = clock()
   if commit_end and commit_end >= commit_start then
      state.max_commit_ms = math.max(state.max_commit_ms, (commit_end - commit_start) * 1000)
   else clock_failure(); return end
   if epochs[self] == epoch then
      epochs[self] = nil
      state.completed = state.completed + 1
      age(epoch, commit_end)
   end
   return true
end
local function dispatch_body(started)
   local positions, rays, visits = 0, 0, 0
   while first and positions < state.max_positions and rays < state.max_rays do
      local node = first
      unlink(node)
      local self, epoch = node.field[1], node.epoch
      if self and epochs[self] == epoch then
         rays = rays + 1
         -- Include validation getters: a native validation error must not leave
         -- this unlinked node permanently pending. Preserve the original error.
         local ok, finished_position = pcall(step, self, epoch)
         if not ok then cancel_epoch(self, epoch); error(finished_position, 0) end
         if finished_position then positions = positions + 1 end
         if epochs[self] == epoch then enqueue(node) end
      elseif not epoch.cancelled then
         epoch.cancelled = true
         state.cancelled = state.cancelled + 1
         age(epoch, clock())
      end
      visits = visits + 1
      local now = clock()
      if not now or now < started then clock_failure(); return end
      if (now - started) * 1000 >= state.budget_ms or visits >= state.max_rays then return end
   end
end
schedule = function()
   if dispatcher or not first or dispatching then return end
   local identity = setmetatable({}, { __mode = 'v' })
   local generation = state.generation
   local ok, handle = pcall(dependencies.loop, 'hearth_smoother farm sunlight continuation', function()
      local current = identity[1]
      if current == nil or dispatcher ~= current or dispatcher_identity ~= identity or generation ~= state.generation then return end
      dispatcher, dispatcher_identity = nil, nil
      if not state.enabled or state.clock_disabled or not active() then cancel_all(); return end
      local started = clock()
      if not started then clock_failure(); return end
      dispatching = true
      state.global_dispatches = state.global_dispatches + 1
      local ok, err = pcall(dispatch_body, started)
      local ended = clock()
      if ended and ended >= started then
         state.max_dispatch_ms = math.max(state.max_dispatch_ms, (ended - started) * 1000)
      else clock_failure() end
      dispatching = false
      -- Schedule remaining farms before propagating any helper/commit exception.
      local scheduled, scheduling_error = pcall(schedule)
      if not ok then error(err, 0) end
      if not scheduled then error(scheduling_error, 0) end
   end)
   if not ok then
      cancel_all() -- no stranded pending epochs after the native scheduler raises
      error(handle, 0)
   end
   identity[1] = handle
   dispatcher, dispatcher_identity = handle, identity
end
request = function(self, record)
   if not live(self) then return end
   state.requests = state.requests + 1
   if not state.enabled or state.clock_disabled or record.generation ~= state.generation or not compatible(self) then
      cancel(self)
      return self:_check_sky_visibility()
   end
   if epochs[self] then state.coalesced = state.coalesced + 1; return end
   local now = clock()
   if not now then clock_failure(); return self:_check_sky_visibility() end
   local size, location = self._sv.size, self._location
   local epoch = { generation = state.generation, started = now, width = size.x, length = size.y,
      x = floor(size.x / 2), z = 0, sum = 0, lx = location.x, ly = location.y, lz = location.z,
      refs = setmetatable({self._sv, self._sv.contents, size, location, self._entity}, { __mode = 'v' }) }
   local node = { field = setmetatable({self}, { __mode = 'v' }), epoch = epoch }
   epoch.node = node
   epochs[self] = epoch
   enqueue(node)
   schedule()
end
local function create_listeners(self, record)
   -- Exact stock body apart from the periodic callback. Never slice its final check.
   self:_destroy_climate_listeners()
   if not self._sv.sunlight_level then self._sv.sunlight_level = 1 end
   self._weather_listener = radiant.events.listen(radiant, 'stonehearth_ace:weather_state_started', function()
      self:_update_weather()
   end)
   self:_update_weather()
   self._season_listener = radiant.events.listen(radiant, 'stonehearth:seasons:changed', function()
      self:_update_season()
   end)
   self:_update_season()
   local field = setmetatable({self}, { __mode = 'v' })
   local identity = setmetatable({}, { __mode = 'v' })
   self._sunlight_timer = stonehearth.calendar:set_interval('farm sunlight check', stonehearth.constants.farming.SUNLIGHT_CHECK_FREQUENCY, function()
      local current, component = identity[1], field[1]
      if current == nil or component == nil or component._sunlight_timer ~= current then return end
      request(component, record)
   end)
   identity[1] = self._sunlight_timer
   self:_check_sky_visibility()
end
local function make_wrapper(record)
   return function(self, ...)
      if record.method ~= '_create_climate_listeners' then
         cancel(self) -- invalidate before stock lifecycle/native destruction
         if not first and not dispatching then stop_dispatcher() end
         return record.original(self, ...)
      end
      if record.generation ~= state.generation or not state.enabled or state.clock_disabled or not compatible(self) then
         cancel(self)
         return record.original(self, ...)
      end
      return create_listeners(self, record)
   end
end
function M.apply()
   if state.applied then return active(), M.status() end
   local require_module = radiant and radiant.mods and radiant.mods.require
   if type(require_module) ~= 'function' then state.skipped_reason = 'require API unavailable'; return false, state.skipped_reason end
   local ok, class = pcall(require_module, PATH)
   if not ok or type(class) ~= 'table' then state.skipped_reason = 'farm class unavailable'; return false, state.skipped_reason end
   for method, range in pairs(bounds) do
      if not inspect(class[method], SOURCE, range) then state.skipped_reason = 'unsupported source/line shape: ' .. method; return false, state.skipped_reason end
   end
   local ray_ok, raycast = pcall(require_module, RAYCAST_PATH)
   if not ray_ok or type(raycast) ~= 'table'
      or not inspect(raycast.is_sight_blocked, RAYCAST_SOURCE, {4, 27})
      or not inspect(raycast.shoot_ray_filtered, FILTERED_RAY_SOURCE, {27, 42}) then
      state.skipped_reason = 'unsupported sunlight raycast source'; return false, state.skipped_reason
   end
   if not stonehearth or not stonehearth.terrain or not inspect(stonehearth.terrain.get_sky_visibility, TERRAIN_SOURCE, {34, 56})
      or not stonehearth.calendar or not inspect(stonehearth.calendar.set_interval, CALENDAR_SOURCE, {284, 286})
      or not radiant.events or not inspect(radiant.events.listen, EVENTS_SOURCE)
      or not inspect(radiant.on_game_loop_once, EVENTS_SOURCE, {75, 77})
      or not _radiant or not _radiant.csg or not native_constructor(_radiant.csg.Point3)
      or not _physics or not native(_physics.walk_line) or not native(_physics.is_blocked)
      or not radiant.terrain or type(radiant.terrain.get_entities_at_point) ~= 'function'
      or type(radiant.terrain.get_entities_in_cube) ~= 'function' or radiant._root_entity_id == nil
      or not native(floor) or not native(abs) or not native(sin) or not native(cos) or not finite(pi) then
      state.skipped_reason = 'unsupported native Point3, terrain/calendar/event dependency'; return false, state.skipped_reason
   end
   dependencies = { terrain = stonehearth.terrain, sky = stonehearth.terrain.get_sky_visibility,
      calendar = stonehearth.calendar, interval = stonehearth.calendar.set_interval,
      listen = radiant.events.listen, loop = radiant.on_game_loop_once, Point3 = _radiant.csg.Point3,
      raycast = raycast, blocked = raycast.is_sight_blocked, filtered = raycast.shoot_ray_filtered,
      physics = _physics, walk_line = _physics.walk_line, is_blocked = _physics.is_blocked,
      radiant_terrain = radiant.terrain, entities_at_point = radiant.terrain.get_entities_at_point,
      entities_in_cube = radiant.terrain.get_entities_in_cube, root_entity_id = radiant._root_entity_id }
   if not dependencies_valid() then state.skipped_reason = 'unsupported sunlight constants/dependency identity'; return false, state.skipped_reason end
   owner, helpers, records = class, {}, {}
   state.generation = state.generation + 1
   for method in pairs(bounds) do helpers[method] = class[method] end
   for _, method in ipairs({'_create_climate_listeners', '_destroy_climate_listeners', 'suspend_entity', '_on_destroy'}) do
      helpers[method] = nil
      local record = { method = method, original = class[method], generation = state.generation }
      record.wrapper = make_wrapper(record)
      records[method] = record
      class[method] = record.wrapper
   end
   state.applied, state.skipped_reason = true, nil
   return true, M.status()
end
function M.set_enabled(enabled)
   if type(enabled) ~= 'boolean' then return false, 'farm sunlight slicing enabled must be boolean' end
   if enabled and not state.applied then local ok, err = M.apply(); if not ok then return false, err end end
   if not enabled then cancel_all() end
   state.enabled, state.clock_disabled = enabled, false
   return true, M.status()
end
function M.configure(options)
   if type(options) ~= 'table' then return false, 'options required' end
   local max = options.max_positions
   if max == nil then max = state.max_positions end
   local budget = options.budget_ms
   if budget == nil then budget = state.budget_ms end
   local rays = options.max_rays
   if rays == nil then rays = state.max_rays end
   if not finite(max) or max < 1 or max > 1000000000 or max ~= floor(max)
      or not finite(rays) or rays < 1 or rays > 1000000000 or rays ~= floor(rays)
      or not finite(budget) or budget < 0 or budget > 1000000000 then return false, 'invalid scan budget' end
   state.max_positions, state.max_rays, state.budget_ms = max, rays, budget
   return true, M.status()
end
function M.status()
   local pending, now = 0, clock()
   for _, epoch in pairs(epochs) do pending = pending + 1; age(epoch, now) end
   return { applied = state.applied, enabled = state.enabled, active = active() and state.enabled and not state.clock_disabled or false,
      source = SOURCE, skipped_reason = state.skipped_reason, generation = state.generation,
      requests = state.requests, coalesced = state.coalesced, global_dispatches = state.global_dispatches,
      query_count = state.query_count, completed = state.completed, cancelled = state.cancelled,
      ray_count = state.ray_count, positions_completed = state.positions_completed, max_ray_ms = state.max_ray_ms,
      pending_fields = pending, max_pending_age_seconds = state.max_pending_age_seconds,
      max_dispatch_ms = state.max_dispatch_ms, max_helper_ms = state.max_helper_ms, max_commit_ms = state.max_commit_ms,
      clock_failures = state.clock_failures, clock_disabled = state.clock_disabled,
      budget = state.budget_ms, budget_ms = state.budget_ms, max_positions = state.max_positions, max_rays = state.max_rays,
      initial_sync_scope = 'Creation, restore and continue retain original immediate sky checks, weather/season updates and growth commits; new field creation retains its extra immediate check.',
      semantics = 'Only newly created guarded periodic callbacks slice. Each turn evaluates one of the original five angles, using the unchanged ACE raycast and stock filtered walk_line. One shared round-robin dispatcher allows at most max_rays ray turns and max_positions completed positions per game loop, with a soft millisecond budget checked after each ray and synchronous commit. One native walk_line with its callbacks or a growth commit cannot be preempted. max_ray_ms measures that ray helper; max_helper_ms sums execution time for a position excluding waits. Pending ticks coalesce. Samples span game loops and can observe changing shadows; original angle-weight and ascending-z summation order is retained, and only a complete field average is published with latest climate multipliers. Existing stock callbacks remain synchronous until listeners are recreated.' }
end
function M.restore()
   cancel_all()
   if records then for method, record in pairs(records) do
      if owner[method] == record.wrapper then owner[method] = record.original end
   end end
   state.applied, state.enabled = false, false
   state.generation = state.generation + 1
   -- Installed periodic callbacks can survive restore: request safely calls stock
   -- on valid current timers, while stale/destroyed/suspended fields do nothing.
   return M.status()
end
return M

