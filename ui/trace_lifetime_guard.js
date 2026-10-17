/* Hearth Smoother: recursive RadiantTrace branch lifetime repair. ES5 / CEF 54. */
(function (global) {
   'use strict';
   var version = '0.10.0';
   function install() {
      if (typeof RadiantTrace === 'undefined' || !RadiantTrace.prototype ||
          typeof radiant === 'undefined' || typeof $ === 'undefined') {
         return false;
      }
      var proto = RadiantTrace.prototype;
      if (proto.__hearthSmootherTraceLifetime) { return true; }

      function release(traces) {
         if (!traces) { return; }
         for (var i = 0; i < traces.length; i++) { traces[i].destroy(); }
      }
      function ownedSnapshot(owner) {
         var traces = [];
         $.each(owner._traces, function (_, trace) { traces.push(trace); });
         return traces;
      }

      proto._expand_uri = function (uri, properties, level) {
         var self = this;
         var deferred = $.Deferred();
         var children = [];
         var generation = 0;
         var dead = false;
         var trace = radiant.trace(uri);
         var nativeDestroy = trace.destroy;
         var id = trace.get_id();

         // Return the original raw Trace. Its mutable children are owned by this
         // branch, rather than a flattened snapshot taken before async delivery.
         trace.destroy = function () {
            if (dead) { return; }
            dead = true;
            generation++;
            var previous = children;
            children = [];
            delete self._traces[id];
            try { release(previous); }
            finally { nativeDestroy.call(trace); }
         };
         self._traces[id] = trace;

         trace.progress(function (json) {
            if (dead || self._destroyed) { return; }
            var current = ++generation;
            var previous = children;
            children = [];
            if (json) {
               // Keep the native create-new-before-remove-old order. Both trees
               // may share one Tracer, including during protected iteration.
               var expanded;
               try {
                  expanded = self._expand_object(json, properties,
                     level !== undefined ? level + 1 : 0);
                  if (dead || self._destroyed || generation !== current) {
                     release(expanded[1]);
                     return;
                  }
                  children = expanded[1];
                  expanded[0].progress(function (eobj) {
                     if (!dead && !self._destroyed && generation === current) {
                        deferred.notify(eobj);
                     }
                  }).fail(function (error) {
                     if (!dead && !self._destroyed && generation === current) {
                        deferred.reject(error);
                     }
                  });
               } finally { release(previous); }
            } else {
               release(previous);
               if (!dead && !self._destroyed && generation === current) {
                  deferred.notify(null);
               }
            }
         }).fail(function (error) {
            if (dead || self._destroyed) { return; }
            generation++;
            var previous = children;
            children = [];
            release(previous);
            if (!dead && !self._destroyed) { deferred.reject(error); }
         });
         return [deferred, [trace]];
      };

      proto._destroyAllTraces = function () {
         // Snapshot avoids mutating the enumerated map as recursive destroy
         // removes descendants. Raw Trace wrappers make duplicate calls safe.
         release(ownedSnapshot(this));
         this._top_deferred = null;
         this._traces = {};
      };

      proto.traceUri = function (uri, properties) {
         var previous = ownedSnapshot(this);
         this._destroyed = false;
         try {
            this._top_deferred = this._expand_uri(uri,
               properties == null ? {} : properties)[0];
         } finally { release(previous); }
         return this._top_deferred;
      };
      proto.__hearthSmootherTraceLifetime = version;
      return true;
   }
   global.HearthSmootherTraceLifetime = {
      version: version,
      install: install,
      isInstalled: function () {
         return typeof RadiantTrace !== 'undefined' &&
            RadiantTrace.prototype.__hearthSmootherTraceLifetime === version;
      }
   };
   if (!install() && typeof $ !== 'undefined') { $(install); }
}(typeof window !== 'undefined' ? window : this));

