
(function () {
   var object;

   // Hearth Smoother v122: contain UI event-handler exceptions. Scalar diagnostics only.
   var hsPumpState = {
      version: 'v123', polls_started: 0, polls_completed: 0,
      events_dispatched: 0, event_errors: 0, batch_errors: 0,
      request_errors: 0, logging_errors: 0, errors_total: 0,
      trace_errors: 0, trace_quarantined: 0, trace_cleanup_errors: 0,
      rpc_progress_quarantined: 0,
      native_log_attempts: 0, native_log_succeeded: 0, native_log_failed: 0,
      native_log_reentrant_suppressed: 0, native_log_limit_suppressed: 0,
      active_requests: 0, retry_scheduled: false, errors: []
   };
   function hsPumpString(value, limit) {
      return typeof value === 'string' ? value.slice(0, limit) : '';
   }
   // Only bounded scalar error summaries are sent to the existing native logger.
   // Never report a logging failure through hsPumpReport: that would recurse.
   var hsPumpNativeLogBusy = false;
   function hsPumpNativeLog(record) {
      if (hsPumpNativeLogBusy) {
         hsPumpState.native_log_reentrant_suppressed++;
         return;
      }
      if (hsPumpState.native_log_attempts >= 16) {
         hsPumpState.native_log_limit_suppressed++;
         return;
      }
      hsPumpState.native_log_attempts++;
      hsPumpNativeLogBusy = true;
      var settled = false;
      var settle = function (ok) {
         if (settled) { return; }
         settled = true;
         if (ok) { hsPumpState.native_log_succeeded++; }
         else { hsPumpState.native_log_failed++; }
      };
      try {
         var summary = ('[Hearth Smoother UI v123] #' + record.sequence +
            ' time_ms=' + record.time_ms + ' kind=' + record.kind +
            ' event=' + record.type + ' call_id=' + record.call_id + '\n' +
            record.message + '\n' + record.stack).slice(0, 4096);
         var request = radiant.call('radiant:browser_log', summary);
         request.done(function () { settle(true); })
            .fail(function () { settle(false); });
      } catch (ignoredNativeLoggingError) {
         settle(false);
      } finally {
         hsPumpNativeLogBusy = false;
      }
   }
   function hsPumpReport(kind, event, error) {
      var message = '', stack = '', type = '', callId = null;
      try {
         if (typeof error === 'string') { message = error; }
         else if (error) {
            message = hsPumpString(error.message, 512);
            stack = hsPumpString(error.stack, 2048);
         }
      } catch (ignoredErrorProperties) { message = '[unreadable error properties]'; }
      try {
         if (event) {
            type = hsPumpString(event.type, 160);
            var id = event.data && event.data.call_id;
            if (typeof id === 'string') { callId = id.slice(0, 128); }
            else if (typeof id === 'number' && isFinite(id)) { callId = id; }
         }
      } catch (ignoredEventProperties) { type = '[unreadable event properties]'; }
      var timeMs = null;
      try { timeMs = Date.now(); } catch (ignoredClockError) {}
      hsPumpState.errors_total++;
      var record = {
         sequence: hsPumpState.errors_total, time_ms: timeMs, kind: kind, type: type,
         call_id: callId, message: hsPumpString(message, 512), stack: stack
      };
      hsPumpState.errors.push(record);
      if (hsPumpState.errors.length > 16) { hsPumpState.errors.shift(); }
      hsPumpNativeLog(record);
      // Avoid unbounded console retention during a repeating bad subscription.
      if (record.sequence <= 16 || record.sequence % 128 === 0) {
         try {
            console.error('[Hearth Smoother UI event error #' + record.sequence + ']',
               record.kind, record.type, record.call_id, record.message, record.stack);
         } catch (ignoredLoggingError) { hsPumpState.logging_errors++; }
      }
   }
   radiant.hearthSmootherEventPump = {
      version: 'v123',
      snapshot: function () {
         return JSON.parse(JSON.stringify(hsPumpState));
      }
   };

   function hsPumpTraceDispatch(trace, method, data) {
      if (trace._hsPumpQuarantined) { return; }
      try {
         trace._deferred[method](data);
      } catch (traceError) {
         // jQuery 2.1.4 leaves a throwing callback list firing. Sending it more
         // progress would queue payloads forever. Isolate only this raw consumer;
         // its view/owner must recreate it. Healthy sibling consumers continue.
         trace._hsPumpQuarantined = true;
         hsPumpState.trace_errors++;
         hsPumpState.trace_quarantined++;
         hsPumpReport('trace_callback', {
            type: method,
            data: {call_id: trace._tracer && trace._tracer._call_id}
         }, traceError);
      }
   }

   var Tracer = SimpleClass.extend({
      init: function (deferred, uri, tracerMap) {
         this._uri = uri;
         this._traces = [];
         this._tracerMap = tracerMap;
         this._dead_traces = [];

         this._stats = {
            progress : 0,
            done : 0,
            fail : 0
         };

         var self = this;

         deferred.done(function(data) {
            self._result = data;
            self._stats.done++;
            self._protectTraceList(function() {
               _.each(self._traces, function (trace) {
                  hsPumpTraceDispatch(trace, 'resolve', data);
               });
            });
         });
         deferred.fail(function(data) {
            self._stats.fail++;
            self._error = data;
            self._protectTraceList(function() {
               _.each(self._traces, function (trace) {
                  hsPumpTraceDispatch(trace, 'reject', data);
               });
            });
         });
         deferred.progress(function(data) {
            self._progress = data;
            self._stats.progress++;

            self._protectTraceList(function() {
               _.each(self._traces, function (trace) {
                  hsPumpTraceDispatch(trace, 'notify', data);
               });
            });
         });
      },

      setCallId: function (call_id) {
         this._call_id = call_id;
      },

      _protectTraceList: function(fn) {
         var self = this;
         var wasProtected = this._protect_traces === true;
         this._protect_traces = true;
         try {
            fn();
         } finally {
            this._protect_traces = wasProtected;
            if (!wasProtected) {
               var deadTraces = self._dead_traces;
               self._dead_traces = [];
               _.each(deadTraces, function (trace) {
                  try {
                     self.removeTrace(trace);
                  } catch (cleanupError) {
                     hsPumpState.trace_cleanup_errors++;
                     hsPumpReport('trace_cleanup', null, cleanupError);
                  }
               });
            }
         }
      },

      addTrace: function(trace) {
         this._traces.push(trace);
         if (this._result) {
            hsPumpTraceDispatch(trace, 'resolve', this._result);
         } else if (this._error) {
            hsPumpTraceDispatch(trace, 'reject', this._error);
         } else if (this._progress) {
            // Must do this async, since the progress calls aren't saved, and the callback may not be registered yet.
            var self = this;
            setTimeout(function () {
               if (self._traces.indexOf(trace) >= 0 && trace._deferred) {  // Haven't removed it yet.
                  hsPumpTraceDispatch(trace, 'notify', self._progress);
               }
            }, 0);
         }
         return trace;
      },

      removeTrace: function(trace) {
         if (this._protect_traces) {
            this._dead_traces.push(trace);
            return;
         }
         var offset = this._traces.indexOf(trace);
         radiant.assert(offset >= 0, 'trace not found in remove_trace');
         this._traces.splice(offset, 1); // remove it
         if (this._traces.length == 0) {
            radiant.call('radiant:remove_trace', this._uri, this._call_id);
            delete object._pendingCalls[this._call_id];
            delete this._tracerMap[this._uri];
            delete trace._deferred;
         }
      }
   });

   var _nextTraceId = 1;
   var Trace = SimpleClass.extend({
      init: function (tracer) {
         this._id = _nextTraceId++;
         this._deferred = $.Deferred();
         this._tracer = tracer;
         this._tracer.addTrace(this);
      },

      get_id: function () {
         return this._id;
      },

      progress: function (cb) {
         this._deferred.progress(cb);
         return this;
      },

      fail: function (cb) {
         this._deferred.fail(cb);
         return this;
      },

      done: function (cb) {
         this._deferred.done(cb);
         return this;
      },

      always: function (cb) {
         this._deferred.always(cb);
         return this;
      },

      destroy: function() {
         if (this._tracer) {
            this._tracer.removeTrace(this);
            this._tracer = undefined;
         }
      }
   });

   var RadiantObject = SimpleClass.extend({
      init: function () {
         this._pendingCalls = {};
         this._enqueuedTraces = {};

         var self = this;
         $(document).ready(function() {
            var foward_fn = function(e, o) {
               var d = self._pendingCalls[o.call_id];
               if (d) {
                  var f = {
                     'radiant_call_progress' : d.notify,
                     'radiant_call_done' : d.resolve,
                     'radiant_call_fail' : d.reject
                  }[e.type];
                  if (f) {
                     var isProgress = e.type === 'radiant_call_progress';
                     if (isProgress && d._hsPumpProgressQuarantined) { return; }
                     try {
                        f(o.data);
                     } catch (callbackError) {
                        if (isProgress) {
                           d._hsPumpProgressQuarantined = true;
                           hsPumpState.rpc_progress_quarantined++;
                        }
                        throw callbackError;
                     }
                  }
               }
            };
            var finish_fn = function(e, o) {
                try {
                   foward_fn(e, o);
                } finally {
                   delete self._pendingCalls[o.call_id];
                }
            };
            $(top).on("radiant_call_progress", foward_fn);
            $(top).on("radiant_call_done", finish_fn);
            $(top).on("radiant_call_fail", finish_fn);
            self._start_poll();
         });
      },

      _start_poll : function() {
         var self = this;
         // This private method has one owner. Never create a second in-flight poll.
         if (self._hsPumpBusy) { return; }
         self._hsPumpBusy = true;
         var deferred;
         try {
            deferred = self._docall('/r/call/?fn=radiant:get_events', []).deferred;
         } catch (requestError) {
            hsPumpState.request_errors++;
            hsPumpReport('request_setup', null, requestError);
            hsPumpState.retry_scheduled = true;
            // A single delayed retry avoids recursive failure if AJAX setup throws.
            setTimeout(function () {
               hsPumpState.retry_scheduled = false;
               self._hsPumpBusy = false;
               self._start_poll();
            }, 1000);
            return;
         }
         hsPumpState.polls_started++;
         hsPumpState.active_requests = 1;
         var finished = false;
         var finish = function () {
            if (finished) { return; }
            finished = true;
            hsPumpState.polls_completed++;
            hsPumpState.active_requests = 0;
            self._hsPumpBusy = false;
            self._start_poll();
         };
         deferred
            .done(function (data) {
               try {
                  // Retain the native empty/string-response behavior.
                  if (!data || typeof data == 'string') { return; }
                  $.each(data, function (_, event) {
                     try {
                        hsPumpState.events_dispatched++;
                        $(top).trigger(event.type, event.data);
                     } catch (eventError) {
                        hsPumpState.event_errors++;
                        hsPumpReport('event_callback', event, eventError);
                     }
                  });
               } catch (batchError) {
                  hsPumpState.batch_errors++;
                  hsPumpReport('batch_dispatch', null, batchError);
               } finally {
                  // Do not replay any event: earlier handlers may have committed work.
                  finish();
               }
            })
            .fail(function (data) {
               try {
                  hsPumpState.request_errors++;
                  var reason = 'radiant:get_events failed';
                  try {
                     if (data && typeof data.error === 'string') { reason = data.error; }
                  } catch (ignoredFailureProperties) { reason += ' [unreadable error]'; }
                  hsPumpReport('request_failed', null, reason);
               } finally {
                  finish();
               }
            });
      },

      _docall : function (url, args) {
         var self = this;
         var deferred = $.Deferred();

         var request = $.ajax({
            type: 'post',
            url: url,
            contentType: 'application/json',
            data: JSON.stringify(args),
            timeout: 60000  // 60 seconds as an excessive but safe margin, since some initial fetches can be huge and the C++ process may be busy loading stuff.
         }).fail(function(data) {
            var error = data.responseText;
            deferred.reject({ error: error });
         }).done(function(data) {
            if (data.type == 'radiant_call_deferred') {
               self._pendingCalls[data.call_id] = deferred;
            } else {
               deferred.resolve(data);
            }
         });
         return { deferred: deferred, request: request };
      },

      _enqueueTrace: function (url) {
         var self = this;
         var deferred = $.Deferred();
         var isFirstTrace = $.isEmptyObject(self._enqueuedTraces);
         var tracer = new Tracer(deferred, url, radiant._tracerMap);
         self._enqueuedTraces[url] = { deferred: deferred, tracer: tracer };
         if (isFirstTrace) {
            // Schedule a submission of this batch.
            setTimeout(function () {
               var queue = self._enqueuedTraces;
               self._enqueuedTraces = {};
               var request = $.ajax({
                  type: 'post',
                  url: '/r/call/?fn=radiant:install_traces',
                  data: JSON.stringify(Object.keys(queue)),
                  contentType: 'application/json',
                  timeout: 60000  // 60 seconds as an excessive but safe margin, since some initial fetches can be huge and the C++ process may be busy loading stuff.
               }).fail(function (data) {
                  radiant.each(queue, function (k, v) {
                     v.deferred.reject({ error: data.responseText });
                  });
               }).done(function (data) {
                  radiant.each(data, function (k, call_id) {
                     var v = queue[k];
                     if (call_id === 0) {
                        v.deferred.reject({ error: "failed to install trace" });
                     } else {
                        v.tracer.setCallId(call_id);
                        self._pendingCalls[call_id] = v.deferred;
                     }
                  });
               });
            }, 0);
         }
         return tracer;
      },
   });

   object = new RadiantObject();

   radiant._tracerMap = {};

   // TODO: maybe collect stats as traces are deleted?
   radiant.get_tracer_map_stats = function() {
      var result = {};

      radiant.each(radiant._tracerMap, function(k, v) {
         var stats = result[k];

         if (!stats) {
            stats = {
               fail: 0,
               done: 0,
               progress: 0
            };
            result[k] = stats;
         }

         stats.done += v._stats.done;
         stats.fail += v._stats.fail;
         stats.progress += v._stats.progress;

         v._stats.done = 0;
         v._stats.fail = 0;
         v._stats.progress = 0;
      });

      return result;
   };

   radiant.callv = function(fn, args) {
      return object._docall('/r/call/?fn='+fn, args);
   };

   radiant.call_objv = function(obj, fn, args) {
      // all callable objects have a __self entry which contains the uri of
      // the object.  let users pass those in directly.
      if (typeof obj == 'object' && obj.__self) {
         obj = obj.__self;
      }
      return object._docall('/r/call/?obj='+obj + '&fn='+fn, args);
   };

   radiant.call = function () {
      var args = Array.prototype.slice.call(arguments);
      if (args.length < 1) {
         throw "radiant:call requires at least 1 argument.";
      }
      var fn = args[0];
      args = args.slice(1);
      return radiant.callv(fn, args).deferred;
   };

   radiant.call_obj = function() {
      var args = Array.prototype.slice.call(arguments);
      if (args.length < 2) {
         throw "radiant:call_obj requires at least 2 arguments.";
      }
      var obj = args[0];
      var fn = args[1];
      args = args.slice(2);
      return radiant.call_objv(obj, fn, args).deferred;
   };

   radiant.trace = function(uri) {
      var tracer = this._tracerMap[uri];
      if (tracer == undefined) {
         tracer = object._enqueueTrace(uri);
         this._tracerMap[uri] = tracer;
      }
      return new Trace(tracer);
   };

   radiant.shallow_copy = function(o) {
      var shallow = {}
      radiant.each(o, function(k, v) {
         shallow[k] = v;
      });
      return shallow;
   };

   radiant.deep_copy_pod = function (o) {
      // Not the most performant, and does not clone functions or prototyped objects, but the simplest solution for PoDs.
      return JSON.parse(JSON.stringify(o));
   };

   // Iterate through each index or key in an array of map.  Takes special
   // care to avoid "private" keys, including things that start with "__", like
   // Radiant's __self and all sorts of stuff throw in by Ember.
   radiant.each = function(o, fn) {      
      if (o) {
         if (Array.isArray(o)) {
            $.each(o, function(index, value) {
               fn(index, value);
            });
         } else {
            $.each(o, function(key, value) {
               if (o.hasOwnProperty(key) && key.indexOf('__') != 0) {
                  fn(key, value);
               }
            });
         }
      }
   };

   // the `filter_fn` is optional.  if specified, will visit each key, value pair
   // before the value is stuffed into the array.  if the filter returns `false`,
   // the value will be omitted.  if it returns `undefined` (or simply 'return's)
   // the origonal (possibly modified) value will be stuffed in the array.  if it
   // returns any other value, that value will be shoved in the array instead of the
   // origonal
   radiant.map_to_array = function(map, filter_fn) {
      var array = [];
      radiant.each(map, function(key, value) {
         if (!filter_fn) {
            array.push(value);
         } else {
            var result = filter_fn(key, value);
            if (result === false) {
            } else if (result === undefined) {
               array.push(value);
            } else {
               array.push(result);
            }
         }
      });
      return array;
   };

   radiant.isNonEmptyString = function(str) {
      return ((typeof str != "undefined") &&
         (typeof str.valueOf() == "string")) &&
         (str.length > 0);
   };

   //lower ordinal -> higher priority
   radiant.sortByOrdinal = function(array) {
      array.sort(function(a, b) {
         return a.ordinal - b.ordinal;
      });
   };

   //Given a string or array of roles, return an array of classes that are relevant to this item
   radiant.findRelevantClassesArray = function(roles) {
      var classes = {};
      var classArray = [];
      if ((typeof roles) === 'string') {
         roles = roles.split(" ");
      }
      var jobData = App.jobConstants;
      for( i=0; i<roles.length; i++ ) {
         var thisRole = roles[i];
         var roleInfo = App.roleConstants[thisRole];
         if (roleInfo) {
            radiant.each(roleInfo, function(targetClass, value) {
               if (!classes[targetClass]) {
                  classes[targetClass] = true;
                  var classInfo = {
                     name : targetClass,
                     readableName:  jobData[targetClass].description.display_name, 
                     icon : jobData[targetClass].description.icon
                  };
                  classArray.push(classInfo);
               }
            });
         }
      }
      return classArray;
   };

   radiant.getJobsForRole = function(roles) {
      var jobs = {};
      if ((typeof roles) === 'string') {
         roles = roles.split(" ");
      }
      var jobData = App.jobConstants;
      for( i=0; i<roles.length; i++ ) {
         var thisRole = roles[i];
         var roleInfo = App.roleConstants[thisRole];
         if (roleInfo) {
            radiant.each(roleInfo, function(targetClass, value) {
               jobs[targetClass] = true;
            });         
         }
      }
      return jobs;
   };

   //Given an array of classes, as produced by findRelevantClasses, above, return a string
   radiant.getClassString = function(classArray) {
      var acceptableClasses = '';
      for (i=0; i<classArray.length; i++) {
         if (i==0) {
            acceptableClasses += i18n.t(classArray[i].readableName) + " ";
         } else {
            acceptableClasses += i18n.t('stonehearth:ui.game.unit_frame.or') + i18n.t(classArray[i].readableName) + " ";
         }
      }
      return acceptableClasses;
   };

   radiant.getEntityId = function(entityData) {
      if (!entityData) {
         return undefined;
      }

      var match = entityData.__self.match(/\/(\d+)$/)
      if (!match) {
         return undefined;
      }
      return parseInt(match[1]);
   };

   //ingredientData.kind is material if we are looking for a material, and uri if we are looking
   //for a URI. Identifier is either the material string or the uri. Also takes a 
   //reference to a usable inventory tracker
   radiant.findUsableCount = function(ingredientData, usableInventoryTracker) {
      var numHave = 0;
     
      if (usableInventoryTracker) {
         if (ingredientData.kind == 'uri') {
            var usableData = usableInventoryTracker[ingredientData.identifier];
            var itemEntry;
            if (usableData) {
               itemEntry = usableData;
            } else {
               for (var k in usableInventoryTracker) {
                  var v = usableInventoryTracker[k];
                  if (v.canonical_uri == ingredientData.identifier) {
                     itemEntry = v;
                     break;
                  }
               }
            }

            if (itemEntry) {
               if (ingredientData.quality) {
                  radiant.each(itemEntry.item_qualities, function (quality, qualityEntry) {
                     if (quality == ingredientData.quality) {
                        numHave = qualityEntry.count;
                     }
                  });
               } else {
                  numHave = itemEntry.count;
               }
            }

         } else if (ingredientData.kind == 'material') {
            var targetMaterialList = ingredientData.identifier;
            for (var itemType in usableInventoryTracker) {
               if (usableInventoryTracker.hasOwnProperty(itemType) && usableInventoryTracker[itemType]) {
                  var catalog = App.catalog.getCatalogData(itemType);
                  if (catalog && catalog.materials) {
                     if (radiant.isMaterial(catalog.materials, targetMaterialList)) {
                        numHave += usableInventoryTracker[itemType].count;
                     }
                  }
               }
            }
         }         
      }
      return numHave;
   };

   var __materialCheckCache = {};

   //Is the materialInQuestion a targetMaterial? For example is a "wood resource food container" a "food container"?
   //targetMaterials is a list of materials
   //returns true if targetMaterial is a subset of materialInQuestion
   radiant.isMaterial = function (materialInQuestion, targetMaterials) {
      var srcCache = __materialCheckCache[materialInQuestion];
      if (!srcCache) {
         __materialCheckCache[materialInQuestion] = srcCache = {};
      }
      if (srcCache[targetMaterials] === undefined) {
         var foundAll = true;

         var materialsInQuestionArray = materialInQuestion;
         if ((typeof materialsInQuestionArray) === 'string') {
            materialsInQuestionArray = materialInQuestion.split(' ');
         }
         var materialsInQuestionDictionary = {};
         for (var i = 0; i < materialsInQuestionArray.length; i++) {
            materialsInQuestionDictionary[materialsInQuestionArray[i]] = true;
         }

         var targetMaterialParts = targetMaterials.split(' ');
         for (var i = 0; i < targetMaterialParts.length; i++) {
            var tag = targetMaterialParts[i];
            var found_tag = materialsInQuestionDictionary[tag];
            if (!found_tag) {
               foundAll = false;
               break;
            }
         }
         srcCache[targetMaterials] = foundAll;
      }
      return srcCache[targetMaterials];
   };

   radiant.getExpPercentAndLabel = function(jobComponentData) {
      if (jobComponentData) {
         var expPercent, expLabel;
         var jobController = jobComponentData.curr_job_controller;

         if (typeof jobController == 'string') {
            console.log('curr_job_controller %s needs to be serialized', jobController);
            return;
         }

         if (jobComponentData.xp_to_next_lv == null) {
            console.log('xp_to_next_lv is nil');
            return;
         }

         // if job has no levels (like worker)
         if (jobController && jobController.no_levels) {
            expPercent = 0;
            expLabel = i18n.t('stonehearth:ui.game.citizen_character_sheet.no_levels');
         // if entity is at max level for this job
         } else if (jobController && jobController.is_max_level) {
            expPercent = 100;
            expLabel = i18n.t('stonehearth:ui.game.citizen_character_sheet.max_level');
         // has levels and can continue to gain exp
         } else {
            var currentLevelExp = jobComponentData.current_level_exp;
            var nextLevelExp = jobComponentData.xp_to_next_lv;
            expPercent = Math.floor(currentLevelExp * 100 / nextLevelExp);

            var currLevel = jobComponentData.curr_job_level;
            var nextLevel = currLevel ? currLevel + 1 : 1;
            expLabel = i18n.t('stonehearth:ui.game.citizen_character_sheet.level_abbreviation') + nextLevel;
         }

         return { percent: expPercent, label: expLabel };
      }
   };

   radiant.applyItemQualityBonus = function(bonus_type, value, quality) {
      var bonuses = App.constants.item_quality.bonuses[bonus_type];
      if (!bonuses) {
         console.log('no item quality constants found for type ' + bonus_type);
         return null;
      }
      if (quality == -1) {  // any quality
         quality = 1;
      }
      var bonus = bonuses[quality - 1];  // Indices start from 1 because... Lua.
      if (typeof bonus != 'number') {
         console.log('no item quality multiplier found for quality ' + quality);
         return null;
      }

      var result;
      if (value < 0) {
         result = Math.min(value + (Math.abs(value) * bonus), 0);
      } else {
         result = value + (value * bonus);
      }

      return Math.round(result);
   };

   // construct an array for display in the UI
   // optional filter function
   radiant.constructTemplateDataList = function(templates, filterFn) {
      var templatesArray = [];
      radiant.each(templates, function(fileName, templateHeader) {
         if (filterFn && filterFn(fileName, templateHeader) == false) {
            return; // continue
         }

         var templateData = {};

         var name = templateHeader.display_name;
         if (name) {
            name = i18n.t(name);
         } else if (templateHeader.custom_name) {
            name = templateHeader.custom_name;
         } else {
            name = templateHeader.name;
         }

         var modName = templateHeader.mod_name;
         if (modName) {
            var localized_mod = i18n.t(modName);
            if (localized_mod) {
               templateData.modName = localized_mod;
            } else {
               templateData.modName = modName;
            }
         }

         templateData.templateName = name;
         templateData.fileName = (templateHeader.file_name || fileName).toString();
         if (templateHeader.is_custom_template) {
            templateData.imageStyle = "/r/building_templates/" + templateData.fileName;
         } else {
            templateData.imageStyle = templateHeader.preview_image;
         }

         templatesArray.push(templateData);
      });

      templatesArray.sort(function(d1, d2) {
         if (d1.templateName < d2.templateName) {
            return -1;
         } else if (d1.templateName == d2.templateName) {
            return 0;
         }
         return 1;
      });

      return templatesArray;
   };

   radiant.isOnline = function(presenceData) {
      var connectionStates = App.constants.multiplayer.connection_state;
      return presenceData.connection_state == connectionStates.CONNECTED || 
         presenceData.connection_state == connectionStates.CONNECTING;
   };

   radiant.isOwnedByAnotherPlayer = function(entity, playerId) {
      return entity.player_id && entity.player_id != '' && entity.player_id != playerId;
   };
})();

