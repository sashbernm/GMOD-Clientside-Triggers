local NET_SYNC_ = "sm_trigger_multiple_Sync"
local NET_REQUEST_ = "sm_trigger_multiple_Request"

local SF_TRIGGER_ALLOW_CLIENTS_ = 0x01
local SF_TRIGGER_ONLY_CLIENTS_IN_VEHICLES_ = 0x20
local SF_TRIGGER_ALLOW_ALL_ = 0x40
local SF_TRIGGER_ONLY_CLIENTS_OUT_OF_VEHICLES_ = 0x200
local SF_TRIGGER_DISALLOW_BOTS_ = 0x1000

local function vector_to_array(vector_value)
  return {vector_value.x, vector_value.y, vector_value.z}
end

local function array_to_vector(array_value)
  if not istable(array_value) then
    return Vector(0, 0, 0)
  end

  return Vector(
      tonumber(array_value[1]) or 0,
      tonumber(array_value[2]) or 0,
      tonumber(array_value[3]) or 0)
end

local function point_inside_aabb(world_pos, mins_value, maxs_value)
  return world_pos.x >= mins_value.x and world_pos.x <= maxs_value.x and
      world_pos.y >= mins_value.y and world_pos.y <= maxs_value.y and
      world_pos.z >= mins_value.z and world_pos.z <= maxs_value.z
end

local function segment_intersects_aabb(start_pos, end_pos, mins_value, maxs_value)
  local direction = end_pos - start_pos
  local t_min = 0
  local t_max = 1

  local function clip_axis(start_value, direction_value, min_value, max_value)
    if math.abs(direction_value) < 0.00001 then
      return start_value >= min_value and start_value <= max_value
    end

    local inv_direction = 1 / direction_value
    local t1 = (min_value - start_value) * inv_direction
    local t2 = (max_value - start_value) * inv_direction
    if t1 > t2 then
      t1, t2 = t2, t1
    end

    t_min = math.max(t_min, t1)
    t_max = math.min(t_max, t2)
    return t_max >= t_min
  end

  if not clip_axis(start_pos.x, direction.x, mins_value.x, maxs_value.x) then
    return false
  end

  if not clip_axis(start_pos.y, direction.y, mins_value.y, maxs_value.y) then
    return false
  end

  if not clip_axis(start_pos.z, direction.z, mins_value.z, maxs_value.z) then
    return false
  end

  return true
end

local function player_passes_spawnflags(player_value, spawnflags_value)
  local allow_players = spawnflags_value == 0 or
      bit.band(spawnflags_value, SF_TRIGGER_ALLOW_CLIENTS_) ~= 0 or
      bit.band(spawnflags_value, SF_TRIGGER_ALLOW_ALL_) ~= 0

  if not allow_players then
    return false
  end

  if bit.band(spawnflags_value, SF_TRIGGER_DISALLOW_BOTS_) ~= 0 and
      player_value:IsBot() then
    return false
  end

  local in_vehicle = player_value:InVehicle()
  if bit.band(spawnflags_value, SF_TRIGGER_ONLY_CLIENTS_IN_VEHICLES_) ~= 0 and
      not in_vehicle then
    return false
  end

  if bit.band(
          spawnflags_value,
          SF_TRIGGER_ONLY_CLIENTS_OUT_OF_VEHICLES_) ~= 0 and
      in_vehicle then
    return false
  end

  return true
end

local function get_output_event_kind(output_key)
  if not isstring(output_key) then
    return nil
  end

  local output_key_lower = string.lower(output_key)
  if string.sub(output_key_lower, 1, 12) == "onstarttouch" then
    return "start_touch"
  end

  if string.sub(output_key_lower, 1, 10) == "onendtouch" then
    return "end_touch"
  end

  return nil
end

local function parse_basevelocity_parameter(parameter_value)
  if not isstring(parameter_value) then
    return nil
  end

  local property_name, vector_text =
      string.match(parameter_value, "^%s*([^%s]+)%s+(.+)%s*$")
  if not property_name or string.lower(property_name) ~= "basevelocity" then
    return nil
  end

  local vector_parts = string.Explode(" ", string.Trim(vector_text), false)
  if #vector_parts < 3 then
    return nil
  end

  local x_value = tonumber(vector_parts[1])
  local y_value = tonumber(vector_parts[2])
  local z_value = tonumber(vector_parts[3])
  if not x_value or not y_value or not z_value then
    return nil
  end

  return Vector(x_value, y_value, z_value)
end

local function parse_basevelocity_output(output_value)
  if not isstring(output_value) then
    return nil
  end

  local output_parts = string.Explode(",", output_value, false)
  if #output_parts < 3 then
    return nil
  end

  local target_name = string.lower(string.Trim(output_parts[1] or ""))
  local input_name = string.lower(string.Trim(output_parts[2] or ""))
  local parameter_value = string.Trim(output_parts[3] or "")
  local delay_value = tonumber(string.Trim(output_parts[4] or "0")) or 0

  if target_name ~= "!activator" then
    return nil
  end

  if input_name ~= "addoutput" then
    return nil
  end

  if delay_value > 0 then
    return nil
  end

  return parse_basevelocity_parameter(parameter_value)
end

if SERVER then
  util.AddNetworkString(NET_SYNC_)
  util.AddNetworkString(NET_REQUEST_)

  local last_crc_ = nil
  local output_vectors_by_entity_ = setmetatable({}, {__mode = "k"})

  local function append_output_vector(
      output_table, output_key, vector_value)
    local output_list = output_table[output_key]
    if not output_list then
      output_list = {}
      output_table[output_key] = output_list
    end

    output_list[#output_list + 1] = vector_value
  end

  hook.Add("EntityKeyValue", "sm_trigger_multiple_CaptureMapOutputs",
           function(entity_value, key_name, key_value)
    if not IsValid(entity_value) then
      return
    end

    if entity_value:GetClass() ~= "trigger_multiple" then
      return
    end

    local event_kind = get_output_event_kind(key_name)
    if not event_kind then
      return
    end

    local basevelocity_value = parse_basevelocity_output(key_value)
    if not basevelocity_value then
      return
    end

    local output_table = output_vectors_by_entity_[entity_value]
    if not output_table then
      output_table = {}
      output_vectors_by_entity_[entity_value] = output_table
    end

    append_output_vector(output_table, event_kind, basevelocity_value)
  end)

  local function build_multiple_snapshot()
    local multiple_snapshot = {}
    local multiple_entities = ents.FindByClass("trigger_multiple")

    for multiple_index = 1, #multiple_entities do
      local trigger_entity = multiple_entities[multiple_index]
      if IsValid(trigger_entity) then
        local key_values = trigger_entity:GetKeyValues() or {}
        local world_mins, world_maxs = trigger_entity:WorldSpaceAABB()
        if world_mins and world_maxs then
          local start_touch_outputs = {}
          local end_touch_outputs = {}
          local output_table = output_vectors_by_entity_[trigger_entity]

          if output_table then
            local start_output_list = output_table.start_touch
            if istable(start_output_list) then
              for output_index = 1, #start_output_list do
                start_touch_outputs[#start_touch_outputs + 1] =
                    start_output_list[output_index]
              end
            end

            local end_output_list = output_table.end_touch
            if istable(end_output_list) then
              for output_index = 1, #end_output_list do
                end_touch_outputs[#end_touch_outputs + 1] =
                    end_output_list[output_index]
              end
            end
          end

          if #start_touch_outputs == 0 and #end_touch_outputs == 0 then
            for output_key, output_value in pairs(key_values) do
              local event_kind = get_output_event_kind(output_key)
              if event_kind then
                local basevelocity_value =
                    parse_basevelocity_output(output_value)
                if basevelocity_value then
                  if event_kind == "start_touch" then
                    start_touch_outputs[#start_touch_outputs + 1] =
                        basevelocity_value
                  else
                    end_touch_outputs[#end_touch_outputs + 1] =
                        basevelocity_value
                  end
                end
              end
            end
          end

          local spawnflags_value = trigger_entity:GetSpawnFlags() or 0
          local wait_time = tonumber(trigger_entity:GetInternalVariable("m_flWait"))
          local is_disabled = trigger_entity:GetInternalVariable("m_bDisabled")

          if not wait_time then
            wait_time = tonumber(key_values.wait or key_values.Wait)
          end

          if wait_time == nil then
            wait_time = 0.2
          end

          if is_disabled == nil then
            local start_disabled = tonumber(
                                       key_values.StartDisabled or
                                           key_values.startdisabled or
                                           0) or
                0
            is_disabled = start_disabled ~= 0
          end

          multiple_snapshot[#multiple_snapshot + 1] = {
            id = trigger_entity:EntIndex(),
            world_mins = vector_to_array(world_mins),
            world_maxs = vector_to_array(world_maxs),
            spawnflags = spawnflags_value,
            wait = wait_time,
            start_touch_basevelocity = {},
            end_touch_basevelocity = {},
            disabled = is_disabled == true
          }

          local snapshot_entry = multiple_snapshot[#multiple_snapshot]
          for output_index = 1, #start_touch_outputs do
            snapshot_entry.start_touch_basevelocity[#snapshot_entry.start_touch_basevelocity + 1] =
                vector_to_array(start_touch_outputs[output_index])
          end

          for output_index = 1, #end_touch_outputs do
            snapshot_entry.end_touch_basevelocity[#snapshot_entry.end_touch_basevelocity + 1] =
                vector_to_array(end_touch_outputs[output_index])
          end
        end
      end
    end

    table.sort(multiple_snapshot, function(left_value, right_value)
      return (left_value.id or 0) < (right_value.id or 0)
    end)

    return multiple_snapshot
  end

  local function send_snapshot(player_value, snapshot_data)
    local snapshot_json = util.TableToJSON(snapshot_data, false)
    if not isstring(snapshot_json) then
      return
    end

    local compressed_snapshot = util.Compress(snapshot_json)
    if not compressed_snapshot then
      return
    end

    net.Start(NET_SYNC_)
    net.WriteUInt(#compressed_snapshot, 32)
    net.WriteData(compressed_snapshot, #compressed_snapshot)

    if IsValid(player_value) then
      net.Send(player_value)
    else
      net.Broadcast()
    end
  end

  local function refresh_snapshot(force_broadcast)
    local snapshot_data = build_multiple_snapshot()
    local snapshot_json = util.TableToJSON(snapshot_data, false) or "[]"
    local snapshot_crc = util.CRC(snapshot_json)

    if force_broadcast or snapshot_crc ~= last_crc_ then
      last_crc_ = snapshot_crc
      send_snapshot(nil, snapshot_data)
    end
  end

  hook.Add("InitPostEntity", "sm_trigger_multiple_InitSnapshot", function()
    refresh_snapshot(true)
  end)

  hook.Add("PostCleanupMap", "sm_trigger_multiple_RebuildSnapshot", function()
    refresh_snapshot(true)
  end)

  timer.Create("sm_trigger_multiple_Refresh", 0.25, 0, function()
    refresh_snapshot(false)
  end)

  hook.Add(
      "PlayerInitialSpawn",
      "sm_trigger_multiple_SendOnJoin",
      function(player_value)
    timer.Simple(0.25, function()
      if IsValid(player_value) then
        send_snapshot(player_value, build_multiple_snapshot())
      end
    end)
  end)

  net.Receive(NET_REQUEST_, function(_, player_value)
    if not IsValid(player_value) then
      return
    end

    send_snapshot(player_value, build_multiple_snapshot())
  end)
else
  local map_multiples_ = {}
  local state_by_player_ = {}

  local function clear_state_for_player(player_value)
    state_by_player_[player_value] = nil
  end

  local function clear_all_states()
    table.Empty(state_by_player_)
  end

  local function get_player_state(player_value, command_data)
    local player_state = state_by_player_[player_value]
    local command_number = (command_data and command_data:CommandNumber()) or 0

    if not player_state then
      player_state = {
        last_cmd = command_number,
        inside = {},
        next_fire = {},
        blocked = {},
        last_pos = nil
      }
      state_by_player_[player_value] = player_state
      return player_state
    end

    if command_number > 0 and command_number <= player_state.last_cmd then
      table.Empty(player_state.inside)
      player_state.last_pos = nil
    end

    player_state.last_cmd = command_number
    return player_state
  end

  local function decode_output_vectors(raw_vectors)
    local decoded_vectors = {}
    if not istable(raw_vectors) then
      return decoded_vectors
    end

    for vector_index = 1, #raw_vectors do
      decoded_vectors[#decoded_vectors + 1] =
          array_to_vector(raw_vectors[vector_index])
    end

    return decoded_vectors
  end

  local function apply_output_basevelocity(move_data, output_vectors)
    for vector_index = 1, #output_vectors do
      local basevelocity_value = output_vectors[vector_index]
      move_data:SetVelocity(move_data:GetVelocity() + basevelocity_value)
    end
  end

  local function decode_snapshot(raw_snapshot_data)
    local decoded_multiples = {}

    for raw_index = 1, #raw_snapshot_data do
      local raw_entry = raw_snapshot_data[raw_index]
      if istable(raw_entry) and raw_entry.id ~= nil and
          raw_entry.world_mins ~= nil and raw_entry.world_maxs ~= nil then
        decoded_multiples[#decoded_multiples + 1] = {
          id = tostring(raw_entry.id),
          world_mins = array_to_vector(raw_entry.world_mins),
          world_maxs = array_to_vector(raw_entry.world_maxs),
          spawnflags = tonumber(raw_entry.spawnflags) or 0,
          wait = tonumber(raw_entry.wait) or 0.2,
          start_touch_basevelocity =
              decode_output_vectors(raw_entry.start_touch_basevelocity),
          end_touch_basevelocity =
              decode_output_vectors(raw_entry.end_touch_basevelocity),
          disabled = raw_entry.disabled == true
        }
      end
    end

    map_multiples_ = decoded_multiples
    clear_all_states()
  end

  net.Receive(NET_SYNC_, function()
    local byte_count = net.ReadUInt(32)
    if byte_count <= 0 then
      map_multiples_ = {}
      clear_all_states()
      return
    end

    local compressed_snapshot = net.ReadData(byte_count)
    local snapshot_json = compressed_snapshot and
        util.Decompress(compressed_snapshot)
    local raw_snapshot_data = snapshot_json and util.JSONToTable(snapshot_json)

    if not istable(raw_snapshot_data) then
      map_multiples_ = {}
      clear_all_states()
      return
    end

    decode_snapshot(raw_snapshot_data)
  end)

  hook.Add("InitPostEntity", "sm_trigger_multiple_RequestSnapshot", function()
    net.Start(NET_REQUEST_)
    net.SendToServer()
  end)

  hook.Add("OnReloaded", "sm_trigger_multiple_RequestSnapshot", function()
    net.Start(NET_REQUEST_)
    net.SendToServer()
  end)

  hook.Add("SetupMove", "sm_trigger_multiple_PredictAllMapMultiple",
           function(player_value, move_data, command_data)
    if player_value ~= LocalPlayer() then
      return
    end

    if not player_value:Alive() or #map_multiples_ == 0 then
      return
    end

    local player_state = get_player_state(player_value, command_data)
    local current_pos = move_data:GetOrigin()
    local previous_pos = player_state.last_pos or current_pos
    local hull_mins = player_value:OBBMins()
    local hull_maxs = player_value:OBBMaxs()
    local current_time = CurTime()

    for multiple_index = 1, #map_multiples_ do
      local multiple_data = map_multiples_[multiple_index]
      local inside_after_move = false
      local segment_touch = false

      if not multiple_data.disabled and
          player_passes_spawnflags(player_value, multiple_data.spawnflags) then
        local expanded_mins = Vector(
            multiple_data.world_mins.x - hull_maxs.x,
            multiple_data.world_mins.y - hull_maxs.y,
            multiple_data.world_mins.z - hull_maxs.z)
        local expanded_maxs = Vector(
            multiple_data.world_maxs.x - hull_mins.x,
            multiple_data.world_maxs.y - hull_mins.y,
            multiple_data.world_maxs.z - hull_mins.z)

        inside_after_move =
            point_inside_aabb(current_pos, expanded_mins, expanded_maxs)
        segment_touch = segment_intersects_aabb(
            previous_pos, current_pos, expanded_mins, expanded_maxs)
      end

      local was_touching = player_state.inside[multiple_data.id] == true
      local start_touch =
          (not was_touching) and (inside_after_move or segment_touch)
      local end_touch = was_touching and not inside_after_move

      if start_touch and not inside_after_move then
        end_touch = true
      end

      if start_touch then
        apply_output_basevelocity(
            move_data, multiple_data.start_touch_basevelocity)
      end

      if start_touch and not player_state.blocked[multiple_data.id] then
        local next_fire_time = player_state.next_fire[multiple_data.id] or 0
        if current_time >= next_fire_time then
          hook.Run("PredictedTriggerMultipleTouch", multiple_data.id, multiple_data)

          if multiple_data.wait > 0 then
            player_state.next_fire[multiple_data.id] =
                current_time + multiple_data.wait
          else
            player_state.blocked[multiple_data.id] = true
          end
        end
      end

      if end_touch then
        apply_output_basevelocity(
            move_data, multiple_data.end_touch_basevelocity)
      end

      player_state.inside[multiple_data.id] = inside_after_move
    end

    player_state.last_pos = current_pos
  end)

  hook.Add("LocalPlayerSpawn", "sm_trigger_multiple_ClearSpawnState", function()
    clear_state_for_player(LocalPlayer())
  end)
end
