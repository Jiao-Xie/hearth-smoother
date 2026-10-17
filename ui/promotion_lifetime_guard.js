/* Hearth Smoother: ACE promotion view lifetime and relevant inventory updates.
 * ES5 / CEF 54. Native promotion rules, RPC, selection and stamp timings remain native.
 */
(function (global) {
   'use strict';
   var version = '0.10.22';
   var own = Object.prototype.hasOwnProperty;
   function state(view) {
      return view.__hsPromotionState || (view.__hsPromotionState = {
         generation: 0, opened: false, citizenReady: false, rendered: null,
         treeRefreshes: 0, skippedInventoryRefreshes: 0
      });
   }
   function live(view, generation) {
      var s = state(view);
      return s.opened && s.generation === generation && !view.isDestroyed &&
         !view.isDestroying && view.get('isVisible') !== false;
   }
   function release(view, key) {
      var trace = view[key];
      view[key] = null;
      if (trace) { trace.destroy(); }
   }
   function reset(view) {
      var s = state(view);
      s.generation++;
      s.citizenReady = false;
      s.rendered = null;
      s.inventoryRequest = s.jobRequest = s.citizenRequest = null;
      release(view, '_playerInventoryTrace');
      release(view, '_jobsTrace');
      release(view, '_citizenTrace');
      view.set('inventory_data', null);
   }
   function close(view) {
      state(view).opened = false;
      reset(view);
   }
   function identity(citizen) {
      return citizen && typeof citizen === 'object' ? citizen.__self : citizen;
   }
   function inventory(view) {
      var s = state(view), generation = s.generation;
      if (!live(view, generation) || s.inventoryRequest || view._playerInventoryTrace) { return; }
      var request = {};
      s.inventoryRequest = request;
      radiant.call_obj('stonehearth.inventory', 'get_item_tracker_command', 'stonehearth:basic_inventory_tracker')
         .done(function (response) {
            if (!live(view, generation) || s.inventoryRequest !== request) { return; }
            s.inventoryRequest = null;
            if (!response || !response.tracker) { return; }
            var trace = new StonehearthDataTrace(response.tracker, {tracking_data: {'*': {}}});
            view._playerInventoryTrace = trace;
            trace.progress(function (data) {
               if (live(view, generation) && view._playerInventoryTrace === trace) {
                  view.set('inventory_data', data && data.tracking_data);
               }
            }).fail(function () {
               if (view._playerInventoryTrace === trace) { release(view, '_playerInventoryTrace'); }
            });
         }).fail(function (error) {
            if (live(view, generation) && s.inventoryRequest === request) {
               s.inventoryRequest = null;
               console.error(error);
            }
         });
   }
   // Snapshot only promotion inputs. Inventory counts and first-item identity do
   // not affect the native rule: it checks first_item truthiness. Keep per-URI
   // presence so alternate tools changing cannot accidentally suppress refresh.
   function renderKey(view) {
      var items = view.get('inventory_data'), jobs = view._jobData;
      var rows = [view._startingJob, view._baseWorkerJob, view.get('selectedJobAlias'), view.get('jobLocked')];
      Object.keys(jobs).sort().forEach(function (alias) {
         var job = jobs[alias], desc = job.description, tools = [], uris;
         if (desc) {
            uris = desc.talisman_uris;
            if (!uris) { uris = {}; uris[desc.talisman_uri] = true; }
            Object.keys(uris).sort().forEach(function (uri) {
               tools.push([uri, !!uris[uri], !!(uris[uri] && items[uri] && items[uri].first_item)]);
            });
         }
         var controller = view._citizenJobData && view._citizenJobData[alias];
         rows.push([alias, desc ? desc.enabled : null, tools,
            desc ? view._calculateRequirementsMet(alias) : false,
            controller ? controller.last_gained_lv : null,
            view._citizenAllowedJobs ? !!view._citizenAllowedJobs[alias] : null]);
      });
      return JSON.stringify(rows);
   }
   function install() {
      if (typeof App === 'undefined' || !App.StonehearthPromotionTree || !App.View ||
          typeof StonehearthDataTrace !== 'function' || typeof radiant === 'undefined') { return false; }
      var klass = App.StonehearthPromotionTree;
      // Ember 1.8 classes materialize mixins lazily. Resolve them before checking
      // capabilities, and again after reopen; reading .prototype alone can see
      // an unmaterialized class before its first instance exists.
      var proto = typeof klass.proto === 'function' ? klass.proto() : klass.prototype;
      if (typeof App.View.proto === 'function') { App.View.proto(); }
      if (!proto || typeof klass.reopen !== 'function' || !App.View.prototype ||
          typeof App.View.prototype.didInsertElement !== 'function') { return false; }
      if (proto.__hsPromotionLifetimeVersion) { return proto.__hsPromotionLifetimeVersion === version; }
      // ACE-specific capabilities rather than raw function identity: Ember wraps
      // methods and a same-source function comparison is not a valid guard.
      var required = ['getParentJobs', '_isValidJob', '_calculateRequirementsMet', '_updateTalismanData',
         '_getJobIndex', '_getCitizenData', '_clearSettings', '_addHandlers', '_buildTree',
         '_buildTreeData', '_updateUi', '_promote', '_animateStamper', 'show', 'hide', 'dismiss', 'destroy'];
      for (var i = 0; i < required.length; i++) {
         if (typeof proto[required[i]] !== 'function') { return false; }
      }
      if (proto.templateName !== 'promotionTree' || typeof _cachedJobIndexes === 'undefined') { return false; }
      klass.reopen({
         __hsPromotionLifetimeVersion: version,
         didInsertElement: function () {
            state(this).opened = true;
            reset(this);
            this.$().draggable({handle: '.title'});
            radiant.call('radiant:play_sound', {track: 'stonehearth:sounds:ui:promotion_menu:scroll_open'});
            App.View.prototype.didInsertElement.call(this);
            this._addHandlers();
            this._getJobIndex();
         },
         show: function () {
            if (this.isDestroyed || this.isDestroying) { return; }
            state(this).opened = true;
            var result = this._super.apply(this, arguments);
            // App.View.show closes exclusive windows, possibly dismissing this
            // retained view itself before it becomes visible again. The native
            // show then sets the new citizen; acquire only that final context.
            if (!state(this).opened && !this.isDestroyed && !this.isDestroying && this.get('isVisible') !== false) {
               state(this).opened = true;
               this._getJobIndex();
            }
            return result;
         },
         dismiss: function () {
            close(this);
            return this._super.apply(this, arguments);
         },
         hide: function () {
            close(this);
            return this._super.apply(this, arguments);
         },
         destroy: function () {
            close(this);
            return this._super.apply(this, arguments);
         },
         _clearSettings: function () {
            reset(this);
            return this._super.apply(this, arguments);
         },
         _getJobIndex: function () {
            var view = this, s = state(view), generation = s.generation;
            if (!live(view, generation)) { return; }
            var citizen = identity(view.get('citizen'));
            if (!citizen) { return; }
            inventory(view);
            release(view, '_jobsTrace');
            release(view, '_citizenTrace');
            s.citizenReady = false;
            s.citizenRequest = null;
            s.rendered = null;
            var request = {};
            s.jobRequest = request;
            function valid() {
               return live(view, generation) && s.jobRequest === request && identity(view.get('citizen')) === citizen;
            }
            function finish(data) {
               if (!valid() || !data || !data.jobs) { return; }
               s.jobRequest = null;
               view._jobData = data.jobs;
               if (data.base_job) { view._baseWorkerJob = data.base_job; }
               view._getCitizenData();
            }
            function gotIndex(index) {
               if (!valid() || !index) { return; }
               if (own.call(_cachedJobIndexes, index)) { finish(_cachedJobIndexes[index]); return; }
               var trace = new StonehearthDataTrace(index, {jobs: {'*': {description: {}}}});
               view._jobsTrace = trace;
               trace.progress(function (data) {
                  if (!valid() || view._jobsTrace !== trace) { return; }
                  release(view, '_jobsTrace');
                  _cachedJobIndexes[index] = data;
                  finish(data);
               }).fail(function () {
                  if (view._jobsTrace === trace) { release(view, '_jobsTrace'); }
                  if (s.jobRequest === request) { s.jobRequest = null; }
               });
            }
            var index = view.get('job_index');
            if (index) { gotIndex(index); }
            else {
               radiant.call_obj('stonehearth.player', 'get_job_index', citizen)
                  .done(function (response) { if (valid()) { gotIndex(response && response.job_index); } })
                  .fail(function () {
                     if (valid()) { s.jobRequest = null; console.error('error getting job index'); }
                  });
            }
         },
         _getCitizenData: function () {
            var view = this, s = state(view), generation = s.generation;
            if (!live(view, generation) || !view._jobData) { return; }
            var citizen = identity(view.get('citizen'));
            if (!citizen) { return; }
            release(view, '_citizenTrace');
            s.citizenReady = false;
            s.rendered = null;
            var request = {};
            s.citizenRequest = request;
            var trace = new StonehearthDataTrace(citizen, {
               'stonehearth:job': {job_controllers: {'*': {}}, allowed_jobs: {}},
               'stonehearth:unit_info': {}, 'stonehearth:properties': {}
            });
            view._citizenTrace = trace;
            trace.progress(function (data) {
               if (!live(view, generation) || s.citizenRequest !== request ||
                   view._citizenTrace !== trace || identity(view.get('citizen')) !== citizen) { return; }
               release(view, '_citizenTrace');
               s.citizenRequest = null;
               var job = data && data['stonehearth:job'];
               if (!job) { return; }
               var props = data['stonehearth:properties'];
               var locked = props && props.properties && props.properties.job_locked || false;
               view.set('jobLocked', locked);
               view.set('jobLockedTitle', locked && i18n.t('stonehearth_ace:ui.game.promotion_tree.job_locked') || '');
               view._startingJob = job.job_uri;
               view._citizenJobData = job.job_controllers;
               view._citizenAllowedJobs = job.allowed_jobs;
               view.set('selectedJobAlias', view._startingJob);
               s.citizenReady = true;
               view._updateTalismanData();
               view.set('citizen', data);
            }).fail(function () {
               if (view._citizenTrace === trace) { release(view, '_citizenTrace'); }
               if (s.citizenRequest === request) { s.citizenRequest = null; }
            });
         },
         _updateTalismanData: function () {
            var s = state(this);
            if (!live(this, s.generation) || !s.citizenReady || !this._jobData ||
                !this._citizenJobData || !this.get('inventory_data')) { return; }
            var key = renderKey(this);
            if (key === s.rendered) { s.skippedInventoryRefreshes++; return; }
            var result = this._super.apply(this, arguments);
            s.treeRefreshes++;
            // Native allowed-jobs filtering can replace _jobData during rendering.
            s.rendered = renderKey(this);
            return result;
         }.observes('inventory_data'),
         _animateStamper: function () {
            var view = this, generation = state(view).generation;
            if (!live(view, generation)) { return; }
            radiant.call('radiant:play_sound', {track: 'stonehearth:sounds:ui:promotion_menu:stamp'});
            view.$('#approveStamper').animate({bottom: 20}, 130, function () {
               if (!live(view, generation)) { return; }
               var approved = view.$('#approvedStamp');
               if (!approved || !approved.length) { return; }
               approved.show();
               $(this).delay(200).animate({bottom: 200}, 150, function () {
                  if (!live(view, generation)) { return; }
                  setTimeout(function () {
                     if (live(view, generation)) { view.invokeDestroy(); }
                  }, 600);
               });
            });
         }
      });
      if (typeof klass.proto === 'function') { klass.proto(); }
      return true;
   }
   global.HearthSmootherPromotionLifetime = {
      version: version, install: install,
      isInstalled: function () {
         return typeof App !== 'undefined' && App.StonehearthPromotionTree &&
            App.StonehearthPromotionTree.prototype.__hsPromotionLifetimeVersion === version;
      },
      status: function () {
         var view = typeof App !== 'undefined' && App.stonehearth && App.stonehearth.promotionTreeView;
         var s = view && view.__hsPromotionState;
         return {version: version, installed: !!this.isInstalled(), view_present: !!view,
            opened: !!(s && s.opened), generation: s ? s.generation : null,
            citizen_ready: !!(s && s.citizenReady),
            inventory_trace: !!(view && view._playerInventoryTrace),
            jobs_trace: !!(view && view._jobsTrace), citizen_trace: !!(view && view._citizenTrace),
            inventory_pending: !!(s && s.inventoryRequest), jobs_pending: !!(s && s.jobRequest),
            tree_refreshes: s ? s.treeRefreshes : 0,
            skipped_inventory_refreshes: s ? s.skippedInventoryRefreshes : 0};
      }
   };
   var watchingStart = false, watchingGame = false;
   function afterModules() {
      install();
      // Mod scripts load asynchronously. DOM-ready can precede the ACE class,
      // and a later ACE assignment can replace a class patched earlier. These
      // existing app promises run after module loading without a polling timer.
      if (typeof App !== 'undefined') {
         if (!watchingStart && typeof App.waitForStartMenuLoad === 'function') {
            watchingStart = true;
            App.waitForStartMenuLoad().then(install);
         }
         if (!watchingGame && typeof App.waitForGameLoad === 'function') {
            watchingGame = true;
            App.waitForGameLoad().then(install);
         }
      }
   }
   afterModules();
   if (typeof $ !== 'undefined') { $(afterModules); }
}(typeof window !== 'undefined' ? window : this));

