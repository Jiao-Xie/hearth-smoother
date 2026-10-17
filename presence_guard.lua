-- Base is_non_npc reads datastore.players[player_id].is_non_npc without nil checks.
-- Keep its established values; absent replicated data is temporarily treated as NPC.
local M = {}
local logged = false

function M.is_non_npc(self, player_id)
   if not self._presence_datastore then return false end
   local data = self._presence_datastore:get_data()
   if not data or not data.players or player_id == nil then return false end
   local player = data.players[player_id]
   if not player then return false end
   return player.is_non_npc
end

function M.apply(presence_class, instance)
   if not presence_class or type(presence_class.is_non_npc) ~= 'function' then
      return false, 'unsupported presence client layout'
   end
   presence_class.is_non_npc = M.is_non_npc
   if instance then instance.is_non_npc = M.is_non_npc end
   if not logged then
      logged = true
      radiant.log.create_logger('hearth_smoother'):write(0, 'client presence is_non_npc nil guard installed')
   end
   return true
end

return M

