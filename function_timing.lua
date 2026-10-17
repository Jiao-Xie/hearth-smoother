-- Opt-in inclusive elapsed wall-time observations of selected outer methods.
-- Never add durations across nested methods: descendants are included twice.
-- No entity arguments, saved variables, per-call closures, or result-pack tables.
local M = {}
local MAX_SECONDS, EVENT_CAPACITY, SLOW_MS = 180, 64, 5
local TIMER_CAPACITY, REASON_CAPACITY, REASON_LENGTH = 128, 128, 160
local TIMER_SOURCE = '@radiant/controllers/time_tracker_controller.lua'
local PERSISTENT_SOURCE = '@radiant/controllers/timer_controller.lua'
local CREATION_CAPACITY = 8192
-- Values contain scalars only: Lua 5.1 weak keys must not indirectly retain a timer.
local creation_records = setmetatable({}, { __mode = 'k' })
local creation = { count = 0, capacity = CREATION_CAPACITY, captured = 0, capacity_skips = 0,
   metadata_failures = 0, capturing = false, record = nil }
local DISPATCH_SOURCE = '@hearth_smoother/timer_dispatch.lua'
local timer_floor = math.floor
local timer_xpcall, lua_xpcall = radiant.xpcall, xpcall
local function timer_configuration()
   local getter = radiant and radiant.util and radiant.util.get_global_config
   if type(getter) ~= 'function' then return false end
   local ok, value = pcall(getter, 'mods.stonehearth.always_clear_timers', false)
   return ok and type(value) == 'boolean', value
end
-- Like stock, capture configuration once, not during each dispatch. There is no
-- supported upvalue inspector to recover a differently configured older module.
local timer_config_ok, timer_clear_config = timer_configuration()
local timers = {}
local function reset_timers()
   timers = { calls = 0, completed_count = 0, timed_count = 0, clock_reads = 0,
      reason_failures = 0, reason_count = 0, reasons = {}, events = {}, slow_count = 0,
      reason_overflow_count = 0, reason_overflow_ms = 0, total_ms = 0, max_ms = 0 }
end
reset_timers()
local state = { applied = false, enabled = false, generation = 0, session = 0,
   clock_failures = 0, slow_event_count = 0, events = {}, methods = {} }
local RESTOCK_SOURCE = '@stonehearth_ace/services/server/inventory/restock_director.lua'
local BOOTSTRAP_SOURCE = '@hearth_smoother/restock_bootstrap.lua'
local targets = {
   { name = 'radiant.update', kind = 'radiant', method = 'update', sources = { '@radiant/server.lua' } },
   { name = 'stonehearth.ai._on_game_loop', kind = 'ai', method = '_on_game_loop',
      sources = { '@stonehearth/services/server/ai/ai_service.lua' } },
   { name = 'Calendar:_on_event_loop', path = 'stonehearth.services.server.calendar.calendar_service', method = '_on_event_loop',
      sources = { '@stonehearth/services/server/calendar/calendar_service.lua', '@stonehearth_ace/monkey_patches/ace_calendar_service.lua' } },
   { name = 'TimeTracker:set_now', path = 'radiant.controllers.time_tracker_controller', method = 'set_now',
      sources = { '@radiant/controllers/time_tracker_controller.lua', DISPATCH_SOURCE } },
   { name = 'FoodDecayService:_on_decay', path = 'stonehearth.services.server.food_decay.food_decay_service', method = '_on_decay',
      sources = { '@stonehearth/services/server/food_decay/food_decay_service.lua', '@stonehearth_ace/services/server/food_decay/food_decay_service.lua' } }
}
for _, method in ipairs({ '__init', 'destroy', '_ensure_started', '_get_next_restockable_item',
   '_generate_next_errand', '_transfer_failed_items_into_reconsider_queues', '_transfer_reconsider_items_into_restockable_queue' }) do
   local sources = { RESTOCK_SOURCE, '@hearth_smoother/restock_slice.lua' }
   if method == '__init' or method == '_ensure_started' or method == 'destroy' then
      sources[#sources + 1] = BOOTSTRAP_SOURCE
   end
   targets[#targets + 1] = { name = 'RestockDirector:' .. method,
      path = 'stonehearth.services.server.inventory.restock_director', method = method,
      sources = sources }
end

local function clock_call() return _host:get_realtime() end
local function host_identifier() return tostring(_host) end
local function clock()
   local ok, value = pcall(clock_call)
   if ok and type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge then return value end
   return nil
end
local function disable(reason, now, invalidate)
   state.enabled = false
   creation.capturing = false
   creation.stop_reason = reason
   state.stop_reason, state.stopped_host_seconds = reason, now
   if invalidate then state.session = state.session + 1 end
end
local function clock_failure()
   state.clock_failures = state.clock_failures + 1
   disable('clock_failure', nil, true)
end
local function owns(record)
   if not state.applied or state.generation ~= record.generation or record.owner[record.method] ~= record.wrapper then return false end
   if record.kind == 'radiant' then return radiant == record.owner end
   if record.kind == 'ai' then return stonehearth and stonehearth.ai == record.owner end
   return true
end
local function record_slow(record, started, ended, elapsed)
   state.slow_event_count = state.slow_event_count + 1
   local slot = (state.slow_event_count - 1) % EVENT_CAPACITY + 1
   local event = state.events[slot]
   if not event then event = {}; state.events[slot] = event end
   event.name, event.start_host_seconds, event.end_host_seconds = record.name, started, ended
   event.elapsed_ms = elapsed
end
local function finish(record, started, session, ...)
   if session ~= state.session or not owns(record) then return ... end
   record.completed_count = record.completed_count + 1
   local ended = clock()
   if not ended or ended < started then clock_failure(); return ... end
   local elapsed = (ended - started) * 1000
   record.timed_count, record.total_ms = record.timed_count + 1, record.total_ms + elapsed
   record.max_ms = math.max(record.max_ms, elapsed)
   if elapsed >= SLOW_MS then record_slow(record, started, ended, elapsed) end
   if state.enabled and ended >= state.deadline_host_seconds then disable('deadline', ended, false) end
   return ...
end

local function read_reason(timer) return timer:get_reason() end
local function bounded_name(value, fallback)
   if type(value) == 'string' then return string.sub(value, 1, REASON_LENGTH) end
   return fallback
end
local function callback_metadata(fn)
   if type(fn) == 'function' then
      local info = debug.getinfo(fn, 'S')
      local line = info.linedefined
      if type(line) ~= 'number' or line ~= line or line == math.huge or line == -math.huge then line = 0 end
      return bounded_name(info.source, '[unknown]'), line, 'function', nil
   elseif type(fn) == 'table' then
      -- Binding objects and captured arguments are never examined or retained.
      return '[binding]', 0, bounded_name(rawget(fn, 'type'), '[unknown]'), bounded_name(rawget(fn, 'fn'), nil)
   end
   return '[unknown]', 0, type(fn), nil
end
local function record_creation(reason, fn, timer)
   if (type(timer) ~= 'table' and type(timer) ~= 'userdata') or creation_records[timer] then return end
   if creation.count >= CREATION_CAPACITY then creation.capacity_skips = creation.capacity_skips + 1; return end
   local source, line, kind, binding = callback_metadata(fn)
   creation_records[timer] = { reason = bounded_name(reason, '[reason unavailable]'),
      callback_source = source, callback_line = line, callback_kind = kind, callback_binding = binding }
   creation.count, creation.captured = creation.count + 1, creation.captured + 1
end
local function finish_creation(record, reason, fn, ...)
   if creation.capturing and owns(record) then
      local ok = pcall(record_creation, reason, fn, ...)
      if not ok then creation.metadata_failures = creation.metadata_failures + 1 end
   end
   return ...
end
local function make_creation_wrapper(record, candidate)
   return function(...)
      if not creation.capturing or not owns(record) then return candidate(...) end
      local self, reason, duration, fn = ...
      local now = clock()
      if not now or now < creation.started_host_seconds or now >= creation.deadline_host_seconds then
         creation.capturing = false
         creation.stop_reason = not now and 'clock_failure' or now < creation.started_host_seconds and 'backwards_clock' or 'deadline'
         return candidate(...)
      end
      return finish_creation(record, reason, fn, candidate(...))
   end
end
local function current_persistent(timer)
   -- Prove the stock controller's fire shape before raw-reading saved variables.
   -- Unknown userdata and naked tables never receive rawget calls here.
   if type(timer) ~= 'table' then return nil end
   local fire = timer.fire
   if type(fire) ~= 'function' then return nil end
   local info = debug.getinfo(fire, 'S')
   if info.what ~= 'Lua' or info.source ~= PERSISTENT_SOURCE or info.linedefined ~= 58 or info.lastlinedefined ~= 83 then return nil end
   local sv = rawget(timer, '_sv')
   if type(sv) ~= 'table' then return nil end
   local fn = rawget(sv, '_fn')
   local source, line, kind, binding = callback_metadata(fn)
   return source, line, kind, binding
end
local function capture_identity(timer)
   local saved = creation_records[timer]
   local ok, source, line, kind, binding = pcall(current_persistent, timer)
   if not ok then creation.metadata_failures = creation.metadata_failures + 1 end
   if ok and source then return saved and saved.reason, source, line, kind, binding, 'current_persistent' end
   if saved then return saved.reason, saved.callback_source, saved.callback_line, saved.callback_kind, saved.callback_binding, 'created' end
   return nil, '[unknown]', 0, '[unknown]', nil, 'unknown'
end
local function read_identity(timer)
   if not state.enabled then return nil, '[unknown]', 0, '[unknown]', nil, 'unknown' end
   return capture_identity(timer)
end
local function begin_timer(record)
   if not state.enabled or not owns(record) then return nil end
   timers.clock_reads = timers.clock_reads + 1
   local started = clock()
   if not started then clock_failure(); return nil end
   if started >= state.deadline_host_seconds then disable('deadline', started, false); return nil end
   timers.calls = timers.calls + 1
   return started, state.session
end
local function end_timer(record, timer, tracker_name, now, started, session, created_reason, source, line, kind, binding, origin)
   if not started or session ~= state.session or not owns(record) then return end
   timers.completed_count = timers.completed_count + 1
   timers.clock_reads = timers.clock_reads + 1
   local ended = clock()
   if not ended or ended < started then clock_failure(); return end
   local elapsed = (ended - started) * 1000
   -- Fallback get_reason runs after the end clock. Identity was captured before
   -- the start clock, before stock persistent fire can clear its one-shot _fn.
   local ok, reason = true, created_reason
   if not reason then ok, reason = pcall(read_reason, timer) end
   if not ok or type(reason) ~= 'string' then
      timers.reason_failures = timers.reason_failures + 1
      reason = '[reason unavailable]'
   end
   reason = bounded_name(reason, '[reason unavailable]')
   if session ~= state.session or not owns(record) then return end
   timers.timed_count, timers.total_ms = timers.timed_count + 1, timers.total_ms + elapsed
   timers.max_ms = math.max(timers.max_ms, elapsed)
   source, line, origin = source or '[unknown]', line or 0, origin or 'unknown'
   local key = reason .. '\0' .. source .. '\0' .. tostring(line) .. '\0' .. origin .. '\0' .. (binding or '')
   local aggregate = timers.reasons[key]
   if not aggregate and timers.reason_count < REASON_CAPACITY then
      aggregate = { reason = reason, calls = 0, total_ms = 0, max_ms = 0, slow_count = 0,
         callback_source = source, callback_line = line, callback_kind = kind,
         callback_binding = binding, identity_origin = origin }
      timers.reasons[key], timers.reason_count = aggregate, timers.reason_count + 1
   end
   if aggregate then
      aggregate.calls, aggregate.total_ms = aggregate.calls + 1, aggregate.total_ms + elapsed
      aggregate.max_ms = math.max(aggregate.max_ms, elapsed)
      if elapsed >= SLOW_MS then aggregate.slow_count = aggregate.slow_count + 1 end
   else
      timers.reason_overflow_count = timers.reason_overflow_count + 1
      timers.reason_overflow_ms = timers.reason_overflow_ms + elapsed
   end
   if elapsed >= SLOW_MS then
      timers.slow_count = timers.slow_count + 1
      local slot = (timers.slow_count - 1) % TIMER_CAPACITY + 1
      -- Only bounded strings and numbers are retained, never timers or entities.
      local event = timers.events[slot]
      if not event then event = {}; timers.events[slot] = event end
      event.reason, event.tracker = reason, bounded_name(tracker_name, '[unnamed tracker]')
      event.callback_source, event.callback_line, event.callback_kind = source, line, kind
      event.callback_binding, event.identity_origin = binding, origin
      event.start_host_seconds, event.end_host_seconds, event.elapsed_ms = started, ended, elapsed
      event.tracker_now = type(now) == 'number' and now == now and now ~= math.huge and now ~= -math.huge and now or nil
   end
   if state.enabled and ended >= state.deadline_host_seconds then disable('deadline', ended, false) end
end

-- Exact stock set_now dispatch, with timing only inside its existing xpcall.
-- No pcall encloses timer:fire; throwing callbacks keep stock exception handling.
local function timed_set_now(record, self, now)
   assert(not self._timers)
   assert(not self._sv._next_timers)
   self._sv._now = now
   local current_bucket = timer_floor(now / self._sv._bucket_size)
   self._sv._next_timers = {}
   local i = self._sv._last_bucket_processed
   local current_timer, fire_current
   local fired, created = 0, 0
   self._sv._buckets_per_interval = (self._sv._buckets_per_interval * 0.9) + (current_bucket - i + 1) * 0.1
   while i <= current_bucket do
      local bucket = self._sv._buckets[i]
      self._sv._buckets[i] = nil
      self._sv._last_bucket_processed = i
      i = i + 1
      if bucket then
         for _, timer in ipairs(bucket) do
            if timer.is_active and timer:is_active() then
               local should_fire = timer:get_expire_time() <= now
               if self._timer_stats then
                  radiant.inc2d(self._timer_stats, timer:get_reason(), should_fire and 'fire_count' or 'misfire_count')
               end
               if should_fire then
                  fired = fired + 1
                  if radiant.xpcall ~= timer_xpcall or xpcall ~= lua_xpcall then
                     created = created + 1
                     radiant.xpcall(function()
                        local reason, source, line, kind, binding, origin = read_identity(timer)
                        local started, session = begin_timer(record)
                        timer:fire(now)
                        end_timer(record, timer, self._name, now, started, session, reason, source, line, kind, binding, origin)
                     end)
                  else
                     current_timer = timer
                     if not fire_current then
                        fire_current = function()
                           local reason, source, line, kind, binding, origin = read_identity(current_timer)
                           local started, session = begin_timer(record)
                           current_timer:fire(now)
                           end_timer(record, current_timer, self._name, now, started, session, reason, source, line, kind, binding, origin)
                        end
                        created = created + 1
                     end
                     radiant.xpcall(fire_current)
                     current_timer = nil
                  end
               end
               if timer:is_active() then table.insert(self._sv._next_timers, timer) end
            end
         end
      end
   end
   self:_queue_next_timers()
   if record.always_clear_timers then self:_remove_inactive_timers() end
   if record.timer_dispatch_module and record.profile_token then
      record.timer_record_profile(record.profile_token, fired, created)
   end
end

local function optional_module(path)
   local require_module = radiant and radiant.mods and radiant.mods.require
   if type(require_module) ~= 'function' then return nil end
   local ok, module = pcall(require_module, path)
   if ok and type(module) == 'table' then return module end
end
local function configure_timer_dispatch(record, info)
   if record.name ~= 'TimeTracker:set_now' then return end
   record.timer_dispatch_supported = false
   -- The exact installed release-949 stock method is lines 54-108.
   -- A same-file foreign/stub function retains outer timing but is never dispatched here.
   if info.source == DISPATCH_SOURCE then
      local module = optional_module('hearth_smoother.timer_dispatch')
      local api_ok = module ~= nil
      for _, name in ipairs({ 'profile_contract', 'profile_ready', 'record_profile', 'register_profiler' }) do
         local fn = module and module[name]
         local ok, source = false, nil
         if type(fn) == 'function' then ok, source = pcall(debug.getinfo, fn, 'S') end
         if not ok or type(source) ~= 'table' or source.source ~= DISPATCH_SOURCE then api_ok = false end
      end
      local contract_ok, supported = false, false
      if api_ok then contract_ok, supported = pcall(module.profile_contract, record.owner, record.original) end
      if not api_ok or not contract_ok or not supported then
         record.timer_dispatch_skipped = 'unrecognized timer optimization wrapper'; return
      end
      record.timer_dispatch_module = module
      record.timer_profile_ready, record.timer_record_profile = module.profile_ready, module.record_profile
   elseif info.what ~= 'Lua' or info.source ~= TIMER_SOURCE or info.linedefined ~= 54 or info.lastlinedefined ~= 108 then
      record.timer_dispatch_skipped = 'stock set_now source/line shape differs'; return
   end
   if type(radiant.xpcall) ~= 'function' then
      record.timer_dispatch_skipped = 'stock config or xpcall API unavailable'; return
   end
   local ok, value = timer_configuration()
   if not timer_config_ok or not ok or value ~= timer_clear_config then
      record.timer_dispatch_skipped = 'timer clear configuration unavailable or changed since module load'; return
   end
   local floor_ok, floor_info = pcall(debug.getinfo, timer_floor, 'S')
   if not floor_ok or type(floor_info) ~= 'table' or floor_info.what ~= 'C' or math.floor ~= timer_floor then
      record.timer_dispatch_skipped = 'math.floor is foreign or changed since module load'; return
   end
   if type(timer_clear_config) ~= 'boolean' then
      record.timer_dispatch_skipped = 'timer clear configuration unavailable'; return
   end
   record.always_clear_timers = timer_clear_config
   record.timer_dispatch_supported = true
end

local function make_wrapper(record, candidate)
   return function(...)
      if not state.enabled or not owns(record) then return candidate(...) end
      local started = clock()
      if not started then clock_failure(); return candidate(...) end
      if started >= state.deadline_host_seconds then disable('deadline', started, false); return candidate(...) end
      record.calls = record.calls + 1
      if record.timer_dispatch_supported then
         if record.timer_dispatch_module then
            if record.timer_dispatch_module.profile_ready ~= record.timer_profile_ready
               or record.timer_dispatch_module.record_profile ~= record.timer_record_profile
               or not record.timer_profile_ready(record.profile_token, record.owner, candidate) then
               return finish(record, started, state.session, candidate(...))
            end
         end
         return finish(record, started, state.session, timed_set_now(record, ...))
      end
      return finish(record, started, state.session, candidate(...))
   end
end

-- The registered optimizer calls this proof against private record identities.
-- Merely forging an allowed source label is not sufficient to own this wrapper.
function M.owns_timer_wrapper(owner, current, candidate, token)
   if not state.applied then return false end
   for _, record in ipairs(state.methods) do
      if record.name == 'TimeTracker:set_now' and record.owner == owner and record.wrapper == current
         and record.original == candidate and record.profile_token == token and token ~= nil
         and record.generation == state.generation and record.timer_dispatch_module then return true end
   end
   return false
end

local function timer_status()
   local reasons, events = {}, {}
   for _, entry in pairs(timers.reasons) do
      reasons[#reasons + 1] = { reason = entry.reason, calls = entry.calls, total_ms = entry.total_ms,
         max_ms = entry.max_ms, slow_count = entry.slow_count,
         callback_source = entry.callback_source, callback_line = entry.callback_line,
         callback_kind = entry.callback_kind, callback_binding = entry.callback_binding, identity_origin = entry.identity_origin }
   end
   table.sort(reasons, function(a, b)
      if a.total_ms == b.total_ms then return a.reason < b.reason end
      return a.total_ms > b.total_ms
   end)
   local count = math.min(timers.slow_count, TIMER_CAPACITY)
   local first = timers.slow_count > TIMER_CAPACITY and timers.slow_count % TIMER_CAPACITY + 1 or 1
   for i = 0, count - 1 do
      local entry = timers.events[(first + i - 1) % TIMER_CAPACITY + 1]
      events[#events + 1] = { reason = entry.reason, tracker = entry.tracker, elapsed_ms = entry.elapsed_ms,
         start_host_seconds = entry.start_host_seconds, end_host_seconds = entry.end_host_seconds,
         tracker_now = entry.tracker_now, callback_source = entry.callback_source, callback_line = entry.callback_line,
         callback_kind = entry.callback_kind, callback_binding = entry.callback_binding, identity_origin = entry.identity_origin }
   end
   return { calls = timers.calls, completed_count = timers.completed_count, timed_count = timers.timed_count,
      clock_reads = timers.clock_reads, reason_failures = timers.reason_failures,
      total_ms = timers.total_ms, max_ms = timers.max_ms, slow_event_count = timers.slow_count,
      slow_events = events, slow_event_capacity = TIMER_CAPACITY, slow_event_threshold_ms = SLOW_MS,
      reasons = reasons, reason_count = timers.reason_count, reason_capacity = REASON_CAPACITY,
      reason_length_limit = REASON_LENGTH, reason_overflow_count = timers.reason_overflow_count,
      reason_overflow_ms = timers.reason_overflow_ms,
      identity_limit = 'Creation labels describe the original callback; a foreign replacement may differ. Existing native timers with no creation label remain unknown. Stock persistent callback identity is read before firing.',
      dependency_assumption = 'Stock tracker and profiler were loaded with the same unchanged timer-clear setting and native math.floor. A config change between profiler load and apply refuses copied dispatch; an older stock upvalue cannot be inspected.',
      caveat = 'Inclusive callback wall time includes clock-call overhead. Do not add callback and outer method totals. Throwing callbacks have no completed duration; calls may exceed completed_count. Identity reads precede the start clock; fallback get_reason follows the end clock.' }
end
local function allowed(source, list)
   for _, expected in ipairs(list) do if source == expected then return true end end
   return false
end
local function resolve(target, classes)
   if target.kind == 'radiant' then return radiant end
   if target.kind == 'ai' then return stonehearth and stonehearth.ai end
   if classes[target.path] ~= nil then return classes[target.path] or nil end
   local require_module = radiant and radiant.mods and radiant.mods.require
   if type(require_module) ~= 'function' then classes[target.path] = false; return nil end
   local ok, value = pcall(require_module, target.path)
   classes[target.path] = ok and (type(value) == 'table' and value or false) or false
   return classes[target.path] or nil
end

function M.status()
   local now = clock()
   local host_ok, host_name = pcall(host_identifier)
   if state.enabled then
      if not now then clock_failure()
      elseif now >= state.deadline_host_seconds then disable('deadline', now, false) end
   end
   if creation.capturing and (not now or now < creation.started_host_seconds or now >= creation.deadline_host_seconds) then
      creation.capturing = false
      creation.stop_reason = not now and 'clock_failure' or now < creation.started_host_seconds and 'backwards_clock' or 'deadline'
   end
   local methods, count, active = {}, 0, 0
   for _, record in ipairs(state.methods) do
      local is_active = record.wrapper ~= nil and owns(record) or false
      if record.wrapper then count = count + 1 end
      if is_active then active = active + 1 end
      methods[record.name] = { source = record.source, active = is_active, applied = record.wrapper ~= nil,
         skipped_reason = record.skipped_reason, calls = record.calls, completed_count = record.completed_count,
         timed_count = record.timed_count, total_ms = record.total_ms, max_ms = record.max_ms,
         timer_dispatch_supported = record.timer_dispatch_supported,
         timer_dispatch_skipped = record.timer_dispatch_skipped }
   end
   local events, event_count = {}, math.min(state.slow_event_count, EVENT_CAPACITY)
   local first = state.slow_event_count > EVENT_CAPACITY and state.slow_event_count % EVENT_CAPACITY + 1 or 1
   for i = 0, event_count - 1 do
      local event = state.events[(first + i - 1) % EVENT_CAPACITY + 1]
      events[#events + 1] = { name = event.name, start_host_seconds = event.start_host_seconds,
         end_host_seconds = event.end_host_seconds, elapsed_ms = event.elapsed_ms }
   end
   return { applied = state.applied, enabled = state.enabled, session = state.session,
      current_host_seconds = now, clock_available = now ~= nil,
      current_host = host_ok and host_name or '[unavailable]',
      started_host_seconds = state.started_host_seconds, deadline_host_seconds = state.deadline_host_seconds,
      stopped_host_seconds = state.stopped_host_seconds, duration_seconds = state.duration_seconds,
      stop_reason = state.stop_reason, clock_failures = state.clock_failures,
      installed_method_count = count, active_method_count = active, methods = methods,
      slow_event_count = state.slow_event_count, slow_events = events, slow_event_capacity = EVENT_CAPACITY,
      slow_event_threshold_ms = SLOW_MS, clock = '_host:get_realtime()',
      timer_callbacks = timer_status(),
      timer_creation = { applied = creation.record ~= nil and creation.record.wrapper ~= nil,
         active = creation.record ~= nil and creation.record.wrapper ~= nil and owns(creation.record) or false,
         capturing = creation.capturing, capture_mode = creation.capture_mode,
         source = creation.record and TIMER_SOURCE or nil, expected_first_line = 154, expected_last_line = 181,
         started_host_seconds = creation.started_host_seconds,
         deadline_host_seconds = creation.deadline_host_seconds, stop_reason = creation.stop_reason,
         skipped_reason = creation.skipped_reason, record_count_upper_bound = creation.count, capacity = CREATION_CAPACITY,
         captured = creation.captured, capacity_skips = creation.capacity_skips, metadata_failures = creation.metadata_failures,
         scope = 'Runtime weak keys with scalar values only. Count is an upper bound between profile starts because weak keys may be collected. Bootstrap lasts at most 180 seconds; manual stop closes it.' },
      timing_semantics = 'Inclusive elapsed wall time; nested method totals must not be added. Not CPU self time or FPS.',
      coverage_limit = 'Active ownership with zero calls does not prove absence of work: native code may retain an original callback reference.' }
end

function M.apply()
   if state.applied then return true, M.status() end
   state.generation = state.generation + 1
   state.methods = {}
   local classes, installed = {}, 0
   for _, target in ipairs(targets) do
      local record = { name = target.name, method = target.method, kind = target.kind,
         generation = state.generation, calls = 0, completed_count = 0, timed_count = 0, total_ms = 0, max_ms = 0 }
      state.methods[#state.methods + 1] = record
      local owner = resolve(target, classes)
      local candidate = owner and owner[target.method]
      local getinfo = debug and debug.getinfo
      if type(candidate) ~= 'function' or type(getinfo) ~= 'function' then
         record.skipped_reason = 'method or debug.getinfo unavailable'
      else
         local ok, info = pcall(getinfo, candidate, 'S')
         record.source = ok and type(info) == 'table' and info.source or nil
         if not record.source or not allowed(record.source, target.sources) then
            record.skipped_reason = 'unsupported ownership source'
         else
            record.owner, record.original = owner, candidate
            configure_timer_dispatch(record, info)
            record.wrapper = make_wrapper(record, candidate)
            owner[target.method] = record.wrapper
            if record.source == BOOTSTRAP_SOURCE then
               local bootstrap = optional_module('hearth_smoother.restock_bootstrap')
               local ok, accepted = false, false
               if bootstrap and type(bootstrap.register_profiler) == 'function' then
                  ok, accepted = pcall(bootstrap.register_profiler, target.method, record.wrapper, candidate)
               end
               if not ok or not accepted then
                  owner[target.method], record.wrapper = candidate, nil
                  record.skipped_reason = 'unrecognized restock bootstrap wrapper'
               end
            end
            if record.source == '@hearth_smoother/restock_slice.lua' then
               local slice = optional_module('hearth_smoother.restock_slice')
               local ok, accepted = false, false
               if slice and type(slice.register_profiler) == 'function' then
                  ok, accepted = pcall(slice.register_profiler, target.method, record.wrapper, candidate)
               end
               if not ok or not accepted then
                  owner[target.method], record.wrapper = candidate, nil
                  record.skipped_reason = 'unrecognized restock optimization wrapper'
               end
            end
            local passive_span = target.method == '_transfer_failed_items_into_reconsider_queues'
               and info.linedefined == 559 and info.lastlinedefined == 575
               or target.method == '_transfer_reconsider_items_into_restockable_queue'
               and info.linedefined == 540 and info.lastlinedefined == 557
            if record.source == RESTOCK_SOURCE and info.what == 'Lua' and passive_span then
               local slice = optional_module('hearth_smoother.restock_slice')
               local ok, accepted = false, false
               if slice and type(slice.register_profiler) == 'function' then
                  ok, accepted = pcall(slice.register_profiler, target.method, record.wrapper, candidate)
               end
               record.passive_slice_registration = ok and accepted == true or false
            end
            if record.wrapper then installed = installed + 1 end
         end
      end
   end
   state.applied = installed > 0
   if not state.applied then return false, 'no supported outer methods available' end
   creation.record, creation.skipped_reason = nil, nil
   local owner = resolve({ path = 'radiant.controllers.time_tracker_controller' }, classes)
   local candidate = owner and owner.set_timer
   local ok, info = false, nil
   if type(candidate) == 'function' and debug and type(debug.getinfo) == 'function' then ok, info = pcall(debug.getinfo, candidate, 'S') end
   if ok and type(info) == 'table' and info.what == 'Lua' and info.source == TIMER_SOURCE
      and info.linedefined == 154 and info.lastlinedefined == 181 then
      local record = { owner = owner, method = 'set_timer', original = candidate, generation = state.generation }
      record.wrapper = make_creation_wrapper(record, candidate)
      owner.set_timer, creation.record = record.wrapper, record
      local now = clock()
      creation.capturing, creation.capture_mode = now ~= nil, 'bootstrap'
      creation.started_host_seconds = now
      creation.deadline_host_seconds = now and now + MAX_SECONDS or nil
      creation.stop_reason = now and nil or 'clock_failure'
   else
      creation.capturing, creation.skipped_reason = false, 'stock set_timer source/line shape differs or unavailable'
   end
   for _, record in ipairs(state.methods) do
      if record.timer_dispatch_module then
         local ok, token = pcall(record.timer_dispatch_module.register_profiler, M)
         record.profile_token = ok and token or nil
         if not record.profile_token then
            record.timer_dispatch_supported = false
            record.timer_dispatch_skipped = 'profiler registration unavailable'
         end
      end
   end
   return true, M.status()
end

function M.start(seconds)
   if type(seconds) ~= 'number' or seconds ~= seconds or seconds < 0 or seconds > MAX_SECONDS then
      return false, 'duration must be finite seconds in [0, 180]'
   end
   if seconds == 0 then return true, M.stop() end
   if not state.applied then return false, 'timing wrappers are not applied' end
   local now = clock()
   if not now then clock_failure(); return false, 'host realtime clock unavailable' end
   state.session = state.session + 1
   state.enabled, state.duration_seconds = true, seconds
   state.started_host_seconds, state.deadline_host_seconds = now, now + seconds
   state.stopped_host_seconds, state.stop_reason = nil, nil
   if creation.record and owns(creation.record) then
      local count = 0
      for _ in pairs(creation_records) do count = count + 1 end
      creation.count, creation.capturing, creation.capture_mode = count, true, 'profile'
      creation.started_host_seconds = now
      creation.deadline_host_seconds, creation.stop_reason = now + seconds, nil
   end
   state.clock_failures, state.slow_event_count, state.events = 0, 0, {}
   reset_timers()
   for _, record in ipairs(state.methods) do
      record.calls, record.completed_count, record.timed_count, record.total_ms, record.max_ms = 0, 0, 0, 0, 0
   end
   return true, M.status()
end

function M.stop()
   disable('manual', clock(), true)
   return M.status()
end

function M.restore()
   disable('restore', clock(), true)
   if creation.record and creation.record.owner.set_timer == creation.record.wrapper then
      creation.record.owner.set_timer = creation.record.original
   end
   for _, record in ipairs(state.methods) do
      if record.wrapper and record.owner[record.method] == record.wrapper then record.owner[record.method] = record.original end
   end
   state.applied = false
   state.generation = state.generation + 1
   return M.status()
end

return M

