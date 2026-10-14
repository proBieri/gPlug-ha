#- gplug_ha.be - Home Assistant MQTT Auto-Discovery for the gPlug's built-in
   smart meter. See spec/s001-ha-mqtt-discovery.md for the full specification.

   All state and functions deliberately live in ONE class (GplugMeterBridge)
   instead of separate top-level functions/variables: method calls go through
   `self.method(...)`, i.e. a runtime attribute lookup on the instance -
   unlike a direct call to a top-level function, the order of the def blocks
   in this file doesn't matter here (Berry has no forward references for
   top-level defs, but methods of a class do, since they're only resolved via
   the instance after the class is fully built). Side effect: only a single
   name (the class plus its one instance) ends up in the global namespace -
   relevant since, per the spec, a second, independent Tasmota app should be
   able to run alongside this one on the same gPlug (see NFR in spec/s001). -#

import mqtt
import json
import string

class GplugMeterBridge
  # -- configuration & runtime state (not persisted) -------------------------
  var version, repo_url, stale_after_s

  var name_v1, name_v2, name_v3
  var name_i1, name_i2, name_i3
  var name_pi, name_po
  var name_p1i, name_p2i, name_p3i
  var name_p1o, name_p2o, name_p3o
  var name_rpi, name_rpo, name_pf1
  var name_ei, name_eo
  var name_rei, name_reo
  var name_ei_t1, name_ei_t2, name_eo_t1, name_eo_t2
  var has_ei_t1, has_ei_t2, has_eo_t1, has_eo_t2
  var name_smid
  var power_scale
  var names_file

  var seen_fingerprint, seen_since
  var active_id, active_smid_text
  var status_html_prefix, status_html_suffix
  var restart_reason
  var device_url
  var diag_temp_c, diag_heap_kb, diag_uptime_s
  var counter_cache
  var pending_tick
  var last_reading
  var discovery_queue
  var minute_count
  var state_interval_s, detail_interval_s, power_interval_s, diag_interval_s, energy_interval_s
  var last_state_publish_utc, last_diag_publish_utc, last_power_publish_utc, last_energy_publish_utc

  def init()
    self.version = "1.0.0"
    self.repo_url = "https://github.com/proBieri/gPlug-ha"
    self.stale_after_s = 60          # beyond this, the smart meter is considered "ok=false"

    self.power_scale = nil
    self.names_file = "gplug_ha_names.cfg"

    self.seen_fingerprint = nil
    self.seen_since = nil
    self.active_id = nil
    self.active_smid_text = nil
    self.status_html_prefix = nil
    self.status_html_suffix = nil
    self.restart_reason = nil
    self.device_url = nil
    self.diag_temp_c = nil
    self.diag_heap_kb = nil
    self.diag_uptime_s = nil
    self.counter_cache = {}
    self.pending_tick = false
    self.last_reading = nil
    self.discovery_queue = []
    self.minute_count = 0
    self.state_interval_s = 0        # 0 = publish on every smart-meter update (see load_config())
    self.detail_interval_s = 120     # legacy combined default for power/diag/energy (see load_config())
    self.power_interval_s = 120      # power republish cadence, independently configurable
    self.diag_interval_s = 120       # diag republish cadence, independently configurable
    self.energy_interval_s = 120     # energy (meter reading) republish cadence, independently configurable
    self.last_state_publish_utc = nil
    self.last_diag_publish_utc = nil
    self.last_power_publish_utc = nil
    self.last_energy_publish_utc = nil
  end

  #- Optional, local, no-reflash config file (gplug_ha.cfg, JSON) - read ONCE
     at boot (see start()), same pattern as the generated names file in
     load_names(): a missing or malformed file silently keeps the defaults
     set in init()
     above, it never crashes the app. This is deliberately still not a
     REMOTE configuration mechanism (see spec's scope boundaries) - editing
     the file still requires filesystem access (Tasmota's own file manager)
     and a restart to take effect, exactly like script.txt.

     `state_interval_s` (default 0): the "state" topic - the fast one,
     driven by json_append() on every real meter update - is normally NOT
     rate-limited at all. Set this to e.g. 30 to only publish it at most
     every 30s instead: useful if you only care about the Home Assistant
     Energy dashboard (which reads the once-every-couple-of-minutes
     `energy` topic anyway, see publish_energy()) and want to cut down on
     how many state_changed events/recorder writes the fast-moving power/
     voltage/current sensors generate.

     `detail_interval_s` (default 120, matching the previous hardcoded
     alternation cadence) is now only the shared *default* for the three
     "detail" topics below, kept for backward compatibility with an
     existing config file that only sets this one key - each of `power`,
     `diag` and `energy` can additionally be overridden independently:

     `power_interval_s`, `diag_interval_s`, `energy_interval_s` (each
     defaulting to `detail_interval_s`'s value unless set explicitly): how
     often the `power`, `diag`, and `energy` topics individually refresh.
     Fully independent - e.g. someone whose PV controller already reads
     live power some other, faster way and only wants this app for the
     Energy dashboard's cumulative counters can set a short `energy`
     (`power_grid_w`, needed for realtime PV control, is on the fast
     `state` topic already - not affected by any of these three) or a
     longer `diag` without the others being tied to it. -#
  def load_config()
    try
      var f = open("gplug_ha.cfg", "r")
      if f == nil return end
      var cfg = json.load(f.read())
      f.close()
      if cfg == nil return end
      self.state_interval_s = self.as_nonneg_int(cfg.find("state_interval_s"), self.state_interval_s)
      self.detail_interval_s = self.as_nonneg_int(cfg.find("detail_interval_s"), self.detail_interval_s)
      if self.detail_interval_s == 0 self.detail_interval_s = 120 end   # 0 would stop all three entirely

      self.power_interval_s = self.as_nonneg_int(cfg.find("power_interval_s"), self.detail_interval_s)
      if self.power_interval_s == 0 self.power_interval_s = 120 end

      self.diag_interval_s = self.as_nonneg_int(cfg.find("diag_interval_s"), self.detail_interval_s)
      if self.diag_interval_s == 0 self.diag_interval_s = 120 end

      self.energy_interval_s = self.as_nonneg_int(cfg.find("energy_interval_s"), self.detail_interval_s)
      if self.energy_interval_s == 0 self.energy_interval_s = 120 end
    except .. as e, m
      # missing/unreadable/corrupt file -> keep the defaults from init()
    end
  end

  #- Accepts a JSON number (Berry's json module hands back `int` or `real`
     depending on whether the file wrote a decimal point) as a non-negative
     interval in seconds; anything else (missing key, wrong type, negative)
     falls back to the current value instead of crashing on a hand-edited
     config file. -#
  def as_nonneg_int(v, fallback)
    var t = type(v)
    if t != 'int' && t != 'real' return fallback end
    var n = int(v)
    return n >= 0 ? n : fallback
  end

  # -- small text helpers, independent of instance state ----------------------
  def looks_like_hex(c)
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
  end

  #- Some meters report the smart meter ID (OBIS 0.0.1) as a hex-ASCII string
     (e.g. "373130363030" -> "710600"), others as a plain number. Only decodes
     when the value has an even number of pure hex characters AND every byte
     pair decodes to printable ASCII, otherwise returns it unchanged - this
     prevents mangling an ID that happens to be hex-decodable but is actually
     purely numeric. -#
  def decode_meter_id(raw)
    if raw == nil return "" end
    var s = str(raw)
    if size(s) == 0 || size(s) % 2 != 0 return s end
    var out = ""
    var i = 0
    while i < size(s)
      var hi = s[i]
      var lo = s[i + 1]
      if !self.looks_like_hex(hi) || !self.looks_like_hex(lo) return s end
      var byte = int("0x" + s[i .. i + 1])
      if byte < 0x20 || byte > 0x7e return s end
      out += string.char(byte)
      i += 2
    end
    return out
  end

  #- gplug_ha_setup.be is the ONLY place left that still parses script.txt
     (OBIS-code/CSV scanning) - see gplug_ha_setup.be's header comment for
     why. This file only ever reads script.txt's raw bytes, to compute the
     SAME cheap length+djb2 fingerprint gplug_ha_setup.be stores alongside
     the names it resolved, so a change to script.txt (meter swap,
     template/firmware update) is still detected automatically - without
     keeping the actual parsing code resident here for the life of the
     process.

     Prefixed with a literal schema version ("v2:" below) - bump it (and
     gplug_ha_setup.be's identical copy) whenever gplug_ha_setup.be starts
     writing different/additional keys into gplug_ha_names.cfg. Without
     this, e.g. when cmps_state/power/energy/diag were added, an old names
     file's "fp" still matched an UNCHANGED script.txt, so load_names()
     accepted a file this version of gplug_ha.be couldn't actually use -
     cmps_for() silently returned {} for every group (confirmed as a real
     failure mode on real hardware before this guard was added). Content-only
     changes to script.txt itself keep working via the length+hash part,
     same as before - the version prefix only guards against
     gplug_ha.be/gplug_ha_setup.be schema skew. -#
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

  #- Loads the variable names + detected power scale that gplug_ha_setup.be
     resolved from script.txt, verifying its stored fingerprint still
     matches script.txt's CURRENT content. Returns true when the names file
     is present, well-formed and fresh (normal operation can proceed);
     false when it's missing, corrupt, or stale (script.txt changed since
     it was written) - in which case start() hands off to
     gplug_ha_setup.be instead of populating any of the name_* fields. -#
  def load_names()
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
    var fp = self.content_fingerprint(content)

    try
      var f = open(self.names_file, "r")
      if f == nil return false end
      var cfg = json.load(f.read())
      f.close()
      if cfg == nil || cfg.find("fp") != fp return false end

      self.name_v1 = cfg.find("name_v1", "V1")
      self.name_v2 = cfg.find("name_v2", "V2")
      self.name_v3 = cfg.find("name_v3", "V3")
      self.name_i1 = cfg.find("name_i1", "I1")
      self.name_i2 = cfg.find("name_i2", "I2")
      self.name_i3 = cfg.find("name_i3", "I3")
      self.name_pi = cfg.find("name_pi", "Pi")
      self.name_po = cfg.find("name_po", "Po")
      self.name_p1i = cfg.find("name_p1i", "P1i")
      self.name_p2i = cfg.find("name_p2i", "P2i")
      self.name_p3i = cfg.find("name_p3i", "P3i")
      self.name_p1o = cfg.find("name_p1o", "P1o")
      self.name_p2o = cfg.find("name_p2o", "P2o")
      self.name_p3o = cfg.find("name_p3o", "P3o")
      self.name_rpi = cfg.find("name_rpi", "rPi")
      self.name_rpo = cfg.find("name_rpo", "rPo")
      self.name_pf1 = cfg.find("name_pf1", "pf1")
      self.name_ei = cfg.find("name_ei", "Ei")
      self.name_eo = cfg.find("name_eo", "Eo")
      self.name_rei = cfg.find("name_rei", "rEi")
      self.name_reo = cfg.find("name_reo", "rEo")
      self.name_ei_t1 = cfg.find("name_ei_t1", "Ei1")
      self.name_ei_t2 = cfg.find("name_ei_t2", "Ei2")
      self.name_eo_t1 = cfg.find("name_eo_t1", "Eo1")
      self.name_eo_t2 = cfg.find("name_eo_t2", "Eo2")
      self.has_ei_t1 = (cfg.find("has_ei_t1") == true)
      self.has_ei_t2 = (cfg.find("has_ei_t2") == true)
      self.has_eo_t1 = (cfg.find("has_eo_t1") == true)
      self.has_eo_t2 = (cfg.find("has_eo_t2") == true)
      self.name_smid = cfg.find("name_smid", "SMid")
      self.power_scale = cfg.find("power_scale")
      return true
    except .. as e, m
      return false
    end
  end

  #- Hands off to gplug_ha_setup.be - a SEPARATE file, not a method here,
     since it's the only place that still needs the OBIS/CSV parsing layer,
     and only ever gets loaded on first install or after script.txt actually
     changes. It re-parses script.txt, (re)writes self.names_file and
     restarts the device; this instance's start() deliberately does nothing
     further after this call (see start()) since wiring up MQTT/cron now
     would just be torn down again by the imminent restart.

     Tries the precompiled gplug_ha_setup.bec first (the .tapp install path
     - see build_tapp.sh), falling back to the raw gplug_ha_setup.be source
     (the single-file/manual install path - see autoexec.be.example) if that
     fails, so both installation methods work without gplug_ha.be needing to
     know which one is in use. -#
  def run_setup_and_restart()
    print("gplug_ha: " + self.names_file + " missing/stale - running one-time setup")
    try
      load(tasmota.wd + "gplug_ha_setup.bec")
    except .. as e, m
      load(tasmota.wd + "gplug_ha_setup.be")
    end
  end

  def tasmota_version_string()
    var v = tasmota.version()
    return str((v >> 24) & 0xFF) + "." + str((v >> 16) & 0xFF) + "." + str((v >> 8) & 0xFF)
  end

  #- Detects whether the smart meter is responding but its values haven't
     actually changed for stale_after_s (an interrupted SML connection:
     Tasmota then keeps showing the last known values unchanged, without any
     indication). `fingerprint` is a string built from values that, under a
     real measurement, practically never stay exactly the same. -#
  def values_are_stale(fingerprint)
    var now = tasmota.rtc('utc')
    if self.seen_fingerprint == nil || fingerprint != self.seen_fingerprint
      self.seen_fingerprint = fingerprint
      self.seen_since = now
      return false
    end
    return (now - self.seen_since) > self.stale_after_s
  end

  #- nil-safe "multiply by the detected power scale, then truncate to int" -
     used for every power-family field (aggregate and per-phase import/
     export), so a meter that doesn't report a given phase (v != nil check)
     doesn't turn into a bogus 0 in the output. -#
  def scaled_power(v, scale)
    return v != nil ? int(v * scale) : nil
  end

  #- nil-safe "import minus export" for one phase - mirrors power_grid_w
     (the aggregate net figure) at the per-phase level. nil only when the
     meter reports NEITHER direction for this phase at all; if it reports
     just one direction, the other is treated as 0 rather than making the
     whole net nil, since e.g. "no export reported for L2" on a meter that
     otherwise clearly separates import/export means zero export, not
     unknown export. -#
  def net_power(imp, exp)
    if imp == nil && exp == nil return nil end
    return (imp != nil ? imp : 0) - (exp != nil ? exp : 0)
  end

  #- Cumulative energy registers (state_class total_increasing in HA) must
     never legitimately decrease - a real meter only starts over on physical
     replacement, which is already handled separately by clearing
     counter_cache on SMid change (see on_tick()). A momentary 0 for a
     register that has already reported a real, nonzero value is therefore
     essentially always a parsing/transport glitch, not a real reading -
     passing it straight through to HA would look like a meter reset to
     Home Assistant's energy dashboard and permanently corrupt its
     long-term statistics for that entity. So: once a nonzero value has been
     seen for `key`, a later exact 0 is replaced with the last known-good
     value instead of being published. A 0 with no prior nonzero history
     (e.g. right after boot, before this register has ever reported) is not
     a "drop" from anything and is passed through unchanged. -#
  def guarded_counter(key, value)
    if value != nil && value != 0
      self.counter_cache[key] = value
      return value
    end
    if value == 0 && self.counter_cache.find(key) != nil
      return self.counter_cache[key]
    end
    return value
  end

  #- Reads the built-in smart meter locally from Tasmota's SML sensor and
     returns EVERY value it reports, not just a curated subset: aggregate
     and per-phase active power (import/export), voltage/current per phase,
     reactive power, power factor, the aggregate energy registers, and - for
     meters with two-tariff billing - the per-tariff energy registers too.
     Returns nil as long as no data is available (yet).

     `power_grid_w` is a convenience net figure (import minus export) kept
     for backward compatibility; `power_import_w`/`power_export_w` are the
     underlying raw aggregate registers Pi/Po themselves, scaled the same
     way. `power_l{1,2,3}_w` are the same net-figure convenience at the
     per-phase level, alongside (not instead of) the separate
     `power_l{1,2,3}_import_w`/`power_l{1,2,3}_export_w` values.
     `current_l{n}_a` is deliberately the unchanged, always positive raw
     sensor value (no encoded sign).

     Reactive power (rPi/rPo) is scaled with the SAME factor detected from
     Pi's declared unit, not its own independently-declared unit - script.txt
     entries for a device have occasionally been observed to declare
     inconsistent units across otherwise-identical field groups (see the
     tasmota-lowmem-webui skill, "don't trust a self-reported unit/scale
     label"), so this is a known, accepted simplification rather than a
     verified-correct per-field scale detection. -#
  def read_meter()
    try
      var sns = json.load(tasmota.read_sensors())
      if sns == nil return nil end
      var z = sns.find("z")
      if z == nil return nil end
      var smid_raw = z.find(self.name_smid)
      if smid_raw == nil return nil end

      var scale = self.power_scale != nil ? self.power_scale : 1.0

      var v1 = z.find(self.name_v1, 0)
      var v2 = z.find(self.name_v2, 0)
      var v3 = z.find(self.name_v3, 0)
      var i1 = z.find(self.name_i1, 0)
      var i2 = z.find(self.name_i2, 0)
      var i3 = z.find(self.name_i3, 0)
      var raw_pi = z.find(self.name_pi, 0)
      var raw_po = z.find(self.name_po, 0)

      var p1i = z.find(self.name_p1i)
      var p2i = z.find(self.name_p2i)
      var p3i = z.find(self.name_p3i)
      var p1o = z.find(self.name_p1o)
      var p2o = z.find(self.name_p2o)
      var p3o = z.find(self.name_p3o)
      var rpi = z.find(self.name_rpi)
      var rpo = z.find(self.name_rpo)
      var pf1 = z.find(self.name_pf1)

      var ei_total = z.find(self.name_ei)
      var eo_total = z.find(self.name_eo)
      var rei = z.find(self.name_rei)
      var reo = z.find(self.name_reo)
      var ei_t1 = z.find(self.name_ei_t1)
      var ei_t2 = z.find(self.name_ei_t2)
      var eo_t1 = z.find(self.name_eo_t1)
      var eo_t2 = z.find(self.name_eo_t2)

      var fingerprint = string.format("%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.3f,%.3f",
        v1, v2, v3, i1, i2, i3, raw_pi, raw_po)

      #- Tariff registers only feed the aggregate fallback when script.txt
         actually declares them (has_ei_t1/has_ei_t2/...) - otherwise ei_t1/
         eo_t1 are just whatever z.find() happened to return for the
         fallback-guessed name "Ei1"/"Eo1", which isn't necessarily this
         meter's tariff register at all. -#
      var ei = ei_total
      if ei == nil && self.has_ei_t1
        ei = ei_t1 + (self.has_ei_t2 && ei_t2 != nil ? ei_t2 : 0)
      end
      var eo = eo_total
      if eo == nil && self.has_eo_t1
        eo = eo_t1 + (self.has_eo_t2 && eo_t2 != nil ? eo_t2 : 0)
      end

      var p1i_w = self.scaled_power(p1i, scale)
      var p2i_w = self.scaled_power(p2i, scale)
      var p3i_w = self.scaled_power(p3i, scale)
      var p1o_w = self.scaled_power(p1o, scale)
      var p2o_w = self.scaled_power(p2o, scale)
      var p3o_w = self.scaled_power(p3o, scale)

      var out = {
        "smid": self.decode_meter_id(smid_raw),
        "power_grid_w": int(raw_pi * scale - raw_po * scale),
        "power_import_w": self.scaled_power(raw_pi, scale),
        "power_export_w": self.scaled_power(raw_po, scale),
        "power_l1_import_w": p1i_w,
        "power_l2_import_w": p2i_w,
        "power_l3_import_w": p3i_w,
        "power_l1_export_w": p1o_w,
        "power_l2_export_w": p2o_w,
        "power_l3_export_w": p3o_w,
        "power_l1_w": self.net_power(p1i_w, p1o_w),
        "power_l2_w": self.net_power(p2i_w, p2o_w),
        "power_l3_w": self.net_power(p3i_w, p3o_w),
        "voltage_l1_v": v1,
        "voltage_l2_v": v2,
        "voltage_l3_v": v3,
        "current_l1_a": i1,
        "current_l2_a": i2,
        "current_l3_a": i3,
        "reactive_power_import_var": self.scaled_power(rpi, scale),
        "reactive_power_export_var": self.scaled_power(rpo, scale),
        "power_factor": pf1,
        "energy_import_kwh": self.guarded_counter("ei", ei),
        "energy_export_kwh": self.guarded_counter("eo", eo),
        "reactive_energy_import_kvarh": self.guarded_counter("rei", rei),
        "reactive_energy_export_kvarh": self.guarded_counter("reo", reo),
        "smartmeter_ok": !self.values_are_stale(fingerprint)
      }
      #- Only reported at all for meters that actually have a second tariff
         (see has_ei_t1/etc.) - matches which components discovery_payload()
         declares, and keeps the state payload smaller for the (much more
         common) single-tariff case. -#
      if self.has_ei_t1 out["energy_import_tariff1_kwh"] = self.guarded_counter("ei_t1", ei_t1) end
      if self.has_ei_t2 out["energy_import_tariff2_kwh"] = self.guarded_counter("ei_t2", ei_t2) end
      if self.has_eo_t1 out["energy_export_tariff1_kwh"] = self.guarded_counter("eo_t1", eo_t1) end
      if self.has_eo_t2 out["energy_export_tariff2_kwh"] = self.guarded_counter("eo_t2", eo_t2) end
      return out
    except .. as e, m
      return nil
    end
  end

  #- gPlug/Tasmota device diagnostics, independent of the smart meter itself
     - published to their own topic_diag() rather than merged into the main
     state message: a full smart-meter reading alone already serializes to
     ~700 bytes, and adding these on top pushed mqtt.publish() past a ~800
     byte limit observed to truncate the payload on real hardware (Tasmota
     logs "BRY: ERROR, bad json" for the corrupted result). Refreshed and
     (re)published once a minute - these values don't need the smart meter's
     own update cadence.

     Deliberately NOT called from on_tick()/json_append(): tasmota.cmd()
     doesn't just read a value, it re-enters Tasmota's own command executor
     (visibly triggering its own "stat/.../STATUS11" MQTT publish as a side
     effect, exactly like typing the command in the console would) - calling
     that from inside json_append(), itself invoked WHILE Tasmota is in the
     middle of assembling its native sensor JSON, caused a real crash on
     real hardware (RestartReason "Exception... Load access fault" on the
     very next boot). refresh_diagnostics() instead runs only from its own
     independent add_cron tick (see start()), the same kind of top-level,
     non-nested trigger this app used safely before switching on_tick()
     itself to json_append() - on_tick() just reads the cached
     diag_temp_c/diag_heap_kb/diag_uptime_s fields this last populated. -#
  def refresh_diagnostics()
    try
      var sns = json.load(tasmota.read_sensors())
      var esp = sns != nil ? sns.find("ESP32") : nil
      self.diag_temp_c = esp != nil ? esp.find("Temperature") : nil
    except .. as e, m
      self.diag_temp_c = nil
    end

    try
      var sts = tasmota.cmd('Status 11', true)['StatusSTS']
      self.diag_heap_kb = sts.find("Heap")
      self.diag_uptime_s = sts.find("UptimeSec")
    except .. as e, m
    end

    if self.restart_reason == nil
      try
        self.restart_reason = tasmota.cmd('Status 1', true)['StatusPRM'].find("RestartReason")
      except .. as e, m
        self.restart_reason = "unknown"
      end
    end

    #- Deliberately NOT cached like restart_reason: refresh_diagnostics() is
       called once synchronously very early in start(), before Tasmota's own
       WiFi/network stack necessarily has an IP yet - caching whatever
       Status 5 returned at that first, possibly-too-early call risked
       permanently freezing this at "0.0.0.0" for the rest of the boot
       (confirmed on real hardware). Re-resolving on every call (still only
       roughly once every couple of minutes via minute_tick(), not the
       json_append() hot path) self-corrects once the real IP is available,
       at the cost of one extra tasmota.cmd() call in an already-infrequent,
       already-safe context. -#
    try
      self.device_url = "http://" + tasmota.cmd('Status 5', true)['StatusNET'].find("IPAddress") + "/"
    except .. as e, m
      self.device_url = nil
    end

    if self.active_id != nil
      self.publish_diag(self.active_id)
    end
  end

  # -- MQTT topics -------------------------------------------------------------
  #- Builds a Tasmota full topic (e.g. the native LWT topic) from the
     currently configured settings instead of guessing it - `%prefix%`/
     `%topic%` are freely changeable by the user in the Tasmota
     configuration. -#
  def device_topic(prefix, suffix)
    try
      var ft = tasmota.cmd('_FullTopic', true)['FullTopic']
      var topic = tasmota.cmd('_Status', true)['Topic']
      var t = string.replace(ft, '%prefix%', prefix)
      t = string.replace(t, '%topic%', topic)
      if size(t) > 0 && t[size(t) - 1] != '/'
        t += '/'
      end
      return t + suffix
    except .. as e, m
      return nil
    end
  end

  def lwt_topic()
    return self.device_topic('tele', 'LWT')
  end

  #- The decoded smart meter ID (decode_meter_id) may contain arbitrary
     printable ASCII characters (including '/', '+', '#', ...), which would
     be problematic in an MQTT topic segment - for topic/ID purposes it is
     therefore reduced to [a-zA-Z0-9_-]; the display (e.g. the discovery
     device name) still uses the unchanged, decoded ID. -#
  def slug(text)
    if text == nil || size(text) == 0 return "" end
    var out = ""
    var i = 0
    while i < size(text)
      var c = text[i]
      if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-'
        out += c
      else
        out += "_"
      end
      i += 1
    end
    return out
  end

  #- State is split across four small topics/discovery messages instead of
     one big one, both ways (data AND discovery config) - confirmed on real
     hardware that a single ~24-key flat state JSON (~700 bytes) intermittently
     corrupted in transit (Tasmota logging "BRY: ERROR, bad json" for the
     truncated result) and a single ~30-component nested discovery JSON
     (~6.6 KB) reliably did, both via mqtt.publish(). HA's MQTT device
     discovery explicitly supports spreading one device's components across
     several config messages that share the same "dev"/"ids" - HA merges
     them into a single device page - which is what topic_discovery*()
     below rely on. -#
  def topic_state(id)
    return "gplug-ha/" + id + "/state"
  end

  def topic_power(id)
    return "gplug-ha/" + id + "/power"
  end

  def topic_energy(id)
    return "gplug-ha/" + id + "/energy"
  end

  def topic_diag(id)
    return "gplug-ha/" + id + "/diag"
  end

  def topic_discovery(id)
    return "homeassistant/device/" + id + "/config"
  end

  def topic_discovery_power(id)
    return "homeassistant/device/" + id + "_power/config"
  end

  def topic_discovery_energy(id)
    return "homeassistant/device/" + id + "_energy/config"
  end

  def topic_discovery_diag(id)
    return "homeassistant/device/" + id + "_diag/config"
  end

  # -- Home Assistant MQTT discovery -------------------------------------------
  #- Reads the "cmps_<group>" map gplug_ha_setup.be precomputed (see its
     fields()/discovery_component()/tariff_flag_present()/build_cmps(), the
     entity schema for one discovery message - which sensors exist, their
     device_class/unit/state_class/entity_category) and patches the real id
     into every component's unique_id (the ONE part of that schema that's
     only known at runtime, not at setup time - see gplug_ha_setup.be's
     id_placeholder "@ID@").

     Deliberately read from self.names_file fresh on EVERY call, not cached
     in a self.* var: discovery only runs rarely (boot, meter-ID change, HA
     restart, the once-per-10-minutes self-heal in minute_tick()), and an
     earlier attempt at permanently caching the equivalent ~33-row table in
     RAM (back when this file still built it directly, before the
     setup/runtime split) measured WORSE on real hardware (40KB
     Berry.HeapUsed after a forced tasmota.gc(), vs. a 37KB baseline before
     that and two other optimizations) - the permanently-retained table
     cost more than it saved. Moving the BUILDING code to gplug_ha_setup.be
     avoids that resident cost a different way: gplug_ha.be no longer
     carries fields()'s ~33-row literal table or the code that walks it at
     all, and the small file read this does instead only happens on those
     same rare occasions.

     A missing/corrupt names file or an unknown group returns {} (no
     components, not a crash) - matches this file's usual "optional local
     file, never fatal" pattern (see load_config()/load_names()); the
     discovery message still gets published with a valid envelope, just
     with no components until the next successful setup run. -#
  def cmps_for(group, id)
    try
      var f = open(self.names_file, "r")
      if f == nil return {} end
      var cfg = json.load(f.read())
      f.close()
      if cfg == nil return {} end
      var cmps = cfg.find("cmps_" + group)
      if cmps == nil return {} end
      for key : cmps.keys()
        var c = cmps[key]
        c["unique_id"] = string.replace(c["unique_id"], "@ID@", id)
      end
      return cmps
    except .. as e, m
      return {}
    end
  end

  #- Shared envelope around one discovery message's "cmps" - `primary` (only
     true for the main "config" message) includes the full device info block
     ("mf"/"mdl"/"sw"); the other three messages send a minimal
     `"dev":{"ids":[id]}` (HA merges by matching "ids", so a minimal dev
     block is sufficient there) to save bytes. The "o" origin block, by
     contrast, is sent on EVERY message, not just the primary one - omitting
     it from the other three (an earlier version of this file did, purely to
     save bytes) meant HA silently discarded those messages entirely rather
     than partially accepting them: real-hardware testing showed exactly and
     consistently the primary message's 9 entities appearing in HA and none
     of the other ~17 from the remaining three messages, which is what
     motivated re-adding "o" everywhere rather than continuing to chase the
     unrelated size/burst theories from the commit history. Availability is
     also repeated on every message, since each is an independent discovery
     payload. -#
  def discovery_envelope(id, smid_text, cmps, state_topic, primary)
    var dev = {"ids": [id]}
    if primary
      dev["name"] = "Smart Meter " + smid_text
      dev["mf"] = "gPlug"
      dev["mdl"] = "gPlug Smart Meter Interface"
      dev["sw"] = self.version + " / Tasmota " + self.tasmota_version_string()
      if self.device_url != nil dev["cu"] = self.device_url end
    end
    var payload = {
      "dev": dev,
      "o": {"name": "gplug-ha", "sw": self.version, "url": self.repo_url},
      "state_topic": state_topic,
      "qos": 0,
      "cmps": cmps
    }
    var avail = self.lwt_topic()
    if avail != nil
      payload["availability_topic"] = avail
      payload["payload_available"] = "Online"
      payload["payload_not_available"] = "Offline"
    end
    return json.dump(payload)
  end

  #- Component names are English, matching the rest of this project. HA
     derives its default entity_id from this name, so keeping name and key
     both English means the entity_id it generates is English too, without
     needing a separate "object_id" override.

     Each function below just reads its group's precomputed components
     (cmps_for(), see gplug_ha_setup.be's FIELDS) and adds the one
     hardcoded special case that doesn't fit that table's shape:
     smartmeter_problem is a binary_sensor with its own value_template
     logic, not a plain value passthrough. -#
  def discovery_payload_state(id, smid_text)
    var cmps = self.cmps_for("state", id)
    cmps["smartmeter_problem"] = {
      "p": "binary_sensor",
      "name": "Smart Meter Problem",
      "device_class": "problem",
      "value_template": "{{ 'OFF' if value_json.smartmeter_ok else 'ON' }}",
      "unique_id": id + "_smartmeter_problem"
    }
    return self.discovery_envelope(id, smid_text, cmps, self.topic_state(id), true)
  end

  def discovery_payload_power(id, smid_text)
    var cmps = self.cmps_for("power", id)
    return self.discovery_envelope(id, smid_text, cmps, self.topic_power(id), false)
  end

  #- Tariff components (Tariff 1/2) are only added when script.txt actually
     declares the corresponding OBIS code (has_ei_t1/has_ei_t2/has_eo_t1/
     has_eo_t2, resolved by gplug_ha_setup.be, read here via load_names()) - most meters only have a single
     register, and always declaring all four regardless would both
     misrepresent meters without tariff billing and needlessly grow the
     payload. See gplug_ha_setup.be's build_cmps()/tariff_flag_present()
     for how FIELDS' 8th column enforces this. -#
  def discovery_payload_energy(id, smid_text)
    var cmps = self.cmps_for("energy", id)
    return self.discovery_envelope(id, smid_text, cmps, self.topic_energy(id), false)
  end

  def discovery_payload_diag(id, smid_text)
    var cmps = self.cmps_for("diag", id)
    return self.discovery_envelope(id, smid_text, cmps, self.topic_diag(id), false)
  end

  #- Enqueues rather than publishes directly - see check_pending() for why:
     four (or, combined with clear_discovery(), up to eight) mqtt.publish()
     calls fired back-to-back from the same call stack were the likely
     cause of some discovery messages arriving corrupted/missing on real
     hardware (some entities never showing up in HA) - the same
     race-with-rapid-successive-publishes problem documented in detail at
     publish_power()/publish_energy(). Spreading them one-per-second via the queue avoids
     that regardless of the exact underlying mechanism. -#
  def enqueue_discovery(topic, payload)
    self.discovery_queue.push([topic, payload])
  end

  def publish_discovery(id, smid_text)
    self.enqueue_discovery(self.topic_discovery(id), self.discovery_payload_state(id, smid_text))
    self.enqueue_discovery(self.topic_discovery_power(id), self.discovery_payload_power(id, smid_text))
    self.enqueue_discovery(self.topic_discovery_energy(id), self.discovery_payload_energy(id, smid_text))
    self.enqueue_discovery(self.topic_discovery_diag(id), self.discovery_payload_diag(id, smid_text))
    print("gplug_ha: discovery queued for " + id)
  end

  def clear_discovery(id)
    self.enqueue_discovery(self.topic_discovery(id), "")
    self.enqueue_discovery(self.topic_discovery_power(id), "")
    self.enqueue_discovery(self.topic_discovery_energy(id), "")
    self.enqueue_discovery(self.topic_discovery_diag(id), "")
    print("gplug_ha: discovery clear queued for " + id)
  end

  #- Only the "state" topic (core values people watch live: grid power,
     voltage/current per phase, power factor, smartmeter_ok) is published on
     every smart-meter update. "power"/"energy" details are published far
     less often, from publish_power()/publish_energy() below, deliberately
     NOT alongside this one - see there for why. -#
  def publish_state(id, reading)
    var core = {
      "power_grid_w": reading["power_grid_w"],
      "voltage_l1_v": reading["voltage_l1_v"],
      "voltage_l2_v": reading["voltage_l2_v"],
      "voltage_l3_v": reading["voltage_l3_v"],
      "current_l1_a": reading["current_l1_a"],
      "current_l2_a": reading["current_l2_a"],
      "current_l3_a": reading["current_l3_a"],
      "power_factor": reading["power_factor"],
      "smartmeter_ok": reading["smartmeter_ok"]
    }
    mqtt.publish(self.topic_state(id), json.dump(core), false)
  end

  #- Per-phase power/reactive power, and separately the energy registers -
     each published at most once a minute (from the same cron as
     refresh_diagnostics(), see start()), using the last reading on_tick()
     cached in self.last_reading (see details_subset()), rather than on
     every smart-meter update like publish_state(). Two separate functions
     (not one, despite reading from the same cached map) so minute_tick()
     can gate and publish them on independent timers (detail_interval_s for
     power, energy_interval_s for energy) - e.g. someone whose PV controller
     already reads live power some other way and only wants this app's
     Energy dashboard integration can slow `energy` down independently of
     `power`.

     This split is a deliberate throughput fix, not just a size
     optimization: three mqtt.publish() calls back-to-back from the same
     on_tick() run (state, power, energy) intermittently corrupted ONE of
     the three in transit on real hardware (Tasmota logging "BRY: ERROR, bad
     json" for whichever message lost the race) - independent of that
     message's own size (it happened even to the smallest, ~9-key state
     payload). This looks like a race in Tasmota's own Berry mqtt.publish()
     binding under rapid back-to-back calls, not a per-message size limit -
     splitting into more same-tick publish() calls (an earlier attempt at
     fixing this) made it *worse*, not better. Reducing the hot path
     (json_append()-driven) to a single publish() call, and moving power and
     energy to the once-a-minute cron (which fires far less often, so an
     occasional collision there is both rarer and lower-stakes) - with
     minute_tick() still only ever firing at most one publish() per
     invocation, power/energy included - is the actual fix. Per-phase
     power/energy data simply doesn't need sub-minute resolution for a
     typical dashboard anyway. -#
  def publish_power(id)
    var reading = self.last_reading
    if reading == nil return end

    var power = {
      "power_import_w": reading["power_import_w"],
      "power_export_w": reading["power_export_w"],
      "power_l1_import_w": reading["power_l1_import_w"],
      "power_l2_import_w": reading["power_l2_import_w"],
      "power_l3_import_w": reading["power_l3_import_w"],
      "power_l1_export_w": reading["power_l1_export_w"],
      "power_l2_export_w": reading["power_l2_export_w"],
      "power_l3_export_w": reading["power_l3_export_w"],
      "power_l1_w": reading["power_l1_w"],
      "power_l2_w": reading["power_l2_w"],
      "power_l3_w": reading["power_l3_w"],
      "reactive_power_import_var": reading["reactive_power_import_var"],
      "reactive_power_export_var": reading["reactive_power_export_var"]
    }
    mqtt.publish(self.topic_power(id), json.dump(power), false)
  end

  def publish_energy(id)
    var reading = self.last_reading
    if reading == nil return end

    var energy = {
      "energy_import_kwh": reading["energy_import_kwh"],
      "energy_export_kwh": reading["energy_export_kwh"],
      "reactive_energy_import_kvarh": reading["reactive_energy_import_kvarh"],
      "reactive_energy_export_kvarh": reading["reactive_energy_export_kvarh"]
    }
    if self.has_ei_t1 energy["energy_import_tariff1_kwh"] = reading["energy_import_tariff1_kwh"] end
    if self.has_ei_t2 energy["energy_import_tariff2_kwh"] = reading["energy_import_tariff2_kwh"] end
    if self.has_eo_t1 energy["energy_export_tariff1_kwh"] = reading["energy_export_tariff1_kwh"] end
    if self.has_eo_t2 energy["energy_export_tariff2_kwh"] = reading["energy_export_tariff2_kwh"] end
    mqtt.publish(self.topic_energy(id), json.dump(energy), false)
  end

  #- Only the fields publish_power()/publish_energy() actually read, not the
     full ~30-key reading read_meter() returns - on_tick() caches THIS
     (smaller) map in self.last_reading instead of the full reading, so the
     ~10 fields publish_state() already consumed immediately and
     publish_power()/publish_energy() never touch (smid, power_grid_w,
     voltage/current per phase, power_factor, smartmeter_ok) don't sit
     around retained in memory for up to a few minutes between minute_tick()
     calls - the full `reading` map itself still gets built fresh every tick
     (unavoidable, publish_state() needs it), it just becomes garbage right
     after on_tick() returns instead of being kept alive. -#
  def details_subset(reading)
    var out = {
      "power_import_w": reading["power_import_w"],
      "power_export_w": reading["power_export_w"],
      "power_l1_import_w": reading["power_l1_import_w"],
      "power_l2_import_w": reading["power_l2_import_w"],
      "power_l3_import_w": reading["power_l3_import_w"],
      "power_l1_export_w": reading["power_l1_export_w"],
      "power_l2_export_w": reading["power_l2_export_w"],
      "power_l3_export_w": reading["power_l3_export_w"],
      "power_l1_w": reading["power_l1_w"],
      "power_l2_w": reading["power_l2_w"],
      "power_l3_w": reading["power_l3_w"],
      "reactive_power_import_var": reading["reactive_power_import_var"],
      "reactive_power_export_var": reading["reactive_power_export_var"],
      "energy_import_kwh": reading["energy_import_kwh"],
      "energy_export_kwh": reading["energy_export_kwh"],
      "reactive_energy_import_kvarh": reading["reactive_energy_import_kvarh"],
      "reactive_energy_export_kvarh": reading["reactive_energy_export_kvarh"]
    }
    if self.has_ei_t1 out["energy_import_tariff1_kwh"] = reading["energy_import_tariff1_kwh"] end
    if self.has_ei_t2 out["energy_import_tariff2_kwh"] = reading["energy_import_tariff2_kwh"] end
    if self.has_eo_t1 out["energy_export_tariff1_kwh"] = reading["energy_export_tariff1_kwh"] end
    if self.has_eo_t2 out["energy_export_tariff2_kwh"] = reading["energy_export_tariff2_kwh"] end
    return out
  end

  def publish_diag(id)
    var diag = {
      "esp32_temperature_c": self.diag_temp_c,
      "heap_free_kb": self.diag_heap_kb,
      "uptime_s": self.diag_uptime_s,
      "restart_reason": self.restart_reason
    }
    mqtt.publish(self.topic_diag(id), json.dump(diag), false)
  end

  #- One topic's "how overdue is it" score, for minute_tick()'s most-overdue
     selection below: nil (never published yet) beats every real elapsed
     time so a topic that hasn't been published since boot always wins its
     first opportunity, regardless of the other two topics' intervals. -#
  def overdue_amount(last_publish_utc, interval_s, now)
    if last_publish_utc == nil return 999999999 end
    return (now - last_publish_utc) - interval_s
  end

  #- Runs once a minute (same add_cron as refresh_diagnostics(), see
     start()) - deliberately does at most ONE publish per invocation, rather
     than letting several fire back-to-back: see publish_power()/
     publish_energy() for why even two rapid mqtt.publish() calls in a row
     are worth avoiding on this hardware. Each topic is gated by elapsed
     time against its own independent interval (diag_interval_s,
     power_interval_s, energy_interval_s - see load_config()), but WHICH due
     topic gets this tick's one publish is decided by overdue_amount() -
     whichever is currently most overdue, not a fixed diag>power>energy
     priority order.

     This matters because a fixed order starves lower-priority topics
     whenever two higher-priority ones are due on every single tick between
     them: with the default 120s interval for all three, diag and power
     alone already land on every minute-tick between them (each fires every
     other minute, offset from the other by one tick), so a fixed
     diag-then-power-then-energy check never even reaches the energy branch
     - energy would never publish, and its HA entities would sit at
     "Unbekannt"/unknown forever. Picking the most-overdue topic instead
     means energy (indefinitely overdue since it's never been published)
     wins its first opportunity, and every topic converges on its own
     configured cadence over time instead of one being starved outright.

     Every 10th minute, also re-enqueues a full discovery refresh
     (self-healing): on real hardware, individual discovery messages have
     been observed to occasionally not arrive intact even after the
     one-per-second queue spacing (enqueue_discovery()) - which one is
     affected varies between attempts, consistent with some transient,
     not-fully-root-caused corruption in Tasmota's own Berry mqtt.publish()
     path rather than anything deterministic about our payloads. Re-sending
     the (retained, therefore idempotent) discovery set periodically is a
     pragmatic mitigation: whichever message got lost last time gets another
     chance without waiting for a reboot or a meter replacement. -#
  def minute_tick()
    self.minute_count += 1
    if self.minute_count % 10 == 0 && self.active_id != nil
      self.publish_discovery(self.active_id, self.active_smid_text)
      return
    end

    var now = tasmota.rtc('utc')
    var diag_due = self.overdue_amount(self.last_diag_publish_utc, self.diag_interval_s, now)
    var power_due = self.active_id != nil ? self.overdue_amount(self.last_power_publish_utc, self.power_interval_s, now) : -999999999
    var energy_due = self.active_id != nil ? self.overdue_amount(self.last_energy_publish_utc, self.energy_interval_s, now) : -999999999

    if diag_due < 0 && power_due < 0 && energy_due < 0 return end

    if diag_due >= power_due && diag_due >= energy_due
      self.refresh_diagnostics()
      self.last_diag_publish_utc = now
    elif power_due >= energy_due
      self.publish_power(self.active_id)
      self.last_power_publish_utc = now
    else
      self.publish_energy(self.active_id)
      self.last_energy_publish_utc = now
    end
  end

  #- Runs on every smart-meter update (see json_append() below), not on a
     fixed timer: reads the meter, (re-)publishes discovery if the SMid
     changed, and publishes the current core state - immediately on first
     detection/SMid change, otherwise subject to state_interval_s (see
     load_config()); 0 (the default) means "every time", matching the
     original always-publish behavior exactly. Caches the details_subset()
     of the reading (not the full ~30-key map - see there) in
     self.last_reading for publish_power()/publish_energy() on EVERY call
     regardless of the state_interval_s gate, so slowing down the state
     topic never makes the power/energy detail topics any staler than they
     already are. -#
  def on_tick()
    var reading = self.read_meter()
    if reading == nil return end
    var raw_id = reading["smid"]
    if raw_id == nil || size(raw_id) == 0 return end
    var id = self.slug(raw_id)
    if size(id) == 0 return end
    self.last_reading = self.details_subset(reading)

    var is_new_meter = (id != self.active_id)
    if is_new_meter
      if self.active_id != nil
        self.clear_discovery(self.active_id)
        self.counter_cache = {}   # old meter's cached registers don't apply to the new one
      end
      self.publish_discovery(id, raw_id)
      self.active_id = id
      self.active_smid_text = raw_id
      # diag/power/energy topics are seeded by the next minute_tick() rather
      # than published immediately here - keeps this rare but already
      # multi-publish branch from growing into an even bigger burst (see
      # publish_power()/publish_energy()/enqueue_discovery() for why bursts are the thing
      # to avoid on this hardware); up to ~2 minutes of delay for those two
      # topics on first detection is an acceptable, one-time trade-off.
    end

    var now = tasmota.rtc('utc')
    var due = self.state_interval_s <= 0 || self.last_state_publish_utc == nil ||
      (now - self.last_state_publish_utc) >= self.state_interval_s
    if is_new_meter || due
      self.publish_state(id, reading)
      self.last_state_publish_utc = now
    end
  end

  # -- re-discovery on HA/broker restart ---------------------------------------
  def on_ha_status(topic, idx, payload_s, payload_b)
    if payload_s == "online" && self.active_id != nil
      self.publish_discovery(self.active_id, self.active_smid_text)
    end
    return true
  end

  # -- status badge on the Tasmota web UI (FR-5) -------------------------------
  #- The Home Assistant mark below is the official "Home Assistant" glyph
     from the Simple Icons project (CC0-licensed brand icon set maintained
     specifically for third-party use like this), not a hand-drawn
     approximation - https://simpleicons.org/icons/homeassistant.svg -#
  static HA_ICON_SVG = "<svg width='8' height='8' viewBox='0 0 24 24' style='display:block;flex-shrink:0'><path fill='#18BCF2' d='M22.939 10.627 13.061.749a1.505 1.505 0 0 0-2.121 0l-9.879 9.878C.478 11.21 0 12.363 0 13.187v9c0 .826.675 1.5 1.5 1.5h9.227l-4.063-4.062a2.034 2.034 0 0 1-.664.113c-1.13 0-2.05-.92-2.05-2.05s.92-2.05 2.05-2.05 2.05.92 2.05 2.05c0 .233-.041.456-.113.665l3.163 3.163V9.928a2.05 2.05 0 0 1-1.15-1.84c0-1.13.92-2.05 2.05-2.05s2.05.92 2.05 2.05a2.05 2.05 0 0 1-1.15 1.84v8.127l3.146-3.146A2.051 2.051 0 0 1 18 12.239c1.13 0 2.05.92 2.05 2.05s-.92 2.05-2.05 2.05c-.25 0-.488-.047-.709-.13L12.9 20.602v3.088h9.6c.825 0 1.5-.675 1.5-1.5v-9c0-.825-.477-1.977-1.061-2.561z'/></svg>"

  #- Builds the fixed markup around the one word that actually changes
     ("active"/"waiting for smart meter data") exactly once and caches it -
     web_sensor() (below) fires on every AJAX poll (every 2-3s), so
     re-formatting the icon/link/style on each call would be wasted work on
     a no-PSRAM ESP32-C3 (see tasmota-lowmem-webui skill, "memoize static
     HTML"). Only the short status word itself is concatenated per call.

     Positioned top-left via `position:absolute` deliberately, styled after
     Tasmota's own native top-right "MQTT" connection badge on this page -
     #l1 itself is `position:static`, so an absolutely positioned element
     inside it (this badge, like Tasmota's own MQTT badge) anchors to the
     nearest positioned ancestor instead (the card wrapping #l1,
     `position:relative`) and renders pinned to that card's corner
     regardless of where in #l1's HTML this fragment ends up - no DOM
     relocation/JS needed.

     `top:5px`, not `top:0`: matching every CSS property Tasmota's own MQTT
     badge uses (`margin:2px`, `padding:1px ...`, `border-width:1px`,
     `font-size:9px`) still rendered our badge 5px higher and 2px shorter
     than the MQTT one on real hardware - Tasmota's badge markup nests an
     inner pill `<span>` (with its own `margin:2px`) inside an outer
     `position:absolute` wrapper `<div>`, which isn't quite the same box
     model as a single element being both the positioned box and the pill.
     `top:5px` (and using the browser's default line-height instead of
     forcing `line-height:1`, which had been fixing the icon/text alignment
     at the cost of shrinking the badge) was arrived at by comparing
     `getBoundingClientRect()` of both badges live in the browser until they
     matched exactly, not derived from matching the CSS declarations
     one-for-one. -#
  def status_fragments()
    if self.status_html_prefix == nil
      #- The four style-string pieces below have no variable between them,
         so they're merged into ONE literal rather than left as separate
         adjacent literals - per the tasmota-lowmem-webui skill ("merge
         adjacent pure-text string literals"), each separate literal is its
         own permanent constant-pool entry regardless of how often this
         runs, and Berry doesn't fold literal-to-literal concatenation for
         you. Only self.repo_url and self.HA_ICON_SVG genuinely need to stay
         as separate `+` operands, since they're variables, not literals. -#
      self.status_html_prefix = "<a href='" + self.repo_url +
        "' target='_blank' rel='noopener' style='position:absolute;top:5px;left:0;margin:2px;" +
        "padding:1px 4px;border-color:#aaaaaa;border-radius:5px;border-style:solid;border-width:1px;" +
        "font-size:9px;font-weight:bold;text-decoration:none;color:inherit;display:inline-flex;" +
        "align-items:center;gap:3px;'>" + self.HA_ICON_SVG + "<span>"
      #- <b id='gpupd'> is an empty placeholder for web_add_main_button()'s
         client-side update check below - empty (as here) it adds zero
         width/height, so it doesn't disturb this badge's pixel-tuned
         layout; only when a newer release exists does client JS fill in
         its text, which is the one case where a tiny layout shift is
         actually correct (there IS more to show). -#
      self.status_html_suffix = "<b id='gpupd'></b></span></a>"
    end
  end

  #- web_sensor() is called by Tasmota on every sensor poll (including AJAX
     refreshes), and its return value is appended INSIDE the existing shared
     sensor container #l1 (AC-5.1) - see status_fragments() above for why
     that placement doesn't matter for this particular badge. This same
     instance also serves as the Tasmota driver here
     (tasmota.add_driver(self) in start()), so a separate UI class isn't
     needed. -#
  def web_sensor()
    self.status_fragments()
    var status = self.active_id != nil ? "active" : "waiting for smart meter data"
    tasmota.web_send(self.status_html_prefix + status + self.status_html_suffix)
  end

  #- Fires ONCE per real page load of "/" - unlike web_sensor() above, NEVER
     on the periodic AJAX poll (`/?m=1`, every 2-3s - see the
     tasmota-lowmem-webui skill's §1). That's deliberately where the update
     check below lives: it does one fetch() against GitHub's Releases API
     per page VIEW, not per poll, so it can't spam GitHub or hit its
     anonymous rate limit under normal use. Entirely client-side and
     zero-cost for the gPlug itself - the browser does the network call and
     the version comparison, this device makes no extra request and holds
     no extra state for it.

     The result is written into the SAME <b id='gpupd'> placeholder
     status_fragments() already left inside the existing status badge,
     rather than a second, separately positioned element - see that
     function's comment for why this badge's position/sizing is pixel-tuned
     and better left alone. Because Tasmota's own poll cycle replaces #l1's
     entire innerHTML on every AJAX refresh (see web_sensor()), that
     placeholder node is torn down and rebuilt EMPTY again on every poll
     along with the rest of the badge - the MutationObserver below is the
     same "Tasmota just repainted, go reapply" trigger from the skill's §3,
     not a second network request: fetch() and the actual version
     comparison still only ever run once per page load. -#
  def web_add_main_button()
    var repo_slug = string.replace(self.repo_url, "https://github.com/", "")
    tasmota.web_send("<script>(function(){" +
      "var CUR='" + self.version + "',REPO='" + repo_slug + "',latest=null;" +
      "function cmp(a,b){a=a.split('.');b=b.split('.');for(var i=0;i<3;i++){" +
      "var x=parseInt(a[i]||0,10),y=parseInt(b[i]||0,10);if(x!=y)return x<y?-1:1;}return 0;}" +
      "function apply(){var e=document.getElementById('gpupd');if(e&&latest&&cmp(CUR,latest)<0){" +
      "e.textContent=' ↑'+latest;e.title='Update available: v'+latest;}}" +
      "fetch('https://api.github.com/repos/'+REPO+'/releases/latest').then(function(r){" +
      "return r.ok?r.json():null;}).then(function(d){if(d&&d.tag_name){" +
      "latest=d.tag_name.replace(/^v/,'');apply();}}).catch(function(){});" +
      "var l1=document.getElementById('l1');" +
      "if(l1&&window.MutationObserver){new MutationObserver(apply).observe(l1,{childList:true});}" +
      "})();</script>")
  end

  #- Fires whenever Tasmota assembles a fresh sensor JSON (native TELE-SENSOR
     message and Status 10) - for a smart meter configured in push mode
     (the gPlug's default), that happens once per meter update, which is
     what drives our own publish cadence instead of an independent timer
     (AC-3.1). For a meter that isn't push-driven, this simply follows
     Tasmota's own TelePeriod cadence instead - there's no lower-level
     per-frame hook exposed to Berry.

     Deliberately does NOTHING but set a flag here - no mqtt.publish(), no
     tasmota.read_sensors(), nothing else. json_append() runs WHILE Tasmota
     is still in the middle of building/sending its own tele/SENSOR MQTT
     message; calling mqtt.publish() (for our own, unrelated topics) from
     inside that window caused a real crash on real hardware twice in a row
     (RestartReason "Exception... Load access fault", then "...Store access
     fault" after moving only the tasmota.cmd() calls out - the mqtt.publish()
     calls in on_tick() itself were still the likely reentrancy culprit).
     check_pending() (below), called from its own independent add_cron tick,
     picks this flag up and does the actual work from a safe, non-nested
     context instead - the same kind of context this app used successfully
     before ever adding json_append(). Also deliberately doesn't call
     tasmota.response_append(): this app has its own state topic (AC-3.2)
     and isn't meant to add fields to Tasmota's native SENSOR JSON. -#
  def json_append()
    self.pending_tick = true
  end

  #- Runs every second (safe top-level cron context, not nested inside any
     Tasmota driver hook). Drains at most ONE queued discovery message per
     call - see enqueue_discovery() - before considering on_tick(), so a
     just-queued batch of discovery messages trickles out one per second
     instead of bursting, and never lands in the very same call as a state
     publish either. Only once the queue is empty does it do the actual
     on_tick() work signaled by json_append() - at most a few seconds of
     added latency behind the real meter update while discovery is
     draining, negligible the rest of the time, and nothing close to the
     several-second cadence a meter update actually arrives at anyway. -#
  def check_pending()
    if size(self.discovery_queue) > 0
      var item = self.discovery_queue[0]
      self.discovery_queue.remove(0)
      mqtt.publish(item[0], item[1], true)
      return
    end
    if self.pending_tick
      self.pending_tick = false
      self.on_tick()
    end
  end

  # -- registration with Tasmota ------------------------------------------------
  #- mqtt.subscribe rejects a bound instance method passed directly
     (Tasmota's callback invocation raises "method not allowed, use a
     closure like '/ args -> obj.func(args)'" - verified on real hardware);
     tasmota.add_driver(self) is unaffected, since Tasmota's driver dispatch
     calls hook methods like web_sensor()/json_append() on the instance
     through a different path - so only mqtt.subscribe/add_cron need a
     wrapping closure here. -#
  def start()
    self.load_config()
    if !self.load_names()
      self.run_setup_and_restart()
      return
    end
    mqtt.subscribe("homeassistant/status",
      / topic, idx, payload_s, payload_b -> self.on_ha_status(topic, idx, payload_s, payload_b))
    tasmota.add_driver(self)
    self.refresh_diagnostics()
    tasmota.add_cron("* * * * * *", / -> self.check_pending(), "gplug_ha_tick")
    tasmota.add_cron("0 * * * * *", / -> self.minute_tick(), "gplug_ha_minute")
    print("gplug_ha: loaded, version=" + self.version)
  end
end

gplug_bridge = GplugMeterBridge()
gplug_bridge.start()
