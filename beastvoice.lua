addon.name      = 'BeastVoice';
addon.author    = 'MoonRise (Eldorin)';
addon.version   = '1.2.0';
addon.desc      = 'Full Active Voice Mod for Beastmen and other Monsters /bv for gui';
addon.link      = '';

require('common');
local chat = require('chat');
local ffi = require('ffi');
local imgui = require('imgui');
local settings = require('settings');

-- 0. Initialize Random Seed
math.randomseed(os.time());
local addon_load_time = os.clock();

-- 1. Setup Advanced Sound Player (MCI)
ffi.cdef[[
    uint32_t mciSendStringA(const char* lpstrCommand, char* lpstrReturnString, uint32_t uReturnLength, void* hwndCallback);
]]
local winmm = ffi.load('winmm');

-- ============================================
-- PARSER ROUTING (Auto / SimpleLog / Traditional)
-- ============================================
-- simplelog_mode: 0 = Auto (route each message by its format), 1 = force
-- SimpleLog parsing, 2 = force Traditional/native parsing. Auto keys off the
-- message content, so the parser always matches whichever chat addon actually
-- produced the line. This removes the historical double-fire/silence caused by
-- running a SimpleLog-style chat addon while the parser toggle was left on the
-- other setting (same model as PartyVoice 1.2).
local PARSER_AUTO        = 0;
local PARSER_SIMPLELOG   = 1;
local PARSER_TRADITIONAL = 2;

-- Content signature: does this message use the SimpleLog bracket / arrow /
-- front-loaded / trailing-(status) format? Native system lines (death, mob
-- damage, "gains the effect of", etc.) never match, so they still flow to the
-- shared/traditional matchers even while a SimpleLog addon is loaded.
local function message_is_simplelog(text)
    if not text then return false; end
    if string.find(text, '^%[%w+%]') then return true; end
    if string.find(text, '→') or string.find(text, '⇒') or string.find(text, '►')
       or string.find(text, '➜') or string.find(text, '➔') then return true; end
    if string.find(text, '^Critical Hit!') or string.find(text, '^Critical hit!')
       or string.find(text, '^Blocked!') or string.find(text, '^Block!')
       or string.find(text, '^Parry') or string.find(text, '^Guarded')
       or string.find(text, '^Evade') or string.find(text, '^Dodge')
       or string.find(text, '^Counter') then return true; end
    if string.find(text, '%([%w]+%)%s*$') then return true; end  -- (status) annotation
    return false;
end

-- Best-effort detection of a SimpleLog-style chat addon (informational only;
-- Auto mode does not depend on it — it is used to warn about forced-mode
-- mismatches in the GUI / /bv mode).
local function simplelog_addon_detected()
    local ok, mgr = pcall(function() return AshitaCore:GetAddonManager(); end);
    if (not ok) or (not mgr) then return false; end
    local okc, count = pcall(function() return mgr:Count(); end);
    if okc and type(count) == 'number' then
        -- Iterate 0..count to cover either 0- or 1-based manager indexing.
        for i = 0, count do
            local okn, nm = pcall(function() return mgr:Get(i); end);
            if okn and type(nm) == 'string' and nm:lower():find('simplelog') then
                return true;
            end
        end
    end
    return false;
end

local parser_mode_label = function(mode)
    if mode == PARSER_SIMPLELOG then return 'SimpleLog'; end
    if mode == PARSER_TRADITIONAL then return 'Traditional'; end
    return 'Auto';
end

-- Coerce any stored parser value into the 0/1/2 enum. Legacy 1.1.x booleans
-- migrate: true (SimpleLog forced) -> 1, false (Traditional forced) -> 0 Auto,
-- so nobody is left in a mismatched parser while a SimpleLog-style chat addon
-- is loaded.
local function normalize_parser_setting(v)
    if type(v) == 'boolean' then
        return v and PARSER_SIMPLELOG or PARSER_AUTO;
    end
    v = tonumber(v) or PARSER_AUTO;
    if (v < PARSER_AUTO) or (v > PARSER_TRADITIONAL) then
        return PARSER_AUTO;
    end
    return v;
end

-- Duck signal for ZoneMusic integration
local duck_signal_file = string.format('%saddons\\voice_duck_signal.txt', AshitaCore:GetInstallPath());
local function signal_duck(duration)
    duration = duration or 2.0;  -- Default 2 seconds if not specified
    pcall(function()
        local f = io.open(duck_signal_file, 'w');
        if f then
            -- Format: timestamp,duration
            -- os.time() (wall-clock seconds) is the ONLY cross-Lua-state safe timestamp.
            -- os.clock() is per-Lua-state and starts at 0 on addon load — ZoneMusic can't
            -- meaningfully compare it to its own clock. The duration is still in seconds.
            f:write(string.format('%s,%s', tostring(os.time()), tostring(duration)));
            f:close();
        end
    end);
end

-- Duck durations for beastman sounds
local DUCK_AGGRO = 2.0;   -- Aggro sounds
local DUCK_COMBAT = 1.5;  -- Attack, ouch
local DUCK_SKILL = 2.5;   -- TP moves
local DUCK_DEATH = 2.5;   -- Death sounds

-- Settings System
local voice_race_names = { 'Orc', 'Quadav', 'Yagudo', 'Goblin', 'Antican', 'Sahagin', 'Demon', 'Shadow Lord', 'Tonberry', 'Monster' };
local function normalize_race_settings(values)
    if type(values) ~= 'table' then values = {}; end
    for _, race in ipairs(voice_race_names) do
        if type(values[race]) ~= 'boolean' then values[race] = true; end
    end
    return values;
end

local default_settings = T{
    enabled = true,
    -- Parser: 0=Auto (per-message), 1=SimpleLog only, 2=Traditional only
    simplelog_mode = 0,
    volume = 500,
    monster_tp_enabled = true,
    tonberry_tp_enabled = true,
    -- Voice Mode: 0=Silent, 1=Ambient(death only), 2=Combat(aggro+death+skills), 3=Full
    voice_mode = 3,
    -- Voice Preset: 0=Muted, 1=Occasional, 2=Balanced, 3=Spammy, 4=Custom
    voice_preset = 2,
    race_enabled = normalize_race_settings({}),
    combat_rates = {
        aggro  = 4,
        attack = 1,
        ouch   = 2,
        death  = 4,
        skills = 3,  -- High (60%). Keep at High/Medium during boss fights to avoid TP-chain audio spam.
    },
};

-- Load settings (returns live settings object)
local bt_settings = settings.load(default_settings);
bt_settings.race_enabled = normalize_race_settings(bt_settings.race_enabled);
bt_settings.tonberry_tp_enabled = bt_settings.tonberry_tp_enabled ~= false;

-- Ensure combat_rates exists with dropdown defaults
if (not bt_settings.combat_rates) then
    bt_settings.combat_rates = {
        aggro = 4,   -- Max (100%)
        attack = 1,  -- Low (10%)
        ouch = 2,    -- Medium (30%)
        death = 4,   -- Max (100%)
        skills = 3,  -- High (60%)
    };
end

-- Ensure enabled exists in loaded settings (fixes nil check bug)
if (bt_settings.enabled == nil) then
    bt_settings.enabled = true;
end

-- Migrate legacy boolean simplelog_mode (1.1.x) -> 0/1/2 parser enum
bt_settings.simplelog_mode = normalize_parser_setting(bt_settings.simplelog_mode);

-- Cache whether a SimpleLog-style chat addon is loaded (used for forced-mode
-- mismatch warnings only; Auto routing does not depend on it).
local sl_addon_loaded = simplelog_addon_detected();

-- 2. GUI Configuration
local beast_config = {
    is_open = { false },
    race_index = { 0 },
    race_enabled = {},
    enabled = { bt_settings.enabled ~= false },
    simplelog_mode = { tonumber(bt_settings.simplelog_mode) or PARSER_AUTO },
    monster_tp_enabled = { bt_settings.monster_tp_enabled ~= false },
    tonberry_tp_enabled = { bt_settings.tonberry_tp_enabled ~= false },
    volume = { math.floor((bt_settings.volume or 500) / 10) },
    voice_mode   = { bt_settings.voice_mode   or 3 },
    voice_preset = { bt_settings.voice_preset or 2 },
    combat_rates = {
        aggro  = { bt_settings.combat_rates.aggro or 4 },
        attack = { bt_settings.combat_rates.attack or 1 },
        ouch   = { bt_settings.combat_rates.ouch or 2 },
        death  = { bt_settings.combat_rates.death or 4 },
        skills = { bt_settings.combat_rates.skills or 3 },
    },
};

for _, race in ipairs(voice_race_names) do
    beast_config.race_enabled[race] = { bt_settings.race_enabled[race] };
end

local StopDisabledRaceVoices;
local function bv_race_allowed(race)
    if not race then return true; end
    local setting = beast_config.race_enabled[race];
    return not setting or setting[1] ~= false;
end

-- Register for settings updates (character change, etc.). Deliberately placed
-- AFTER beast_config is declared: a callback defined earlier in the chunk would
-- resolve 'beast_config' as a nil global (Lua lexical scoping) and this sync
-- would silently never run.
settings.register('settings', 'beastvoice_settings_update', function(new_settings)
    bt_settings = new_settings;
    bt_settings.tonberry_tp_enabled = bt_settings.tonberry_tp_enabled ~= false;
    beast_config.tonberry_tp_enabled[1] = bt_settings.tonberry_tp_enabled;
    bt_settings.race_enabled = normalize_race_settings(bt_settings.race_enabled);
    for _, race in ipairs(voice_race_names) do beast_config.race_enabled[race][1] = bt_settings.race_enabled[race]; end
    if StopDisabledRaceVoices then StopDisabledRaceVoices(); end

    -- Normalize any legacy/stray parser value (older booleans, out-of-range)
    bt_settings.simplelog_mode = normalize_parser_setting(bt_settings.simplelog_mode);

    -- Ensure combat_rates exists on freshly loaded settings
    if (not bt_settings.combat_rates) then
        bt_settings.combat_rates = { aggro = 4, attack = 1, ouch = 2, death = 4, skills = 3 };
    end

    -- Update GUI state from loaded settings
    beast_config.enabled[1] = bt_settings.enabled ~= false;
    beast_config.simplelog_mode[1] = bt_settings.simplelog_mode;
    beast_config.monster_tp_enabled[1] = bt_settings.monster_tp_enabled ~= false;
    beast_config.volume[1] = math.floor((bt_settings.volume or 500) / 10);
    beast_config.voice_mode[1]   = bt_settings.voice_mode   or 3;
    beast_config.voice_preset[1] = bt_settings.voice_preset or 2;
    beast_config.combat_rates.aggro[1]  = bt_settings.combat_rates.aggro  or 4;
    beast_config.combat_rates.attack[1] = bt_settings.combat_rates.attack or 1;
    beast_config.combat_rates.ouch[1]   = bt_settings.combat_rates.ouch   or 2;
    beast_config.combat_rates.death[1]  = bt_settings.combat_rates.death  or 4;
    beast_config.combat_rates.skills[1] = bt_settings.combat_rates.skills or 3;
end);



-- Save settings function (defined after beast_config so it can access it)
local function save_settings()
    bt_settings.enabled = beast_config.enabled[1];
    bt_settings.simplelog_mode = beast_config.simplelog_mode[1];
    bt_settings.monster_tp_enabled = beast_config.monster_tp_enabled[1];    bt_settings.volume = beast_config.volume[1] * 10;
    bt_settings.voice_mode   = beast_config.voice_mode[1];
    bt_settings.voice_preset = beast_config.voice_preset[1];
    bt_settings.tonberry_tp_enabled = beast_config.tonberry_tp_enabled[1];

    bt_settings.combat_rates.aggro = beast_config.combat_rates.aggro[1];
    bt_settings.combat_rates.attack = beast_config.combat_rates.attack[1];
    bt_settings.combat_rates.ouch = beast_config.combat_rates.ouch[1];
    bt_settings.combat_rates.death = beast_config.combat_rates.death[1];
    bt_settings.combat_rates.skills = beast_config.combat_rates.skills[1];

    for _, race in ipairs(voice_race_names) do bt_settings.race_enabled[race] = beast_config.race_enabled[race][1]; end
    settings.save();
    print(chat.header('BeastVoice'):append(chat.message('Settings saved!')));
end

-- === VOICE MODE: category gate ===
-- 0=Silent, 1=Ambient(death only), 2=Combat(death+aggro+skills), 3=Full(everything)
local BV_AMBIENT  = { death=true };
local BV_COMBAT   = { death=true, aggro=true, skills=true };

local function bv_category_allowed(category)
    if beast_config.voice_preset[1] == 0 then return false; end
    local mode = beast_config.voice_mode[1];
    if mode == 0 then return false; end
    if mode == 1 then return BV_AMBIENT[category] == true; end
    if mode == 2 then return BV_COMBAT[category] == true; end
    return true;  -- Full
end

-- Named presets use fixed profiles; saved custom dropdowns are independent.
local BV_CUSTOM_PRESET = 4;
local BV_PRESET_RATES = {
    [0] = { aggro=0, attack=0, ouch=0, death=0, skills=0 },
    [1] = { aggro=10, attack=1, ouch=3, death=10, skills=6 },
    [2] = { aggro=20, attack=2, ouch=6, death=20, skills=12 },
    [3] = { aggro=100, attack=10, ouch=30, death=100, skills=60 },
};

-- === COMBAT RATE SYSTEM ===
local sound_type_cooldown = {};
local RAPID_FIRE_THRESHOLD = 0.35;  -- 350ms minimum between same sound type

-- Per-race aggro cooldown (prevents audio soup when rooms full of same race aggro at once)
local last_aggro_by_race = {};
local AGGRO_RACE_COOLDOWN = 3.0;  -- seconds before same race can fire an aggro bark again

-- Monster ability spam blocker (prevents SimpleLog double-trigger)
-- SimpleLog shows same TP move twice: [Enemy] Ability (readies), then [Enemy] Ability (uses)
-- Format: [enemy_name .. "_" .. ability_name] = last_time
local monster_ability_blocker = {};

-- Global TP/skill category cooldown. Prevents audio soup during boss TP chains where
-- the boss fires multiple DIFFERENT TPs in quick succession (per-ability blocker
-- above doesn't catch this since each key is unique).
-- Applies regardless of combat_rate setting — even Max respects this floor.
local last_skill_sound_time = 0;
local SKILL_GLOBAL_COOLDOWN = 2.5;  -- seconds between ANY two TP/skill sounds

-- Message deduplication (catches chatlog sending same message twice)
local last_message = "";
local last_message_time = 0;

local function get_combat_rate(category)
    local preset = beast_config.voice_preset[1];
    if preset ~= BV_CUSTOM_PRESET then
        local profile = BV_PRESET_RATES[preset] or BV_PRESET_RATES[2];
        return profile[category] or 0;
    end
    -- Convert dropdown index to percentage
    -- 0=Off(0%), 1=Low(10%), 2=Medium(30%), 3=High(60%), 4=Max(100%)
    local function index_to_percent(idx)
        if idx == 0 then return 0 end
        if idx == 1 then return 10 end
        if idx == 2 then return 30 end
        if idx == 3 then return 60 end
        if idx == 4 then return 100 end
        return 100;  -- Default to max
    end

    local index = 4;  -- Default to Max
    if (category == 'aggro') then index = beast_config.combat_rates.aggro[1];
    elseif (category == 'attack') then index = beast_config.combat_rates.attack[1];
    elseif (category == 'ouch') then index = beast_config.combat_rates.ouch[1];
    elseif (category == 'death') then index = beast_config.combat_rates.death[1];
    elseif (category == 'skills') then index = beast_config.combat_rates.skills[1]; end

    return index_to_percent(index);
end

local function should_play_combat(category, race)
    if not bv_race_allowed(race) then return false; end
    if not bv_category_allowed(category) then return false; end
    local rate = get_combat_rate(category);
    local roll = math.random(1, 100);
    if (roll > rate) then
        return false;  -- Failed rate check
    end

    -- Global TP/skill spam floor — applies even at Max.
    -- A boss firing 4 different TPs in 3 seconds will pass the per-ability blocker
    -- (different keys) and the per-category rapid-fire (bypassed at Max), so this
    -- is the only thing standing between the player and the audio brown-note.
    if (category == 'skills') then
        local now_skill = os.clock();
        if (now_skill - last_skill_sound_time) < SKILL_GLOBAL_COOLDOWN then
            return false;
        end
        last_skill_sound_time = now_skill;
    end

    -- Second check: rapid-fire protection (prevent echo effect)
    -- SKIP cooldown if rate is Max (100%) - user wants EVERY instance
    -- EXCEPTION: skills always honor rapid-fire; TP-chain spam is never desirable.
    if (rate < 100 or category == 'skills') then
        local sound_key = "beast_" .. category;
        if (os.clock() - (sound_type_cooldown[sound_key] or 0) < RAPID_FIRE_THRESHOLD) then
            return false;  -- Too soon since last sound of this type
        end
        sound_type_cooldown[sound_key] = os.clock();
    end

    return true;
end

local race_list = { 'Orc', 'Quadav', 'Yagudo', 'Goblin', 'Antican', 'Sahagin', 'Demon', 'Shadow Lord', 'Tonberry' };
local sound_pool_index = 1;
local sound_pool_races = {};
local MAX_POLYPHONY = 15;

-- Aggro tracking: remember which mobs have already aggro'd
local engaged_mobs = {};  -- Track by entity index
-- Departure leaves old entities in memory after their tracking is cleared.
local aggro_transition = { phase='active', identity=nil, stable_since=nil };
local AGGRO_ARRIVAL_STABLE_TIME = 1.0;

local last_check = 0;
local CHECK_INTERVAL = 0.1;  -- Check every 100ms
local DEBUG_AGGRO = false;  -- Set to true to see debug output
local last_debug_heartbeat = 0;  -- For periodic debug messages

-- Beastman name patterns for entity scanning
local beastman_patterns = {
    { pattern = 'Orc', race = 'Orc' },
    { pattern = 'Quadav', race = 'Quadav' },
    { pattern = 'Yagudo', race = 'Yagudo' },
    { pattern = 'Goblin', race = 'Goblin' },
    { pattern = 'Antican', race = 'Antican' },
    { pattern = 'Sahagin', race = 'Sahagin' },
    { pattern = 'Shadow Lord', race = 'Shadow Lord' },
    { pattern = 'Demon', race = 'Demon' },
    { pattern = 'Tonberry', race = 'Tonberry' },
};

-- Named creatures without their family in the displayed name need an explicit alias.
local beast_name_aliases = { ['Bonze Marberry'] = 'Tonberry' };

-- Check if entity name matches a beastman
local function get_beastman_race(name)
    if (not name or name == '') then return nil; end

    -- Exclude pet names (contain "'s" like "Goblin's Bee")
    if (string.find(name, "'s") or string.find(name, " s")) then
        return nil;
    end

    local actor = name:gsub('^[Tt]he%s+', ''):gsub('%s+$', '');
    if beast_name_aliases[actor] then return beast_name_aliases[actor]; end

    for _, bm in ipairs(beastman_patterns) do
        if (string.find(name, bm.pattern)) then
            return bm.race;
        end
    end
    return nil;
end

-- Check if player/party is engaged with any beastman of a specific race
local function is_engaged_with_race(race_name)
    for entity_idx, stored_race in pairs(engaged_mobs) do
        if (stored_race == race_name) then
            return true;
        end
    end
    return false;
end

-- 3. Define Sound Data (Pre-filled to 10 slots)
local beast_data = {
    ['Orc'] = {
        ['skills'] = {
            ['Battle Dance']    = 'orc_battledance.wav',
            ['Shoulder Attack'] = 'orc_shoulder.wav',
            ['Howl']            = 'orc_howl.wav',
            ['Slam Dunk']       = 'orc_slamdunk.wav',
            ['Arm Block']        = 'orc_armblock.wav',
            ['Aerial Wheel']    = 'orc_aerialwheel.wav',
        },
        ['aggro']  = { 'orc_aggro1.wav', 'orc_aggro2.wav', 'orc_aggro3.wav', 'orc_aggro4.wav', 'orc_aggro5.wav', 'orc_aggro6.wav', 'orc_aggro7.wav', 'orc_aggro8.wav', 'orc_aggro9.wav' },
        ['attack'] = { 'orc_attack1.wav', 'orc_attack2.wav', 'orc_attack3.wav', 'orc_attack4.wav', 'orc_attack5.wav', 'orc_attack6.wav', 'orc_attack7.wav', 'orc_attack8.wav', 'orc_attack9.wav', 'orc_attack10.wav' },
        ['ouch']   = { 'orc_ouch1.wav', 'orc_ouch2.wav', 'orc_ouch3.wav', 'orc_ouch4.wav', 'orc_ouch5.wav', 'orc_ouch6.wav', 'orc_ouch7.wav', 'orc_ouch8.wav', 'orc_ouch9.wav', 'orc_ouch10.wav' },
        ['death']  = { 'orc_death1.wav', 'orc_death2.wav', 'orc_death3.wav', 'orc_death4.wav', 'orc_death5.wav', 'orc_death6.wav', 'orc_death7.wav', 'orc_death8.wav', 'orc_death9.wav', 'orc_death10.wav' },
    },
    ['Quadav'] = {
        ['skills'] = {
            ['Shell Bash']       = 'quadav_shellbash.wav',
            ['Head Butt']        = 'quadav_headbutt.wav',
            ['Howl']             = 'quadav_howl.wav',
            ['Shell Guard']      = 'quadav_shellguard.wav',
            ['Ore Toss']         = 'quadav_oretoss.wav',
        },
        ['aggro']  = { 'quadav_aggro1.wav', 'quadav_aggro2.wav', 'quadav_aggro3.wav', 'quadav_aggro4.wav', 'quadav_aggro5.wav', 'quadav_aggro6.wav', 'quadav_aggro7.wav', 'quadav_aggro8.wav', 'quadav_aggro9.wav' },
        ['attack'] = { 'quadav_attack1.wav', 'quadav_attack2.wav', 'quadav_attack3.wav', 'quadav_attack4.wav', 'quadav_attack5.wav', 'quadav_attack6.wav', 'quadav_attack7.wav', 'quadav_attack8.wav', 'quadav_attack9.wav', 'quadav_attack10.wav' },
        ['ouch']   = { 'quadav_ouch1.wav', 'quadav_ouch2.wav', 'quadav_ouch3.wav', 'quadav_ouch4.wav', 'quadav_ouch5.wav', 'quadav_ouch6.wav', 'quadav_ouch7.wav', 'quadav_ouch8.wav', 'quadav_ouch9.wav', 'quadav_ouch10.wav' },
        ['death']  = { 'quadav_death1.wav', 'quadav_death2.wav', 'quadav_death3.wav', 'quadav_death4.wav', 'quadav_death5.wav', 'quadav_death6.wav', 'quadav_death7.wav', 'quadav_death8.wav', 'quadav_death9.wav', 'quadav_death10.wav' },
    },
['Yagudo'] = {
        ['skills'] = {
            -- TP Moves
            ['Sweep']           = 'yagudo_sweep.wav',
            ['Feather Storm']   = 'yagudo_storm.wav',
            ['Double Kick']     = 'yagudo_doublekick.wav',
            ['Parry']           = 'yagudo_parry.wav',
            ['Howl']            = 'yagudo_howl.wav',

            -- Existing Songs
            ['Foe Requiem']       = 'yagudo_foerequiem.wav',
            ['Foe Requiem II']    = 'yagudo_foerequiem.wav',
            ['Foe Requiem III']   = 'yagudo_foerequiem.wav',
            ['Horde Lullaby']     = 'yagudo_lullaby.wav',
            ['Foe Lullaby']       = 'yagudo_lullaby.wav',
            ['Battlefield Elegy'] = 'yagudo_elegy.wav',
            ['Carnage Elegy']     = 'yagudo_elegy.wav',
            ['Magic Finale']      = 'yagudo_finale.wav',

            -- NEW SPELLS ADDED
            ['Advancing March']   = 'yagudo_foerequiem.wav',
            ['Army\'s Paeon II']  = 'yagudo_foerequiem.wav',
            ['Army\'s Paeon III'] = 'yagudo_foerequiem.wav',
            ['Knight\'s Minne II']= 'yagudo_foerequiem.wav',
            ['Sheepfoe Mambo']    = 'yagudo_foerequiem.wav',
            ['Sword Madrigal']    = 'yagudo_elegy.wav',
            ['Valor Minuet II']   = 'yagudo_elegy.wav',
        },
        ['aggro']  = { 'yagudo_aggro1.wav', 'yagudo_aggro2.wav', 'yagudo_aggro3.wav', 'yagudo_aggro4.wav', 'yagudo_aggro5.wav', 'yagudo_aggro6.wav', 'yagudo_aggro7.wav', 'yagudo_aggro8.wav', 'yagudo_aggro9.wav' },
        ['attack'] = { 'yagudo_attack1.wav', 'yagudo_attack2.wav', 'yagudo_attack3.wav', 'yagudo_attack4.wav', 'yagudo_attack5.wav', 'yagudo_attack6.wav', 'yagudo_attack7.wav', 'yagudo_attack8.wav', 'yagudo_attack9.wav', 'yagudo_attack10.wav' },
        ['ouch']   = { 'yagudo_ouch1.wav', 'yagudo_ouch2.wav', 'yagudo_ouch3.wav', 'yagudo_ouch4.wav', 'yagudo_ouch5.wav', 'yagudo_ouch6.wav', 'yagudo_ouch7.wav', 'yagudo_ouch8.wav', 'yagudo_ouch9.wav', 'yagudo_ouch10.wav' },
        ['death']  = { 'yagudo_death1.wav', 'yagudo_death2.wav', 'yagudo_death3.wav', 'yagudo_death4.wav', 'yagudo_death5.wav', 'yagudo_death6.wav', 'yagudo_death7.wav', 'yagudo_death8.wav', 'yagudo_death9.wav', 'yagudo_death10.wav' },
    },
    ['Goblin'] = {
        ['skills'] = {
            ['Bomb Toss']   = 'goblin_bombtoss.wav',
            ['Goblin Rush'] = 'goblin_rush.wav',
        },
        ['aggro']  = { 'goblin_aggro1.wav', 'goblin_aggro2.wav', 'goblin_aggro3.wav', 'goblin_aggro4.wav', 'goblin_aggro5.wav', 'goblin_aggro6.wav', 'goblin_aggro7.wav', 'goblin_aggro8.wav', 'goblin_aggro9.wav' },
        ['attack'] = { 'goblin_attack1.wav', 'goblin_attack2.wav', 'goblin_attack3.wav', 'goblin_attack4.wav', 'goblin_attack5.wav', 'goblin_attack6.wav', 'goblin_attack7.wav', 'goblin_attack8.wav', 'goblin_attack9.wav', 'goblin_attack10.wav' },
        ['ouch']   = { 'goblin_ouch1.wav', 'goblin_ouch2.wav', 'goblin_ouch3.wav', 'goblin_ouch4.wav', 'goblin_ouch5.wav', 'goblin_ouch6.wav', 'goblin_ouch7.wav', 'goblin_ouch8.wav', 'goblin_ouch9.wav', 'goblin_ouch10.wav' },
        ['death']  = { 'goblin_death1.wav', 'goblin_death2.wav', 'goblin_death3.wav', 'goblin_death4.wav', 'goblin_death5.wav', 'goblin_death6.wav', 'goblin_death7.wav', 'goblin_death8.wav', 'goblin_death9.wav', 'goblin_death10.wav' },
    },
    ['Antican'] = {
        ['skills'] = {
            ['Magnetite Cloud'] = 'antican_magnetitecloud.wav',
            ['Jamming Wave']    = 'antican_jammingwave.wav',
            ['Sand Veil']       = 'antican_sandveil.wav',
            ['Sand Shield']     = 'antican_sandshield.wav',
            ['Shoulder Slam']   =  'antican_shoulderslam.wav',
            ['Sand Trap']       = 'antican_sandtrap.wav',
            ['Spike Ball']      = 'antican_spikeball.wav',
        },
        ['aggro']  = { 'antican_aggro1.wav', 'antican_aggro2.wav', 'antican_aggro3.wav', 'antican_aggro4.wav', 'antican_aggro5.wav', 'antican_aggro6.wav', 'antican_aggro7.wav', 'antican_aggro8.wav', 'antican_aggro9.wav' },
        ['attack'] = { 'antican_attack1.wav', 'antican_attack2.wav', 'antican_attack3.wav', 'antican_attack4.wav', 'antican_attack5.wav', 'antican_attack6.wav', 'antican_attack7.wav', 'antican_attack8.wav', 'antican_attack9.wav', 'antican_attack10.wav' },
        ['ouch']   = { 'antican_ouch1.wav', 'antican_ouch2.wav', 'antican_ouch3.wav', 'antican_ouch4.wav', 'antican_ouch5.wav', 'antican_ouch6.wav', 'antican_ouch7.wav', 'antican_ouch8.wav', 'antican_ouch9.wav', 'antican_ouch10.wav' },
        ['death']  = { 'antican_death1.wav', 'antican_death2.wav', 'antican_death3.wav', 'antican_death4.wav', 'antican_death5.wav', 'antican_death6.wav', 'antican_death7.wav', 'antican_death8.wav', 'antican_death9.wav', 'antican_death10.wav' },
    },
    ['Sahagin'] = {
        ['skills'] = {
            ['Spinning Fin']     = 'sahagin_spinningfin.wav',
            ['Hydro Shot']       = 'sahagin_hydroshot.wav',
            ['Bubble Armor']     = 'sahagin_bubblearmor.wav',
            ['Hydro Ball']       = 'sahagin_hydroball.wav',
            ['Hydroball']        = 'sahagin_hydroball.wav',
            ['Jumping Thrust']   = 'sahagin_jumpingthrust.wav',
                        -- Songs (starts casting)
            ['Foe Requiem']     = 'sahagin_foerequiem.wav',
            ['Foe Requiem II']  = 'sahagin_foerequiem.wav',
            ['Foe Requiem III'] = 'sahagin_foerequiem.wav',
            ['Horde Lullaby']   = 'sahagin_lullaby.wav',
            ['Foe Lullaby']     = 'sahagin_lullaby.wav',
            ['Battlefield Elegy'] = 'sahagin_elegy.wav',
            ['Carnage Elegy']   = 'sahagin_elegy.wav',
            ['Magic Finale']    = 'sahagin_finale.wav',
            ['Advancing March']   = 'sahagin_foerequiem.wav',
            ['Victory March']     = 'sahagin_foerequiem.wav',

            ['Knight\'s Minne']   = 'sahagin_elegy.wav',
            ['Knight\'s Minne II']= 'sahagin_elegy.wav',
            ['Knight\'s Minne III']='sahagin_elegy.wav',
            ['Knight\'s Minne IV']= 'sahagin_elegy.wav',

            ['Valor Minuet']      = 'sahagin_foerequiem.wav',
            ['Valor Minuet II']   = 'sahagin_foerequiem.wav',
            ['Valor Minuet III']  = 'sahagin_foerequiem.wav',
            ['Valor Minuet IV']   = 'sahagin_foerequiem.wav',

            ['Sword Madrigal']    = 'sahagin_foerequiem.wav',
            ['Blade Madrigal']    = 'sahagin_foerequiem.wav',

            ['Sheepfoe Mambo']    = 'sahagin_elegy.wav',
            ['Dragonfoe Mambo']   = 'sahagin_elegy.wav',

            ['Army\'s Paeon']     = 'sahagin_elegy.wav',
            ['Army\'s Paeon II']  = 'sahagin_elegy.wav',
            ['Army\'s Paeon III'] = 'sahagin_elegy.wav',
            ['Army\'s Paeon IV']  = 'sahagin_elegy.wav',
            ['Army\'s Paeon V']   = 'sahagin_elegy.wav',

            ['Mage\'s Ballad']    = 'sahagin_elegy.wav',
            ['Mage\'s Ballad II'] = 'sahagin_elegy.wav',
            ['Mage\'s Ballad III']= 'sahagin_elegy.wav',
        },
        ['aggro']  = { 'sahagin_aggro1.wav', 'sahagin_aggro2.wav', 'sahagin_aggro3.wav', 'sahagin_aggro4.wav', 'sahagin_aggro5.wav', 'sahagin_aggro6.wav', 'sahagin_aggro7.wav', 'sahagin_aggro8.wav', 'sahagin_aggro9.wav' },
        ['attack'] = { 'sahagin_attack1.wav', 'sahagin_attack2.wav', 'sahagin_attack3.wav', 'sahagin_attack4.wav', 'sahagin_attack5.wav', 'sahagin_attack6.wav', 'sahagin_attack7.wav', 'sahagin_attack8.wav', 'sahagin_attack9.wav', 'sahagin_attack10.wav' },
        ['ouch']   = { 'sahagin_ouch1.wav', 'sahagin_ouch2.wav', 'sahagin_ouch3.wav', 'sahagin_ouch4.wav', 'sahagin_ouch5.wav', 'sahagin_ouch6.wav', 'sahagin_ouch7.wav', 'sahagin_ouch8.wav', 'sahagin_ouch9.wav', 'sahagin_ouch10.wav' },
        ['death']  = { 'sahagin_death1.wav', 'sahagin_death2.wav', 'sahagin_death3.wav', 'sahagin_death4.wav', 'sahagin_death5.wav', 'sahagin_death6.wav', 'sahagin_death7.wav', 'sahagin_death8.wav', 'sahagin_death9.wav', 'sahagin_death10.wav' },
    },
    ['Demon'] = {
        ['skills'] = {
            ['Demonic Howl']    = 'demon_demonichowl.wav',
            ['Hecatomb Wave']   = 'demon_hecatombwave.wav',
            ['Soul Drain']      = 'demon_souldrain.wav',
            ['Condemnation']    = 'demon_condemnation.wav',
            ['Hellborn Yawp']   = 'demon_hellbornyawp.wav',
            ['Quadrastrike']    = 'demon_quadrastrike.wav',
        },
        ['aggro']  = { 'demon_aggro1.wav', 'demon_aggro2.wav', 'demon_aggro3.wav', 'demon_aggro4.wav', 'demon_aggro5.wav', 'demon_aggro6.wav', 'demon_aggro7.wav', 'demon_aggro8.wav', 'demon_aggro9.wav' },
        ['attack'] = { 'demon_attack1.wav', 'demon_attack2.wav', 'demon_attack3.wav', 'demon_attack4.wav', 'demon_attack5.wav', 'demon_attack6.wav', 'demon_attack7.wav', 'demon_attack8.wav', 'demon_attack9.wav', 'demon_attack10.wav' },
        ['ouch']   = { 'demon_ouch1.wav', 'demon_ouch2.wav', 'demon_ouch3.wav', 'demon_ouch4.wav', 'demon_ouch5.wav', 'demon_ouch6.wav', 'demon_ouch7.wav', 'demon_ouch8.wav', 'demon_ouch9.wav', 'demon_ouch10.wav' },
        ['death']  = { 'demon_death1.wav', 'demon_death2.wav', 'demon_death3.wav', 'demon_death4.wav', 'demon_death5.wav', 'demon_death6.wav', 'demon_death7.wav', 'demon_death8.wav', 'demon_death9.wav', 'demon_death10.wav' },
    },
    ['Tonberry'] = {
        ['skills'] = {
            ['Words of Bane'] = 'tonberry_words_of_bane.mp3',
            ['Ritual Bind'] = 'tonberry_ritual_bind.mp3',
            ['Sigh'] = 'tonberry_sigh.wav',
            ['Light of Penance'] = 'tonberry_light_of_penance.mp3',
            ['Lateral Slash'] = 'tonberry_lateralslash.wav',
            ['Vertical Slash'] = 'tonberry_verticalslash.wav',
            ['Throat Stab'] = 'tonberry_throatstab.wav',
            ['Everyone\'s Grudge'] = 'tonberry_everyones_grudge.mp3',
            ['Everyone\'s Rancor'] = 'tonberry_everyones_rancor.wav',
        },
        ['aggro'] = { 'tonberry_aggro1.wav', 'tonberry_aggro2.wav', 'tonberry_aggro3.wav', 'tonberry_aggro4.wav', 'tonberry_aggro5.wav', 'tonberry_aggro6.wav', 'tonberry_aggro7.wav', 'tonberry_aggro8.wav', 'tonberry_aggro9.wav', 'tonberry_aggro10.wav' },
        ['attack'] = { 'tonberry_attack1.wav', 'tonberry_attack2.wav', 'tonberry_attack3.wav', 'tonberry_attack4.wav', 'tonberry_attack5.wav', 'tonberry_attack6.wav', 'tonberry_attack7.wav', 'tonberry_attack8.wav', 'tonberry_attack9.wav', 'tonberry_attack10.wav' },
        ['ouch'] = { 'tonberry_ouch1.wav', 'tonberry_ouch2.wav', 'tonberry_ouch3.wav', 'tonberry_ouch4.wav', 'tonberry_ouch5.wav', 'tonberry_ouch6.wav', 'tonberry_ouch7.wav', 'tonberry_ouch8.wav', 'tonberry_ouch9.wav', 'tonberry_ouch10.wav' },
        ['death'] = { 'tonberry_death1.wav', 'tonberry_death2.wav', 'tonberry_death3.wav', 'tonberry_death4.wav', 'tonberry_death5.wav', 'tonberry_death6.wav', 'tonberry_death7.wav', 'tonberry_death8.wav', 'tonberry_death9.wav', 'tonberry_death10.wav' },
    },
    ['Shadow Lord'] = {
        ['skills'] = {
            ['Giga Slash']      = 'shadow_gigaslash.wav',
            ['Kick Back']       = 'shadow_kickback.wav',
            ['Umbra Smash']     = 'shadow_umbrasmash.wav',
            ['Dark Nova']       = 'shadow_darknova.wav',
            ['Implosion']       = { 'shadow_implosion1.wav', 'shadow_implosion2.wav', 'shadow_implosion3.wav', 'shadow_implosion4.wav' },
            -- Spells
            ['Drain']           = 'shadow_drain.wav',
            ['Aspir']           = 'shadow_aspir.wav',
            ['Blind']           = 'shadow_blind.wav',
            ['Blizzaga']        = 'shadow_blizzaga.wav',
            ['Thundaga']      = 'shadow_thundaga.wav',
            ['Firaga']          = 'shadow_firaga.wav',
            ['Waterga']         = 'shadow_waterga.wav',
            ['Aeroga']          = 'shadow_aeroga.wav',
            ['Stonega']         = 'shadow_stonega.wav',
            ['Ice Spikes']      = 'shadow_icespikes.wav',
            ['Burn']               = 'shadow_burn.wav',
            ['Rasp']               = 'shadow_rasp.wav',
            ['Choke']              = 'shadow_choke.wav',
            ['Frost']              = 'shadow_frost.wav',
            ['Freeze']             = 'shadow_freeze.wav',
            ['Shock']              = 'shadow_shock.wav',
            ['Drown']              = 'shadow_drown.wav',
        },
        ['aggro']  = { 'shadow_aggro1.wav', 'shadow_aggro2.wav', 'shadow_aggro3.wav', 'shadow_aggro4.wav', 'shadow_aggro5.wav', 'shadow_aggro6.wav', 'shadow_aggro7.wav', 'shadow_aggro8.wav', 'shadow_aggro9.wav' },
        ['attack'] = { 'shadow_attack1.wav', 'shadow_attack2.wav', 'shadow_attack3.wav', 'shadow_attack4.wav', 'shadow_attack5.wav', 'shadow_attack6.wav', 'shadow_attack7.wav', 'shadow_attack8.wav', 'shadow_attack9.wav', 'shadow_attack10.wav' },
        ['ouch']   = { 'shadow_ouch1.wav', 'shadow_ouch2.wav', 'shadow_ouch3.wav', 'shadow_ouch4.wav', 'shadow_ouch5.wav', 'shadow_ouch6.wav', 'shadow_ouch7.wav', 'shadow_ouch8.wav', 'shadow_ouch9.wav', 'shadow_ouch10.wav' },
        ['death']  = { 'shadow_death1.wav', 'shadow_death2.wav', 'shadow_death3.wav', 'shadow_death4.wav', 'shadow_death5.wav', 'shadow_death6.wav', 'shadow_death7.wav', 'shadow_death8.wav', 'shadow_death9.wav', 'shadow_death10.wav' },
    },
};

-- Folder mapping: race key -> subfolder name inside sounds/
local race_sound_folders = {
    ['Orc']         = 'Orc',
    ['Quadav']      = 'Quadav',
    ['Yagudo']      = 'Yagudo',
    ['Goblin']      = 'Goblin',
    ['Antican']     = 'Antican',
    ['Sahagin']     = 'Sahagin',
    ['Demon']       = 'Demon',
    ['Shadow Lord'] = 'Shadowlord',
    ['Tonberry']    = 'Tonberry',
};

-- Folder classification keeps every playback path, including auditions, gated.
local function GetVoiceRace(filename)
    local folder = filename:lower():gsub('\\', '/'):match('^([^/]+)/');
    if folder == 'monster' then return 'Monster'; end
    for race, sound_folder in pairs(race_sound_folders) do
        if sound_folder:lower() == folder then return race; end
    end
    return nil;
end

local function IsVoiceRaceAllowed(filename, actor_race)
    local race = GetVoiceRace(filename);
    if race == 'Monster' and actor_race == 'Tonberry' and not beast_config.tonberry_tp_enabled[1] then return false; end
    return bv_race_allowed(race) and bv_race_allowed(actor_race);
end

-- Reuse a recorded spell family across tiers, while retaining exact overrides.
local shadow_spell_families = {
    ['Drain'] = true, ['Aspir'] = true, ['Blind'] = true,
    ['Blizzaga'] = true, ['Thundaga'] = true, ['Firaga'] = true,
    ['Waterga'] = true, ['Aeroga'] = true, ['Stonega'] = true, ['Ice Spikes'] = true,
    ['Burn'] = true, ['Rasp'] = true, ['Choke'] = true, ['Frost'] = true,
    ['Freeze'] = true, ['Shock'] = true, ['Drown'] = true,
};
local spell_tiers = { I=true, II=true, III=true, IV=true, V=true, VI=true, VII=true, VIII=true, IX=true, X=true };

local function lookup_beast_skill(race_key, action_name)
    local data = beast_data[race_key];
    local skills = data and data.skills;
    if not skills or not action_name then return nil; end
    if skills[action_name] then return skills[action_name]; end
    if race_key ~= 'Shadow Lord' then return nil; end
    local base, tier = action_name:match('^(.-)%s+([IVX]+)$');
    if base and spell_tiers[tier] and shadow_spell_families[base] then
        return skills[base];
    end
    return nil;
end

-- === SMART RANDOMIZER v2 (History Buffer - Blocks last N sounds, not just last 1) ===
local HISTORY_SIZE = 6;  -- Won't repeat any of the last 6 sounds played per category
local sound_history = {}; -- { ["Orc_aggro"] = {2, 1, 3}, ["Goblin_attack"] = {5, 2, 8, 1}, ... }

-- Check if index is in recent history
local function is_in_history(key, idx)
    local history = sound_history[key];
    if not history then return false; end
    for _, v in ipairs(history) do
        if v == idx then return true; end
    end
    return false;
end

-- Add to history (circular buffer - oldest gets pushed out)
local function add_to_history(key, idx)
    if not sound_history[key] then sound_history[key] = {}; end
    table.insert(sound_history[key], idx);
    while #sound_history[key] > HISTORY_SIZE do
        table.remove(sound_history[key], 1);
    end
end

-- === CONTAINER FORMAT (extension-agnostic, PartyVoice protocol) ===
-- BeastVoice packs may ship as .wav OR .mp3. The data tables name files with a
-- .wav suffix for historical reasons, so these helpers treat every declared
-- name as a STEM and probe SOUND_EXTS. A fully .mp3-converted pack plays with
-- no data-table changes. .wav is probed first so a mixed pack keeps .wav
-- authoritative. Both formats are opened through the same MCI 'mpegvideo'
-- device in play_sound(), so this list is the ONLY extension policy here.
local SOUND_EXTS = { '.wav', '.mp3' };

-- Strip a trailing audio extension to get the file stem.
local function bv_stem(name)
    return (name:gsub('%.%w+$', ''));
end

-- Resolve a folder + declared name (may carry an extension) to the first
-- existing container path relative to the sounds dir ("Folder\\stem.ext"), or
-- nil when no supported container exists on disk.
local function bv_probe(folder, name)
    local stem = bv_stem(name);
    local root = AshitaCore:GetInstallPath();
    for _, ext in ipairs(SOUND_EXTS) do
        local path = string.format('%saddons\\beastvoice\\sounds\\%s\\%s%s', root, folder, stem, ext);
        local f = io.open(path, "r");
        if f then
            io.close(f);
            return folder .. '\\' .. stem .. ext;
        end
    end
    return nil;
end

local function get_next_sound(race, action)
    local list = beast_data[race][action];
    if (not list) then return nil; end

    local folder = race_sound_folders[race] or race;

    -- Map each DECLARED entry index to an actually-existing container path.
    -- Missing variants are skipped silently (nil), never played.
    local existing = {};          -- [declared_index] = "Folder\\stem.ext"
    for i = 1, #list do
        local resolved = bv_probe(folder, list[i]);
        if resolved then existing[i] = resolved; end
    end

    -- Auto-discover extra numbered variants on disk beyond the declared list
    -- (e.g. goblin_attack11.wav when the list stops at attack10). Treats the
    -- declared names as one numbered family and probes <prefix><k> up to 20.
    local last_decl = list[#list];
    if (type(last_decl) == 'string') then
        local prefix = last_decl:match('^(.-)%d+%.%w+$');
        if (prefix and #list < 20) then
            for k = #list + 1, 20 do
                if (not existing[k]) then
                    local resolved = bv_probe(folder, prefix .. k .. '.wav');
                    if resolved then existing[k] = resolved; end
                end
            end
        end
    end

    -- Existing indices as an array (random-pick pool)
    local existing_indices = {};
    for i in pairs(existing) do table.insert(existing_indices, i); end

    -- If no files exist, return nil
    if #existing_indices == 0 then return nil; end

    -- If there's only 1 option, we have to play it
    if #existing_indices == 1 then return existing[existing_indices[1]]; end

    -- History key for this race + action combo
    local key = race .. "_" .. action;

    -- Build list of available picks (exist AND not in recent history)
    local valid_indices = {};
    for _, idx in ipairs(existing_indices) do
        if not is_in_history(key, idx) then
            table.insert(valid_indices, idx);
        end
    end

    -- If history blocked everything, partial reset: keep most recent entry
    -- so the just-played file can't immediately repeat after reset
    if #valid_indices == 0 then
        local last_played = sound_history[key] and sound_history[key][#sound_history[key]];
        sound_history[key] = last_played and { last_played } or {};
        valid_indices = {};
        for _, idx in ipairs(existing_indices) do
            if not is_in_history(key, idx) then
                table.insert(valid_indices, idx);
            end
        end
        -- Only 1 file total — no choice
        if #valid_indices == 0 then
            valid_indices = existing_indices;
        end
    end

    -- Pick randomly from available (existing, non-recent) indices
    local pick_idx = valid_indices[math.random(1, #valid_indices)];

    -- Add to history
    add_to_history(key, pick_idx);

    return existing[pick_idx];
end

-- Implosion follows its numbered recordings in order, then repeats from 1.
local implosion_cycle = {};

local function resolve_implosion_sound(skill_entry, race_key)
    local folder = race_sound_folders[race_key] or race_key;
    if #implosion_cycle == 0 then
        for _, filename in ipairs(skill_entry) do
            local resolved = bv_probe(folder, filename);
            if resolved then table.insert(implosion_cycle, resolved); end
        end
    end
    return table.remove(implosion_cycle, 1);
end

-- Resolve skill sound: handles both single file (string) and variant arrays (table)
-- For arrays, uses history-based no-repeat selection from existing files only.
-- Files declared in the data table that don't exist on disk are skipped, so a
-- table claiming 4 variants when only 3 exist plays correctly instead of
-- silently picking the missing index ~25% of the time. .wav/.mp3 agnostic.
local function resolve_skill_sound(skill_entry, race_key, action_name)
    if race_key == 'Shadow Lord' and action_name == 'Implosion' and type(skill_entry) == 'table' then
        return resolve_implosion_sound(skill_entry, race_key);
    end
    local folder = race_sound_folders[race_key] or race_key;

    if type(skill_entry) == 'string' then
        return bv_probe(folder, skill_entry);
    end
    if type(skill_entry) == 'table' then
        -- Filter to indices whose file actually exists on disk
        local existing = {};
        for i = 1, #skill_entry do
            if bv_probe(folder, skill_entry[i]) then
                table.insert(existing, i);
            end
        end
        if #existing == 0 then return nil; end
        if #existing == 1 then return bv_probe(folder, skill_entry[existing[1]]); end

        local key = race_key .. "_skill_" .. action_name;
        local valid = {};
        for _, idx in ipairs(existing) do
            if not is_in_history(key, idx) then
                table.insert(valid, idx);
            end
        end
        if #valid == 0 then
            -- History blocked everything; partial reset, keep most recent
            local last_played = sound_history[key] and sound_history[key][#sound_history[key]];
            sound_history[key] = last_played and { last_played } or {};
            valid = {};
            for _, idx in ipairs(existing) do
                if not is_in_history(key, idx) then
                    table.insert(valid, idx);
                end
            end
            if #valid == 0 then
                valid = existing;
            end
        end
        local pick = valid[math.random(1, #valid)];
        add_to_history(key, pick);
        return bv_probe(folder, skill_entry[pick]);
    end
    return nil;
end



-- Resolve a generic Monster\monster_<ability>[N] variant by scanning for numbered
-- files on disk (1..20). Falls back to legacy un-numbered monster_<ability>.wav if
-- no numbered variants are present. Uses the same history-buffer no-repeat logic as
-- get_next_sound so the same line doesn't fire twice in a row. .wav/.mp3 agnostic.
-- Returns the path-relative filename (e.g. "Monster\\monster_impalement1.wav") or nil.
local function resolve_monster_variant(clean_ability)
    if (not clean_ability or clean_ability == "") then return nil; end

    local folder = "Monster";
    local max_count = 20;

    -- Scan for numbered variants: monster_<ability>1..monster_<ability>20 (.wav/.mp3)
    local existing = {};
    for i = 1, max_count do
        local resolved = bv_probe(folder, string.format('monster_%s%d', clean_ability, i));
        if resolved then
            table.insert(existing, resolved);
        end
    end

    -- No numbered variants — try legacy un-numbered file (either container)
    if (#existing == 0) then
        return bv_probe(folder, string.format('monster_%s', clean_ability));
    end

    -- Only one variant — play it
    if (#existing == 1) then
        return existing[1];
    end

    -- History-buffer pick (reuses the existing sound_history table)
    local key = "Monster_" .. clean_ability;
    local valid = {};
    for i = 1, #existing do
        if not is_in_history(key, i) then
            table.insert(valid, i);
        end
    end

    if (#valid == 0) then
        -- History blocked everything; partial reset keeping most recent
        local last_played = sound_history[key] and sound_history[key][#sound_history[key]];
        sound_history[key] = last_played and { last_played } or {};
        for i = 1, #existing do
            if not is_in_history(key, i) then
                table.insert(valid, i);
            end
        end
        if (#valid == 0) then
            valid = {};
            for i = 1, #existing do table.insert(valid, i); end
        end
    end

    local pick = valid[math.random(1, #valid)];
    add_to_history(key, pick);
    return existing[pick];
end


-- 5. MIXER ENGINE
local function play_sound_unmanaged(filename, debug_mode, duck_duration, actor_race)
    if (filename == nil) then return; end
    if not IsVoiceRaceAllowed(filename, actor_race) then return false; end
    if (not bt_settings.enabled) then return; end
    local path = string.format('%saddons\\beastvoice\\sounds\\%s', AshitaCore:GetInstallPath(), filename);

    -- Check if file exists BEFORE attempting to play
    local f = io.open(path, "r");
    if f == nil then
        if (debug_mode) then
            print(chat.header('BeastVoice'):append(chat.error('MISSING: ' .. filename)));
        end
        return;  -- Exit early - don't play, don't duck
    end
    io.close(f);

    if (debug_mode) then
        print(chat.header('BeastVoice'):append(chat.message('Playing: ' .. filename .. ' (Slot ' .. sound_pool_index .. ')')));
    end

    local alias = "beast_sfx_" .. sound_pool_index;
    winmm.mciSendStringA("close " .. alias, nil, 0, nil);
    local open_cmd = string.format('open "%s" type mpegvideo alias %s', path, alias);
    local open_result = winmm.mciSendStringA(open_cmd, nil, 0, nil);

    -- If MCI open failed (unsupported/corrupt container, codec missing), bail
    -- without spamming volume/play on a dead alias or ducking ZoneMusic.
    if open_result ~= 0 then
        if (debug_mode) then
            print(chat.header('BeastVoice'):append(chat.error('MCI open failed: ' .. tostring(open_result) .. ' ' .. path)));
        end
        return;
    end

    -- Set volume (0-1000, where 1000 = 100%)
    local volume = bt_settings.volume or 500;
    local volume_cmd = string.format('setaudio %s volume to %d', alias, volume);
    winmm.mciSendStringA(volume_cmd, nil, 0, nil);

    winmm.mciSendStringA("play " .. alias, nil, 0, nil);

    -- Signal ZoneMusic to duck with appropriate duration
    signal_duck(duck_duration or DUCK_COMBAT);

    sound_pool_races[sound_pool_index] = { race=GetVoiceRace(filename), actor_race=actor_race };
    sound_pool_index = sound_pool_index + 1;
    if (sound_pool_index > MAX_POLYPHONY) then sound_pool_index = 1; end
end

-- Shadow Lord speaks on one channel. Completion status, rather than a fixed
-- duration guess, keeps long recordings from overlapping the next line.
local shadow_voice_alias = 'beast_shadow_voice';
local shadow_voice_active = nil;
local shadow_voice_pending = {};
local shadow_voice_ready_at = 0;
local shadow_combat_ready_at = 0;
local shadow_voice_last_poll = -math.huge;

local function ClearShadowVoiceQueue()
    winmm.mciSendStringA('close ' .. shadow_voice_alias, nil, 0, nil);
    shadow_voice_active = nil;
    shadow_voice_pending = {};
    shadow_voice_ready_at = 0;
    shadow_combat_ready_at = 0;
end

-- Exclusive TP vocals reuse BeastVoice's MCI player and own exactly one alias.
-- The installed Lua event API has no MCI completion notification. Schedule a
-- one-shot check from measured media length, then verify mode/position; incoming
-- voice requests also reconcile early stops. No render-loop polling is added.
local tonberry_voice_alias = 'beast_tonberry_tp';
local tonberry_exclusive = nil;

local function ClearTonberryExclusive()
    tonberry_exclusive = nil;
    winmm.mciSendStringA('close ' .. tonberry_voice_alias, nil, 0, nil);
end

local function ReadTonberryStatus(field)
    local buffer = ffi.new('char[64]');
    local result = winmm.mciSendStringA('status ' .. tonberry_voice_alias .. ' ' .. field, buffer, 64, nil);
    if result ~= 0 then return nil; end
    return ffi.string(buffer);
end

local function IsTonberryExclusiveActive()
    if not tonberry_exclusive then return false; end
    local mode = ReadTonberryStatus('mode');
    if mode == 'playing' or mode == 'seeking' then return true; end
    -- Failed, stopped, closed or paused playback cannot hold a stale lock.
    ClearTonberryExclusive();
    return false;
end

local function IsTonberryTPVocal(filename)
    local normalized = filename:lower():gsub('\\', '/');
    local stem = normalized:match('^tonberry/(.+)$');
    if not stem then return false; end
    stem = bv_stem(stem);
    -- This skill table is Tonberry's configured TP category, including variants.
    for _, entry in pairs(beast_data.Tonberry.skills) do
        local variants = type(entry) == 'table' and entry or { entry };
        for _, candidate in ipairs(variants) do
            if bv_stem(candidate):lower() == stem then return true; end
        end
    end
    return false;
end

local CheckTonberryCompletion;
local function ScheduleTonberryCompletion(state, remaining_ms)
    local ok = pcall(function()
        ashita.tasks.once(math.max(remaining_ms / 1000, 0.05), function()
            if tonberry_exclusive == state then CheckTonberryCompletion(state); end
        end);
    end);
    if not ok then ClearTonberryExclusive(); end
    return ok;
end

CheckTonberryCompletion = function(state)
    if tonberry_exclusive ~= state or not IsTonberryExclusiveActive() then return; end
    local position = tonumber(ReadTonberryStatus('position'));
    if not position or position < 0 then ClearTonberryExclusive(); return; end
    if position >= state.length_ms then
        -- Give the driver one final boundary check without assuming animation time.
        if state.checked_end then ClearTonberryExclusive(); return; end
        state.checked_end = true;
        ScheduleTonberryCompletion(state, 50);
        return;
    end
    if position <= state.last_position then
        -- A device with no forward progress must not permanently lock all voices.
        ClearTonberryExclusive();
        return;
    end
    state.last_position = position;
    ScheduleTonberryCompletion(state, state.length_ms - position);
end;

local function StartTonberryExclusive(filename, debug_mode)
    if not beast_config.tonberry_tp_enabled[1] then return false; end
    if not bv_race_allowed('Tonberry') then return false; end
    if IsTonberryExclusiveActive() then return false; end
    if not bv_category_allowed('skills') then return false; end
    if not ashita.tasks or type(ashita.tasks.once) ~= 'function' then return false; end
    local path = string.format('%saddons\\beastvoice\\sounds\\%s', AshitaCore:GetInstallPath(), filename);
    local file = io.open(path, 'rb');
    if not file then return false; end
    file:close();
    winmm.mciSendStringA('close ' .. tonberry_voice_alias, nil, 0, nil);
    local result = winmm.mciSendStringA(string.format('open "%s" type mpegvideo alias %s', path, tonberry_voice_alias), nil, 0, nil);
    if result ~= 0 then ClearTonberryExclusive(); return false; end
    result = winmm.mciSendStringA('set ' .. tonberry_voice_alias .. ' time format milliseconds', nil, 0, nil);
    local length = tonumber(ReadTonberryStatus('length'));
    if result ~= 0 or not length or length <= 0 then ClearTonberryExclusive(); return false; end
    result = winmm.mciSendStringA(string.format('setaudio %s volume to %d', tonberry_voice_alias, bt_settings.volume or 500), nil, 0, nil);
    if result ~= 0 then ClearTonberryExclusive(); return false; end
    -- Stop only aliases owned by BeastVoice. Never use a global MCI close/stop.
    ClearShadowVoiceQueue();
    for i = 1, MAX_POLYPHONY do
        winmm.mciSendStringA('close beast_sfx_' .. i, nil, 0, nil);
    end
    result = winmm.mciSendStringA('play ' .. tonberry_voice_alias, nil, 0, nil);
    if result ~= 0 then ClearTonberryExclusive(); return false; end
    local state = { filename=filename, length_ms=length, last_position=-1 };
    tonberry_exclusive = state;
    -- Tonberry exclusivity never signals music ducking or changes native audio.
    if not ScheduleTonberryCompletion(state, length) then return false; end
    if debug_mode then
        print(chat.header('BeastVoice'):append(chat.message('Exclusive Tonberry voice: ' .. filename)));
    end
    return true;
end

local function StartShadowVoice(request)
    if not bv_race_allowed('Shadow Lord') then return false; end
    local path = string.format('%saddons\\beastvoice\\sounds\\%s', AshitaCore:GetInstallPath(), request.filename);
    local file = io.open(path, 'rb');
    if not file then
        if request.debug_mode then
            print(chat.header('BeastVoice'):append(chat.error('MISSING: ' .. request.filename)));
        end
        return false;
    end
    file:close();
    winmm.mciSendStringA('close ' .. shadow_voice_alias, nil, 0, nil);
    local result = winmm.mciSendStringA(string.format('open "%s" type mpegvideo alias %s', path, shadow_voice_alias), nil, 0, nil);
    if result ~= 0 then
        if request.debug_mode then
            print(chat.header('BeastVoice'):append(chat.error('MCI open failed: ' .. tostring(result) .. ' ' .. request.filename)));
        end
        return false;
    end
    winmm.mciSendStringA(string.format('setaudio %s volume to %d', shadow_voice_alias, bt_settings.volume or 500), nil, 0, nil);
    result = winmm.mciSendStringA('play ' .. shadow_voice_alias, nil, 0, nil);
    if result ~= 0 then
        winmm.mciSendStringA('close ' .. shadow_voice_alias, nil, 0, nil);
        return false;
    end
    shadow_voice_active = request;
    signal_duck(request.duck_duration or DUCK_COMBAT);
    if request.debug_mode then
        print(chat.header('BeastVoice'):append(chat.message('Playing: ' .. request.filename .. ' (Shadow Lord)')));
    end
    return true;
end

local function HandleShadowVoiceQueue()
    if not bv_race_allowed('Shadow Lord') then
        if shadow_voice_active or #shadow_voice_pending > 0 then ClearShadowVoiceQueue(); end
        return;
    end
    if aggro_transition.phase ~= 'active' then return; end
    if tonberry_exclusive then return; end
    if not bt_settings.enabled then
        if shadow_voice_active or #shadow_voice_pending > 0 then ClearShadowVoiceQueue(); end
        return;
    end
    local now = os.clock();
    if shadow_voice_active then
        if now - shadow_voice_last_poll < 0.1 then return; end
        shadow_voice_last_poll = now;
        local mode = ffi.new('char[32]');
        local result = winmm.mciSendStringA('status ' .. shadow_voice_alias .. ' mode', mode, 32, nil);
        local playing = result == 0 and ffi.string(mode):lower();
        if bv_category_allowed(shadow_voice_active.category)
           and (playing == 'playing' or playing == 'seeking' or playing == 'paused') then
            return;
        end
        winmm.mciSendStringA('close ' .. shadow_voice_alias, nil, 0, nil);
        shadow_voice_active = nil;
        shadow_voice_ready_at = now + 0.2;
        shadow_combat_ready_at = now + 0.75;
    end
    if now < shadow_voice_ready_at then return; end
    while #shadow_voice_pending > 0 do
        local next_index = 1;
        for i = 2, #shadow_voice_pending do
            if shadow_voice_pending[i].priority > shadow_voice_pending[next_index].priority then
                next_index = i;
            end
        end
        local request = table.remove(shadow_voice_pending, next_index);
        if bv_category_allowed(request.category) and StartShadowVoice(request) then return; end
    end
end

local function play_sound(filename, debug_mode, duck_duration, actor_race)
    if not debug_mode and aggro_transition.phase ~= 'active' then return false; end
    if not filename or not bt_settings.enabled then return false; end
    if not IsVoiceRaceAllowed(filename, actor_race) then return false; end
    if IsTonberryExclusiveActive() then return false; end
    if IsTonberryTPVocal(filename) then return StartTonberryExclusive(filename, debug_mode); end
    local normalized = filename:lower():gsub('\\', '/');
    if not normalized:match('^shadowlord/') then
        return play_sound_unmanaged(filename, debug_mode, duck_duration, actor_race);
    end
    local category = 'skills';
    if normalized:match('/shadow_death%d+%.') then category = 'death';
    elseif normalized:match('/shadow_aggro%d+%.') then category = 'aggro';
    elseif normalized:match('/shadow_attack%d+%.') then category = 'attack';
    elseif normalized:match('/shadow_ouch%d+%.') then category = 'ouch'; end
    if not bv_category_allowed(category) then return false; end
    local priorities = { death=4, aggro=3, skills=2, attack=1, ouch=1 };
    local request = { filename=filename, debug_mode=debug_mode, duck_duration=duck_duration,
                      category=category, priority=priorities[category] };
    local now = os.clock();
    if category == 'death' then
        ClearShadowVoiceQueue();
        return StartShadowVoice(request);
    end
    if request.priority == 1 then
        -- Combat chatter is dropped, never queued behind important dialogue.
        if shadow_voice_active or #shadow_voice_pending > 0
           or now < shadow_voice_ready_at or now < shadow_combat_ready_at then return false; end
        return StartShadowVoice(request);
    end
    if shadow_voice_active and shadow_voice_active.priority == 1 then
        winmm.mciSendStringA('close ' .. shadow_voice_alias, nil, 0, nil);
        shadow_voice_active = nil;
        shadow_voice_ready_at = 0;
    end
    table.insert(shadow_voice_pending, request);
    HandleShadowVoiceQueue();
    return true;
end

ashita.events.register('d3d_present', 'beastvoice_shadow_voice_queue', HandleShadowVoiceQueue);

-- Turning a group off stops only its own channels, not another creature.
StopDisabledRaceVoices = function()
    for index, owner in pairs(sound_pool_races) do
        if not bv_race_allowed(owner.race) or not bv_race_allowed(owner.actor_race)
           or (owner.race == 'Monster' and owner.actor_race == 'Tonberry' and not beast_config.tonberry_tp_enabled[1]) then
            winmm.mciSendStringA('close beast_sfx_' .. index, nil, 0, nil);
            sound_pool_races[index] = nil;
        end
    end
    if not bv_race_allowed('Shadow Lord') and (shadow_voice_active or #shadow_voice_pending > 0) then ClearShadowVoiceQueue(); end
    if (not bv_race_allowed('Tonberry') or not beast_config.tonberry_tp_enabled[1]) and tonberry_exclusive then ClearTonberryExclusive(); end
end;

local function SetVoiceRaceEnabled(race, enabled)
    beast_config.race_enabled[race][1] = enabled;
    bt_settings.race_enabled[race] = enabled;
    StopDisabledRaceVoices();
end

-- Keep stale zone entities and delayed voice requests silent across loading.
local function BeginAggroTransition(phase)
    aggro_transition.phase = phase;
    aggro_transition.identity = nil;
    aggro_transition.stable_since = nil;
    engaged_mobs = {};
    last_aggro_by_race = {};
    ClearShadowVoiceQueue();
    ClearTonberryExclusive();
    for i = 1, MAX_POLYPHONY do
        winmm.mciSendStringA('close beast_sfx_' .. i, nil, 0, nil);
    end
end

local function SuspendAggroUntilReady()
    if aggro_transition.phase == 'active' then BeginAggroTransition('recovering'); end
    aggro_transition.identity = nil;
    aggro_transition.stable_since = nil;
end

-- 6. GUI Rendering
local bv_gui_page = { 0 };  -- 0=General, 1=Voice setup, 2=Rates, 3=Audition

local function bv_select_preset(index)
    beast_config.voice_preset[1] = index;
    bt_settings.voice_preset = index;
    if index == BV_CUSTOM_PRESET then bv_gui_page[1] = 2; end
end

local function bv_help(text)
    imgui.PushStyleColor(ImGuiCol_Text, {0.62, 0.68, 0.76, 1.0});
    imgui.TextWrapped(text);
    imgui.PopStyleColor(1);
end

local function bv_section(label)
    imgui.Spacing();
    imgui.TextColored({0.94, 0.73, 0.43, 1.0}, label);
    imgui.Separator();
end

local function bv_rate_row(label, category)
    local config_ref = beast_config.combat_rates[category];
    local opts = { 'Off - 0%', 'Low - 10%', 'Medium - 30%', 'High - 60%', 'Max - 100%' };
    imgui.SetNextItemWidth(150);
    if (imgui.BeginCombo('##bvr_' .. label, opts[config_ref[1] + 1])) then
        for i = 0, 4 do
            if (imgui.Selectable(opts[i+1], i == config_ref[1])) then
                config_ref[1] = i;
                bt_settings.combat_rates[category] = i;
            end
        end
        imgui.EndCombo();
    end
    imgui.SameLine(); imgui.Text(label);
end

ashita.events.register('d3d_present', 'beastvoice_gui', function ()
    if not beast_config.is_open[1] then return; end
    local mode_names = { 'Silent', 'Ambient', 'Combat', 'Full' };
    local mode_help = {
        'All voice categories are silent.',
        'Death lines only.',
        'Aggro, death, TP moves and spells. Attack and ouch chatter is silent.',
        'All voice categories are available.',
    };
    local preset_names = { 'Muted', 'Occasional', 'Balanced', 'Spammy', 'Custom' };
    local nav_labels = { 'General', 'Voice Setup', 'Rates', 'Audition', 'Creatures' };
    local categories = {
        { 'Aggro', 'aggro' }, { 'Attack', 'attack' }, { 'Ouch', 'ouch' },
        { 'Death', 'death' }, { 'TP Skills', 'skills' },
    };
    local colors = {
        { ImGuiCol_WindowBg, {0.065, 0.080, 0.105, 0.98} },
        { ImGuiCol_ChildBg, {0.090, 0.110, 0.145, 1.0} },
        { ImGuiCol_Border, {0.23, 0.28, 0.35, 0.75} },
        { ImGuiCol_Text, {0.90, 0.93, 0.97, 1.0} },
        { ImGuiCol_TitleBg, {0.10, 0.12, 0.16, 1.0} },
        { ImGuiCol_TitleBgActive, {0.15, 0.19, 0.24, 1.0} },
        { ImGuiCol_FrameBg, {0.13, 0.17, 0.22, 1.0} },
        { ImGuiCol_FrameBgHovered, {0.19, 0.24, 0.31, 1.0} },
        { ImGuiCol_FrameBgActive, {0.23, 0.29, 0.37, 1.0} },
        { ImGuiCol_Button, {0.17, 0.22, 0.29, 1.0} },
        { ImGuiCol_ButtonHovered, {0.26, 0.33, 0.43, 1.0} },
        { ImGuiCol_ButtonActive, {0.33, 0.39, 0.47, 1.0} },
        { ImGuiCol_Header, {0.25, 0.31, 0.40, 1.0} },
        { ImGuiCol_HeaderHovered, {0.32, 0.39, 0.49, 1.0} },
        { ImGuiCol_HeaderActive, {0.39, 0.45, 0.54, 1.0} },
        { ImGuiCol_CheckMark, {0.94, 0.73, 0.43, 1.0} },
        { ImGuiCol_SliderGrab, {0.79, 0.59, 0.32, 1.0} },
        { ImGuiCol_SliderGrabActive, {0.98, 0.79, 0.48, 1.0} },
    };
    for _, color in ipairs(colors) do imgui.PushStyleColor(color[1], color[2]); end
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, {16, 14});
    imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, 7);
    imgui.PushStyleVar(ImGuiStyleVar_ChildRounding, 5);
    imgui.PushStyleVar(ImGuiStyleVar_FrameRounding, 4);
    imgui.PushStyleVar(ImGuiStyleVar_FramePadding, {9, 6});
    imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, {10, 9});
    imgui.SetNextWindowSizeConstraints({620, 460}, {1200, 1000});
    imgui.SetNextWindowSize({700, 560}, ImGuiCond_FirstUseEver);
    if imgui.Begin('BeastVoice', beast_config.is_open, 0) then
        imgui.TextColored({0.94, 0.73, 0.43, 1.0}, 'BEASTVOICE');
        imgui.SameLine();
        imgui.Text('Voice control');
        bv_help('Choose what speaks, how often, and which recordings to audition.');
        imgui.Separator();

        local available_w, available_h = imgui.GetContentRegionAvail();
        local body_h = math.max(160, available_h - 76);
        local nav_w = 156;
        imgui.BeginChild('##bv_navigation', {nav_w, body_h}, ImGuiChildFlags_Borders);
        local status_color = beast_config.enabled[1] and {0.40, 0.82, 0.63, 1.0} or {0.88, 0.52, 0.43, 1.0};
        imgui.TextColored(status_color, beast_config.enabled[1] and 'ACTIVE' or 'PAUSED');
        bv_help(mode_names[beast_config.voice_mode[1] + 1] .. '\n' .. preset_names[beast_config.voice_preset[1] + 1]);
        imgui.Spacing();
        for i, label in ipairs(nav_labels) do
            local active = bv_gui_page[1] == i - 1;
            if active then
                imgui.PushStyleColor(ImGuiCol_Button, {0.38, 0.29, 0.18, 1.0});
                imgui.PushStyleColor(ImGuiCol_Text, {1.0, 0.82, 0.55, 1.0});
            end
            if imgui.Button(label, {-1, 34}) then bv_gui_page[1] = i - 1; end
            if active then imgui.PopStyleColor(2); end
        end
        imgui.Spacing(); imgui.Separator();
        if imgui.Checkbox('Enabled', beast_config.enabled) then bt_settings.enabled = beast_config.enabled[1]; end
        imgui.EndChild();
        imgui.SameLine();

        imgui.BeginChild('##bv_content', {0, body_h}, ImGuiChildFlags_Borders);
        local content_w = imgui.GetContentRegionAvail();
        imgui.PushItemWidth(-1);
        if bv_gui_page[1] == 0 then
            bv_section('Playback');
            imgui.Text(string.format('Volume - %d%%', beast_config.volume[1]));
            imgui.SetNextItemWidth(-1);
            if imgui.SliderInt('##bvvol', beast_config.volume, 0, 100) then bt_settings.volume = beast_config.volume[1] * 10; end
            bv_help('Adjust voice volume independently of your rate settings.');
            bv_section('Chat recognition');
            imgui.SetNextItemWidth(-1);
            if imgui.BeginCombo('##bvparser', parser_mode_label(beast_config.simplelog_mode[1] or PARSER_AUTO)) then
                for _, option in ipairs({ {'Auto (per-message)', PARSER_AUTO}, {'SimpleLog', PARSER_SIMPLELOG}, {'Traditional', PARSER_TRADITIONAL} }) do
                    if imgui.Selectable(option[1], beast_config.simplelog_mode[1] == option[2]) then
                        beast_config.simplelog_mode[1] = option[2]; bt_settings.simplelog_mode = option[2];
                    end
                end
                imgui.EndCombo();
            end
            bv_help('Auto recognizes each chat line by its format. Use a forced parser only when needed.');
            local parser_now = beast_config.simplelog_mode[1] or PARSER_AUTO;
            if parser_now == PARSER_SIMPLELOG and not sl_addon_loaded then
                bv_help('SimpleLog is selected, but a matching chat addon was not detected.');
            elseif parser_now == PARSER_TRADITIONAL and sl_addon_loaded then
                bv_help('Traditional is selected while a SimpleLog-style addon is loaded.');
            end
            bv_section('Monster announcements');
            if imgui.Checkbox('Monster TP Moves', beast_config.monster_tp_enabled) then bt_settings.monster_tp_enabled = beast_config.monster_tp_enabled[1]; end
            bv_help('Enable the separate monster move announcements. Their existing cooldown rules still apply.');
        elseif bv_gui_page[1] == 1 then
            bv_section('Voice mode');
            imgui.SetNextItemWidth(-1);
            if imgui.BeginCombo('##bvmode', mode_names[beast_config.voice_mode[1] + 1]) then
                for i = 0, 3 do
                    if imgui.Selectable(mode_names[i+1], beast_config.voice_mode[1] == i) then beast_config.voice_mode[1] = i; bt_settings.voice_mode = i; end
                end
                imgui.EndCombo();
            end
            bv_help(mode_help[beast_config.voice_mode[1] + 1]);
            bv_section('Rate source');
            imgui.SetNextItemWidth(-1);
            if imgui.BeginCombo('##bvpreset', preset_names[beast_config.voice_preset[1] + 1]) then
                for i = 0, 4 do
                    if imgui.Selectable(preset_names[i+1], beast_config.voice_preset[1] == i) then bv_select_preset(i); end
                end
                imgui.EndCombo();
            end
            if beast_config.voice_preset[1] == BV_CUSTOM_PRESET then
                bv_help('Custom uses only your category dropdowns. No preset multiplier is applied.');
                if imgui.Button('Edit Custom Rates', {-1, 32}) then bv_gui_page[1] = 2; end
            else
                bv_help('This preset uses its own fixed rates. Your saved custom values do not change them.');
                if imgui.Button('View Preset Rates', {-1, 32}) then bv_gui_page[1] = 2; end
            end
        elseif bv_gui_page[1] == 2 then
            local custom = beast_config.voice_preset[1] == BV_CUSTOM_PRESET;
            bv_section(custom and 'Custom rates' or (preset_names[beast_config.voice_preset[1] + 1] .. ' rates'));
            if custom then
                bv_help('Each dropdown is the direct chance for its category. Voice mode and cooldowns still apply.');
                imgui.Spacing();
                for _, category in ipairs(categories) do bv_rate_row(category[1], category[2]); end
            else
                bv_help('Fixed preset values. Custom dropdowns are inactive until you select Custom.');
                imgui.Spacing();
                for _, category in ipairs(categories) do
                    imgui.Text(category[1]); imgui.SameLine(160);
                    imgui.TextColored({0.94, 0.73, 0.43, 1.0}, string.format('%d%%', get_combat_rate(category[2])));
                end
                imgui.Spacing();
                if imgui.Button('Use Custom Rates', {-1, 32}) then bv_select_preset(BV_CUSTOM_PRESET); end
            end
        elseif bv_gui_page[1] == 3 then
            bv_section('Audition recordings');
            bv_help('Pick a creature, then play a category or a specific move. Missing files are skipped.');
            imgui.SetNextItemWidth(-1);
            if imgui.BeginCombo('##bvtrace', race_list[beast_config.race_index[1] + 1]) then
                for i = 0, #race_list - 1 do
                    if imgui.Selectable(race_list[i+1], beast_config.race_index[1] == i) then beast_config.race_index[1] = i; end
                end
                imgui.EndCombo();
            end
            local current = race_list[beast_config.race_index[1] + 1];
            local data = beast_data[current];
            bv_section(current .. ' - Combat');
            local button_w = math.max(100, (content_w - 10) / 2);
            for i, category in ipairs({ {'Aggro','aggro'}, {'Attack','attack'}, {'Ouch','ouch'}, {'Death','death'} }) do
                if data and data[category[2]] then
                    if imgui.Button(category[1], {button_w, 32}) then play_sound(get_next_sound(current, category[2]), true); end
                    if i % 2 == 1 then imgui.SameLine(); end
                end
            end
            if data and data.skills then
                bv_section('Moves and spells');
                local keys = {};
                for key in pairs(data.skills) do table.insert(keys, key); end
                table.sort(keys);
                for _, key in ipairs(keys) do
                    if imgui.Button(key .. '##bvsk', {-1, 30}) then
                        local resolved = resolve_skill_sound(data.skills[key], current, key);
                        if resolved then play_sound(resolved, true); end
                    end
                end
            end
        elseif bv_gui_page[1] == 4 then
            bv_section('Creature voices');
            bv_help("Choose which groups can speak. OFF applies to every voice category and stops that group's current or waiting lines.");
            local button_w = math.max(100, (content_w - 10) / 2);
            if imgui.Button('All On', {button_w, 30}) then
                for _, race in ipairs(voice_race_names) do SetVoiceRaceEnabled(race, true); end
            end
            imgui.SameLine();
            if imgui.Button('All Off', {button_w, 30}) then
                for _, race in ipairs(voice_race_names) do SetVoiceRaceEnabled(race, false); end
            end
            imgui.Spacing();
            for _, race in ipairs(voice_race_names) do
                local label = race == 'Monster' and 'Other Monsters' or race;
                local toggle = beast_config.race_enabled[race];
                if imgui.Checkbox(label .. '##bvrace_' .. race, toggle) then SetVoiceRaceEnabled(race, toggle[1]); end
                imgui.SameLine();
                imgui.TextColored(toggle[1] and {0.40,0.82,0.63,1.0} or {0.62,0.68,0.76,1.0}, toggle[1] and 'ON' or 'OFF');
                if race == 'Tonberry' then
                    if imgui.Checkbox('Tonberry TP Songs##bv_tonberry_tp', beast_config.tonberry_tp_enabled) then
                        bt_settings.tonberry_tp_enabled = beast_config.tonberry_tp_enabled[1];
                        StopDisabledRaceVoices();
                    end
                    bv_help('TP vocals only. Aggro, attack, ouch and death lines keep their own settings.');
                end
            end
            bv_help('Other Monsters also requires Monster TP Moves under General. Save Settings keeps these choices.');
        end
        imgui.PopItemWidth();
        imgui.EndChild();
        imgui.Spacing();
        if imgui.Button('Save Settings', {156, 32}) then save_settings(); end
        imgui.SameLine();
        if imgui.Button('Close', {90, 32}) then beast_config.is_open[1] = false; end
        bv_help('Changes apply immediately. Save keeps them for your next session.');
    end
    imgui.End();
    imgui.PopStyleVar(6);
    imgui.PopStyleColor(#colors);
end);

-- 7. Slash Command
ashita.events.register('command', 'beast_command', function (e)
    local args = e.command:args();
    if (#args == 0) then return; end

    -- Accept both /beastvoice and /bv
    if (args[1] ~= '/beastvoice' and args[1] ~= '/bv') then return; end
    e.blocked = true;

    local sub = args[2] and string.lower(args[2]) or '';

    -- No sub-command: toggle GUI
    if (sub == '') then
        beast_config.is_open[1] = not beast_config.is_open[1];
        return;
    end

    -- /bv enable | /bv disable
    if (sub == 'enable') then
        bt_settings.enabled = true;
        beast_config.enabled[1] = true;
        print(chat.header('BeastVoice'):append(chat.success('Enabled.')));
        return;
    end
    if (sub == 'disable') then
        bt_settings.enabled = false;
        beast_config.enabled[1] = false;
        print(chat.header('BeastVoice'):append(chat.message('Disabled.')));
        return;
    end

    -- /bv mode → cycle Auto → SimpleLog → Traditional
    if (sub == 'mode') then
        beast_config.simplelog_mode[1] = ((beast_config.simplelog_mode[1] or PARSER_AUTO) + 1) % 3;
        bt_settings.simplelog_mode = beast_config.simplelog_mode[1];
        sl_addon_loaded = simplelog_addon_detected();
        local det_txt = '';
        if (beast_config.simplelog_mode[1] ~= PARSER_AUTO) then
            local mismatched = (beast_config.simplelog_mode[1] == PARSER_SIMPLELOG and not sl_addon_loaded)
                            or (beast_config.simplelog_mode[1] == PARSER_TRADITIONAL and sl_addon_loaded);
            if mismatched then det_txt = ' (WARNING: mismatches loaded chat log)'; end
        end
        print(chat.header('BeastVoice'):append(chat.message('Parser → ' .. parser_mode_label(beast_config.simplelog_mode[1]) .. det_txt)));
        pcall(save_settings);
        return;
    end

    -- /bv volume [0-100]
    if (sub == 'volume') then
        local val = tonumber(args[3]);
        if (val and val >= 0 and val <= 100) then
            beast_config.volume[1] = val;
            bt_settings.volume = val * 10;
            print(chat.header('BeastVoice'):append(chat.message('Volume set to ' .. val .. '%')));
        else
            print(chat.header('BeastVoice'):append(chat.message('Usage: /bv volume [0-100]')));
        end
        return;
    end

    -- /bv aggro → toggle aggro debug
    if (sub == 'aggro') then
        DEBUG_AGGRO = not DEBUG_AGGRO;
        local status = DEBUG_AGGRO and 'ON' or 'OFF';
        print(chat.header('BeastVoice'):append(chat.message('Aggro debug: ' .. status)));
        return;
    end

    -- /bv info → current state
    if (sub == 'info') then
        local enabled_str = bt_settings.enabled and 'Enabled' or 'Disabled';
        local mode_str    = parser_mode_label(beast_config.simplelog_mode[1] or PARSER_AUTO);
        local vol_str     = tostring(beast_config.volume[1]) .. '%';
        local engaged_count = 0;
        for _ in pairs(engaged_mobs) do engaged_count = engaged_count + 1; end
        print(chat.header('BeastVoice'):append(chat.message(
            string.format('[ %s | Parser: %s | Vol: %s | Engaged mobs: %d ]',
                enabled_str, mode_str, vol_str, engaged_count))));
        return;
    end

    -- /bv help or unknown
    print(chat.header('BeastVoice'):append(chat.message('Commands:')));
    print(chat.header('BeastVoice'):append(chat.message('  /bv             → Toggle settings menu')));
    print(chat.header('BeastVoice'):append(chat.message('  /bv enable      → Enable addon')));
    print(chat.header('BeastVoice'):append(chat.message('  /bv disable     → Disable addon')));
    print(chat.header('BeastVoice'):append(chat.message('  /bv mode        → Cycle Auto / SimpleLog / Traditional parser')));
    print(chat.header('BeastVoice'):append(chat.message('  /bv volume [n]  → Set volume 0-100')));
    print(chat.header('BeastVoice'):append(chat.message('  /bv info        → Show current state')));
    print(chat.header('BeastVoice'):append(chat.message('  /bv aggro       → Toggle aggro debug mode')));
    print(chat.header('BeastVoice'):append(chat.message('  /bv help        → This list')));
end);

-- 8. AGGRO DETECTION via Entity Scanning
-- Scans nearby entities for beastmen in combat targeting the player or party
ashita.events.register('d3d_present', 'beastvoice_aggro_scan', function()
    if (not bt_settings.enabled) then return; end
    if aggro_transition.phase == 'departing' then return; end

    -- Throttle checks
    local now = os.clock();
    if (now - last_check < CHECK_INTERVAL) then return; end
    last_check = now;

    local entity = AshitaCore:GetMemoryManager():GetEntity();
    local party = AshitaCore:GetMemoryManager():GetParty();
    if not entity or not party then SuspendAggroUntilReady(); return; end

    local player_index = party:GetMemberTargetIndex(0);
    local player_id = party:GetMemberServerId(0);
    local player_zone = party:GetMemberZone(0);
    if not player_index or player_index <= 0 or not player_id or player_id <= 0
       or not player_zone or player_zone <= 0
       or entity:GetServerId(player_index) ~= player_id then
        SuspendAggroUntilReady();
        return;
    end
    local player_x = entity:GetLocalPositionX(player_index);
    local player_z = entity:GetLocalPositionZ(player_index);
    if not player_x or not player_z or player_x ~= player_x or player_z ~= player_z
       or math.abs(player_x) == math.huge or math.abs(player_z) == math.huge then
        SuspendAggroUntilReady();
        return;
    end
    local identity = string.format('%d:%d:%d', player_zone, player_id, player_index);
    if aggro_transition.phase == 'active' and aggro_transition.identity
       and aggro_transition.identity ~= identity then
        BeginAggroTransition('recovering');
    end
    local seed_aggro_only = false;
    if aggro_transition.phase ~= 'active' then
        if aggro_transition.identity ~= identity then
            aggro_transition.identity = identity;
            aggro_transition.stable_since = now;
            return;
        end
        if now - aggro_transition.stable_since < AGGRO_ARRIVAL_STABLE_TIME then return; end
        aggro_transition.phase = 'active';
        seed_aggro_only = true;
    end
    aggro_transition.identity = identity;

    -- Build list of valid party member target indices
    local party_indices = {};
    for i = 0, 5 do
        local member_index = party:GetMemberTargetIndex(i);
        if (member_index > 0) then
            party_indices[member_index] = true;
        end
    end

    if (DEBUG_AGGRO) then
        if (math.floor(now) % 5 == 0 and math.floor(now) ~= (last_debug_heartbeat or 0)) then
            last_debug_heartbeat = math.floor(now);
            print(chat.header('BeastVoice'):append(chat.message('Aggro scanner running... Player at ' .. math.floor(player_x) .. ', ' .. math.floor(player_z))));
        end
    end

    -- Scan nearby entities
    for i = 1, 1023 do
        local spawn_flags = entity:GetSpawnFlags(i);

        -- Check if entity exists and is a mob (spawn flag 0x10 = NPC/Mob type)
        if (spawn_flags and bit.band(spawn_flags, 0x10) ~= 0) then
            local status = entity:GetStatus(i);

            -- Status 1 = engaged/fighting
            if (status == 1) then
                -- Check distance to player (aggro range ~ 50 units)
                local mob_x = entity:GetLocalPositionX(i);
                local mob_z = entity:GetLocalPositionZ(i);
                local dx = player_x - mob_x;
                local dz = player_z - mob_z;
                local distance = math.sqrt(dx * dx + dz * dz);

                if distance <= 50 or seed_aggro_only then
                    -- Check if mob is targeting US or a party member
                    local mob_target = entity:GetTargetIndex(i);
                    local is_targeting_party = (mob_target and mob_target > 0 and party_indices[mob_target]);

                    -- Also check claim status - if we claimed it, it's ours
                    -- MUST check claim_id > 0 first! Otherwise 0 == 0 returns true
                    local claim_id = entity:GetClaimStatus(i);
                    local player_server_id = party:GetMemberServerId(0);
                    local is_our_claim = false;
                    local is_someone_elses_claim = false;

                    if (claim_id and claim_id > 0) then
                        -- Check if player claimed it
                        if (player_server_id and claim_id == player_server_id) then
                            is_our_claim = true;
                        else
                            -- Check if any party member claimed it
                            local found_party = false;
                            for pi = 1, 5 do  -- Start at 1, we already checked 0
                                local member_id = party:GetMemberServerId(pi);
                                if (member_id and member_id > 0 and member_id == claim_id) then
                                    is_our_claim = true;
                                    found_party = true;
                                    break;
                                end
                            end
                            -- If claimed but not by us or party, it's someone else's
                            if (not found_party) then
                                is_someone_elses_claim = true;
                            end
                        end
                    end

                    -- AGGRO LOGIC:
                    -- 1. If targeting us or we claimed it = definitely ours
                    -- 2. If UNCLAIMED and very close (< 20 units) = probably just aggro'd us
                    -- 3. If claimed by someone ELSE = not ours, skip
                    local is_our_fight = false;
                    local aggro_reason = "";

                    if (is_targeting_party) then
                        is_our_fight = true;
                        aggro_reason = "targeting";
                    elseif (is_our_claim) then
                        is_our_fight = true;
                        aggro_reason = "claimed";
                    elseif (not is_someone_elses_claim and distance <= 10) then
                        -- Unclaimed mob VERY close = fresh aggro on us
                        is_our_fight = true;
                        aggro_reason = "close+unclaimed";
                    end

                    if (is_our_fight) then
                        if (not engaged_mobs[i]) then
                            local mob_name = entity:GetName(i);
                            local race = get_beastman_race(mob_name);

                            if (race) then
                                -- NEW AGGRO! Store the race for filtering
                                engaged_mobs[i] = race;

                                if (DEBUG_AGGRO) then
                                    print(chat.header('BeastVoice'):append(chat.success(string.format('AGGRO DETECTED: %s (%s) - Reason: %s, Dist: %.0f',
                                        mob_name, race, aggro_reason, distance))));
                                end

                                if not seed_aggro_only and should_play_combat('aggro', race) then
                                    local now_aggro = os.clock();
                                    if (now_aggro - (last_aggro_by_race[race] or 0) >= AGGRO_RACE_COOLDOWN) then
                                        last_aggro_by_race[race] = now_aggro;
                                        local aggro_sound = get_next_sound(race, 'aggro');
                                        if (aggro_sound) then
                                            play_sound(aggro_sound, false, DUCK_AGGRO);
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            -- FIX IS HERE: Check for Status 2 (Dead).
            -- If dead, do NOT clear from engaged_mobs yet, so text_in can catch the death message.
            elseif (status == 2) then
                -- Mob is dead (corpse visible), keep in list for now.
                -- Do nothing.
            else
                -- Mob is not fighting (1) and not dead (2). Likely Idle (0).
                -- Clear it.
                if (engaged_mobs[i]) then
                    if (DEBUG_AGGRO) then
                        print(chat.header('BeastVoice'):append(chat.message(string.format('Mob [%d] left combat/reset, clearing', i))));
                    end
                    engaged_mobs[i] = nil;
                end
            end
        else
             -- Entity is no longer a mob (or despawned/index reused)
             if (engaged_mobs[i]) then
                 engaged_mobs[i] = nil;
             end
        end
    end
end);

-- ============================================
-- SIMPLELOG COMPATIBILITY FUNCTIONS
-- ============================================

-- Extract enemy name from SimpleLog message
local function sl_extract_enemy_name(text)
    local name = text:match("^%[([^%]]+)%]");  -- [The Orc], [Antican], etc.
    if name then return name; end
    return nil;
end

-- Normalize a SimpleLog action/ability string: chat-log addons differ on whether
-- they keep the leading verb ("readies Bomb Toss" vs "Bomb Toss", "uses X" vs
-- "X"). The skill tables are keyed by the bare ability name, so strip any
-- leading readies/uses/casts verb before lookups.
local function sl_strip_leading_verb(action)
    if (not action) then return nil; end
    action = action:gsub("^%s*[Rr]eadies%s+", "");
    action = action:gsub("^%s*[Uu]ses%s+", "");
    action = action:gsub("^%s*[Cc]asts%s+", "");
    return action;
end

-- Check if extracted name contains a beast race
local function sl_get_beast_race(name)
    if not name then return nil; end

    -- CRITICAL: Handle possessive names like "Goblin's Spider"
    -- The actual race is AFTER the apostrophe-s, not before!
    -- "Goblin's Spider" = Spider (owned by Goblin)
    -- "Orc's Wyvern" = Wyvern (owned by Orc)
    local possessive_race = name:match("'s%s+(.+)");
    if possessive_race then
        -- Use what comes AFTER the 's (the actual creature type)
        name = possessive_race;
    end

    -- Check each race in beast_data
    -- Try to find the LONGEST match first (more specific = better)
    local best_match = nil;
    local best_match_data = nil;
    local best_match_length = 0;

    for race_name, data in pairs(beast_data) do
        if string.find(name, race_name) then
            -- Found a match - but is it longer/more specific than previous?
            if #race_name > best_match_length then
                best_match = race_name;
                best_match_data = data;
                best_match_length = #race_name;
            end
        end
    end

    if not best_match then
        local race = get_beastman_race(name);
        if race then return race, beast_data[race]; end
    end
    return best_match, best_match_data;
end

-- Extract action/ability from SimpleLog message
local function sl_extract_beast_action(text)
    -- Remove the actor name part (with brackets)
    local without_actor = text:gsub("^%[[^%]]+%]%s*", "");

    -- Remove damage numbers if present
    without_actor = without_actor:gsub("^%d+%s+", "");

    -- Extract action - try multiple methods
    local action;

    -- Method 1: Stop at any arrow-like character
    for _, delimiter in ipairs({"→", "⇒", "►", "➜", "➔", "%-%->"}) do
        local pos = without_actor:find(delimiter, 1, true);
        if pos then
            action = without_actor:sub(1, pos - 1);
            action = action:gsub("%s+$", "");  -- Trim
            return action;
        end
    end

    -- Method 2: Look for MULTIPLE SPACES
    action = without_actor:match("^(.-)%s%s+");
    if action and action ~= "" then
        return action;
    end

    -- Method 3: Stop before capital letter ONLY if it looks like a player name
    -- Common ability words that should NOT be stripped
    local ability_words = {
        "Rush", "Slash", "Strike", "Attack", "Punch", "Kick", "Toss", "Dance",
        "Cloud", "Wave", "Ball", "Shot", "Fin", "Armor", "Thrust", "Song",
        "Howl", "Dunk", "Slam", "Charge", "Spin", "Shield", "Trap", "Veil",
        "Requiem", "Threnody", "Elegy", "Paeon", "Ballad", "Minuet", "Madrigal",
        "II", "III", "IV", "V"
    };

    local words = {};
    for word in without_actor:gmatch("%S+") do
        table.insert(words, word);
    end

    if #words > 1 then
        local last_word = words[#words];
        -- Only strip if it starts with capital AND is NOT a common ability word
        if last_word:match("^[A-Z]") then
            local is_ability_word = false;
            for _, aw in ipairs(ability_words) do
                if last_word == aw then
                    is_ability_word = true;
                    break;
                end
            end
            if not is_ability_word then
                table.remove(words, #words);
                action = table.concat(words, " ");
                return action;
            end
        end
    end

    -- Method 4: Take everything
    action = without_actor:gsub("%s+$", "");
    return action;
end

-- Main SimpleLog parser for beast actions
local function parse_simplelog_beast(message)
    if not message or message == "" then return nil; end

    -- Check for bracket format (SimpleLog marker)
    if not message:match("^%[") then
        return nil;  -- Not SimpleLog format
    end

    -- Extract enemy name
    local enemy_name = sl_extract_enemy_name(message);
    if not enemy_name then return nil; end

    -- Check if it's a beast race
    local race_name, race_data = sl_get_beast_race(enemy_name);
    if not race_name then return nil; end  -- Not a tracked beast

    -- Extract action (normalized: leading readies/uses/casts verb stripped so
    -- "[Enemy] readies Battle Dance → X" matches the 'Battle Dance' skill key)
    local action = sl_strip_leading_verb(sl_extract_beast_action(message));
    if not action or action == "" then return nil; end

    -- Check for damage number (indicates player hitting enemy)
    local has_damage = message:match("%]%s+%d+%s+");

    return {
        enemy_name = enemy_name,
        race_name = race_name,
        race_data = race_data,
        action = action,
        has_damage = has_damage,
        raw = message
    };
end

-- Completed TP messages must not replay vocals started by their readies line.
local function IsCompletedTPMessage(text)
    local lower = text:lower();
    return lower:match('^%[[^%]]+%]%s*uses%s+') ~= nil
        or lower:match('^.-%s+uses%s+') ~= nil;
end

-- Tonberry TP vocals use first-wins exclusivity, independent of TP rate rolls.
local function HandleTonberryTP(text)
    local parsed = parse_simplelog_beast(text);
    local enemy, action;
    if parsed and parsed.race_name == 'Tonberry' then
        if IsCompletedTPMessage(text) then return true; end
        enemy, action = parsed.enemy_name, parsed.action;
    else
        enemy, action = text:match('^(.-)%s+readies%s+(.+)$');
        if not enemy or get_beastman_race(enemy) ~= 'Tonberry' then return false; end
    end
    action = action:gsub('%s+on%s+.+$', ''):gsub(',.*$', ''):gsub('[%.!]+$', ''):gsub('%s+$', '');
    local entry = beast_data.Tonberry.skills[action];
    if not entry then return false; end
    if not bv_race_allowed('Tonberry') or not beast_config.tonberry_tp_enabled[1] then return true; end
    if not bt_settings.enabled or not bv_category_allowed('skills') then return true; end
    local key = enemy:lower():gsub('[^%w]', '') .. '_' .. action:lower():gsub('[^%w]', '');
    local now = os.clock();
    if now - (monster_ability_blocker[key] or -math.huge) < 3 then return true; end
    local resolved = resolve_skill_sound(entry, 'Tonberry', action);
    if resolved and play_sound(resolved, false, DUCK_SKILL) then monster_ability_blocker[key] = now; end
    return true;
end

-- Implosion can complete without a readies line. Match its text before parser
-- routing so message color and forced parser mode cannot hide a use event.
local last_implosion_use_time = -math.huge;
local function HandleShadowLordImplosion(text)
    local lower = text:lower();
    local action = lower:match('^the shadow lord%s+(.+)$')
                or lower:match('^shadow lord%s+(.+)$')
                or lower:match('^%[the shadow lord%]%s+(.+)$')
                or lower:match('^%[shadow lord%]%s+(.+)$');
    if not action then return false; end
    local verb, ability = action:match('^(%a+)%s+(.+)$');
    if verb ~= 'uses' and verb ~= 'readies' then
        -- Some bracket logs omit the verb on completed actions.
        if lower:sub(1, 1) ~= '[' then return false; end
        ability = action;
        verb = 'uses';
    end
    if ability ~= 'implosion' and not ability:match('^implosion[%s%.!]') then
        return false;
    end
    -- Suppress preparation here; only the completed use advances the cycle.
    if verb == 'readies' then return true; end
    if not bv_race_allowed('Shadow Lord') then return true; end
    if not bt_settings.enabled or not bv_category_allowed('skills') then return true; end
    local now = os.clock();
    -- Match the existing short chat-echo window, without the TP rate/cooldown.
    if now - last_implosion_use_time < 0.5 then return true; end
    local resolved = resolve_skill_sound(beast_data['Shadow Lord'].skills.Implosion, 'Shadow Lord', 'Implosion');
    if resolved then
        last_implosion_use_time = now;
        play_sound(resolved, false, DUCK_SKILL);
    end
    return true;
end

-- 9. The Main Text Listener
ashita.events.register('text_in', 'text_in_beast', function (e)
    -- Skip chatlog backlog replay on addon load
    if (os.clock() - addon_load_time) < 3.0 then return false; end
    if aggro_transition.phase ~= 'active' then return false; end
    if IsTonberryExclusiveActive() then return false; end

    local text = e.message;
    local clean_text = string.gsub(text, '[\x1F\x1E].', '');  -- Strip color codes
    clean_text = string.gsub(clean_text, '%s+$', '');  -- Trim trailing whitespace/newlines

    -- Skip our own addon messages (prevents self-triggering on debug output)
    if string.find(clean_text, "%[BeastVoice%]") then
        return false;
    end

    -- === DUPLICATE MESSAGE FILTER (catches chatlog duplicates) ===
    -- FFXI commonly sends identical messages 150-300ms apart
    local now = os.clock();
    if (last_message == clean_text and (now - last_message_time) < 0.5) then
        return false;  -- Exact duplicate within 500ms, ignore
    end
    last_message = clean_text;
    last_message_time = now;

    -- Implosion is the intentional completion-only exception.
    if HandleShadowLordImplosion(clean_text) then return false; end
    if IsCompletedTPMessage(clean_text) then return false; end
    if HandleTonberryTP(clean_text) then return false; end

    -- Parser routing: forced mode wins; Auto picks per-message by format so the
    -- parser always matches the chat addon that actually produced the line.
    -- (Auto eliminates double-fire/silence when a SimpleLog-style addon is
    -- loaded while the parser toggle was left on the other setting.)
    local parser_mode = beast_config.simplelog_mode[1] or PARSER_AUTO;
    local use_simplelog;
    if (parser_mode == PARSER_SIMPLELOG) then
        use_simplelog = true;
    elseif (parser_mode == PARSER_TRADITIONAL) then
        use_simplelog = false;
    else
        use_simplelog = message_is_simplelog(clean_text);
    end

    -- Get Party Manager
    local party = AshitaCore:GetMemoryManager():GetParty();

    -- === SIMPLELOG FORMAT DETECTION (forced SimpleLog, or Auto + bracket line) ===
    if use_simplelog then
    -- Try SimpleLog arrow format first: [Enemy] Action → Target
    local parsed = parse_simplelog_beast(clean_text);

    -- DEBUG: Show what SimpleLOG parsed
    if (DEBUG_AGGRO and clean_text:match("^%[")) then
        if parsed then
            print(chat.header('BeastVoice'):append(chat.message('SIMPLELOG PARSED: enemy="' .. tostring(parsed.enemy_name) .. '" race="' .. tostring(parsed.race_name) .. '" action="' .. tostring(parsed.action) .. '"')));
        else
            print(chat.header('BeastVoice'):append(chat.warning('SIMPLELOG: No parse result for bracket message')));
        end
    end

    if parsed then
        -- Check if this is a TP move (skill)
        local skill_file = lookup_beast_skill(parsed.race_name, parsed.action);

        -- DEBUG: Log all skill lookups when debug mode is on
        if (DEBUG_AGGRO and parsed.action) then
            local found = skill_file and "FOUND" or "NOT FOUND";
            print(chat.header('BeastVoice'):append(chat.message('SKILL LOOKUP: "' .. parsed.action .. '" -> ' .. found)));
            if skill_file then
                print(chat.header('BeastVoice'):append(chat.message('  File: ' .. skill_file)));
            else
                -- Show what skills ARE available for this race
                local available = {};
                if parsed.race_data.skills then
                    for k, v in pairs(parsed.race_data.skills) do
                        table.insert(available, '"' .. k .. '"');
                    end
                end
                print(chat.header('BeastVoice'):append(chat.warning('  Available: ' .. table.concat(available, ", "))));
            end
        end

        if skill_file then
            -- Spam blocker: SimpleLog + traditional both fire for same TP move
            -- Use cleaned names so both paths produce the same key
            local clean_enemy = string.lower(parsed.enemy_name):gsub("[^%w]", "");
            local clean_action = string.lower(parsed.action):gsub("[^%w]", "");
            local spam_key = clean_enemy .. "_" .. clean_action;
            local now = os.clock();

            if (now - (monster_ability_blocker[spam_key] or 0)) < 3.0 then
                return false;  -- Block duplicate
            end

            monster_ability_blocker[spam_key] = now;

            -- Play the specific skill sound (with rate check)
            if (should_play_combat('skills', parsed.race_name)) then
                local resolved = resolve_skill_sound(skill_file, parsed.race_name, parsed.action);
                if resolved then
                    play_sound(resolved, false, DUCK_SKILL);
                end
            end
            return false;
        end

        -- Check if action is "Attack" or looks like a regular attack
        local action_lower = string.lower(parsed.action);
        if action_lower == "attack" or action_lower == "hit" or action_lower == "kick" or action_lower == "punch" then
            if parsed.has_damage then
                -- Has damage number = player hitting enemy = enemy ouch
                if should_play_combat('ouch', parsed.race_name) then
                    play_sound(get_next_sound(parsed.race_name, 'ouch'), false, DUCK_COMBAT);
                end
            else
                -- No damage = enemy attacking = enemy attack
                if should_play_combat('attack', parsed.race_name) then
                    play_sound(get_next_sound(parsed.race_name, 'attack'), false, DUCK_COMBAT);
                end
            end
            return false;
        end
    end

    -- Also check if player is hitting an enemy (bracket has player name, target has enemy)
    -- Format: [PlayerName] 155 Attack → The Orc
    if clean_text:match("^%[%w+%]") and clean_text:match("%d+") then
        -- Extract target part (after arrow)
        local target = clean_text:match("→%s*(.+)") or clean_text:match("⇒%s*(.+)") or clean_text:match("►%s*(.+)");
        if target then
            -- Check if target contains a beast race
            local race_name, race_data = sl_get_beast_race(target);
            if race_name and should_play_combat('ouch', race_name) then
                play_sound(get_next_sound(race_name, 'ouch'), false, DUCK_COMBAT);
                return false;
            end
        end
    end

    -- Check for death messages in SimpleLog format
    -- Format: [PlayerName] defeats [The Orc] or similar
    if clean_text:match("defeats") or clean_text:match("falls to the ground") then
        -- Extract what was defeated
        local defeated = clean_text:match("defeats%s+%[?([^%]]+)%]?") or clean_text:match("([^%s]+)%s+falls to the ground");
        if defeated then
            local race_name, race_data = sl_get_beast_race(defeated);
            if race_name then
                -- Verify it was a party member who killed it
                local party_killed = false;
                if party then
                    for i = 0, 5 do
                        local member_name = party:GetMemberName(i);
                        if member_name and member_name ~= "" and string.find(clean_text, member_name, 1, true) then
                            party_killed = true;
                            break;
                        end
                    end
                end
                if party_killed then
                    play_sound(get_next_sound(race_name, 'death'), false, DUCK_DEATH);
                    return false;
                end
            end
        end
    end

    end -- if use_simplelog (SimpleLog beast detection)

    -- Helper: Check if any party member name is in the message
    local function is_party_involved()
        if not party then return false; end
        for i = 0, 5 do
            local member_name = party:GetMemberName(i);
            if member_name and member_name ~= "" then
                if string.find(clean_text, member_name, 1, true) then
                    return true;
                end
            end
        end
        return false;
    end

    -- GENERIC MONSTER TP MOVE DETECTION
    -- Handles BOTH SimpleLog format ([Enemy] Ability) and Traditional format (Enemy readies Ability)
    -- Only play if party member is involved (being targeted or nearby combat).
    -- Honors the master gates: these do NOT flow through should_play_combat(),
    -- so without this check Voice Mode 'Silent' and Preset 'Muted' would still
    -- let generic monster TPs through. Rate (skills) is intentionally NOT
    -- applied — this path is opt-in via the 'Monster TP Moves' toggle and is
    -- meant to announce every telegraphed monster move within cooldown limits.
    if (bt_settings.monster_tp_enabled ~= false)
       and (beast_config.voice_mode[1] ~= 0)
       and (beast_config.voice_preset[1] ~= 0) and bv_race_allowed('Monster') then
        local ability_name = nil;
        local enemy_name = nil;  -- MOVED OUTSIDE - must be in scope for spam key!

        -- Try SimpleLog format first: [Enemy] Ability → Target
        if use_simplelog and clean_text:match("^%[") then
            enemy_name = clean_text:match("^%[([^%]]+)%]");  -- Extract enemy name
            if enemy_name then
                local without_actor = clean_text:gsub("^%[" .. enemy_name:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1") .. "%]%s*", "");
                without_actor = without_actor:gsub("^%d+%s+", "");  -- Remove damage

                -- Extract action (stop at arrow or multiple spaces)
                for _, delimiter in ipairs({"→", "⇒", "►", "➜", "➔", "%-%->"}) do
                    local pos = without_actor:find(delimiter, 1, true);
                    if pos then
                        ability_name = without_actor:sub(1, pos - 1):gsub("%s+$", "");
                        break;
                    end
                end

                if not ability_name or ability_name == "" then
                    ability_name = without_actor:match("^(.-)%s%s+") or without_actor:gsub("%s+$", "");
                end
            end
        end

        -- Fall back to traditional format: "Enemy readies Ability"
        -- Only runs when SimpleLog Mode is OFF
        if not use_simplelog and not ability_name then
            local readies_start = string.find(clean_text, " readies ");
            if (readies_start) then
                ability_name = string.match(clean_text, "readies (.-)%.")
                                  or string.match(clean_text, "readies (.-)$");

                if (ability_name) then
                    local on_start = string.find(ability_name, " on ");
                    if (on_start) then ability_name = string.sub(ability_name, 1, on_start - 1); end

                    local comma_start = string.find(ability_name, ",");
                    if (comma_start) then ability_name = string.sub(ability_name, 1, comma_start - 1); end

                    ability_name = string.match(ability_name, "^%s*(.-)%s*$");

                    -- Extract enemy name from traditional format for spam key
                    if not enemy_name then
                        enemy_name = string.sub(clean_text, 1, readies_start - 1);
                        enemy_name = string.match(enemy_name, "^%s*(.-)%s*$");
                    end
                end
            end
        end

        -- Normalize: strip a leading readies/uses/casts verb that some chat-log
        -- addons keep in the arrow text (both formats may carry it).
        if ability_name then
            ability_name = sl_strip_leading_verb(ability_name);
        end

        -- If we got an ability name from either format, try to play it
        local actor_race = get_beastman_race(enemy_name);
        if ability_name and ability_name ~= '' and bv_race_allowed(actor_race)
           and (actor_race ~= 'Tonberry' or beast_config.tonberry_tp_enabled[1]) then
            -- Check if a party member is being targeted by "on PlayerName"
            local party_targeted = is_party_involved();

            -- Also check if PLAYER is in combat (Status 1 = fighting)
            local player_ent = GetPlayerEntity();
            local player_in_combat = (player_ent and player_ent.Status == 1);

            -- Also check if we're engaged with ANY beastman (means we're in combat)
            local we_are_in_combat = false;
            for _, _ in pairs(engaged_mobs) do
                we_are_in_combat = true;
                break;
            end

            if (party_targeted or player_in_combat or we_are_in_combat) then
                local clean_ability = string.lower(ability_name);
                clean_ability = string.gsub(clean_ability, "%s+", "");
                clean_ability = string.gsub(clean_ability, "[^%w]", "");

                -- Resolve to rotating variant: monster_<ability>1.wav, monster_<ability>2.wav, ...
                -- Falls back to legacy single-file monster_<ability>.wav if no variants exist.
                local resolved_filename = resolve_monster_variant(clean_ability);

                if (resolved_filename) then
                    -- Spam blocker: SimpleLog + traditional both fire for same TP move.
                    -- Use cleaned enemy+ability key. Both paths now produce matching keys.
                    local clean_enemy = enemy_name and string.lower(enemy_name):gsub("[^%w]", "") or "unknown";
                    local spam_key = clean_enemy .. "_" .. clean_ability;
                    local now = os.clock();

                    if (now - (monster_ability_blocker[spam_key] or 0)) < 3.0 then
                        return false;  -- Block duplicate
                    end

                    -- Global TP cooldown: catches boss firing multiple different TPs in
                    -- quick succession (per-ability blocker has unique keys per move so
                    -- doesn't help here).
                    if (now - last_skill_sound_time) < SKILL_GLOBAL_COOLDOWN then
                        return false;
                    end

                    monster_ability_blocker[spam_key] = now;
                    last_skill_sound_time = now;

                    play_sound(resolved_filename, false, DUCK_SKILL, actor_race);
                    return false;
                end
            end
        end
    end

    -- BEASTMEN-SPECIFIC DETECTION
    local is_player_pet = false;
    if party then
        for i = 0, 5 do
            local member_name = party:GetMemberName(i);
            if member_name and member_name ~= "" then
                if string.find(clean_text, member_name .. "'s") then
                    is_player_pet = true;
                    break;
                end
            end
        end
    end

    if is_player_pet then
        return false;
    end

    for race_name, data in pairs(beast_data) do
        local race_start, race_end = string.find(clean_text, race_name);
        if not race_start then
            for name, race in pairs(beast_name_aliases) do
                if race == race_name then
                    race_start, race_end = string.find(clean_text, name, 1, true);
                    if race_start then break; end
                end
            end
        end
        if (race_start) then

            -- [FIX]: Check for death messages explicitly (case-insensitive)
            local clean_lower = string.lower(clean_text);
            local is_death_msg = string.find(clean_lower, " defeats the ") or string.find(clean_lower, "falls to the ground");

            if (DEBUG_AGGRO and is_death_msg) then
                print(chat.header('BeastVoice'):append(chat.message('DEATH MSG found, race=' .. race_name .. ', text=' .. string.sub(clean_text, 1, 60))));
            end

            -- [FIX]: For death messages, verify party member OR THEIR PET is the killer
            if (is_death_msg) then
                local defeats_pos = string.find(clean_lower, " defeats the ");
                if (defeats_pos) then
                    -- "PlayerName defeats the Goblin" or "SaberSiravarde defeats the Goblin"
                    -- Also handle SimpleLOG: "[SaberSiravarde] Defeats the Goblin"
                    local killer_name = string.sub(clean_text, 1, defeats_pos - 1);

                    -- Strip SimpleLOG brackets if present: "[Name]" -> "Name"
                    local bracket_name = string.match(killer_name, "^%[(.-)%]");
                    if bracket_name then
                        killer_name = bracket_name;
                    end

                    -- Trim whitespace
                    killer_name = string.match(killer_name, "^%s*(.-)%s*$") or killer_name;

                    -- Skip if killer name is empty or too short
                    if (not killer_name or #killer_name < 2) then
                        goto continue_race_loop;
                    end

                    local valid_kill = false;

                    -- Check 1: Is killer a party member?
                    if party then
                        for i = 0, 5 do
                            local member_name = party:GetMemberName(i);
                            if member_name and member_name ~= "" then
                                if string.find(killer_name, member_name, 1, true) then
                                    valid_kill = true;
                                    break;
                                end
                                -- Check possessive pet: "Eldorin's Carbuncle"
                                if string.find(killer_name, member_name .. "'s", 1, true) then
                                    valid_kill = true;
                                    break;
                                end
                            end
                        end
                    end

                    -- Check 2: Is player in combat? (pet fighting for them)
                    if (not valid_kill) then
                        local player_ent = GetPlayerEntity();
                        if (player_ent and player_ent.Status == 1) then
                            valid_kill = true;
                        end
                    end

                    -- Check 3: Were we engaged with this race?
                    if (not valid_kill and is_engaged_with_race(race_name)) then
                        valid_kill = true;
                    end

                    -- Check 4: Is killer NOT a beastman? (then it's probably friendly - BST pet, etc)
                    if (not valid_kill) then
                        local killer_is_beastman = false;
                        local killer_lower = string.lower(killer_name);
                        for _, bm in ipairs(beastman_patterns) do
                            if string.find(killer_lower, string.lower(bm.pattern)) then
                                killer_is_beastman = true;
                                break;
                            end
                        end
                        if (not killer_is_beastman) then
                            -- Killer isn't a beastman = friendly kill (pet, adventurer, NPC, etc)
                            valid_kill = true;
                            if (DEBUG_AGGRO) then
                                print(chat.header('BeastVoice'):append(chat.message('DEATH: Killer "' .. killer_name .. '" is not a beastman, treating as friendly')));
                            end
                        end
                    end

                    -- STRICT: Only play death if valid kill
                    if (not valid_kill) then
                        if (DEBUG_AGGRO) then
                            print(chat.header('BeastVoice'):append(chat.warning('DEATH SKIP: ' .. race_name .. ' - not valid kill. Killer: ' .. tostring(killer_name))));
                        end
                        goto continue_race_loop;
                    else
                        if (DEBUG_AGGRO) then
                            print(chat.header('BeastVoice'):append(chat.success('DEATH VALID: ' .. race_name .. ' - Killer: ' .. tostring(killer_name))));
                        end
                    end
                elseif (string.find(clean_lower, "falls to the ground")) then
                    -- "falls to the ground" has no killer name - only play if we were engaged
                    if (not is_engaged_with_race(race_name)) then
                        goto continue_race_loop;
                    end
                end
            else
                -- [FIX]: Only enforce "engaged" check if it is NOT a death message.
                if (not is_engaged_with_race(race_name)) then
                    goto continue_race_loop;
                end
            end

            local after_race = race_end + 1;
            if after_race <= #clean_text then
                local next_chars = string.sub(clean_text, after_race, after_race + 1);
                if next_chars == "'s" or next_chars == "s" then
                    goto continue_race_loop;
                end
            end

            -- TP ABILITY Logic (traditional only - SimpleLog handles via bracket parser)
            if not use_simplelog then
            local ability_name = string.match(clean_text, "readies (.-)%.")
                              or string.match(clean_text, "readies (.-)$");

            if (ability_name) then
                local on_start = string.find(ability_name, " on ");
                if (on_start) then ability_name = string.sub(ability_name, 1, on_start - 1); end

                local comma_start = string.find(ability_name, ",");
                if (comma_start) then ability_name = string.sub(ability_name, 1, comma_start - 1); end

                ability_name = string.match(ability_name, "^%s*(.-)%s*$");

                local specific_sound = data['skills'][ability_name];

                -- DEBUG: Log traditional TP skill lookups
                if (DEBUG_AGGRO) then
                    local found = specific_sound and "FOUND" or "NOT FOUND";
                    print(chat.header('BeastVoice'):append(chat.message('TRAD SKILL: "' .. ability_name .. '" for ' .. race_name .. ' -> ' .. found)));
                end

                if (specific_sound) then
                    -- Cross-format dedup: SimpleLog may have already played this
                    local clean_enemy = string.lower(race_name):gsub("[^%w]", "");
                    local clean_action = string.lower(ability_name):gsub("%s+", ""):gsub("[^%w]", "");
                    local spam_key = clean_enemy .. "_" .. clean_action;
                    local now = os.clock();

                    if (now - (monster_ability_blocker[spam_key] or 0)) < 3.0 then
                        return false;  -- Already played via SimpleLog
                    end

                    if (should_play_combat('skills', race_name)) then
                        monster_ability_blocker[spam_key] = now;
                        local resolved = resolve_skill_sound(specific_sound, race_name, ability_name);
                        if resolved then
                            play_sound(resolved, false, DUCK_SKILL);
                        end
                        return false;
                    end
                end
            end

            -- SONG/MAGIC Logic
            local spell_name = string.match(clean_text, "starts casting (.-)%.")
                            or string.match(clean_text, "starts casting (.-)$");

            if (spell_name) then
                local on_start = string.find(spell_name, " on ");
                if (on_start) then spell_name = string.sub(spell_name, 1, on_start - 1); end

                spell_name = string.match(spell_name, "^%s*(.-)%s*$");

                local specific_sound = lookup_beast_skill(race_name, spell_name);
                if (specific_sound) then
                    -- Cross-format dedup (8s for spells with cast times)
                    local clean_enemy = string.lower(race_name):gsub("[^%w]", "");
                    local clean_spell = string.lower(spell_name):gsub("%s+", ""):gsub("[^%w]", "");
                    local spam_key = clean_enemy .. "_" .. clean_spell;
                    local now = os.clock();

                    if (now - (monster_ability_blocker[spam_key] or 0)) < 8.0 then
                        return false;
                    end

                    if (should_play_combat('skills', race_name)) then
                        monster_ability_blocker[spam_key] = now;
                        local resolved = resolve_skill_sound(specific_sound, race_name, spell_name);
                        if resolved then
                            play_sound(resolved, false, DUCK_SKILL);
                        end
                        return false;
                    end
                end
            end

            end -- if not use_simplelog (TP ability / song traditional detection)

            -- DEATH (case-insensitive)
            local death_start = string.find(string.lower(clean_text), " defeats the ");
            if (death_start) then
                if (race_start > death_start and should_play_combat('death', race_name)) then
                    if (DEBUG_AGGRO) then
                        print(chat.header('BeastVoice'):append(chat.success('DEATH: ' .. race_name .. ' - playing sound')));
                    end
                    play_sound(get_next_sound(race_name, 'death'), false, DUCK_DEATH);
                    return false;
                elseif (DEBUG_AGGRO) then
                    print(chat.header('BeastVoice'):append(chat.warning('DEATH: ' .. race_name .. ' - race_start=' .. tostring(race_start) .. ' death_start=' .. tostring(death_start))));
                end
            end
            if (string.find(string.lower(clean_text), "falls to the ground") and should_play_combat('death', race_name)) then
                if (DEBUG_AGGRO) then
                    print(chat.header('BeastVoice'):append(chat.success('DEATH (falls): ' .. race_name)));
                end
                play_sound(get_next_sound(race_name, 'death'), false, DUCK_DEATH);
                return false;
            end

            if (string.find(clean_text, "casting") or string.find(clean_text, "casts")
                or string.find(clean_text, "readies") or string.find(clean_text, "uses")) then
                return false;
            end

            -- ATTACK / OUCH - Must verify party involvement
            local hit_start = string.find(clean_text, " hits ");
            if (hit_start) then
                -- Check if party member (or their pet) is involved
                local party_involved = false;
                local attacker_part = string.sub(clean_text, 1, hit_start - 1);
                local target_part = string.sub(clean_text, hit_start + 6);  -- after " hits "

                if party then
                    for i = 0, 5 do
                        local member_name = party:GetMemberName(i);
                        if member_name and member_name ~= "" then
                            -- Check if party member is attacker OR target
                            if string.find(attacker_part, member_name, 1, true) then
                                party_involved = true;
                                break;
                            end
                            if string.find(target_part, member_name, 1, true) then
                                party_involved = true;
                                break;
                            end
                            -- Also check for party member's pet: "Elodrin's Carbuncle"
                            if string.find(attacker_part, member_name .. "'s", 1, true) then
                                party_involved = true;
                                break;
                            end
                        end
                    end
                end

                if party_involved then
                    if (race_start < hit_start and should_play_combat('attack', race_name)) then
                        -- Beastman attacking party member
                        play_sound(get_next_sound(race_name, 'attack'), false, DUCK_COMBAT);
                    elseif (race_start > hit_start and should_play_combat('ouch', race_name)) then
                        -- Party member hitting beastman
                        play_sound(get_next_sound(race_name, 'ouch'), false, DUCK_COMBAT);
                    end
                end
                return false;
            end

            local takes_start = string.find(clean_text, " takes ");
            if (takes_start and string.find(clean_text, "damage")) then
                -- Check if damage is from a pet ability: "X takes N damage from PetName's Ability"
                -- If "from" clause exists, verify the source is a party member or beastman.
                -- If neither, it's a pet/NPC hit — skip to avoid wyvern/BST pet triggering ouch.
                local from_pos = string.find(clean_text, " from ", takes_start);
                if (from_pos) then
                    local from_part = string.sub(clean_text, from_pos + 6);

                    local from_is_valid = false;

                    -- Check if source is a party member
                    if party then
                        for i = 0, 5 do
                            local member_name = party:GetMemberName(i);
                            if member_name and member_name ~= "" and string.find(from_part, member_name, 1, true) then
                                from_is_valid = true;
                                break;
                            end
                        end
                    end

                    -- Check if source is a beastman (beastman-on-beastman is fine to track)
                    if (not from_is_valid) then
                        for _, bm in ipairs(beastman_patterns) do
                            if string.find(from_part, bm.pattern) then
                                from_is_valid = true;
                                break;
                            end
                        end
                    end

                    -- Source is neither party member nor beastman = pet/NPC, skip
                    if (not from_is_valid) then
                        if (DEBUG_AGGRO) then
                            print(chat.header('BeastVoice'):append(chat.warning('OUCH SKIP: damage from pet/NPC source: ' .. string.sub(from_part, 1, 40))));
                        end
                        goto continue_race_loop;
                    end
                end

                if (race_start < takes_start and should_play_combat('ouch', race_name) and is_engaged_with_race(race_name)) then
                    play_sound(get_next_sound(race_name, 'ouch'), false, DUCK_COMBAT);
                end
                return false;
            end
        end

        ::continue_race_loop::
    end
    return false;
end);

-- Zone-out must suspend scanning until zone-in and stable player identity.
ashita.events.register('packet_in', 'beastvoice_packet', function(e)
    if e.id == 0x00B then
        BeginAggroTransition('departing');
    elseif e.id == 0x00A then
        BeginAggroTransition('arriving');
    end
    return false;
end);

-- Cleanup on unload to prevent crash
ashita.events.register('unload', 'beastvoice_unload', function()
    -- Save all settings using the proper function
    pcall(save_settings);

    -- Close all MCI sound aliases
    pcall(function()
        ClearShadowVoiceQueue();
        ClearTonberryExclusive();
        for i = 1, MAX_POLYPHONY do
            local alias = "beast_sfx_" .. i;
            winmm.mciSendStringA("close " .. alias, nil, 0, nil);
        end
    end);
end);
