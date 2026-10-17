if hearth_smoother_presence_guard then return hearth_smoother_presence_guard end
hearth_smoother_presence_guard = require 'hearth_smoother.presence_guard'

local function apply_guard()
   local PresenceClientService = require 'stonehearth.services.client.presence_client.presence_client_service'
   hearth_smoother_presence_guard.apply(PresenceClientService,
      stonehearth and stonehearth.presence_client)
end

-- ACE doesn't replace is_non_npc. Reapply after its class patches for explicit ordering.
radiant.events.listen_once(radiant, 'radiant:required_loaded', apply_guard)
radiant.events.listen_once(radiant, 'stonehearth_ace:client:required_loaded', apply_guard)
radiant.events.listen_once(radiant, 'radiant:client:server_ready', apply_guard)

return hearth_smoother_presence_guard

