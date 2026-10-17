-- Spread initial Lua path-search launches using the stock asynchronous timer.
-- This changes launch timing only, not native A* algorithms or retry backoff.
local M = {}
local PATH = 'stonehearth.ai.actions.find_path_to_entity'
local SOURCE = '@stonehearth/ai/actions/find_path_to_entity.lua'
local owner, original, replacement, deps, methods, shared_log
local state = {applied=false, enabled=true, priming_calls=0, staggered_calls=0,
   total_added_ms=0, max_added_ms=0, compatibility_fallbacks=0,
   phase_histogram={0,0,0,0,0,0,0}}

local function source_is(fn, first, last)
   if type(fn) ~= 'function' then return false end
   local ok, info = pcall(debug.getinfo, fn, 'S')
   return ok and type(info)=='table' and info.source==SOURCE
      and info.linedefined==first and info.lastlinedefined==last
end

local function native(fn)
   if type(fn)~='function' then return false end
   local ok, info=pcall(debug.getinfo,fn,'S')
   return ok and type(info)=='table' and info.what=='C'
end

local function real_method(rng)
   return rng.get_real
end

local function compatible(self)
   if not owner or owner.start_thinking~=replacement
      or radiant.mods.require~=deps.require_module
      or radiant.set_realtime_timer~=deps.timer
      or _radiant.math.get_default_rng~=deps.get_rng
      or assert~=deps.assert or rawget~=deps.rawget or type~=deps.type
      or pcall~=deps.pcall or pairs~=deps.pairs or math.min~=deps.min or math.floor~=deps.floor
      or string.format~=deps.format then return false end
   for name,fn in pairs(methods) do
      if owner[name]~=fn or (self and self[name]~=fn) then return false end
   end
   return deps.rng.get_real==deps.get_real
end

function M.status()
   local histogram={}
   for i=1,7 do histogram[i]=state.phase_histogram[i] end
   return {applied=state.applied,enabled=state.enabled,
      active=state.applied and state.enabled and compatible() or false,
      expected_source=SOURCE,skipped_reason=state.skipped_reason,
      primed=shared_log~=nil,priming_calls=state.priming_calls,
      staggered_calls=state.staggered_calls,total_added_ms=state.total_added_ms,
      max_added_ms=state.max_added_ms,phase_histogram=histogram,
      compatibility_fallbacks=state.compatibility_fallbacks,
      phase_step_ms=10,phase_max_ms=60,
      scope='Initial Lua search launch timing only; stock timer, native search, cancellation and nonzero retry backoff retained.'}
end

function M.apply()
   if state.applied then
      if compatible() then return true,M.status() end
      return false,'FindPathToEntity ownership/dependency changed'
   end
   if not radiant or not radiant.mods or type(radiant.mods.require)~='function'
      or not _radiant or not _radiant.math or type(debug)~='table'
      or type(debug.getinfo)~='function' then
      state.skipped_reason='module/source inspection unavailable';return false,state.skipped_reason
   end
   local ok,cls=pcall(radiant.mods.require,PATH)
   if not ok or type(cls)~='table' or not source_is(cls.start_thinking,24,57) then
      state.skipped_reason='unsupported FindPathToEntity start method';return false,state.skipped_reason
   end
   local ranges={__init={20,22},_start_pathfinder={59,114},get_debug_info={116,120},
      _start_debug_timer={122,142},_on_position_changed={144,168},_cleanup={170,183},stop_thinking={185,196}}
   local checked={}
   for name,range in pairs(ranges) do
      if not source_is(cls[name],range[1],range[2]) then
         state.skipped_reason='unsupported FindPathToEntity helper: '..name;return false,state.skipped_reason
      end
      checked[name]=cls[name]
   end
   if not native(assert) or not native(rawget) or not native(type) or not native(pcall)
      or not native(pairs) or not native(math.min) or not native(math.floor)
      or not native(string.format) or not native(_radiant.math.get_default_rng) then
      state.skipped_reason='unsupported builtin or RNG factory';return false,state.skipped_reason
   end
   local got,rng=pcall(_radiant.math.get_default_rng)
   if not got or (type(rng)~='userdata' and type(rng)~='table') then
      state.skipped_reason='default RNG unavailable';return false,state.skipped_reason
   end
   local has_real,get_real=pcall(real_method,rng)
   if not has_real or not native(get_real) then
      state.skipped_reason='default RNG native get_real unavailable';return false,state.skipped_reason
   end
   -- The native default generator may be exposed through distinct Lua userdata
   -- wrappers. Their __eq is unsupported; never compare opaque RNG wrappers.
   -- Like stock callers, capture this native default factory result once.
   deps={require_module=radiant.mods.require,timer=radiant.set_realtime_timer,
      get_rng=_radiant.math.get_default_rng,rng=rng,get_real=get_real,
      assert=assert,rawget=rawget,type=type,pcall=pcall,pairs=pairs,
      min=math.min,floor=math.floor,format=string.format}
   owner,original,methods=cls,cls.start_thinking,checked
   shared_log=nil
   local captured_original=original
   local installed
   installed=function(self,ai,entity,args)
      if not state.applied or not state.enabled or replacement~=installed then
         return captured_original(self,ai,entity,args)
      end
      if not compatible(self) then
         state.compatibility_fallbacks=state.compatibility_fallbacks+1
         return captured_original(self,ai,entity,args)
      end
      -- Preserve the entire stock retry branch, including its original RNG call.
      if self._search_exhausted_count~=0 then return captured_original(self,ai,entity,args) end
      local get_id=entity and entity.get_id
      local valid,id=false,nil
      if type(get_id)=='function' then valid,id=pcall(get_id,entity) end
      if not valid or type(id)~='number' or id~=id or id<0 or id>9007199254740991
         or math.floor(id)~=id then
         state.compatibility_fallbacks=state.compatibility_fallbacks+1
         return captured_original(self,ai,entity,args)
      end
      if not shared_log then
         -- Stock owns this logger. Prime once without introspecting Lua upvalues.
         -- Only capture following normal return and a located, scheduled start.
         local result=captured_original(self,ai,entity,args)
         if rawget(self,'_timer') and rawget(self,'_location') then
            shared_log=rawget(self,'_log')
            if shared_log then state.priming_calls=state.priming_calls+1 end
         end
         return result
      end
      assert(not self._timer)
      assert(not self._pathfinder)
      if not ai.CURRENT.location then
         ai:set_debug_progress('dead; no starting location (suspended?)')
         return
      end
      self._ai=ai
      self._log=shared_log
      self._entity=entity
      self._location=ai.CURRENT.location
      self._destination=args.destination
      self._is_future=ai.CURRENT.location_changed
      self._thinking=true
      self._ready=false
      self._ai:set_debug_progress('starting thinking')
      local wait_time=self._search_exhausted_count*50
      wait_time=wait_time+deps.rng:get_real(0,wait_time)
      wait_time=math.min(30000,wait_time)
      local phase=(id%97)%7
      local added=phase*10
      wait_time=wait_time+added
      state.staggered_calls=state.staggered_calls+1
      state.total_added_ms=state.total_added_ms+added
      if added>state.max_added_ms then state.max_added_ms=added end
      state.phase_histogram[phase+1]=state.phase_histogram[phase+1]+1
      ai:set_debug_progress(string.format('waiting %.2fms to start pathfinder',wait_time))
      self._timer=radiant.set_realtime_timer('FindPathToEntity start_thinking',wait_time,function()
         self._timer=nil
         ai:set_debug_progress(string.format('starting pathfinder after %.2fms delay',wait_time))
         self:_start_pathfinder(ai)
      end)
   end
   replacement=installed
   cls.start_thinking=installed
   state.applied,state.skipped_reason=true,nil
   return true,M.status()
end

function M.set_enabled(value)
   if type(value)~='boolean' then return false,'enabled must be boolean' end
   state.enabled=value;return true,M.status()
end

function M.restore()
   if state.applied and owner.start_thinking==replacement then owner.start_thinking=original end
   state.applied=false
   return M.status()
end
return M

