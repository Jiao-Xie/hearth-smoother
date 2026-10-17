-- Reuse a dispatch closure only within one synchronous stock set_now invocation.
-- No saved variables, scheduling changes, global current timer or callback retention.
local M = {}
local PATH = 'radiant.controllers.time_tracker_controller'
local SOURCE = '@radiant/controllers/time_tracker_controller.lua'
local XPCALL_SOURCE = '@radiant/modules/commons.lua'
local PROFILE_SOURCE = '@hearth_smoother/function_timing.lua'
local floor, protected_call = math.floor, radiant.xpcall
local native_xpcall = xpcall
local getinfo = debug and debug.getinfo
local config_getter = radiant and radiant.util and radiant.util.get_global_config
local function configuration()
   local getter = radiant and radiant.util and radiant.util.get_global_config
   if type(getter) ~= 'function' then return false end
   local ok, value = pcall(getter, 'mods.stonehearth.always_clear_timers', false)
   return ok and type(value) == 'boolean', value
end
local config_ok, clear_timers = configuration()
local state = { applied = false, enabled = true, generation = 0, set_now_calls = 0,
   expired_fires = 0, closures_created = 0, closures_avoided = 0 }
local owner, original, wrapper, registration

local function source_is(fn, source, first, last)
   if type(fn) ~= 'function' or type(getinfo) ~= 'function' then return false end
   local ok, info = pcall(getinfo, fn, 'S')
   return ok and type(info) == 'table' and info.what == 'Lua' and info.source == source
      and (not first or info.linedefined == first) and (not last or info.lastlinedefined == last)
end
local function native_function(fn)
   if type(fn) ~= 'function' or type(getinfo) ~= 'function' then return false end
   local ok, info = pcall(getinfo, fn, 'S')
   return ok and type(info) == 'table' and info.what == 'C'
end
-- Function source metadata is immutable; validate once and then guard identity.
-- Avoid allocating debug-info tables on every optimized set_now invocation.
local helper_contract = source_is(protected_call, XPCALL_SOURCE, 64, 69)
   and native_function(floor) and native_function(native_xpcall)
local function dependencies_valid()
   if not helper_contract or not config_ok or not debug or debug.getinfo ~= getinfo
      or not radiant or radiant.xpcall ~= protected_call or math.floor ~= floor or xpcall ~= native_xpcall
      or not radiant.util or radiant.util.get_global_config ~= config_getter then return false end
   return true
end
local function configuration_matches()
   local ok, value = configuration()
   return config_ok and ok and value == clear_timers
end
local function profile_owns(current)
   local r = registration
   if not r or r.generation ~= state.generation then return false end
   local ok, value = pcall(r.module.owns_timer_wrapper, owner, current, wrapper, r.token)
   return ok and value == true
end
local function owns_current()
   return owner and (owner.set_now == wrapper or profile_owns(owner.set_now))
end

local function dispatch(self, now)
   assert(not self._timers)
   assert(not self._sv._next_timers)
   state.set_now_calls = state.set_now_calls + 1
   self._sv._now = now
   local current_bucket = floor(now / self._sv._bucket_size)
   self._sv._next_timers = {}
   local i = self._sv._last_bucket_processed
   local current_timer, fire_current
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
                  if radiant.xpcall ~= protected_call or xpcall ~= native_xpcall then
                     -- A callback may replace the helper mid-dispatch. Do not restart
                     -- the loop or reuse its closure with a foreign retaining helper.
                     state.closures_created = state.closures_created + 1
                     state.expired_fires = state.expired_fires + 1
                     radiant.xpcall(function() timer:fire(now) end)
                  else
                     current_timer = timer
                     if not fire_current then
                        fire_current = function() current_timer:fire(now) end
                        state.closures_created = state.closures_created + 1
                     else
                        state.closures_avoided = state.closures_avoided + 1
                     end
                     state.expired_fires = state.expired_fires + 1
                     protected_call(fire_current)
                     current_timer = nil
                  end
               end
               if timer:is_active() then table.insert(self._sv._next_timers, timer) end
            end
         end
      end
   end
   self:_queue_next_timers()
   if clear_timers then self:_remove_inactive_timers() end
end

function M.status()
   return { applied = state.applied, enabled = state.enabled,
      active = state.applied and owns_current() and dependencies_valid() or false,
      generation = state.generation, set_now_calls = state.set_now_calls,
      expired_fires = state.expired_fires, closures_created = state.closures_created,
      closures_avoided = state.closures_avoided, skipped_reason = state.skipped_reason,
      assumption = 'Stock and this module loaded with the same static clear-timers flag and native floor; older stock upvalues cannot be inspected.' }
end
function M.set_enabled(enabled)
   if type(enabled) ~= 'boolean' then return false, 'enabled must be boolean' end
   state.enabled = enabled
   return true, M.status()
end
function M.apply()
   if state.applied then
      if owns_current() then return true end
      return false, 'timer method changed by another module'
   end
   local require_module = radiant and radiant.mods and radiant.mods.require
   if type(require_module) ~= 'function' then return false, 'module loader unavailable' end
   local ok, cls = pcall(require_module, PATH)
   local candidate = ok and type(cls) == 'table' and cls.set_now
   if not source_is(candidate, SOURCE, 54, 108) or not dependencies_valid() or not configuration_matches() then
      state.skipped_reason = 'stock set_now/xpcall/floor/static configuration contract unavailable'
      return false, state.skipped_reason
   end
   state.generation = state.generation + 1
   local token = state.generation
   local this_wrapper
   this_wrapper = function(self, now, ...)
      if not state.applied or not state.enabled or state.generation ~= token
         or wrapper ~= this_wrapper or owner ~= cls or not owns_current() or not dependencies_valid() then
         return candidate(self, now, ...)
      end
      return dispatch(self, now)
   end
   owner, original, wrapper = cls, candidate, this_wrapper
   registration = nil
   cls.set_now = wrapper
   state.applied, state.skipped_reason = true, nil
   return true
end

-- Registration is tied to the actual cached profiler module and its private-record
-- proof, not acceptance of an arbitrary class wrapper's filename.
function M.register_profiler(module)
   local require_module = radiant and radiant.mods and radiant.mods.require
   if not state.applied or type(require_module) ~= 'function' or type(module) ~= 'table'
      or not source_is(module.owns_timer_wrapper, PROFILE_SOURCE) then return nil end
   local ok, cached = pcall(require_module, 'hearth_smoother.function_timing')
   if not ok or cached ~= module then return nil end
   local token = {}
   registration = { module = module, token = token, generation = state.generation }
   return token
end
function M.profile_contract(cls, candidate)
   return state.applied and cls == owner and candidate == wrapper and dependencies_valid()
      and configuration_matches() or false
end
function M.profile_ready(token, cls, candidate)
   return state.applied and state.enabled and registration and registration.token == token
      and registration.generation == state.generation and cls == owner and candidate == wrapper
      and owns_current() and dependencies_valid() or false
end
function M.record_profile(token, fired, created)
   if not registration or registration.token ~= token or registration.generation ~= state.generation then return end
   state.set_now_calls = state.set_now_calls + 1
   state.expired_fires = state.expired_fires + fired
   state.closures_created = state.closures_created + created
   state.closures_avoided = state.closures_avoided + math.max(0, fired - created)
end
function M.restore()
   -- A registered profiler captures this wrapper. Restoring here makes its retained
   -- candidate delegate stock; do not overwrite that profiler or a foreign method.
   if owner and owner.set_now == wrapper then owner.set_now = original end
   state.applied = false
   state.generation = state.generation + 1
   registration = nil
   return M.status()
end
return M

