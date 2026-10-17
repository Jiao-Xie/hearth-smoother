-- Explicit bounded inclusive wall-time diagnostic; no queries or callbacks replaced.
-- Arguments and results are forwarded only on the Lua call stack, never retained.
local M = {}
local MAX_SECONDS, EVENT_CAPACITY, SLOW_MS = 180, 64, 5
local targets = {
   {name='FollowPath:_find_intercept_path', path='stonehearth.ai.lib.follow_path', method='_find_intercept_path', optional=true,
      sources={{'@stonehearth/ai/lib/follow_path.lua',425,461}},
      scope='Lua intercept outer: includes direct finder and synchronous fallback; unavailable when native FollowPath is selected.'},
   {name='PathFinderComponent:find_path_to_entity', path='stonehearth.components.pathfinder.pathfinder_component', method='find_path_to_entity',
      sources={{'@stonehearth/components/pathfinder/pathfinder_component.lua',127,141}},
      scope='Ordinary AStar registration/submission; can reuse a search. Not asynchronous search lifetime or a native query creation count.'},
   {name='PathFinderComponent:_find_path_to_entity_type_ipf', path='stonehearth.components.pathfinder.pathfinder_component', method='_find_path_to_entity_type_ipf',
      sources={{'@stonehearth/components/pathfinder/pathfinder_component.lua',165,184}},
      scope='IPF registration/submission including cache setup and cached result dispatch; can reuse a query.'},
   {name='PathFinderComponent:_find_path_to_entity_type_bfs', path='stonehearth.components.pathfinder.pathfinder_component', method='_find_path_to_entity_type_bfs',
      sources={{'@stonehearth/components/pathfinder/pathfinder_component.lua',186,203}},
      scope='BFS registration/submission including cache setup and cached result dispatch; can reuse a search.'},
   {name='PathFinderComponent:find_path_to_entity_sync', path='stonehearth.components.pathfinder.pathfinder_component', method='find_path_to_entity_sync',
      sources={{'@stonehearth/components/pathfinder/pathfinder_component.lua',109,123}},
      scope='Synchronous component outer including start/search/stop/reset; excludes direct users of get_sync_pathfinder.'},
   {name='IpfSearch:_call_solved_cbs', path='stonehearth.components.pathfinder.ipf_search', method='_call_solved_cbs',
      sources={{'@stonehearth/components/pathfinder/ipf_search.lua',192,216}},
      scope='IPF result dispatch including downstream callbacks, lease checks and reentry; not native search work.'},
   {name='BfsSearch:_call_solved_cbs', path='stonehearth.components.pathfinder.bfs_search', method='_call_solved_cbs',
      sources={{'@stonehearth/components/pathfinder/bfs_search.lua',202,226}},
      scope='BFS result dispatch including downstream callbacks, lease checks and reentry; not native search work.'},
   {name='AStarSearch:_on_exhausted', path='stonehearth.components.pathfinder.astar_search', method='_on_exhausted',
      sources={{'@stonehearth/components/pathfinder/astar_search.lua',144,155}},
      scope='AStar exhausted callback dispatch only; ordinary solved callbacks deliberately remain unwrapped.'},
   {name='PutAnotherRestockableItemIntoBackpack:_find_path_to_item', path='stonehearth.ai.actions.put_another_restockable_item_into_backpack_action', method='_find_path_to_item',
      sources={{'@stonehearth_ace/monkey_patches/ace_put_another_restockable_item_into_backpack_action.lua',70,218},
         {'@stonehearth/ai/actions/put_another_restockable_item_into_backpack_action.lua',143,249}},
      scope='Backpack synchronous search outer including candidates, filter, lease, inventory and AI future-state work; not AStar self CPU.'}
}
local state = {applied=false, enabled=false, generation=0, session=0, clock_reads=0, clock_failures=0,
   slow_event_count=0, records={}, events={}}
-- Allocate only these fixed slots once, never during a measured call.
for i=1,EVENT_CAPACITY do state.events[i]={} end
local function finite(value)
   return type(value)=='number' and value==value and value~=math.huge and value~=-math.huge
end
local function raw_clock() return _host:get_realtime() end
local function disable(reason, now, invalidate)
   state.enabled=false
   state.stop_reason, state.stopped_host_seconds=reason,now
   if invalidate then state.session=state.session+1 end
end
local function clock_failure(reason)
   state.clock_failures=state.clock_failures+1
   state.last_clock_failure=reason
   disable('clock_failure',nil,true)
end
local function observe_clock()
   state.clock_reads=state.clock_reads+1
   local generation,session=state.generation,state.session
   local ok,now=pcall(raw_clock)
   if generation~=state.generation or session~=state.session then return nil,'session_changed' end
   if not ok or not finite(now) then clock_failure('unavailable_or_nonfinite'); return nil end
   if state.last_observed_host_seconds and now<state.last_observed_host_seconds then
      clock_failure('backwards'); return nil
   end
   state.last_observed_host_seconds=now
   return now
end
local function owns(record)
   return state.applied and record.wrapper~=nil and record.generation==state.generation
      and record.owner[record.method]==record.wrapper
end
local function slow_event(record,started,ended,elapsed)
   state.slow_event_count=state.slow_event_count+1
   local item=state.events[(state.slow_event_count-1)%EVENT_CAPACITY+1]
   item.sequence,item.session,item.name=state.slow_event_count,state.session,record.name
   item.start_host_seconds,item.end_host_seconds,item.elapsed_ms=started,ended,elapsed
end
local function finish(record,started,session,...)
   if state.session~=session or not owns(record) then return ... end
   record.completed_count=record.completed_count+1
   local ended=observe_clock()
   if not ended or state.session~=session or not owns(record) then return ... end
   local elapsed=(ended-started)*1000
   record.timed_count,record.total_ms=record.timed_count+1,record.total_ms+elapsed
   if elapsed>record.max_ms then record.max_ms=elapsed end
   if elapsed>=SLOW_MS then slow_event(record,started,ended,elapsed) end
   if state.enabled and ended>=state.deadline_host_seconds then disable('deadline',ended,false) end
   return ...
end
local function make_wrapper(record,candidate)
   return function(...)
      if not state.enabled or not owns(record) then return candidate(...) end
      local started=observe_clock()
      if not started or not state.enabled or not owns(record) then return candidate(...) end
      if started>=state.deadline_host_seconds then disable('deadline',started,false); return candidate(...) end
      record.calls=record.calls+1
      local session=state.session
      -- No protected call, coroutine wrapper, result pack or per-call closure.
      -- Original errors propagate and therefore have no completed duration.
      return finish(record,started,session,candidate(...))
   end
end
local function read_method(owner,method) return owner[method] end
local function inspect(candidate,target)
   if type(candidate)~='function' or type(debug)~='table' or type(debug.getinfo)~='function' then return nil end
   local ok,info=pcall(debug.getinfo,candidate,'S')
   if not ok or type(info)~='table' then return nil end
   if info.what=='Lua' then
      for _,source in ipairs(target.sources) do
         if info.source==source[1] and info.linedefined==source[2] and info.lastlinedefined==source[3] then return info,true end
      end
   end
   return info,false
end
local function snapshot()
   local methods,installed,active={},0,0
   for _,r in ipairs(state.records) do
      local owned=owns(r)
      if r.wrapper then installed=installed+1 end
      if owned then active=active+1 end
      methods[r.name]={applied=r.wrapper~=nil,active=not not owned,optional=r.optional or false,
         skipped_reason=r.skipped_reason,observed_owner_type=r.observed_owner_type,
         source=r.source,linedefined=r.linedefined,lastlinedefined=r.lastlinedefined,
         calls=r.calls,completed_count=r.completed_count,timed_count=r.timed_count,
         total_ms=r.total_ms,max_ms=r.max_ms,scope=r.scope}
   end
   local events={}
   local n=state.slow_event_count<EVENT_CAPACITY and state.slow_event_count or EVENT_CAPACITY
   for sequence=state.slow_event_count-n+1,state.slow_event_count do
      local e=state.events[(sequence-1)%EVENT_CAPACITY+1]
      events[#events+1]={sequence=e.sequence,session=e.session,name=e.name,
         start_host_seconds=e.start_host_seconds,end_host_seconds=e.end_host_seconds,elapsed_ms=e.elapsed_ms}
   end
   return {applied=state.applied,enabled=state.enabled,capturing=state.enabled,session=state.session,
      generation=state.generation,target_count=#targets,installed_method_count=installed,active_method_count=active,
      skipped_reason=state.skipped_reason,methods=methods,clock='_host:get_realtime()',clock_reads=state.clock_reads,
      clock_failures=state.clock_failures,last_clock_failure=state.last_clock_failure,
      current_host_seconds=state.last_observed_host_seconds,started_host_seconds=state.started_host_seconds,
      deadline_host_seconds=state.deadline_host_seconds,stopped_host_seconds=state.stopped_host_seconds,
      duration_seconds=state.duration_seconds,stop_reason=state.stop_reason,
      slow_event_count=state.slow_event_count,slow_events=events,
      slow_event_capacity=EVENT_CAPACITY,slow_event_threshold_ms=SLOW_MS,
      timing_semantics='Inclusive completed-call elapsed wall milliseconds, including child calls and any external callback yield/wait. Not CPU self time or asynchronous search lifetime. Nested method totals overlap and must not be added. Errors have calls but no completed duration; stop/restart/restore invalidates in-flight completions.',
      coverage_limit='Default native FollowPath is not wrapped: the Lua intercept target may be unavailable. Ordinary AStar solved callbacks and guarded AStar methods remain untouched to preserve astar_callback ownership. Short-lived native work, native internal/slave searches and callbacks retaining pre-apply method references may be invisible. Submission counts may reuse existing searches and are not new native query counts.',
      deadline_semantics='No timer or trace. The 0..180 second admission deadline is checked at entry, completion and enabled status reads. A call admitted before expiry may complete after expiry and contributes its full wall duration unless explicitly stopped, restarted or restored.',
      clock_snapshot_scope='current_host_seconds is the last validated clock observation; disabled status performs no clock read.'}
end
function M.apply()
   if state.applied then
      for _,r in ipairs(state.records) do
         if r.wrapper and not owns(r) then return false,'timing method ownership changed: '..r.name end
      end
      return true,snapshot()
   end
   local resolver=radiant and radiant.mods and radiant.mods.require
   if type(resolver)~='function' or type(debug)~='table' or type(debug.getinfo)~='function' then
      state.skipped_reason='module/source inspection unavailable'; return false,state.skipped_reason
   end
   state.generation=state.generation+1
   state.records={}
   local classes,installed={},0
   for _,target in ipairs(targets) do
      local r={name=target.name,method=target.method,scope=target.scope,optional=target.optional,
         generation=state.generation,calls=0,completed_count=0,timed_count=0,total_ms=0,max_ms=0}
      state.records[#state.records+1]=r
      local owner=classes[target.path]
      if owner==nil then
         local ok,value=pcall(resolver,target.path)
         owner=ok and value or false
         classes[target.path]=owner
      end
      r.observed_owner_type=type(owner)
      if type(owner)~='table' then r.skipped_reason='owner_not_table'
      else
         local ok,candidate=pcall(read_method,owner,target.method)
         if not ok or type(candidate)~='function' then r.skipped_reason='method_unavailable'
         else
            local info,supported=inspect(candidate,target)
            if info then r.source,r.linedefined,r.lastlinedefined=info.source,info.linedefined,info.lastlinedefined end
            if not supported then r.skipped_reason='unsupported_source_or_lines'
            else
               r.owner,r.original=owner,candidate
               r.wrapper=make_wrapper(r,candidate)
               owner[target.method]=r.wrapper
               installed=installed+1
            end
         end
      end
   end
   state.applied=installed>0
   state.skipped_reason=installed==0 and 'no supported timing targets' or nil
   return state.applied,state.applied and snapshot() or state.skipped_reason
end
function M.start(seconds)
   if not finite(seconds) or seconds<0 or seconds>MAX_SECONDS or seconds%1~=0 then
      return false,'duration must be integer seconds in [0, 180]'
   end
   if seconds==0 then
      disable('manual',state.last_observed_host_seconds,true)
      return true,snapshot()
   end
   if not state.applied then return false,'timing wrappers are not applied' end
   for _,r in ipairs(state.records) do
      if r.wrapper and not owns(r) then return false,'timing method ownership changed: '..r.name end
   end
   -- A fresh session may start after a clock reset, but never conceal a failure
   -- during an active session. Validate before replacing the previous counters.
   if not state.enabled then state.last_observed_host_seconds=nil end
   local now,reason=observe_clock()
   if not now then return false,reason or 'host realtime clock unavailable or backwards' end
   state.session=state.session+1
   state.enabled,state.duration_seconds=true,seconds
   state.started_host_seconds,state.deadline_host_seconds=now,now+seconds
   state.stopped_host_seconds,state.stop_reason=nil,nil
   state.clock_reads,state.clock_failures,state.last_clock_failure=1,0,nil
   state.slow_event_count=0
   for _,r in ipairs(state.records) do
      r.calls,r.completed_count,r.timed_count,r.total_ms,r.max_ms=0,0,0,0,0
   end
   return true,snapshot()
end
function M.status()
   if state.enabled then
      local now=observe_clock()
      if now and now>=state.deadline_host_seconds then disable('deadline',now,false) end
   end
   return snapshot()
end
function M.restore()
   disable('restore',state.last_observed_host_seconds,true)
   for _,r in ipairs(state.records) do
      if r.wrapper and r.owner[r.method]==r.wrapper then r.owner[r.method]=r.original end
   end
   state.applied=false
   state.generation=state.generation+1
   return snapshot()
end
return M

