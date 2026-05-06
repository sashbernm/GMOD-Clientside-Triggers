local DEBUG_ = false

local NET_SYNC_ = "sm_trigger_teleport_replace_Sync"
local NET_REQUEST_ = "sm_trigger_teleport_replace_Request"

local REFRESH_INTERVAL_ = 0.25
local TELEPORT_COOLDOWN_ = 0.20

local SF_TRIGGER_ALLOW_CLIENTS_ = 0x01
local SF_TRIGGER_ALLOW_ALL_ = 0x40
local SF_TRIGGER_ONLY_CLIENTS_OUT_OF_VEHICLES_ = 0x200
local SF_TRIGGER_DISALLOW_BOTS_ = 0x1000

local function debug_print(...)
  if not DEBUG_ then
    return
  end

  print("[trigger_teleport_replace]", ...)
end

local function vector_to_array(vec)
  if not vec then
    return {0, 0, 0}
  end

  return {vec.x, vec.y, vec.z}
end

local function array_to_vector(tbl)
  if not istable(tbl) then
    return Vector(0, 0, 0)
  end

  return Vector(
      tonumber(tbl[1]) or 0,
      tonumber(tbl[2]) or 0,
      tonumber(tbl[3]) or 0)
end

local function angle_to_array(ang)
  if not ang then
    return {0, 0, 0}
  end

  return {ang.p, ang.y, ang.r}
end

local function normalize_yaw(yaw)
  local normalized_yaw = (tonumber(yaw) or 0) % 360
  if normalized_yaw > 180 then
    normalized_yaw = normalized_yaw - 360
  end

  return normalized_yaw
end

local function array_to_angle(tbl)
  if not istable(tbl) then
    return Angle(0, 0, 0)
  end

  return Angle(
      tonumber(tbl[1]) or 0,
      tonumber(tbl[2]) or 0,
      tonumber(tbl[3]) or 0)
end

local function sanitize_view_angles(ang)
  local sanitized_angle = Angle(0, 0, 0)
  if ang then
    sanitized_angle.p = math.Clamp(tonumber(ang.p) or 0, -89, 89)
    sanitized_angle.y = normalize_yaw(ang.y)
  end

  sanitized_angle.r = 0
  return sanitized_angle
end

local function point_inside_aabb(pos, mins, maxs)
  return pos.x >= mins.x and pos.x <= maxs.x and
      pos.y >= mins.y and pos.y <= maxs.y and
      pos.z >= mins.z and pos.z <= maxs.z
end

local function segment_intersects_aabb(start_pos, end_pos, mins, maxs)
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

  if not clip_axis(start_pos.x, direction.x, mins.x, maxs.x) then
    return false
  end

  if not clip_axis(start_pos.y, direction.y, mins.y, maxs.y) then
    return false
  end

  if not clip_axis(start_pos.z, direction.z, mins.z, maxs.z) then
    return false
  end

  return true
end

local function player_passes_spawnflags(ply, spawnflags)
  local allow_players = spawnflags == 0 or
      bit.band(spawnflags, SF_TRIGGER_ALLOW_CLIENTS_) ~= 0 or
      bit.band(spawnflags, SF_TRIGGER_ALLOW_ALL_) ~= 0

  if not allow_players then
    return false
  end

  if bit.band(spawnflags, SF_TRIGGER_DISALLOW_BOTS_) ~= 0 and ply:IsBot() then
    return false
  end

  if bit.band(spawnflags, SF_TRIGGER_ONLY_CLIENTS_OUT_OF_VEHICLES_) ~= 0 and
      ply:InVehicle() then
    return false
  end

  return true
end

local function expanded_trigger_bounds(trigger_data, ply)
  local hull_mins = ply:OBBMins()
  local hull_maxs = ply:OBBMaxs()

  return Vector(
      trigger_data.world_mins.x - hull_maxs.x,
      trigger_data.world_mins.y - hull_maxs.y,
      trigger_data.world_mins.z - hull_maxs.z),
      Vector(
          trigger_data.world_maxs.x - hull_mins.x,
          trigger_data.world_maxs.y - hull_mins.y,
          trigger_data.world_maxs.z - hull_mins.z)
end

local function calculate_teleport_destination(trigger_data, player_pos)
  local destination_pos = trigger_data.destination_pos
  if trigger_data.landmark_pos then
    destination_pos = trigger_data.destination_pos +
        (player_pos - trigger_data.landmark_pos)
  end

  return destination_pos, sanitize_view_angles(trigger_data.destination_angle)
end

local function find_named_entity(name)
  if not isstring(name) or name == "" then
    return nil
  end

  local matching_entities = ents.FindByName(name)
  for entity_index = 1, #matching_entities do
    local entity_value = matching_entities[entity_index]
    if IsValid(entity_value) then
      return entity_value
    end
  end

  return nil
end

local function decode_teleport_snapshot(raw_snapshot_data)
  local decoded_triggers = {}
  if not istable(raw_snapshot_data) then
    return decoded_triggers
  end

  for raw_index = 1, #raw_snapshot_data do
    local raw_entry = raw_snapshot_data[raw_index]
    if istable(raw_entry) and raw_entry.id ~= nil and
        raw_entry.world_mins ~= nil and raw_entry.world_maxs ~= nil and
        raw_entry.destination_pos ~= nil and raw_entry.destination_angle ~= nil then
      local landmark_pos = nil
      local landmark_angle = nil

      if raw_entry.landmark_pos ~= nil then
        landmark_pos = array_to_vector(raw_entry.landmark_pos)
      end

      if raw_entry.landmark_angle ~= nil then
        landmark_angle = array_to_angle(raw_entry.landmark_angle)
      end

      decoded_triggers[#decoded_triggers + 1] = {
        id = tostring(raw_entry.id),
        ent_index = tonumber(raw_entry.ent_index) or tonumber(raw_entry.id) or 0,
        world_mins = array_to_vector(raw_entry.world_mins),
        world_maxs = array_to_vector(raw_entry.world_maxs),
        spawnflags = tonumber(raw_entry.spawnflags) or 0,
        disabled = raw_entry.disabled == true,
        start_disabled = raw_entry.start_disabled == true,
        target = tostring(raw_entry.target or ""),
        landmark = tostring(raw_entry.landmark or ""),
        destination_pos = array_to_vector(raw_entry.destination_pos),
        destination_angle = sanitize_view_angles(
            array_to_angle(raw_entry.destination_angle)),
        landmark_pos = landmark_pos,
        landmark_angle = landmark_angle
      }
    end
  end

  return decoded_triggers
end

if SERVER then
  util.AddNetworkString(NET_SYNC_)
  util.AddNetworkString(NET_REQUEST_)

  local last_crc_ = nil
  local active_triggers_ = {}
  local state_by_player_ = {}
  local captured_keyvalues_by_entity_ = setmetatable({}, {__mode = "k"})
  local logical_disabled_by_entity_ = setmetatable({}, {__mode = "k"})
  local native_disabled_by_entity_ = setmetatable({}, {__mode = "k"})
  local native_disable_input_by_entity_ = setmetatable({}, {__mode = "k"})

  local function string_to_bool(value, default_value)
    if value == nil then
      return default_value
    end

    if isbool(value) then
      return value
    end

    if isnumber(value) then
      return value ~= 0
    end

    if isstring(value) then
      local lower_value = string.lower(string.Trim(value))
      return lower_value == "1" or lower_value == "true" or lower_value == "yes"
    end

    return default_value
  end

  local function get_captured_value(entity_value, key_values, key_name)
    local captured_keyvalues = captured_keyvalues_by_entity_[entity_value]
    local lower_key_name = string.lower(key_name)

    if captured_keyvalues and captured_keyvalues[lower_key_name] ~= nil then
      return captured_keyvalues[lower_key_name]
    end

    if istable(key_values) then
      return key_values[key_name] or key_values[lower_key_name]
    end

    return nil
  end

  local function get_initial_disabled(entity_value, key_values)
    local internal_disabled = entity_value:GetInternalVariable("m_bDisabled")
    if internal_disabled ~= nil and native_disabled_by_entity_[entity_value] ~= true then
      return string_to_bool(internal_disabled, false)
    end

    local start_disabled = get_captured_value(
        entity_value, key_values, "StartDisabled")
    return string_to_bool(start_disabled, false)
  end

  local function disable_native_trigger(trigger_entity)
    if not IsValid(trigger_entity) then
      return
    end

    if native_disabled_by_entity_[trigger_entity] == true and string_to_bool(
        trigger_entity:GetInternalVariable("m_bDisabled"), false) then
      return
    end

    native_disable_input_by_entity_[trigger_entity] = true
    trigger_entity:Fire("Disable")
    timer.Simple(0, function()
      native_disable_input_by_entity_[trigger_entity] = nil
    end)

    if native_disabled_by_entity_[trigger_entity] ~= true then
      debug_print("disabled native trigger_teleport", trigger_entity:EntIndex())
    end

    native_disabled_by_entity_[trigger_entity] = true
  end

  local function build_teleport_snapshot()
    local teleport_snapshot = {}
    local teleport_entities = ents.FindByClass("trigger_teleport")

    for teleport_index = 1, #teleport_entities do
      local trigger_entity = teleport_entities[teleport_index]
      if IsValid(trigger_entity) then
        local key_values = trigger_entity:GetKeyValues() or {}
        local target_name = get_captured_value(trigger_entity, key_values, "target")
        local landmark_name =
            get_captured_value(trigger_entity, key_values, "landmark")
        local destination_entity = find_named_entity(target_name)
        local landmark_entity = find_named_entity(landmark_name)
        local has_landmark = isstring(landmark_name) and landmark_name ~= ""
        local landmark_is_valid = not has_landmark or IsValid(landmark_entity)
        local world_mins, world_maxs = trigger_entity:WorldSpaceAABB()

        if IsValid(destination_entity) and landmark_is_valid and world_mins and
            world_maxs then
          local logical_disabled = logical_disabled_by_entity_[trigger_entity]
          if logical_disabled == nil then
            logical_disabled = get_initial_disabled(trigger_entity, key_values)
            logical_disabled_by_entity_[trigger_entity] = logical_disabled
          end

          local start_disabled = string_to_bool(
              get_captured_value(trigger_entity, key_values, "StartDisabled"),
              false)
          local spawnflags = trigger_entity:GetSpawnFlags() or
              tonumber(get_captured_value(trigger_entity, key_values, "spawnflags")) or
              0
          local destination_angle =
              sanitize_view_angles(destination_entity:GetAngles())
          local snapshot_entry = {
            id = trigger_entity:EntIndex(),
            ent_index = trigger_entity:EntIndex(),
            world_mins = vector_to_array(world_mins),
            world_maxs = vector_to_array(world_maxs),
            spawnflags = spawnflags,
            disabled = logical_disabled == true,
            start_disabled = start_disabled == true,
            target = tostring(target_name or ""),
            landmark = tostring(landmark_name or ""),
            destination_pos = vector_to_array(destination_entity:GetPos()),
            destination_angle = angle_to_array(destination_angle)
          }

          if has_landmark and IsValid(landmark_entity) then
            snapshot_entry.landmark_pos = vector_to_array(landmark_entity:GetPos())
            snapshot_entry.landmark_angle =
                angle_to_array(sanitize_view_angles(landmark_entity:GetAngles()))
          end

          teleport_snapshot[#teleport_snapshot + 1] = snapshot_entry
          disable_native_trigger(trigger_entity)
        end
      end
    end

    table.sort(teleport_snapshot, function(left_value, right_value)
      return (left_value.id or 0) < (right_value.id or 0)
    end)

    debug_print("captured trigger_teleport count", #teleport_snapshot)
    return teleport_snapshot
  end

  local function send_snapshot(ply, snapshot)
    local snapshot_json = util.TableToJSON(snapshot, false)
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

    if IsValid(ply) then
      net.Send(ply)
    else
      net.Broadcast()
    end
  end

  local function refresh_snapshot(force_broadcast)
    local snapshot = build_teleport_snapshot()
    local snapshot_json = util.TableToJSON(snapshot, false) or "[]"
    local snapshot_crc = util.CRC(snapshot_json)

    active_triggers_ = decode_teleport_snapshot(snapshot)

    if force_broadcast or snapshot_crc ~= last_crc_ then
      last_crc_ = snapshot_crc
      send_snapshot(nil, snapshot)
    end
  end

  local function get_player_state(ply, cmd)
    local player_state = state_by_player_[ply]
    local command_number = (cmd and cmd:CommandNumber()) or 0

    if not player_state then
      player_state = {
        last_cmd = command_number,
        last_pos = nil,
        inside = {},
        next_fire = {}
      }
      state_by_player_[ply] = player_state
      return player_state
    end

    player_state.last_cmd = command_number
    return player_state
  end

  local function apply_server_teleport(ply, mv, cmd, trigger_data, current_pos)
    local destination_pos, destination_angle =
        calculate_teleport_destination(trigger_data, current_pos)

    -- TODO: capture OnStartTouch/OnEndTouch outputs if map compatibility needs it.
    -- TODO: manually fire copied outputs or call TriggerOutput on a wrapper entity if needed.
    ply:SetPos(destination_pos)
    mv:SetOrigin(destination_pos)

    if ply:IsBot() then
      ply:SetEyeAngles(destination_angle)
      if mv.SetMoveAngles then
        mv:SetMoveAngles(destination_angle)
      end

      if cmd and cmd.SetViewAngles then
        cmd:SetViewAngles(destination_angle)
      end
    end

    debug_print(
        "server teleport",
        ply:Nick(),
        trigger_data.id,
        tostring(destination_pos),
        tostring(destination_angle))

    return destination_pos
  end

  hook.Add("EntityKeyValue", "sm_trigger_teleport_replace_CaptureKeyValues",
           function(entity_value, key_name, key_value)
    if not IsValid(entity_value) or entity_value:GetClass() ~= "trigger_teleport" then
      return
    end

    local lower_key_name = string.lower(key_name or "")
    if lower_key_name ~= "target" and lower_key_name ~= "landmark" and
        lower_key_name ~= "startdisabled" and lower_key_name ~= "spawnflags" then
      return
    end

    local captured_keyvalues = captured_keyvalues_by_entity_[entity_value]
    if not captured_keyvalues then
      captured_keyvalues = {}
      captured_keyvalues_by_entity_[entity_value] = captured_keyvalues
    end

    captured_keyvalues[lower_key_name] = key_value
  end)

  hook.Add("AcceptInput", "sm_trigger_teleport_replace_TrackDisabledInputs",
           function(entity_value, input_name)
    if not IsValid(entity_value) or entity_value:GetClass() ~= "trigger_teleport" then
      return
    end

    local lower_input_name = string.lower(input_name or "")
    if lower_input_name == "enable" then
      logical_disabled_by_entity_[entity_value] = false
      timer.Simple(0, function()
        if IsValid(entity_value) then
          disable_native_trigger(entity_value)
          refresh_snapshot(false)
        end
      end)
    elseif lower_input_name == "disable" then
      if native_disable_input_by_entity_[entity_value] == true then
        return
      end

      logical_disabled_by_entity_[entity_value] = true
      timer.Simple(0, function()
        refresh_snapshot(false)
      end)
    end
  end)

  hook.Add("InitPostEntity", "sm_trigger_teleport_replace_InitSnapshot",
           function()
    refresh_snapshot(true)
  end)

  hook.Add("PostCleanupMap", "sm_trigger_teleport_replace_RebuildSnapshot",
           function()
    table.Empty(state_by_player_)
    refresh_snapshot(true)
  end)

  timer.Create(
      "sm_trigger_teleport_replace_Refresh",
      REFRESH_INTERVAL_,
      0,
      function()
    refresh_snapshot(false)
  end)

  hook.Add(
      "PlayerInitialSpawn",
      "sm_trigger_teleport_replace_SendOnJoin",
      function(ply)
    timer.Simple(0.25, function()
      if IsValid(ply) then
        send_snapshot(ply, build_teleport_snapshot())
      end
    end)
  end)

  net.Receive(NET_REQUEST_, function(_, ply)
    if not IsValid(ply) then
      return
    end

    send_snapshot(ply, build_teleport_snapshot())
  end)

  hook.Add("SetupMove", "sm_trigger_teleport_replace_ServerTeleport",
           function(ply, mv, cmd)
    if not IsValid(ply) or not ply:Alive() or #active_triggers_ == 0 then
      return
    end

    local player_state = get_player_state(ply, cmd)
    local current_pos = mv:GetOrigin()
    local previous_pos = player_state.last_pos or current_pos
    local current_time = CurTime()

    for trigger_index = 1, #active_triggers_ do
      local trigger_data = active_triggers_[trigger_index]
      local inside_after_move = false
      local segment_touch = false

      if not trigger_data.disabled and
          player_passes_spawnflags(ply, trigger_data.spawnflags) then
        local expanded_mins, expanded_maxs =
            expanded_trigger_bounds(trigger_data, ply)
        inside_after_move =
            point_inside_aabb(current_pos, expanded_mins, expanded_maxs)
        segment_touch = segment_intersects_aabb(
            previous_pos, current_pos, expanded_mins, expanded_maxs)
      end

      local was_touching = player_state.inside[trigger_data.id] == true
      local start_touch =
          (not was_touching) and (inside_after_move or segment_touch)
      local next_fire_time = player_state.next_fire[trigger_data.id] or 0

      if start_touch and current_time >= next_fire_time then
        local destination_pos = apply_server_teleport(
            ply, mv, cmd, trigger_data, current_pos)
        player_state.next_fire[trigger_data.id] =
            current_time + TELEPORT_COOLDOWN_
        player_state.inside[trigger_data.id] = false
        player_state.last_pos = destination_pos
        return
      end

      player_state.inside[trigger_data.id] = inside_after_move
    end

    player_state.last_pos = current_pos
  end)

  hook.Add("PlayerDisconnected", "sm_trigger_teleport_replace_ClearPlayerState",
           function(ply)
    state_by_player_[ply] = nil
  end)
else
  local map_triggers_ = {}
  local state_by_player_ = {}
  local pending_view_angle_ = nil

  local function clear_prediction_state()
    table.Empty(state_by_player_)
    pending_view_angle_ = nil
  end

  local function get_player_state(ply, cmd)
    local player_state = state_by_player_[ply]
    local command_number = (cmd and cmd:CommandNumber()) or 0

    if not player_state then
      player_state = {
        last_cmd = command_number,
        last_pos = nil,
        inside = {},
        next_predict = {},
        predicted_commands = {}
      }
      state_by_player_[ply] = player_state
      return player_state
    end

    if command_number > 0 and command_number <= player_state.last_cmd then
      table.Empty(player_state.inside)
      player_state.last_pos = nil
    end

    player_state.last_cmd = command_number
    return player_state
  end

  local function command_was_predicted(player_state, trigger_id, command_number)
    if command_number <= 0 then
      return false
    end

    local trigger_commands = player_state.predicted_commands[trigger_id]
    return trigger_commands and trigger_commands[command_number] == true
  end

  local function mark_command_predicted(player_state, trigger_id, command_number)
    if command_number <= 0 then
      return
    end

    local trigger_commands = player_state.predicted_commands[trigger_id]
    if not trigger_commands then
      trigger_commands = {}
      player_state.predicted_commands[trigger_id] = trigger_commands
    end

    trigger_commands[command_number] = true
  end

  net.Receive(NET_SYNC_, function()
    local byte_count = net.ReadUInt(32)
    if byte_count <= 0 then
      map_triggers_ = {}
      clear_prediction_state()
      return
    end

    local compressed_snapshot = net.ReadData(byte_count)
    local snapshot_json = compressed_snapshot and
        util.Decompress(compressed_snapshot)
    local raw_snapshot_data = snapshot_json and util.JSONToTable(snapshot_json)

    map_triggers_ = decode_teleport_snapshot(raw_snapshot_data)
    clear_prediction_state()
  end)

  local function request_snapshot()
    net.Start(NET_REQUEST_)
    net.SendToServer()
  end

  hook.Add("InitPostEntity", "sm_trigger_teleport_replace_RequestSnapshot",
           request_snapshot)

  hook.Add("OnReloaded", "sm_trigger_teleport_replace_RequestSnapshot",
           request_snapshot)

  hook.Add("SetupMove", "sm_trigger_teleport_replace_PredictTeleport",
           function(ply, mv, cmd)
    if ply ~= LocalPlayer() or not ply:Alive() or #map_triggers_ == 0 then
      return
    end

    local player_state = get_player_state(ply, cmd)
    local command_number = (cmd and cmd:CommandNumber()) or 0
    local current_pos = mv:GetOrigin()
    local previous_pos = player_state.last_pos or current_pos
    local current_time = RealTime()

    for trigger_index = 1, #map_triggers_ do
      local trigger_data = map_triggers_[trigger_index]
      local inside_after_move = false
      local segment_touch = false

      if not trigger_data.disabled and
          player_passes_spawnflags(ply, trigger_data.spawnflags) then
        local expanded_mins, expanded_maxs =
            expanded_trigger_bounds(trigger_data, ply)
        inside_after_move =
            point_inside_aabb(current_pos, expanded_mins, expanded_maxs)
        segment_touch = segment_intersects_aabb(
            previous_pos, current_pos, expanded_mins, expanded_maxs)
      end

      local was_touching = player_state.inside[trigger_data.id] == true
      local start_touch =
          (not was_touching) and (inside_after_move or segment_touch)
      local next_predict_time =
          player_state.next_predict[trigger_data.id] or 0
      local already_predicted = command_was_predicted(
          player_state, trigger_data.id, command_number)

      if start_touch and
          (already_predicted or current_time >= next_predict_time) then
        local destination_pos, destination_angle =
            calculate_teleport_destination(trigger_data, current_pos)
        mv:SetOrigin(destination_pos)

        if not already_predicted then
          pending_view_angle_ = destination_angle
          player_state.next_predict[trigger_data.id] =
              current_time + TELEPORT_COOLDOWN_
          mark_command_predicted(player_state, trigger_data.id, command_number)
        end

        player_state.inside[trigger_data.id] = false
        player_state.last_pos = destination_pos

        if not already_predicted then
          debug_print(
              "client predicted teleport",
              trigger_data.id,
              tostring(destination_pos),
              tostring(destination_angle))
        end
        return
      end

      player_state.inside[trigger_data.id] = inside_after_move
    end

    player_state.last_pos = current_pos
  end)

  hook.Add("CreateMove", "sm_trigger_teleport_replace_ApplyPredictedAngle",
           function(cmd)
    if not pending_view_angle_ then
      return
    end

    local destination_angle = pending_view_angle_
    pending_view_angle_ = nil

    cmd:SetViewAngles(destination_angle)

    local ply = LocalPlayer()
    if IsValid(ply) then
      ply:SetEyeAngles(destination_angle)
    end
  end)

  hook.Add("LocalPlayerSpawn", "sm_trigger_teleport_replace_ClearSpawnState",
           function()
    clear_prediction_state()
  end)
end
