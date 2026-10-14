#- gplug_ha_setup.be - ONE-TIME script.txt parser + HA discovery schema
   builder for gplug_ha.

   Loaded by gplug_ha.be's start() (via run_setup_and_restart()) only when
   gplug_ha_names.cfg is missing or its stored fingerprint no longer matches
   the CURRENT script.txt content (first install, a meter swap, or a
   firmware/template update that changes script.txt's OBIS layout). Parses
   script.txt exactly once, writes the resolved variable names, the
   detected power scale, the HA MQTT discovery component schema (see below),
   and a content fingerprint to gplug_ha_names.cfg, then restarts the device
   so gplug_ha.be's lightweight runtime path (load_names()) picks the fresh
   file up on the next boot.

   This file is deliberately the ONLY place in the whole app that still
   contains the OBIS-code/CSV parsing helpers - once resolved, those names
   don't change until script.txt itself changes, so there's no reason to
   keep the parsing code (and its heap cost) resident in gplug_ha.be for
   the entire life of every subsequent boot. Measured with this project's
   own tools/compile_to_bec.be: moving this layer out of gplug_ha.be cut
   its compiled .bec size by ~15% (24328 -> 20557 bytes on gplug_ha 0.2.2).

   It's ALSO the only place that still contains fields()/discovery_component()
   /tariff_flag_present()/build_cmps() - the HA discovery entity SCHEMA
   (which sensors exist, their device_class/unit/state_class) is a pure
   function of has_ei_t1/has_ei_t2/has_eo_t1/has_eo_t2, exactly like the
   OBIS names above, so it's resolved once here (with a placeholder id, see
   cmps_for() in gplug_ha.be) and shipped as 4 precomputed "cmps_<group>"
   maps instead of being rebuilt from the ~33-row FIELDS table on every
   discovery publish. Deliberately NOT the same thing as caching FIELDS() in
   RAM (an earlier attempt at that, in gplug_ha.be itself, measured WORSE on
   real hardware - see gplug_ha.be's cmps_for()): this moves the BUILDING
   CODE out of the resident image, while gplug_ha.be still reads the result
   back from flash fresh on every (rare) discovery publish rather than
   keeping it permanently resident.

   Standalone top-level functions (not a class) are fine here - unlike
   gplug_ha.be, this file only ever runs once per invocation and is then
   discarded (the device restarts immediately after), so there's no
   multi-method instance state to carry between calls. -#

import string
import json

# -- OBIS/CSV parsing helpers, identical to the pre-split gplug_ha.be -------
def looks_like_digit(c)
  return c >= '0' && c <= '9'
end

#- Finds the script.txt line whose 5th comma field is exactly `obis` (e.g.
   "1.7.0" for active power import) - the OBIS code is vendor-independent,
   the variable name preceding it (e.g. "P1i" vs. "Pi1") is not. -#
def obis_line(content, obis)
  var from = 0
  while true
    var pos = string.find(content, obis, from)
    if pos < 0 return nil end
    var boundary_before = (pos == 0) || !looks_like_digit(content[pos - 1])
    var tail = pos + size(obis)
    var boundary_after = (tail >= size(content)) || !looks_like_digit(content[tail])
    if boundary_before && boundary_after
      var ls = pos
      while ls > 0 && content[ls - 1] != '\n'
        ls -= 1
      end
      var le = pos
      while le < size(content) && content[le] != '\n' && content[le] != '\r'
        le += 1
      end
      var line = content[ls .. le - 1]
      if size(line) > 0 && line[0] != ';'
        return line
      end
    end
    from = pos + 1
  end
end

def csv_field(line, index)
  var field = 0
  var start = 0
  var i = 0
  while i <= size(line)
    if i == size(line) || line[i] == ','
      if field == index return line[start .. i - 1] end
      field += 1
      start = i + 1
    end
    i += 1
  end
  return nil
end

def varname_for(content, obis, fallback)
  if content == nil return fallback end
  var line = obis_line(content, obis)
  if line == nil return fallback end
  var name = csv_field(line, 4)
  return (name != nil && size(name) > 0) ? name : fallback
end

#- Maps a unit declared in script.txt ("W"/"kW", case-insensitive) to a
   scaling factor, nil for a missing or unrecognized unit. -#
def scale_for_unit(unit)
  if unit == nil || size(unit) == 0 return nil end
  var u = string.tolower(unit)
  if string.find(u, "kw") == 0 return 1000.0 end
  if string.find(u, "w") == 0 return 1.0 end
  return nil
end

#- MUST stay byte-for-byte identical to gplug_ha.be's content_fingerprint()
   (including the "v2:" schema-version prefix - bump BOTH copies together
   whenever this file starts writing different/additional keys into
   gplug_ha_names.cfg, not just when the OBIS-parsing algorithm changes; see
   gplug_ha.be's content_fingerprint() for why) - both sides need to compute
   the exact same value from the exact same script.txt content for the
   freshness check in load_names() to work. -#
def content_fingerprint(content)
  if content == nil return nil end
  var h = 5381
  var n = size(content)
  var i = 0
  while i < n
    h = ((h << 5) + h) + string.byte(content[i])
    i += 1
  end
  return "v2:" + str(n) + ":" + str(h)
end

# -- HA MQTT discovery component schema, identical to the pre-split
#    gplug_ha.be's fields()/discovery_component()/tariff_flag_present()/
#    build_cmps() - see gplug_ha.be's cmps_for() for why only THIS part
#    (the entity schema, a pure function of has_ei_t1/etc.) is precomputed
#    here, while device_url/availability/smid_text stay live in
#    gplug_ha.be's discovery_envelope(). -----------------------------------
def fields()
  return [
    ["power_grid_w", "Grid Power", "power", "W", "measurement", nil, "state"],
    ["voltage_l1_v", "Voltage L1", "voltage", "V", "measurement", nil, "state"],
    ["voltage_l2_v", "Voltage L2", "voltage", "V", "measurement", nil, "state"],
    ["voltage_l3_v", "Voltage L3", "voltage", "V", "measurement", nil, "state"],
    ["current_l1_a", "Current L1", "current", "A", "measurement", nil, "state"],
    ["current_l2_a", "Current L2", "current", "A", "measurement", nil, "state"],
    ["current_l3_a", "Current L3", "current", "A", "measurement", nil, "state"],
    ["power_factor", "Power Factor", "power_factor", nil, "measurement", nil, "state"],
    ["power_import_w", "Power Import", "power", "W", "measurement", nil, "power"],
    ["power_export_w", "Power Export", "power", "W", "measurement", nil, "power"],
    ["power_l1_import_w", "Power L1 Import", "power", "W", "measurement", nil, "power"],
    ["power_l2_import_w", "Power L2 Import", "power", "W", "measurement", nil, "power"],
    ["power_l3_import_w", "Power L3 Import", "power", "W", "measurement", nil, "power"],
    ["power_l1_export_w", "Power L1 Export", "power", "W", "measurement", nil, "power"],
    ["power_l2_export_w", "Power L2 Export", "power", "W", "measurement", nil, "power"],
    ["power_l3_export_w", "Power L3 Export", "power", "W", "measurement", nil, "power"],
    ["power_l1_w", "Power L1", "power", "W", "measurement", nil, "power"],
    ["power_l2_w", "Power L2", "power", "W", "measurement", nil, "power"],
    ["power_l3_w", "Power L3", "power", "W", "measurement", nil, "power"],
    ["reactive_power_import_var", "Reactive Power Import", "reactive_power", "var", "measurement", nil, "power"],
    ["reactive_power_export_var", "Reactive Power Export", "reactive_power", "var", "measurement", nil, "power"],
    ["energy_import_kwh", "Energy Import", "energy", "kWh", "total_increasing", nil, "energy"],
    ["energy_export_kwh", "Energy Export", "energy", "kWh", "total_increasing", nil, "energy"],
    ["energy_import_tariff1_kwh", "Energy Import Tariff 1", "energy", "kWh", "total_increasing", nil, "energy", "ei1"],
    ["energy_import_tariff2_kwh", "Energy Import Tariff 2", "energy", "kWh", "total_increasing", nil, "energy", "ei2"],
    ["energy_export_tariff1_kwh", "Energy Export Tariff 1", "energy", "kWh", "total_increasing", nil, "energy", "eo1"],
    ["energy_export_tariff2_kwh", "Energy Export Tariff 2", "energy", "kWh", "total_increasing", nil, "energy", "eo2"],
    ["reactive_energy_import_kvarh", "Reactive Energy Import", nil, "kVArh", "total_increasing", nil, "energy"],
    ["reactive_energy_export_kvarh", "Reactive Energy Export", nil, "kVArh", "total_increasing", nil, "energy"],
    ["esp32_temperature_c", "ESP32 Temperature", "temperature", "°C", "measurement", "diagnostic", "diag"],
    ["heap_free_kb", "Heap Free", nil, "kB", "measurement", "diagnostic", "diag"],
    ["uptime_s", "Uptime", "duration", "s", "measurement", "diagnostic", "diag"],
    ["restart_reason", "Restart Reason", nil, nil, nil, "diagnostic", "diag"]
  ]
end

def discovery_component(key, name, device_class, unit, state_class, id, category)
  var c = {
    "p": "sensor",
    "name": name,
    "value_template": "{{ value_json." + key + " }}",
    "unique_id": id + "_" + key
  }
  if device_class != nil c["device_class"] = device_class end
  if unit != nil c["unit_of_measurement"] = unit end
  if state_class != nil c["state_class"] = state_class end
  if category != nil c["entity_category"] = category end
  return c
end

def tariff_flag_present(flag, has_ei_t1, has_ei_t2, has_eo_t1, has_eo_t2)
  if flag == "ei1" return has_ei_t1 end
  if flag == "ei2" return has_ei_t2 end
  if flag == "eo1" return has_eo_t1 end
  if flag == "eo2" return has_eo_t2 end
  return true
end

def build_cmps(group, id, has_ei_t1, has_ei_t2, has_eo_t1, has_eo_t2)
  var cmps = {}
  for row : fields()
    if row[6] == group
      var include = true
      if size(row) > 7 include = tariff_flag_present(row[7], has_ei_t1, has_ei_t2, has_eo_t1, has_eo_t2) end
      if include
        cmps[row[0]] = discovery_component(row[0], row[1], row[2], row[3], row[4], id, row[5])
      end
    end
  end
  return cmps
end

def run()
  var content = nil
  try
    var f = open("script.txt", "r")
    if f != nil
      content = f.read()
      f.close()
    end
  except .. as e, m
    content = nil
  end

  var pi_line = content != nil ? obis_line(content, "1.7.0") : nil
  var pi_name = pi_line != nil ? csv_field(pi_line, 4) : nil
  var pi_unit = pi_line != nil ? csv_field(pi_line, 3) : nil
  var scale = scale_for_unit(pi_unit)

  var has_ei_t1 = content != nil && obis_line(content, "1.8.1") != nil
  var has_ei_t2 = content != nil && obis_line(content, "1.8.2") != nil
  var has_eo_t1 = content != nil && obis_line(content, "2.8.1") != nil
  var has_eo_t2 = content != nil && obis_line(content, "2.8.2") != nil

  #- "@ID@" is a placeholder gplug_ha.be's cmps_for() patches into every
     component's unique_id with the REAL (runtime-only-known) device id -
     safe because slug() (gplug_ha.be) only ever produces [a-zA-Z0-9_-], so
     a real id can never collide with this token. -#
  var id_placeholder = "@ID@"
  var cmps_state = build_cmps("state", id_placeholder, has_ei_t1, has_ei_t2, has_eo_t1, has_eo_t2)
  var cmps_power = build_cmps("power", id_placeholder, has_ei_t1, has_ei_t2, has_eo_t1, has_eo_t2)
  var cmps_energy = build_cmps("energy", id_placeholder, has_ei_t1, has_ei_t2, has_eo_t1, has_eo_t2)
  var cmps_diag = build_cmps("diag", id_placeholder, has_ei_t1, has_ei_t2, has_eo_t1, has_eo_t2)

  var names = {
    "fp": content_fingerprint(content),
    "name_v1": varname_for(content, "32.7.0", "V1"),
    "name_v2": varname_for(content, "52.7.0", "V2"),
    "name_v3": varname_for(content, "72.7.0", "V3"),
    "name_i1": varname_for(content, "31.7.0", "I1"),
    "name_i2": varname_for(content, "51.7.0", "I2"),
    "name_i3": varname_for(content, "71.7.0", "I3"),
    "name_pi": (pi_name != nil && size(pi_name) > 0) ? pi_name : "Pi",
    "name_po": varname_for(content, "2.7.0", "Po"),
    "name_p1i": varname_for(content, "21.7.0", "P1i"),
    "name_p2i": varname_for(content, "41.7.0", "P2i"),
    "name_p3i": varname_for(content, "61.7.0", "P3i"),
    "name_p1o": varname_for(content, "22.7.0", "P1o"),
    "name_p2o": varname_for(content, "42.7.0", "P2o"),
    "name_p3o": varname_for(content, "62.7.0", "P3o"),
    "name_rpi": varname_for(content, "3.7.0", "rPi"),
    "name_rpo": varname_for(content, "4.7.0", "rPo"),
    "name_pf1": varname_for(content, "33.7.0", "pf1"),
    "name_ei": varname_for(content, "1.8.0", "Ei"),
    "name_eo": varname_for(content, "2.8.0", "Eo"),
    "name_rei": varname_for(content, "3.8.0", "rEi"),
    "name_reo": varname_for(content, "4.8.0", "rEo"),
    "name_ei_t1": varname_for(content, "1.8.1", "Ei1"),
    "name_ei_t2": varname_for(content, "1.8.2", "Ei2"),
    "name_eo_t1": varname_for(content, "2.8.1", "Eo1"),
    "name_eo_t2": varname_for(content, "2.8.2", "Eo2"),
    "has_ei_t1": has_ei_t1,
    "has_ei_t2": has_ei_t2,
    "has_eo_t1": has_eo_t1,
    "has_eo_t2": has_eo_t2,
    "name_smid": varname_for(content, "0.0.1", "SMid"),
    "power_scale": scale,
    "cmps_state": cmps_state,
    "cmps_power": cmps_power,
    "cmps_energy": cmps_energy,
    "cmps_diag": cmps_diag
  }

  try
    var f = open("gplug_ha_names.cfg", "w")
    f.write(json.dump(names))
    f.close()
    if scale != nil
      print(string.format("gplug_ha_setup: power scale detected: factor %.0f (source: script.txt)", scale))
    end
    print("gplug_ha_setup: wrote gplug_ha_names.cfg - restarting")
  except .. as e, m
    # Nothing we can recover from here - without a names file, gplug_ha.be's
    # start() will just call us again on the next boot (see load_names()).
    print("gplug_ha_setup: FAILED to write gplug_ha_names.cfg: " + str(e) + " " + str(m))
  end

  tasmota.set_timer(500, / -> tasmota.cmd("Restart 1"))
end

run()
