-- tintin.lua
-- arvo pärt's tintinnabuli technique for norns + grid
-- m-voice played on scalar grid keyboard
-- t-voice (bell) generated automatically from chosen triad position
--
-- grid layout:
--   row 1 (top) : cols 9-12 = pattern slots
--   row 2       : cols 1-16 = t-voice delay (0-1000ms)
--   row 3       : sustain bar (cols 1-16 = 0.1s-4.0s)
--   rows 4-8    : col 1 rows 5-8 = t-voice position (2dn,1dn,1up,2up)
--                 cols 3-14 = scalar keyboard (right=+1 degree, up=+int_y degrees)
--
-- encoders:
--   e1 : volume
--   e2 : t-voice delay (fine adjust)
--   e3 : sustain (fine adjust)
--
-- keys:
--   k2 : panic (all notes off)
--   k3 : unused

engine.name = "PolyPerc"

local nb = include 'tintin/lib/nb'
local has_nb = true
local Pt = require 'pattern_time'
local musicutil = require 'musicutil'

local g = grid.connect()

-- build SCALES from musicutil, stripping the trailing octave (12) from intervals
local SCALES = {}
for _, s in ipairs(musicutil.SCALES) do
  local ivs = {}
  for _, v in ipairs(s.intervals) do
    if v < 12 then ivs[#ivs+1] = v end
  end
  SCALES[#SCALES+1] = {name = s.name, intervals = ivs}
end

local NOTE_NAMES = {"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"}

-- -------------------------------------------------------
-- scalar grid layout
-- right = +1 scale degree, up = +5 scale degrees
-- row 1 = bottom of grid (norns grid convention)
-- -------------------------------------------------------
local GRID_COLS = 16
local GRID_ROWS = 8
local KEYBOARD_TOP_ROW = 4   -- rows 4-8 are the keyboard (row 8 = bottom)
local T_POS_ROW   = 1        -- top row
local T_DELAY_ROW  = 2        -- second row
local T_SUSTAIN_ROW = 3        -- third row

local key_oct = 0  -- keyboard octave offset (shifted via grid col 1)
local int_y   = 5  -- scale degrees per row upward on keyboard

-- convert grid (col, row) to a scale degree index (0-based)
-- bottom-left of keyboard (col 3, row 8) = degree 0 (lowest note)
-- keyboard occupies rows 4-8, cols 3-14; row 8 = bottom, row 4 = top
local function grid_to_degree(col, row)
  local flipped = GRID_ROWS - row  -- 0 at row 8, 4 at row 4
  return (col - 3) + flipped * int_y
end

-- convert a scale degree index to a midi note number
-- base_note param is the midi note at bottom-left of keyboard (col 3, row 8)
local function degree_to_midi(degree)
  local base_note = params:get("base_note") + key_oct * 12
  local scale_i   = params:get("scale")
  local intervals = SCALES[scale_i].intervals
  local n         = #intervals

  -- find which scale degree the base_note falls on
  -- (base_note is always the root; we build upward from it)
  local octave_offset = math.floor(degree / n)
  local scale_index   = (degree % n) + 1  -- 1-indexed

  -- base_note gives us the absolute starting midi pitch
  -- intervals are relative to root pitch class, so:
  local root_pitch = base_note  -- bottom-left is always root in chosen octave
  return root_pitch + octave_offset * 12 + intervals[scale_index] - intervals[1]
end

-- is this grid position a root note (any octave)?
local function is_root_degree(col, row)
  local scale_i = params:get("scale")
  local n       = #SCALES[scale_i].intervals
  local degree  = grid_to_degree(col, row)
  return (degree % n) == 0
end

-- -------------------------------------------------------
-- state
-- -------------------------------------------------------
local screen_cursor = 1  -- selected row in screen columns (1-4)
local held = {}          -- held[col][row] = true/false
local t_position = 3   -- 1=2dn, 2=1dn, 3=1up, 4=2up
local t_delay_ms = 0   -- ms delay before t-voice triggers (0 = immediate)
local sus_hold = false -- hold mode: notes sustain indefinitely
local last_m_note = nil
local last_t_note = nil
-- pattern recorder (4 slots, cols 9-12 row 1)
-- states: 1=empty, 2=recording, 3=playing, 4=stopped
local patterns       = {}
local pat_state      = {1, 1, 1, 1, 1, 1, 1, 1}
local pat_active     = 0
local pat_timer      = {}
local pat_shortpress = {true, true, true, true, true, true, true, true}
local pat_just_started = {false, false, false, false, false, false, false, false}

-- -------------------------------------------------------
-- params
-- -------------------------------------------------------
local function setup_params()
  params:add_separator("TINTINNABULI")

  params:add_option("scale", "Scale",
    (function() local t={} for _,s in ipairs(SCALES) do t[#t+1]=s.name end return t end)(),
    (function() for i,s in ipairs(SCALES) do if s.name == "Natural Minor" then return i end end return 1 end)())

  params:add_option("int_y", "Row Interval (degrees)", {"4", "5"}, 2)

  params:add_number("base_note", "base_note", 0, 127, 36)
  params:hide("base_note")
  -- base_note: midi note number for bottom-left grid key
  -- C1=24, C2=36, C3=48, C4=60 etc. Default C2=36
  -- build label list matching note_name() convention: midi 36 = C2, midi 60 = C4
  -- midi note = index - 1, octave label = floor(midi/12) - 1
  local base_note_names = {}
  local note_name_list = {"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"}
  for midi = 0, 95 do
    local oct = math.floor(midi / 12) - 1
    local name = note_name_list[(midi % 12) + 1]
    base_note_names[#base_note_names+1] = name .. oct
  end
  -- default C2 = midi 36 = index 37
  params:add_option("base_note_label", "Bottom-Left Note", base_note_names, 37)
  params:hide("base_note_label")

  params:add_option("t_position", "T-Voice Position",
    {"2nd below","1st below","1st above","2nd above"}, 3)

  params:add_number("t_delay", "T-Voice Delay (ms)", 0, 1000, 0)

  params:add_number("t_octave_shift", "T-Voice Octave", -2, 2, 0)


  params:add_number("vel_min", "Velocity Min", 0, 127, 40)
  params:add_number("vel_max", "Velocity Max", 0, 127, 120)

  params:add_control("sustain", "Sustain (Release)",
    controlspec.new(0.1, 4.0, "lin", 0.01, 2.0, "s"))
  params:set_action("sustain", function(v)
    engine.release(v)
  end)

  params:add_separator("SOUND SOURCE")

  local source_options = {"PolyPerc (internal)", "MIDI out"}
  if has_nb then source_options[#source_options+1] = "nb" end
  params:add_option("m_source", "M-Voice", source_options, 1)
  params:add_option("t_source", "T-Voice", source_options, 1)

  -- nb voice selectors (hidden until source is set to nb)
  if has_nb then
    nb:add_param("m_voice", "M-Voice (nb)")
    nb:add_param("t_voice", "T-Voice (nb)")
    nb:add_player_params()
    params:hide("m_voice")
    params:hide("t_voice")
  end

  params:add_number("midi_out_device", "MIDI Out Device", 1, 4, 1)
  params:add_number("midi_out_ch", "MIDI Out Channel", 1, 16, 1)

  params:add_separator("MIDI INPUT")
  local ch_names = {"any"}
  for i = 1, 16 do ch_names[#ch_names+1] = tostring(i) end
  params:add_number("midi_in_device", "MIDI In Device", 1, 4, 1)
  params:add_option("midi_in_ch", "MIDI In Channel", ch_names, 1)

  params:add_separator("POLYPERC")

  params:add_control("amp", "Amplitude",
    controlspec.new(0.0, 1.0, "lin", 0.01, 0.5, ""))

  params:add_control("release", "Release",
    controlspec.new(0.1, 4.0, "lin", 0.1, 1.2, "s"))
  -- note: the grid sustain bar also drives release via the sustain param

  params:add_control("cutoff", "Cutoff",
    controlspec.new(200, 8000, "exp", 1, 2000, "hz"))

  params:add_control("gain", "Gain",
    controlspec.new(0.1, 4.0, "lin", 0.1, 1.0, ""))

  params:set_action("amp",     function(v) engine.amp(v) end)
  params:set_action("release", function(v) engine.release(v) end)
  params:set_action("cutoff",  function(v) engine.cutoff(v) end)
  params:set_action("gain",    function(v) engine.gain(v) end)

  params:bang()
end

-- find nearest note in current scale to an arbitrary midi note
local function quantize_to_scale(midi_note)
  local scale_i  = params:get("scale")
  local intervals = SCALES[scale_i].intervals
  local root     = params:get("base_note") % 12
  local best, best_dist = midi_note, 999
  for oct = -1, 10 do
    for _, iv in ipairs(intervals) do
      local candidate = oct * 12 + root + iv
      local dist = math.abs(candidate - midi_note)
      if dist < best_dist then
        best_dist = dist
        best = candidate
      end
    end
  end
  return math.max(0, math.min(127, best))
end

-- -------------------------------------------------------
-- midi setup
-- -------------------------------------------------------
local midi_out = nil
local midi_in_dev = nil
local midi_held = {}  -- maps raw incoming note → {m_note, t_note}

local function setup_midi()
  midi_out = midi.connect(params:get("midi_out_device"))
end

-- -------------------------------------------------------
-- music helpers
-- -------------------------------------------------------

-- return the triad notes (degrees 1,3,5) from the current scale
-- spans a wide range centred on base_note so t-voice always has options
local function get_triad_notes()
  local base_note = params:get("base_note")
  local scale_i   = params:get("scale")
  local ivs       = SCALES[scale_i].intervals
  -- root pitch class derived from base_note
  local root      = base_note % 12
  local triad     = {}
  for midi_oct = 0, 10 do
    for _, deg in ipairs({1, 3, 5}) do
      if ivs[deg] then
        local mn = midi_oct * 12 + root + ivs[deg]
        if mn >= 0 and mn <= 127 then
          triad[#triad+1] = mn
        end
      end
    end
  end
  table.sort(triad)
  return triad
end

-- find the nth triad note above m_note (position 1 or 2, strictly above)
local function triad_above(m_note, n)
  local triad = get_triad_notes()
  local count = 0
  for _, t in ipairs(triad) do
    if t > m_note then
      count = count + 1
      if count == n then return t end
    end
  end
  -- wrap: if we ran out, return the highest we have
  return triad[#triad]
end

-- find the nth triad note below m_note (position 1 or 2, strictly below)
local function triad_below(m_note, n)
  local triad = get_triad_notes()
  local count = 0
  for i = #triad, 1, -1 do
    if triad[i] < m_note then
      count = count + 1
      if count == n then return triad[i] end
    end
  end
  return triad[1]
end

-- get the t-voice midi note for a given m-voice midi note
local function get_t_note(m_note)
  local pos    = params:get("t_position")
  local octoff = params:get("t_octave_shift") * 12
  local t
  if     pos == 1 then t = triad_below(m_note, 2)
  elseif pos == 2 then t = triad_below(m_note, 1)
  elseif pos == 3 then t = triad_above(m_note, 1)
  elseif pos == 4 then t = triad_above(m_note, 2)
  end
  return math.max(0, math.min(127, t + octoff))
end

-- midi note to hz
local function midi_to_hz(note)
  return 440 * 2 ^ ((note - 69) / 12)
end

-- -------------------------------------------------------
-- note on / off
-- -------------------------------------------------------
local function note_on(midi_note, is_t_voice, vel)
  vel = vel or 100
  local src = params:get(is_t_voice and "t_source" or "m_source")
  if src == 1 then
    engine.amp(params:get("amp") * (vel / 127))
    engine.hz(midi_to_hz(midi_note))
  elseif src == 2 then
    if midi_out then
      midi_out:note_on(midi_note, vel, params:get("midi_out_ch"))
    end
  elseif has_nb and src == 3 then
    local voice_id = is_t_voice and "t_voice" or "m_voice"
    local player = params:lookup_param(voice_id):get_player()
    if player then player:note_on(midi_note, vel / 127) end
  end
end

local function note_off(midi_note, is_t_voice)
  local src = params:get(is_t_voice and "t_source" or "m_source")
  if src == 2 then
    if midi_out then
      midi_out:note_off(midi_note, 0, params:get("midi_out_ch"))
    end
  elseif has_nb and src == 3 then
    local voice_id = is_t_voice and "t_voice" or "m_voice"
    local player = params:lookup_param(voice_id):get_player()
    if player then player:note_off(midi_note) end
  end
  -- PolyPerc handles its own release
end

local function all_notes_off()
  -- always send MIDI all-notes-off in case source was switched while notes held
  if midi_out then
    for ch = 1, 16 do midi_out:cc(123, 0, ch) end
  end
  if has_nb then
    local mp = params:lookup_param("m_voice"):get_player()
    local tp = params:lookup_param("t_voice"):get_player()
    if mp then mp:note_off() end
    if tp then tp:note_off() end
  end
  held = {}
  midi_held = {}
end

local function setup_midi_in()
  if midi_in_dev then midi_in_dev.event = nil end
  midi_in_dev = midi.connect(params:get("midi_in_device"))
  midi_in_dev.event = function(data)
    local msg = midi.to_msg(data)
    local ch_param = params:get("midi_in_ch")
    if ch_param > 1 and msg.ch ~= ch_param - 1 then return end

    if msg.type == "note_on" and msg.vel > 0 then
      local m_note = quantize_to_scale(msg.note)
      local t_note = get_t_note(m_note)
      local vel = msg.vel
      midi_held[msg.note] = {m_note = m_note, t_note = t_note}
      last_m_note = m_note
      last_t_note = t_note
      if pat_active > 0 then
        patterns[pat_active]:watch({note = m_note, vel = vel})
      end
      note_on(m_note, false, vel)
      local delay_s = params:get("t_delay") / 1000
      local t_src = params:get("t_source")
      local length_s = sus_hold and 300 or params:get("sustain")
      if delay_s <= 0 then
        note_on(t_note, true, vel)
        if t_src == 2 or (has_nb and t_src == 3) then
          clock.run(function() clock.sleep(length_s) note_off(t_note, true) end)
        end
      else
        clock.run(function()
          clock.sleep(delay_s)
          note_on(t_note, true, vel)
          if t_src == 2 or (has_nb and t_src == 3) then
            clock.run(function() clock.sleep(length_s) note_off(t_note, true) end)
          end
        end)
      end
      redraw()

    elseif msg.type == "note_off" or (msg.type == "note_on" and msg.vel == 0) then
      local h = midi_held[msg.note]
      if h then
        note_off(h.m_note, false)
        note_off(h.t_note, true)
        midi_held[msg.note] = nil
      end
      redraw()
    end
  end
end

-- -------------------------------------------------------
-- grid note triggering
-- -------------------------------------------------------
local function trigger_note(col, row)
  local degree = grid_to_degree(col, row)
  local m_note = math.max(0, math.min(127, degree_to_midi(degree)))

  local t_note = get_t_note(m_note)

  last_m_note = m_note
  last_t_note = t_note

  local vel = math.random(params:get("vel_min"), params:get("vel_max"))

  if pat_active > 0 then
    patterns[pat_active]:watch({note = m_note, vel = vel})
  end

  note_on(m_note, false, vel)

  local delay_s = params:get("t_delay") / 1000
  local length_s = sus_hold and 300 or params:get("sustain")
  local m_src = params:get("m_source")
  local t_src = params:get("t_source")

  if delay_s <= 0 then
    note_on(t_note, true, vel)
    if t_src == 2 or (has_nb and t_src == 3) then
      clock.run(function() clock.sleep(length_s) note_off(t_note, true) end)
    end
  else
    clock.run(function()
      clock.sleep(delay_s)
      note_on(t_note, true, vel)
      if t_src == 2 or (has_nb and t_src == 3) then
        clock.run(function() clock.sleep(length_s) note_off(t_note, true) end)
      end
    end)
  end

  if m_src == 2 or (has_nb and m_src == 3) then
    clock.run(function() clock.sleep(length_s) note_off(m_note, false) end)
  end

  redraw()
end

-- -------------------------------------------------------
-- grid rendering: root notes bright (15), all others dim (3)
-- held notes full bright regardless
-- -------------------------------------------------------
local T_POS_LABELS = {"2dn","1dn","1up","2up"}

local function grid_redraw()
  if not g then return end
  g:all(0)

  -- row 1, cols 9-16: pattern slots (1-4 on cols 9-12, 5-8 on cols 13-16)
  for i = 1, 8 do
    local s = pat_state[i]
    local brightness = s == 1 and 2 or (s == 2 and 15 or (s == 3 and 8 or 4))
    g:led(i + 8, T_POS_ROW, brightness)
  end

  -- row 2: t-voice delay bar (cols 1-16 = 0ms to 500ms)
  -- col N is "active" when delay >= (N-1)/15 * 500
  -- col 1 always lit (represents 0ms / off)
  local delay_ms = params:get("t_delay")
  for col = 1, GRID_COLS do
    local col_threshold = math.floor((col - 1) * 1000 / 15)
    local brightness
    if delay_ms == 0 and col == 1 then
      brightness = 15   -- col 1 = no delay, show as active
    elseif delay_ms > 0 and delay_ms >= col_threshold then
      -- brightest at the highest lit col
      local next_threshold = math.floor(col * 1000 / 15)
      brightness = (delay_ms < next_threshold) and 15 or 4
    else
      brightness = 0
    end
    g:led(col, T_DELAY_ROW, brightness)
  end

  -- row 3: sustain bar cols 1-15, col 16 = hold mode
  local sustain_v = params:get("sustain")  -- 0.1 to 4.0
  local sustain_col = math.floor((sustain_v - 0.1) / 3.9 * 14 + 0.5) + 1
  for col = 1, 15 do
    local brightness
    if sus_hold then
      brightness = 2
    elseif col < sustain_col then
      brightness = 4
    elseif col == sustain_col then
      brightness = 15
    else
      brightness = 0
    end
    g:led(col, T_SUSTAIN_ROW, brightness)
  end
  g:led(16, T_SUSTAIN_ROW, sus_hold and 15 or 3)

  -- col 1, rows 5-8: t-voice position (2dn, 1dn, 1up, 2up)
  local t_pos = params:get("t_position")
  for row = 5, 8 do
    g:led(1, row, (9 - row == t_pos) and 15 or 3)
  end

  -- col 16, rows 4-8: t-voice octave (+2 to -2, row 4=+2, row 6=0, row 8=-2)
  local t_oct = params:get("t_octave_shift")
  for row = 4, 8 do
    g:led(16, row, (6 - row == t_oct) and 15 or 3)
  end

  -- rows 4-8, cols 3-14: scalar keyboard
  for col = 3, 14 do
    for row = KEYBOARD_TOP_ROW, GRID_ROWS do
      local brightness
      if held[col] and held[col][row] then
        brightness = 15
      elseif is_root_degree(col, row) then
        brightness = 15
      else
        brightness = 3
      end
      g:led(col, row, brightness)
    end
  end

  g:refresh()
end

-- -------------------------------------------------------
-- grid input
-- -------------------------------------------------------
g.key = function(col, row, z)
  if z == 0 then
    -- pattern slot key up
    if row == T_POS_ROW and col >= 9 and col <= 16 then
      local i = col - 8
      if pat_timer[i] then clock.cancel(pat_timer[i]) pat_timer[i] = nil end
      if pat_just_started[i] then
        -- ignore key-up from the press that started recording
        pat_just_started[i] = false
      elseif pat_shortpress[i] then
        local s = pat_state[i]
        if s == 2 then
          -- recording: stop and start playing
          patterns[i]:rec_stop()
          patterns[i]:start()
          pat_state[i] = 3
          pat_active = 0
        elseif s == 3 then
          -- playing: stop
          patterns[i]:stop()
          pat_state[i] = 4
        elseif s == 4 then
          -- stopped: resume
          patterns[i]:start()
          pat_state[i] = 3
        end
      end
      grid_redraw()
      return
    end
    -- key up: only matters for keyboard cols 3-14
    if row >= KEYBOARD_TOP_ROW and col >= 3 and col <= 14 then
      if not held[col] then held[col] = {} end
      held[col][row] = false
    end
    grid_redraw()
    return
  end

  -- key down
  if row == T_POS_ROW then
    -- pattern slots: cols 9-16
    if col >= 9 and col <= 16 then
      local i = col - 8
      pat_shortpress[i] = true
      if pat_timer[i] then clock.cancel(pat_timer[i]) end
      if pat_state[i] == 1 then
        -- empty: start recording immediately on key down
        patterns[i]:rec_start()
        pat_state[i] = 2
        pat_active = i
        pat_just_started[i] = true
        grid_redraw()
      else
        -- non-empty: start hold timer to detect clear
        pat_timer[i] = clock.run(function()
          clock.sleep(0.6)
          pat_shortpress[i] = false
          if pat_active == i then pat_active = 0 end
          patterns[i]:stop()
          patterns[i]:clear()
          pat_state[i] = 1
          grid_redraw()
        end)
      end
      return
    end

    -- row 1 cols 1-4 now unused

  elseif row == T_DELAY_ROW then
    -- T-voice delay: col 1=0ms, col 16=1000ms
    local delay = math.floor((col - 1) * 1000 / 15)
    t_delay_ms = delay
    params:set("t_delay", delay)
    redraw()
    grid_redraw()

  elseif row == T_SUSTAIN_ROW then
    if col == 16 then
      sus_hold = not sus_hold
      if sus_hold then
        engine.release(30)
      else
        engine.release(4.0)
      end
      grid_redraw()
      return
    end
    -- sustain: col 1=0.1s, col 15=4.0s
    sus_hold = false
    local v = 0.1 + (col - 1) / 14 * 3.9
    params:set("sustain", v)
    redraw()
    grid_redraw()

  elseif row >= KEYBOARD_TOP_ROW then
    if col == 1 then
      -- t-voice position (rows 5-8 = 1dn2, 1dn, 1up, 2up)
      if row >= 5 and row <= 8 then
        t_position = 9 - row
        params:set("t_position", t_position)
        redraw()
        grid_redraw()
      end
    elseif col == 16 then
      -- t-voice octave (row 4=+2, row 5=+1, row 6=0, row 7=-1, row 8=-2)
      params:set("t_octave_shift", 6 - row)
      redraw()
      grid_redraw()
    elseif col >= 3 and col <= 14 then
      -- keyboard
      if not held[col] then held[col] = {} end
      held[col][row] = true
      trigger_note(col, row)
      grid_redraw()
    end
  end
end

-- -------------------------------------------------------
-- norns screen
-- -------------------------------------------------------
local function note_name(midi_note)
  if not midi_note then return "---" end
  local n = NOTE_NAMES[(midi_note % 12) + 1]
  local o = math.floor(midi_note / 12) - 1
  return n .. o
end

local T_POS_NAMES = {"2nd below", "1st below", "1st above", "2nd above"}
local T_POS_SHORT = {"2dn", "1dn", "1up", "2up"}

function redraw()
  screen.clear()
  screen.aa(1)
  screen.font_face(1)

  local lx = 4    -- left col x
  local rx = 68   -- right col x

  -- column headers with last notes played inline
  screen.font_size(7)
  screen.level(4)
  screen.move(lx, 10)
  screen.text("M")
  screen.move(rx, 10)
  screen.text("T")
  screen.level(15)
  screen.font_size(8)
  screen.move(lx + 10, 10)
  screen.text(note_name(last_m_note))
  screen.move(rx + 10, 10)
  screen.text(note_name(last_t_note))

  -- divider
  screen.move(0, 13)
  screen.line_width(0.5)
  screen.line(128, 13)
  screen.level(3)
  screen.stroke()

  local bn         = params:get("base_note")
  local scale_name = SCALES[params:get("scale")].name
  local scale_abbr = #scale_name > 10 and (string.gsub(string.sub(scale_name, 1, 9), "%s+$", "") .. ".") or scale_name
  local dms        = params:get("t_delay")
  local t_oct      = params:get("t_octave_shift")

  local sus = params:get("sustain")
  local m_rows = {
    scale_abbr,
    NOTE_NAMES[(bn % 12) + 1] .. (math.floor(bn / 12) - 1),
    "sus " .. string.format("%.1f", sus) .. "s",
  }

  local t_rows = {
    T_POS_NAMES[params:get("t_position")],
    "oct " .. (t_oct >= 0 and "+" or "") .. t_oct,
    "delay " .. (dms == 0 and "off" or dms .. "ms"),
  }

  local rows = {22, 32, 42}

  screen.font_size(7)
  for i = 1, 3 do
    local bright = (i == screen_cursor) and 15 or 6
    screen.level(bright)
    screen.move(lx, rows[i])
    screen.text(m_rows[i])
    screen.move(rx, rows[i])
    screen.text(t_rows[i])
  end

  -- divider before voice names
  screen.move(0, 52)
  screen.line_width(0.5)
  screen.line(128, 52)
  screen.level(3)
  screen.stroke()

  -- voice names (read-only)
  local src_names = {"PolyPerc", "MIDI", nil}
  local function voice_label(src_param, voice_param)
    local src = params:get(src_param)
    return src_names[src] or params:string(voice_param)
  end
  screen.level(4)
  screen.move(lx, 62)
  screen.text(voice_label("m_source", "m_voice"))
  screen.move(rx, 62)
  screen.text(voice_label("t_source", "t_voice"))

  screen.update()
end

-- -------------------------------------------------------
-- encoders
-- -------------------------------------------------------
function enc(n, d)
  if n == 1 then
    params:delta("amp", d)
  elseif n == 2 then
    if screen_cursor == 1 then
      params:delta("scale", d)
    elseif screen_cursor == 2 then
      params:delta("base_note_label", d)
    elseif screen_cursor == 3 then
      params:delta("sustain", d)
    end
  elseif n == 3 then
    if screen_cursor == 1 then
      params:delta("t_position", d)
    elseif screen_cursor == 2 then
      params:delta("t_octave_shift", d)
    elseif screen_cursor == 3 then
      params:delta("t_delay", d * 10)
    end
  end
  redraw()
  grid_redraw()
end

-- -------------------------------------------------------
-- keys
-- -------------------------------------------------------
local k1_held = false

function key(n, z)
  if n == 1 then
    k1_held = (z == 1)
  elseif z == 1 then
    if k1_held then
      -- K1 hold + K2/K3 = panic
      all_notes_off()
      redraw()
      grid_redraw()
    elseif n == 2 then
      screen_cursor = (screen_cursor - 2) % 3 + 1
      redraw()
    elseif n == 3 then
      screen_cursor = screen_cursor % 3 + 1
      redraw()
    end
  end
end

-- -------------------------------------------------------
-- init
-- -------------------------------------------------------
function init()
  if has_nb then nb:init() end
  setup_params()
  setup_midi()
  setup_midi_in()

  -- init pattern slots
  for i = 1, 8 do
    patterns[i] = Pt.new()
    patterns[i].process = function(e)
      local t_note = get_t_note(e.note)
      last_m_note = e.note
      last_t_note = t_note
      note_on(e.note, false, e.vel)
      local delay_s = params:get("t_delay") / 1000
      local length_s = sus_hold and 300 or params:get("sustain")
      local m_src = params:get("m_source")
      local t_src = params:get("t_source")

      if delay_s <= 0 then
        note_on(t_note, true, e.vel)
        if t_src == 2 or (has_nb and t_src == 3) then
          clock.run(function() clock.sleep(length_s) note_off(t_note, true) end)
        end
      else
        clock.run(function()
          clock.sleep(delay_s)
          note_on(t_note, true, e.vel)
          if t_src == 2 or (has_nb and t_src == 3) then
            clock.run(function() clock.sleep(length_s) note_off(t_note, true) end)
          end
        end)
      end
      if m_src == 2 or (has_nb and m_src == 3) then
        clock.run(function() clock.sleep(length_s) note_off(e.note, false) end)
      end
      redraw()
      grid_redraw()
    end
  end

  -- initialise held table
  for c = 1, GRID_COLS do
    held[c] = {}
    for r = 1, GRID_ROWS do
      held[c][r] = false
    end
  end

  int_y = params:get("int_y") + 3

  -- param change callbacks that need a grid redraw
  params:set_action("int_y",  function(v) int_y = v + 3 grid_redraw() end)
  params:set_action("scale",  function(_) grid_redraw() redraw() end)
  params:set_action("t_position", function(v) t_position = v grid_redraw() redraw() end)
  params:set_action("base_note_label", function(v)
    params:set("base_note", v - 1)
    grid_redraw()
    redraw()
  end)
  params:set_action("m_source", function(v)
    all_notes_off()
    setup_midi()
    if has_nb then
      if v == 3 then params:show("m_voice")
      else params:hide("m_voice") end
      _menu.rebuild_params()
    end
    redraw()
  end)
  params:set_action("t_source", function(v)
    all_notes_off()
    setup_midi()
    if has_nb then
      if v == 3 then params:show("t_voice")
      else params:hide("t_voice") end
      _menu.rebuild_params()
    end
    redraw()
  end)
  params:set_action("midi_out_device", function(_) setup_midi() end)
  params:set_action("midi_in_device", function(_) setup_midi_in() end)

  engine.amp(params:get("amp"))
  engine.release(params:get("release"))
  engine.cutoff(params:get("cutoff"))
  engine.gain(params:get("gain"))

  params.action_write = function(filename, name, number)
    local data = {}
    for i = 1, 8 do
      data[i] = {state = pat_state[i], duration = patterns[i].duration, events = {}}
      for j, e in ipairs(patterns[i].data) do
        data[i].events[j] = {time = e.time, note = e.event.note, vel = e.event.vel}
      end
    end
    tab.save(data, _path.data .. "tintin/patterns_" .. number .. ".data")
  end

  params.action_read = function(filename, silent, number)
    clock.run(function()
      clock.sleep(0.1)
      local data = tab.load(_path.data .. "tintin/patterns_" .. number .. ".data")
      if not data then return end
      for i = 1, 8 do
        if data[i] and data[i].state > 1 then
          patterns[i].data = {}
          for j, e in ipairs(data[i].events) do
            patterns[i].data[j] = {time = e.time, event = {note = e.note, vel = e.vel}}
          end
          patterns[i].duration = data[i].duration
          pat_state[i] = (data[i].state == 2) and 4 or data[i].state
          if pat_state[i] == 3 then patterns[i]:start() end
        end
      end
      grid_redraw()
      redraw()
    end)
  end

  grid_redraw()
  redraw()
end
