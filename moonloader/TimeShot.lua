script_name('TimeShot')
script_author('jalisco')
script_version('1.0.12')
script_description('/t - /time + screenshot into a report folder, /tmenu - reports and gov tools, /td - department radio')

local ffi = require 'ffi'
local bit = require 'bit'
local imgui = require 'mimgui'
local encoding = require 'encoding'
local sampev = require 'samp.events'
encoding.default = 'CP1251'
local u8 = encoding.UTF8
local new = imgui.new

local function cp(text)
    return u8:decode(text)
end

local AUTHOR = 'jalisco'
local CONFIG_PATH = getWorkingDirectory() .. '\\config\\TimeShot.json'

ffi.cdef[[
int __stdcall WideCharToMultiByte(unsigned int codePage, unsigned long flags, const wchar_t* source, int sourceLength, char* target, int targetSize, const char* fallback, int* usedFallback);
int __stdcall CreateDirectoryW(const wchar_t* path, void* security);
unsigned long __stdcall GetFileAttributesW(const wchar_t* path);
int __stdcall MoveFileExW(const wchar_t* from, const wchar_t* to, unsigned long flags);
int __stdcall DeleteFileW(const wchar_t* path);
void* __stdcall CreateFileW(const wchar_t* path, unsigned long access, unsigned long share, void* security, unsigned long creation, unsigned long flags, void* template);
int __stdcall ReadFile(void* file, void* buffer, unsigned long size, unsigned long* done, void* overlapped);
int __stdcall WriteFile(void* file, const void* buffer, unsigned long size, unsigned long* done, void* overlapped);
unsigned long __stdcall GetFileSize(void* file, unsigned long* high);
unsigned long __stdcall SetFilePointer(void* file, long distance, long* high, unsigned long method);
int __stdcall CloseHandle(void* handle);
typedef struct { unsigned long attributes; unsigned long times[6]; unsigned long sizeHigh, sizeLow, reserved0, reserved1; wchar_t name[260]; wchar_t altName[14]; } TS_FIND_DATAW;
void* __stdcall FindFirstFileW(const wchar_t* path, TS_FIND_DATAW* data);
int __stdcall FindNextFileW(void* handle, TS_FIND_DATAW* data);
int __stdcall FindClose(void* handle);
long __stdcall SHGetFolderPathW(void* window, int folder, void* token, unsigned long flags, wchar_t* path);
void* __stdcall ShellExecuteW(void* window, const wchar_t* operation, const wchar_t* file, const wchar_t* parameters, const wchar_t* directory, int show);
]]

local fs = { invalid = ffi.cast('void*', -1) }

function fs.wide(text, codePage)
    codePage = codePage or 65001
    local size = ffi.C.MultiByteToWideChar(codePage, 0, text, #text, nil, 0)
    local buffer = ffi.new('wchar_t[?]', size + 1)
    if size > 0 then ffi.C.MultiByteToWideChar(codePage, 0, text, #text, buffer, size) end
    return buffer
end

function fs.utf8(wide)
    local size = ffi.C.WideCharToMultiByte(65001, 0, wide, -1, nil, 0, nil, nil)
    if size <= 1 then return '' end
    local buffer = ffi.new('char[?]', size)
    ffi.C.WideCharToMultiByte(65001, 0, wide, -1, buffer, size, nil, nil)
    return ffi.string(buffer, size - 1)
end

function fs.fromAnsi(text)
    return fs.utf8(fs.wide(text, 0))
end

function fs.attributes(path)
    local value = ffi.C.GetFileAttributesW(fs.wide(path))
    if value == 0xFFFFFFFF then return nil end
    return value
end

function fs.exists(path)
    return fs.attributes(path) ~= nil
end

function fs.isDir(path)
    local value = fs.attributes(path)
    return value ~= nil and bit.band(value, 0x10) ~= 0
end

function fs.mkdir(path)
    if fs.isDir(path) then return true end
    local parent = path:match('^(.*)\\[^\\]+$')
    if parent and parent ~= '' and not parent:match('^%a:$') then fs.mkdir(parent) end
    ffi.C.CreateDirectoryW(fs.wide(path), nil)
    return fs.isDir(path)
end

function fs.move(from, to)
    return ffi.C.MoveFileExW(fs.wide(from), fs.wide(to), 2) ~= 0
end

function fs.remove(path)
    return ffi.C.DeleteFileW(fs.wide(path)) ~= 0
end

function fs.list(dir)
    local entries, data = {}, ffi.new('TS_FIND_DATAW')
    local handle = ffi.C.FindFirstFileW(fs.wide(dir .. '\\*'), data)
    if handle == nil or handle == fs.invalid then return entries end
    repeat
        local name = fs.utf8(data.name)
        if name ~= '.' and name ~= '..' and name ~= '' then
            entries[#entries + 1] = { name = name, isDir = bit.band(data.attributes, 0x10) ~= 0 }
        end
    until ffi.C.FindNextFileW(handle, data) == 0
    ffi.C.FindClose(handle)
    return entries
end

function fs.read(path)
    local handle = ffi.C.CreateFileW(fs.wide(path), 0x80000000, 3, nil, 3, 0x80, nil)
    if handle == nil or handle == fs.invalid then return nil end
    local size = ffi.C.GetFileSize(handle, nil)
    local text = ''
    if size ~= 0xFFFFFFFF and size > 0 then
        local buffer, done = ffi.new('char[?]', size), ffi.new('unsigned long[1]')
        if ffi.C.ReadFile(handle, buffer, size, done, nil) ~= 0 then text = ffi.string(buffer, done[0]) end
    end
    ffi.C.CloseHandle(handle)
    return text
end

function fs.write(path, text, append)
    local handle = ffi.C.CreateFileW(fs.wide(path), 0x40000000, 1, nil, append and 4 or 2, 0x80, nil)
    if handle == nil or handle == fs.invalid then return false end
    if append then ffi.C.SetFilePointer(handle, 0, nil, 2) end
    local done = ffi.new('unsigned long[1]')
    local ok = ffi.C.WriteFile(handle, text, #text, done, nil) ~= 0
    ffi.C.CloseHandle(handle)
    return ok
end

function fs.open(path)
    ffi.load('shell32').ShellExecuteW(nil, fs.wide('open'), fs.wide(path), nil, nil, 1)
end

local BASE_DIR, BASE_FALLBACK = nil, false
do
    local override = os.getenv('TIMESHOT_HOME')
    local fallback = fs.fromAnsi(getWorkingDirectory()) .. '\\TimeShot'
    local preferred
    if override and override ~= '' then
        preferred = fs.fromAnsi(override)
    else
        local buffer = ffi.new('wchar_t[520]')
        if ffi.load('shell32').SHGetFolderPathW(nil, 5, nil, 0, buffer) == 0 then
            local documents = fs.utf8(buffer)
            if documents ~= '' then preferred = documents .. '\\GTA San Andreas User Files\\TimeShot by Jalisco' end
        end
    end
    if preferred and fs.mkdir(preferred) then
        BASE_DIR = preferred
    else
        fs.mkdir(fallback)
        BASE_DIR, BASE_FALLBACK = fallback, true
    end
end
local TEMP_FILE = BASE_DIR .. '\\_timeshot_tmp.jpg'
local NOTES_DIR = BASE_DIR .. '\\Заметки'
local WEEK_PATTERN = '^%d%d%.%d%d%.%d%d%d%d %- %d%d%.%d%d%.%d%d%d%d$'
local AFK_TIMER = 0x7153

local ORG_TAGS = { 'Пра-во', 'ЦЛ', 'СК', 'СМИ ЛС', 'СМИ СФ', 'СМИ ЛВ', 'ФД', 'ФБР', 'ЛСПД', 'СФПД', 'ЛВПД', 'РКШД',
    'ЛСа', 'СФа', 'ТСР', 'ЛСМЦ', 'ЛВМЦ', 'СФМЦ', 'ЖМЦ' }
local RADIO_TAGS = { 'Всем', 'ЦА', 'МЮ', 'МО', 'МЗ', 'СМИ' }
for _, tag in ipairs(ORG_TAGS) do RADIO_TAGS[#RADIO_TAGS + 1] = tag end
for _, tag in ipairs({ 'Губернатор', 'Вице-Губернатор', 'Мин.Юстиции', 'Мин.Обороны', 'Мин.Здрав', 'Ген.Прокуратура',
    'Прокуратура', 'Судья', 'Спикер', 'Ассамблея' }) do
    RADIO_TAGS[#RADIO_TAGS + 1] = tag
end

local PUNISH_COMMANDS = { demoute = true, dismiss = true, gwarn = true }
local JUSTICE_COMMANDS = { su = true, ticket = true, take = true }

local PATTERN = {
    gov = cp('^Гос%.Новости: ([%w_]+)%[%d+%]:'),
    radio = cp('^%[D%].-([%w_]+)%[%d+%]: %[(.-)%] %- '),
    interview = cp('^%[D%].-([%w_]+)%[%d+%].-назначил собеседование в свою организацию на (%d+):(%d+)'),
    invited = cp('([%w_]+) принял ваше предложение вступить'),
    promoted = cp('Вы повысили игрока ([%w_]+) до (%d+) ранга'),
    demoted = cp('Вы понизили игрока ([%w_]+) до (%d+) ранга'),
    flood = cp('Не флуди'),
    membersTitle = cp('%(В сети: %d+%)'),
    membersTitleAlt = cp('В сети всего'),
    nextPage = cp('Следующая страница'),
    you = cp('%(Вы%)'),
    lmenuInterviews = cp('обеседован'),
    lmenuAssign = cp('азначить'),
    slotTaken = cp('уже кто-то назначил'),
    serverError = cp('^%[Ошибка%]%s*(.+)$'),
}

local cfg = {
    categories = { 'Собеседование', 'RP ситуации' },
    delay = 800,
    weekly = true,
    weekStart = 1,
    ownTag = '',
    interviewNorm = 3,
    autoStaff = true,
    autoPunish = true,
    autoJustice = false,
    afkWarn = true,
    widget = false,
    hud = false,
    hudX = 99,
    hudY = 45,
    hudSize = 16,
    hudToday = true,
    hudWeek = true,
    hudNorm = true,
    hudStatus = false,
    hudInterviews = false,
    hudNick = false,
    hudTime = false,
    myRank = '',
    members = false,
    membersX = 1,
    membersY = 45,
    membersSize = 14,
    membersInterval = 30,
    membersNorm = 6,
    membersMax = 25,
    membersRank = true,
    membersId = true,
    membersAfk = true,
    binds = {},
    hidden = {},
    snakeBest = 0,
    autoUpdate = true,
    interviewPlace = '',
    interviewRemind = true,
    termStart = '',
    termDays = 30,
    termExtra = 0,
    keys = { shot = 0, menu = 0, wheel = 0, radio = 0 },
    radioKeySeeded = false,
    sens = false,
    sensX = 0,
    sensY = 0,
    wheelSeeded = false,
    wheelKeySeeded = false,
    menuKeySeeded = false,
    accent = 1,
    online = {},
    onlineClean = {},
    gov = {},
    slots = {},
}

local pickWindow = new.bool(false)
local menuWindow = new.bool(false)
local radioWindow = new.bool(false)
local newName = new.char[64]()
local subName = new.char[64]()
local radioText = new.char[200]()
local sliders = {}
local ns, bs = {}, {}
ns.title = new.char[96]()
ns.text = new.char[65536]()
ns.list = {}
ns.current = nil
ns.editing = false
ns.confirm = false
ns.view = ''
ns.doc = {}
ns.search = new.char[96]()
ns.tag = nil
ns.tags = {}
ns.cursor = { pos = 0, s = 0, e = 0 }
bs.name = new.char[96]()
bs.command = new.char[32]()
bs.text = new.char[32768]()
bs.delay = new.int(2500)
bs.index = nil
bs.confirm = false
bs.wheel = new.bool(false)
local binder = { running = false, stop = false, name = '', index = 0, total = 0, commands = {} }
local inputActive = false
local onlineEdit = { day = nil, busy = false, hours = new.int(0), minutes = new.int(0), cleanHours = new.int(0), cleanMinutes = new.int(0) }
local avatar = { texture = nil, dirty = true, ansi = getWorkingDirectory() .. '\\config\\TimeShot_avatar.jpg',
    path = fs.fromAnsi(getWorkingDirectory()) .. '\\config\\TimeShot_avatar.jpg' }
ns.pending = nil
ns.refocus = false
local members = { list = {}, collecting = {}, waiting = false, requestAt = 0, lastRequest = 0, at = 0, misses = 0, fraction = '' }
local toggles = {}
local menuTab = 1
local radioTarget = 'Всем'
local pending = nil
local busy = false
local cfgDirty = false
local stateDirty = false
local floodHit = false
local timeSentAt = 0
local lastAuto = {}
local nickTags = {}
local gameWindow = nil
local afk = { since = nil, warned = 0 }
local stats = { cats = {}, oldPunish = 0, punishTotal = 0 }
local lastTick = os.time()
local lastReminder = ''
local ticks = 0

local function notify(text)
    sampAddChatMessage(u8:decode('[TimeShot] {FFFFFF}' .. text), 0x4FA3FF)
end

local function saveConfig()
    local f = io.open(CONFIG_PATH, 'w')
    if f then
        f:write(encodeJson(cfg))
        f:close()
    end
end

local function loadConfig()
    local f = io.open(CONFIG_PATH, 'r')
    local ok, data = false, nil
    if f then
        ok, data = pcall(decodeJson, f:read('*a'))
        f:close()
    end
    if ok and type(data) == 'table' then
        for key, default in pairs(cfg) do
            if type(data[key]) == type(default) then cfg[key] = data[key] end
        end
    end
    cfg.delay = math.floor(cfg.delay)
    cfg.keys.shot, cfg.keys.menu = tonumber(cfg.keys.shot) or 0, tonumber(cfg.keys.menu) or 0
    cfg.keys.wheel = tonumber(cfg.keys.wheel) or 0
    if not cfg.wheelKeySeeded then
        cfg.wheelKeySeeded = true
        if cfg.keys.wheel == 0 then cfg.keys.wheel = 0x200 + 0x52 end
    end
    cfg.keys.radio = tonumber(cfg.keys.radio) or 0
    if not cfg.radioKeySeeded then
        cfg.radioKeySeeded = true
        if cfg.keys.radio == 0 then cfg.keys.radio = 0x72 end
    end
    if not cfg.menuKeySeeded then
        cfg.menuKeySeeded = true
        if cfg.keys.menu == 0 then cfg.keys.menu = 0x74 end
    end
    if not cfg.wheelSeeded then
        cfg.wheelSeeded = true
        local presets = {
            { 'Принять в организацию', table.concat({
                '/me достал из папки бланк и внёс в него данные нового сотрудника',
                '/do Бланк заполнен, форма и рация лежат на столе.',
                '/me передал форму и рацию человеку напротив',
                '/invite {tid}',
            }, '\n') },
            { 'Уволить', table.concat({
                '/me открыл базу данных и удалил личное дело сотрудника {tname}',
                '/do Личное дело удалено из базы данных.',
                '/uninvite {tid} {reason}',
            }, '\n') },
            { 'Изменить ранг', table.concat({
                '/me достал новые погоны и передал их сотруднику {tname}',
                '/do Погоны переданы.',
                '/giverank {tid} {trank}',
            }, '\n') },
        }
        for _, preset in ipairs(presets) do
            cfg.binds[#cfg.binds + 1] = { name = preset[1], cmd = '', delay = 2500, text = preset[2], key = 0, wheel = true }
        end
        saveConfig()
    end
    if cfg.weekStart ~= 0 then cfg.weekStart = 1 end

    local importPath = getWorkingDirectory() .. '\\config\\TimeShot_import.json'
    local source = io.open(importPath, 'r')
    if source then
        local parsed, list = pcall(decodeJson, source:read('*a'))
        source:close()
        os.remove(importPath)
        local added = 0
        for _, item in ipairs(parsed and type(list) == 'table' and list or {}) do
            if type(item) == 'table' and type(item.name) == 'string' and type(item.text) == 'string' then
                local exists = false
                for _, bind in ipairs(cfg.binds) do
                    if bind.name == item.name then exists = true end
                end
                if not exists then
                    cfg.binds[#cfg.binds + 1] = {
                        name = item.name,
                        cmd = type(item.cmd) == 'string' and item.cmd or '',
                        delay = tonumber(item.delay) or 2500,
                        text = item.text,
                        key = tonumber(item.key) or 0,
                        wheel = item.wheel == true,
                    }
                    added = added + 1
                end
            end
        end
        if added > 0 then
            saveConfig()
            notify('Импортировано биндов: ' .. added .. '. Они в разделе «Биндер».')
        end
    end

    local cutoff = os.date('%Y-%m-%d', os.time() - 30 * 86400)
    for _, days in ipairs({ cfg.online, cfg.onlineClean }) do
        for day in pairs(days) do
            if type(day) ~= 'string' or day < cutoff then days[day] = nil end
        end
    end
end

local function ensureDir(path)
    return fs.mkdir(path)
end

local function cleanName(s)
    return (s:gsub('[\\/:*?"<>|%%%c]', ''):gsub('^%s+', ''):gsub('[%s%.]+$', ''))
end

local function weekStartTime()
    local now = os.date('*t')
    local sinceStart = (now.wday - 1 - cfg.weekStart) % 7
    return os.time({ year = now.year, month = now.month, day = now.day - sinceStart, hour = 12 })
end

local function weekFolder()
    local start = weekStartTime()
    return os.date('%d.%m.%Y', start) .. ' - ' .. os.date('%d.%m.%Y', start + 6 * 86400)
end

local function weekDates()
    local start, list, set = weekStartTime(), {}, {}
    for i = 0, 6 do
        local day = os.date('%Y-%m-%d', start + i * 86400)
        list[#list + 1] = day
        set[day] = true
    end
    return list, set
end

local function rootDir()
    return cfg.weekly and (BASE_DIR .. '\\' .. weekFolder()) or BASE_DIR
end

local function categoryDir(name, sub)
    local dir = rootDir() .. '\\' .. name
    if sub and sub ~= '' then dir = dir .. '\\' .. sub end
    return dir
end

local function addCategory(raw)
    local name = cleanName(raw)
    if name == '' then return nil, 'Введи название папки.' end
    for _, existing in ipairs(cfg.categories) do
        if existing == name then return name end
    end
    table.insert(cfg.categories, name)
    cfg.hidden[name] = nil
    fs.mkdir(rootDir() .. '\\' .. name)
    saveConfig()
    return name
end

local function findCategory(part, default)
    for _, name in ipairs(cfg.categories) do
        if name:find(part, 1, true) then return name end
    end
    return default
end

local function formatDuration(seconds)
    seconds = math.max(0, math.floor(seconds))
    return ('%d ч %02d мин'):format(math.floor(seconds / 3600), math.floor(seconds % 3600 / 60))
end

local function countdown(seconds)
    seconds = math.max(0, math.floor(seconds))
    return ('%d:%02d'):format(math.floor(seconds / 60), seconds % 60)
end

local function myNick()
    local ok, id = sampGetPlayerIdByCharHandle(PLAYER_PED)
    return ok and sampGetPlayerNickname(id) or ''
end

ffi.cdef[[
typedef struct { long left, top, right, bottom; } TS_RECT;
typedef struct { long x, y; } TS_POINT;
typedef struct { unsigned int Width, Height, RefreshRate, Format; } TS_D3DDISPLAYMODE;
typedef struct { unsigned long cbSize; TS_RECT rcMonitor; TS_RECT rcWork; unsigned long dwFlags; } TS_MONITORINFO;
typedef struct { unsigned long attributes; unsigned long times[6]; unsigned long sizeHigh, sizeLow, reserved0, reserved1; char name[260]; char altName[14]; } TS_FIND_DATA;

int __stdcall GetClientRect(void* hWnd, TS_RECT* lpRect);
int __stdcall ClientToScreen(void* hWnd, TS_POINT* lpPoint);
void* __stdcall MonitorFromWindow(void* hWnd, unsigned long dwFlags);
int __stdcall GetMonitorInfoA(void* hMonitor, TS_MONITORINFO* lpmi);
void* __stdcall GetForegroundWindow(void);
short __stdcall GetKeyState(int key);
typedef struct { unsigned long cbSize; unsigned long flags; void* hCursor; TS_POINT pt; } TS_CURSORINFO;
int __stdcall GetCursorInfo(TS_CURSORINFO* info);
unsigned int __stdcall SetTimer(void* hWnd, unsigned int id, unsigned int ms, void* proc);
int __stdcall KillTimer(void* hWnd, unsigned int id);
int __stdcall FlashWindow(void* hWnd, int invert);
void* __stdcall FindFirstFileA(const char* path, TS_FIND_DATA* data);
int __stdcall FindNextFileA(void* handle, TS_FIND_DATA* data);
int __stdcall FindClose(void* handle);
void* __stdcall ShellExecuteA(void* hWnd, const char* op, const char* file, const char* params, const char* dir, int show);
int __stdcall PlaySoundA(const char* sound, void* module, unsigned long flags);
long __stdcall D3DXSaveSurfaceToFileW(const wchar_t* file, int format, void* surface, const void* palette, const TS_RECT* rect);
]]

local D3DFMT_A8R8G8B8, D3DPOOL_SYSTEMMEM, D3DXIFF_JPG = 21, 2, 1
local INVALID_HANDLE = ffi.cast('void*', -1)

local saveSurface
for _, ver in ipairs({ 25, 43, 42, 41, 40, 39, 38, 37, 36, 35, 34, 33, 32, 31, 30, 29, 28, 27, 26, 24 }) do
    local ok, fn = pcall(function() return ffi.load('d3dx9_' .. ver).D3DXSaveSurfaceToFileW end)
    if ok then
        saveSurface = fn
        break
    end
end

local function vmethod(obj, index, ctype)
    return ffi.cast(ctype, ffi.cast('void***', obj)[0][index])
end

local function releaseSurface(surface)
    vmethod(surface, 2, 'unsigned long(__stdcall*)(void*)')(surface)
end

local function gameRect(width, height)
    local hwnd = ffi.cast('void*', readMemory(0x00C8CF88, 4, false))
    local rc, pt, mi = ffi.new('TS_RECT'), ffi.new('TS_POINT'), ffi.new('TS_MONITORINFO')
    if ffi.C.GetClientRect(hwnd, rc) == 0 or ffi.C.ClientToScreen(hwnd, pt) == 0 then return nil end
    mi.cbSize = ffi.sizeof(mi)
    if ffi.C.GetMonitorInfoA(ffi.C.MonitorFromWindow(hwnd, 2), mi) ~= 0 then
        pt.x, pt.y = pt.x - mi.rcMonitor.left, pt.y - mi.rcMonitor.top
    end
    local rect = ffi.new('TS_RECT')
    rect.left, rect.top = math.max(pt.x, 0), math.max(pt.y, 0)
    rect.right, rect.bottom = math.min(pt.x + rc.right, width), math.min(pt.y + rc.bottom, height)
    if rect.right - rect.left < 64 or rect.bottom - rect.top < 64 then return nil end
    return rect
end

local function captureFrontBuffer(device, path, crop)
    local mode = ffi.new('TS_D3DDISPLAYMODE')
    if vmethod(device, 8, 'long(__stdcall*)(void*, unsigned int, TS_D3DDISPLAYMODE*)')(device, 0, mode) < 0 then
        return false
    end
    local out = ffi.new('void*[1]')
    local hr = vmethod(device, 36, 'long(__stdcall*)(void*, unsigned int, unsigned int, int, int, void**, void*)')
        (device, mode.Width, mode.Height, D3DFMT_A8R8G8B8, D3DPOOL_SYSTEMMEM, out, nil)
    if hr < 0 or out[0] == nil then return false end
    local surface = out[0]
    hr = vmethod(device, 33, 'long(__stdcall*)(void*, unsigned int, void*)')(device, 0, surface)
    if hr >= 0 then
        local rect = gameRect(mode.Width, mode.Height)
        if crop then
            local left, top = rect and rect.left or 0, rect and rect.top or 0
            local right, bottom = rect and rect.right or mode.Width, rect and rect.bottom or mode.Height
            rect = ffi.new('TS_RECT')
            rect.left = math.max(left, math.min(left + crop.x, right - 32))
            rect.top = math.max(top, math.min(top + crop.y, bottom - 32))
            rect.right = math.min(rect.left + crop.size, right)
            rect.bottom = math.min(rect.top + crop.size, bottom)
        end
        hr = saveSurface(fs.wide(path), D3DXIFF_JPG, surface, nil, rect)
    end
    releaseSurface(surface)
    return hr >= 0
end

local function captureBackBuffer(device, path, crop)
    local out = ffi.new('void*[1]')
    local hr = vmethod(device, 18, 'long(__stdcall*)(void*, unsigned int, unsigned int, int, void**)')(device, 0, 0, 0, out)
    if hr < 0 or out[0] == nil then return false end
    local rect = nil
    if crop then
        rect = ffi.new('TS_RECT')
        rect.left, rect.top = math.max(crop.x, 0), math.max(crop.y, 0)
        rect.right, rect.bottom = rect.left + crop.size, rect.top + crop.size
    end
    hr = saveSurface(fs.wide(path), D3DXIFF_JPG, out[0], nil, rect)
    releaseSurface(out[0])
    return hr >= 0
end

local function captureScreen(path, crop)
    if not saveSurface then return false, 'не найдена d3dx9_*.dll (установи DirectX End-User Runtime)' end
    local ok, result = pcall(function()
        local device = ffi.cast('void*', getD3DDevicePtr())
        return captureFrontBuffer(device, path, crop) or captureBackBuffer(device, path, crop)
    end)
    if not ok then return false, tostring(result) end
    if not result or not fs.exists(path) then return false, 'DirectX не отдал кадр' end
    return true
end

local function listDir(dir)
    return fs.list(dir)
end

local function syncFolders()
    local root = rootDir()
    if not fs.mkdir(root) then return end
    local known = {}
    for _, name in ipairs(cfg.categories) do
        known[name] = true
        fs.mkdir(root .. '\\' .. name)
    end
    local added = false
    for _, entry in ipairs(fs.list(root)) do
        local name = entry.name
        if entry.isDir and not known[name] and not cfg.hidden[name] and name ~= 'Заметки'
            and name:sub(1, 1) ~= '.' and not name:match(WEEK_PATTERN) then
            cfg.categories[#cfg.categories + 1] = name
            known[name] = true
            added = true
        end
    end
    if added then saveConfig() end
end
local function refreshStats()
    pcall(syncFolders)
    local result = { cats = {}, oldPunish = 0, punishTotal = 0 }
    local currentWeek = weekFolder()
    local _, inWeek = weekDates()
    local today = os.date('%Y-%m-%d')
    local cutoff = os.date('%Y-%m-%d', os.time() - 5 * 86400)
    local punishDir = findCategory('Наказ', 'Наказания')

    local function walk(dir, week, category, rel, depth)
        for _, entry in ipairs(listDir(dir)) do
            local path = dir .. '\\' .. entry.name
            if entry.isDir then
                if depth < 5 then
                    if not week and not category and entry.name:match(WEEK_PATTERN) then
                        walk(path, entry.name, nil, '', depth + 1)
                    elseif not category then
                        walk(path, week, entry.name, '', depth + 1)
                    else
                        walk(path, week, category, rel .. entry.name .. '\\', depth + 1)
                    end
                end
            elseif category and entry.name:lower():match('%.[jp][pn]e?g$') then
                local date, hour, minute = entry.name:match('^(%d%d%d%d%-%d%d%-%d%d)_(%d%d)%-(%d%d)')
                local counted
                if cfg.weekly then counted = week == currentWeek else counted = date ~= nil and inWeek[date] == true end
                if counted then
                    local key = category
                    local cat = result.cats[key]
                    if not cat then
                        cat = { week = 0, files = {}, todayTimes = {} }
                        result.cats[key] = cat
                    end
                    cat.week = cat.week + 1
                    cat.files[#cat.files + 1] = rel .. entry.name
                    if date == today then cat.todayTimes[#cat.todayTimes + 1] = tonumber(hour) * 60 + tonumber(minute) end
                end
                if category == punishDir then
                    result.punishTotal = result.punishTotal + 1
                    if date and date < cutoff then result.oldPunish = result.oldPunish + 1 end
                end
            end
        end
    end

    local ok = pcall(walk, BASE_DIR, nil, nil, '', 0)
    if ok then stats = result end
end

local function weekCount(name)
    local cat = stats.cats[name]
    return cat and cat.week or 0
end

local function interviewsToday()
    local cat = stats.cats[findCategory('Собесед', 'Собеседование')]
    if not cat or #cat.todayTimes == 0 then return 0 end
    table.sort(cat.todayTimes)
    local sessions = 1
    for i = 2, #cat.todayTimes do
        if cat.todayTimes[i] - cat.todayTimes[i - 1] > 20 then sessions = sessions + 1 end
    end
    return sessions
end

local function weekOnline(days)
    local total = 0
    for _, day in ipairs((weekDates())) do total = total + (days[day] or 0) end
    return total
end

local function onlineStatus(hours)
    if hours < 14 then return '2 строгих выговора', 14, false end
    if hours < 17 then return '1 строгий выговор', 17, false end
    if hours < 21 then return 'устный выговор', 21, false end
    if hours <= 24 then return 'норма выполнена', 24, true end
    if hours <= 30 then return 'снимается устный выговор', 30, true end
    return 'начисляется иммунитет', nil, true
end

local function journal(line)
    local dir = rootDir()
    if not ensureDir(dir) then return end
    local path = dir .. '\\Журнал.txt'
    local prefix = fs.exists(path) and '' or '\239\187\191'
    fs.write(path, prefix .. os.date('%d.%m.%Y %H:%M:%S') .. ' | ' .. u8(line) .. '\r\n', true)
end
local function discardPending()
    if pending then
        fs.remove(pending)
        pending = nil
    end
    pickWindow[0] = false
end

local function saveShot(name, sub)
    if not pending then return end
    local dir = categoryDir(name, sub)
    if not ensureDir(dir) then return notify('Не удалось создать папку «' .. name .. '».') end
    local stamp = os.date('%Y-%m-%d_%H-%M-%S')
    local dest, n = dir .. '\\' .. stamp .. '.jpg', 1
    while fs.exists(dest) do
        n = n + 1
        dest = ('%s\\%s_%d.jpg'):format(dir, stamp, n)
    end
    if not fs.move(pending, dest) then return notify('Не удалось сохранить скриншот в папку «' .. name .. '».') end
    pending = nil
    pickWindow[0] = false
    notify('Скриншот сохранён: {4FA3FF}' .. dest:sub(#BASE_DIR + 2))
    refreshStats()
end

local function savePending(name)
    saveShot(name, cleanName(ffi.string(subName)))
end

local function sendTime()
    floodHit = false
    timeSentAt = os.clock()
    sampSendChat('/time')
    wait(cfg.delay)
end

local function takeShot(preDelay)
    if preDelay then wait(preDelay) end
    sendTime()
    if floodHit then
        wait(1600)
        sendTime()
    end
    ensureDir(BASE_DIR)
    return captureScreen(TEMP_FILE)
end

local function cmdShot()
    if busy then return end
    if pending then
        pickWindow[0] = true
        return notify('Сначала выбери папку для предыдущего скриншота.')
    end
    busy = true
    lua_thread.create(function()
        local ok, err = takeShot()
        busy = false
        if not ok then return notify('Не удалось сделать скриншот: ' .. err) end
        pending = TEMP_FILE
        pcall(syncFolders)
        pickWindow[0] = true
    end)
end

local function autoShot(folder)
    if busy or pending then return end
    local now = os.clock()
    if lastAuto[folder] and now - lastAuto[folder] < 6 then return end
    lastAuto[folder] = now
    busy = true
    lua_thread.create(function()
        local ok, err = takeShot(1700)
        busy = false
        if not ok then return notify('Не удалось сделать автоскриншот: ' .. err) end
        pending = TEMP_FILE
        addCategory(folder)
        saveShot(folder, '')
    end)
end

local function openPath(path)
    fs.open(path)
end

local function openFolder(path)
    ensureDir(path)
    openPath(path)
end

local function buildReport()
    refreshStats()
    local lines = {}
    local function add(text) lines[#lines + 1] = text end

    add('Отчёт за неделю ' .. weekFolder())
    add(myNick())
    add('')
    add('Онлайн за неделю (по счётчику TimeShot): ' .. formatDuration(weekOnline(cfg.online)))
    add('Из них с 8:00 до 22:00: ' .. formatDuration(weekOnline(cfg.onlineClean)))
    add('')

    local listed = {}
    local function section(name)
        if listed[name] then return end
        listed[name] = true
        local cat = stats.cats[name]
        add(('%s — %d скр.'):format(name, cat and cat.week or 0))
        if cat then
            table.sort(cat.files)
            for i, file in ipairs(cat.files) do add(('  %d. %s — '):format(i, file)) end
        end
        add('')
    end
    for _, name in ipairs(cfg.categories) do section(name) end
    local extra = {}
    for name in pairs(stats.cats) do extra[#extra + 1] = name end
    table.sort(extra)
    for _, name in ipairs(extra) do section(name) end

    local dir = rootDir()
    ensureDir(dir)
    local path = dir .. '\\Отчёт.txt'
    if not fs.write(path, '\239\187\191' .. table.concat(lines, '\r\n')) then
        return notify('Не удалось записать файл отчёта.')
    end
    openPath(path)
    notify('Отчёт собран: {4FA3FF}' .. path:sub(#BASE_DIR + 2))
end

local function upcomingSlots()
    local t = os.date('*t')
    local first = os.time({ year = t.year, month = t.month, day = t.day, hour = t.hour, min = 5, sec = 0 }) + 3600
    local list = {}
    for i = 0, 5 do list[#list + 1] = first + i * 600 end
    return list
end

local function slotOwner(slot)
    for _, entry in ipairs(cfg.slots) do
        if entry.t == slot then return entry.nick end
    end
end

local function nearestFreeSlot()
    for _, slot in ipairs(upcomingSlots()) do
        if not slotOwner(slot) then return slot end
    end
end

local function govReadyAt()
    local gov = cfg.gov
    return math.max((gov.lastOther or 0) + 20 * 60, (gov.lastOwn or 0) + 30 * 60, (gov.lastOwnNews or 0) + 5 * 60)
end

local function rememberSlot(nick, hour, minute)
    local now, t = os.time(), os.date('*t')
    local slot = os.time({ year = t.year, month = t.month, day = t.day, hour = hour, min = minute, sec = 0 })
    if slot < now - 3600 then slot = slot + 86400 end
    local kept = {}
    for _, entry in ipairs(cfg.slots) do
        if type(entry) == 'table' and type(entry.t) == 'number' and entry.t > now - 3600 and entry.t ~= slot then
            kept[#kept + 1] = entry
        end
    end
    kept[#kept + 1] = { t = slot, nick = nick }
    cfg.slots = kept
end

local function sendRadio(target, text)
    if cfg.ownTag == '' then
        notify('Сначала выбери свой тег: /tmenu, вкладка «Гос».')
        return false
    end
    local message = cp(('/d [%s] - [%s]: %s'):format(cfg.ownTag, target, text))
    if #message > 128 then
        notify('Слишком длинное сообщение для рации.')
        return false
    end
    lua_thread.create(function() sampSendChat(message) end)
    return true
end

local booking = { place = new.char[96](), slot = nil, step = 0, startedAt = 0, status = '', ok = false, input = '' }

function booking.fail(reason)
    booking.step, booking.ok = 0, false
    booking.status = 'не получилось: ' .. reason
    notify('Собеседование не назначено: ' .. reason .. '. Окно оставил открытым — можно закончить вручную.')
    return nil
end

function booking.start()
    local place = ffi.string(booking.place):gsub('^%s+', ''):gsub('%s+$', '')
    if not booking.slot then return notify('Нет свободного слота на следующий час.') end
    local length = #cp(place)
    if length < 2 or length > 20 then
        return notify('Место собеседования: от 2 до 20 символов, сейчас ' .. length .. '.')
    end
    if sampIsDialogActive() then return notify('Сначала закрой открытое окно.') end
    if place ~= cfg.interviewPlace then
        cfg.interviewPlace = place
        saveConfig()
    end
    local t = os.date('*t', booking.slot)
    booking.input = cp(('%02d,%02d,%s'):format(t.hour, t.min, place))
    booking.step, booking.startedAt, booking.ok = 1, os.clock(), false
    booking.status = 'открываю /lmenu…'
    lua_thread.create(function() sampSendChat('/lmenu') end)
end

function booking.dialog(dialogId, style, text)
    if booking.step == 0 then return nil end
    if os.clock() - booking.startedAt > (booking.step == 4 and 2.5 or 8) then
        booking.step = 0
        return nil
    end
    local clean = text:gsub('{%x%x%x%x%x%x}', '')

    if booking.step == 4 then
        if style == 0 and not booking.ok then
            local line = clean:match('[^\r\n]+') or ''
            if line ~= '' then booking.status = 'ответ сервера: ' .. u8(line:sub(1, 110)) end
        end
        sampSendDialogResponse(dialogId, 0, 0, '')
        booking.step = 0
        return false
    end

    if style == 1 or style == 3 then
        sampSendDialogResponse(dialogId, 1, 0, booking.input)
        booking.step, booking.startedAt = 4, os.clock()
        booking.status = 'отправил время и место, жду ответа…'
        return false
    end

    local wanted = booking.step == 1 and PATTERN.lmenuInterviews or PATTERN.lmenuAssign
    local number = 0
    for line in clean:gmatch('[^\r\n]+') do
        number = number + 1
        local index = number - (style == 5 and 2 or 1)
        if index >= 0 and line:find(wanted, 1, true) then
            sampSendDialogResponse(dialogId, 1, index, line)
            booking.step, booking.startedAt = booking.step + 1, os.clock()
            return false
        end
    end
    return booking.fail(booking.step == 1 and 'в /lmenu не нашёлся пункт «Собеседования»'
        or 'не нашёлся пункт «Назначить собеседование»')
end

function booking.message(clean)
    if booking.status == '' or os.clock() - booking.startedAt > 10 then return end
    if clean:find(PATTERN.slotTaken, 1, true) then
        booking.ok, booking.status = false, 'на это время уже кто-то назначил собеседование'
        return
    end
    local problem = clean:match(PATTERN.serverError)
    if problem and booking.step ~= 0 then
        booking.ok, booking.status = false, 'ошибка: ' .. u8(problem:sub(1, 110))
        return
    end
    local nick, hour, minute = clean:match(PATTERN.interview)
    if nick and nick == myNick() then
        booking.ok, booking.status = true, ('назначено на %s:%s'):format(hour, minute)
    end
end

local function parseMemberLine(line)
    local color = line:match('^%s*{(%x%x%x%x%x%x)}')
    local you = line:find(PATTERN.you) ~= nil
    local clean = line:gsub('{%x%x%x%x%x%x}', ''):gsub(PATTERN.you, '')
    local who, id, rest = clean:match('^%s*(.-)%((%d+)%)%s*(.*)$')
    if not who then return nil end
    local nick = who:match('([%w_]+)%s*$')
    local rank, rankNumber = rest:match('^([^%(]+)%((%d+)%)')
    if not nick or not rank then return nil end
    local warns, afkTime = rest:match('(%d+)%s*%[%d+%]%s*/%s*(%d+)')
    return {
        nick = nick,
        id = tonumber(id),
        rank = u8((rank:gsub('^%s+', ''):gsub('%s+$', ''))),
        rankNumber = tonumber(rankNumber),
        warns = tonumber(warns) or 0,
        afk = tonumber(afkTime) or 0,
        working = color == nil or color:upper() == '90EE90',
        you = you,
    }
end

local function requestMembers()
    if sampGetGamestate() ~= 3 then return end
    members.waiting, members.collecting = true, {}
    members.requestAt, members.lastRequest = os.clock(), os.time()
    sampSendChat('/members')
end

function sampev.onShowDialog(dialogId, style, title, button1, button2, text)
    if booking.step ~= 0 then
        local handled = booking.dialog(dialogId, style, text)
        if handled ~= nil then return handled end
    end
    if not members.waiting or os.clock() - members.requestAt > 5 then return end
    local cleanTitle = title:gsub('{%x%x%x%x%x%x}', '')
    if not (cleanTitle:find(PATTERN.membersTitle) or cleanTitle:find(PATTERN.membersTitleAlt, 1, true)) then
        if os.clock() - members.requestAt < 2 then
            members.waiting = false
            members.misses = members.misses + 1
            if members.misses >= 2 and cfg.members then
                cfg.members = false
                saveConfig()
                notify('Не удалось распознать окно /members — чекер состава выключен.')
            end
        end
        return
    end

    local count, nextIndex = 0, nil
    for line in text:gmatch('[^\r\n]+') do
        count = count + 1
        if line:find(PATTERN.nextPage, 1, true) then
            nextIndex = count - 2
        else
            local member = parseMemberLine(line)
            if member then members.collecting[#members.collecting + 1] = member end
        end
    end
    if nextIndex then
        members.requestAt = os.clock()
        sampSendDialogResponse(dialogId, 1, nextIndex, '')
        return false
    end

    sampSendDialogResponse(dialogId, 0, 0, '')
    table.sort(members.collecting, function(a, b)
        if a.rankNumber ~= b.rankNumber then return a.rankNumber > b.rankNumber end
        return a.nick < b.nick
    end)
    local me = myNick()
    for _, member in ipairs(members.collecting) do
        if (member.you or member.nick == me) and member.rank ~= cfg.myRank then
            cfg.myRank = member.rank
            stateDirty = true
        end
    end
    members.list, members.collecting = members.collecting, {}
    members.waiting, members.misses, members.at = false, 0, os.time()
    members.fraction = u8((cleanTitle:match('^(.-)%s*%(') or ''))
    return false
end

function sampev.onServerMessage(color, text)
    local clean = text:gsub('{%x%x%x%x%x%x}', '')

    if clean:find('^%[D%]') then
        local me = myNick()
        local prefix = me ~= '' and clean:match('^%[D%]%s*(.-)%s*' .. me .. '%[')
        if prefix then
            prefix = prefix:gsub('^%[.-%]%s*', '')
            if prefix ~= '' and u8(prefix) ~= cfg.myRank then
                cfg.myRank = u8(prefix)
                stateDirty = true
            end
        end
    end

    if os.clock() - timeSentAt < 2 and clean:find(PATTERN.flood, 1, true) then floodHit = true end
    booking.message(clean)

    local nick, tag = clean:match(PATTERN.radio)
    if nick then nickTags[nick] = tag end

    nick = clean:match(PATTERN.gov)
    if nick then
        local own = nick == myNick() or (cfg.ownTag ~= '' and nickTags[nick] == cp(cfg.ownTag))
        cfg.gov[own and 'lastOwn' or 'lastOther'] = os.time()
        cfg.gov.lastNick = nick
        cfg.gov.lastWasOwn = own
        stateDirty = true
        return
    end

    local hour, minute
    nick, hour, minute = clean:match(PATTERN.interview)
    if nick then
        rememberSlot(nick, tonumber(hour), tonumber(minute))
        if nick == myNick() then cfg.gov.lastOwnNews = os.time() end
        stateDirty = true
        return
    end

    if not cfg.autoStaff then return end
    local rank
    nick = clean:match(PATTERN.invited)
    if nick then
        journal(cp('Принят в организацию: ') .. nick)
        autoShot(findCategory('Инвайт', 'Инвайты'))
        return
    end
    nick, rank = clean:match(PATTERN.promoted)
    if nick then
        journal(cp('Повышен: ') .. nick .. cp(' до ') .. rank .. cp(' ранга'))
        autoShot(findCategory('Повыш', 'Повышения'))
        return
    end
    nick, rank = clean:match(PATTERN.demoted)
    if nick then
        journal(cp('Понижен: ') .. nick .. cp(' до ') .. rank .. cp(' ранга'))
        autoShot(findCategory('Повыш', 'Повышения'))
    end
end

function sampev.onSendCommand(command)
    local name, args = command:match('^/(%S+)%s*(.*)$')
    if not name then return end
    name = name:lower()

    local folder
    if cfg.autoStaff and name == 'uninvite' then
        folder = findCategory('Увол', 'Увольнения')
    elseif cfg.autoStaff and name == 'giverank' then
        folder = findCategory('Повыш', 'Повышения')
    elseif (cfg.autoPunish and PUNISH_COMMANDS[name]) or (cfg.autoJustice and JUSTICE_COMMANDS[name]) then
        folder = findCategory('Наказ', 'Наказания')
    elseif not (cfg.autoStaff and name == 'invite') then
        return
    end

    local line = cp('Команда: ') .. command
    local id = tonumber(args:match('^(%d+)'))
    if id and sampIsPlayerConnected(id) then line = line .. ' (' .. sampGetPlayerNickname(id) .. ')' end
    journal(line)
    if folder then autoShot(folder) end
end

local function deadlineDay()
    local list = weekDates()
    return list[7] == os.date('%Y-%m-%d')
end

local function remindDeadline()
    refreshStats()
    notify('Сегодня сдача отчёта — до {FF6E6E}23:59{FFFFFF}. Собрать текст: /tmenu, вкладка «Отчёт».')
    local summary = 'Скриншотов за неделю:'
    for i, name in ipairs(cfg.categories) do
        local part = (i > 1 and ', ' or ' ') .. name .. ' ' .. weekCount(name)
        if #summary + #part > 190 then break end
        summary = summary .. part
    end
    notify(summary)
end

local term = { input = new.char[16]() }

function term.start()
    local day, month, year = cfg.termStart:match('^%s*(%d+)%.(%d+)%.(%d+)%s*$')
    if not day then return nil end
    day, month, year = tonumber(day), tonumber(month), tonumber(year)
    if year < 100 then year = year + 2000 end
    if month < 1 or month > 12 or day < 1 or day > 31 or year < 2020 or year > 2100 then return nil end
    return os.time({ year = year, month = month, day = day, hour = 12 })
end

function term.info()
    local start = term.start()
    if not start then return nil end
    local now = os.date('*t')
    local today = os.time({ year = now.year, month = now.month, day = now.day, hour = 12 })
    local passed = math.floor((today - start) / 86400 + 0.5)
    local total = cfg.termDays + cfg.termExtra
    return {
        start = start,
        passed = passed,
        day = passed + 1,
        total = total,
        left = total - passed,
        finish = start + total * 86400,
    }
end

function term.remind()
    local info = term.info()
    if not info or info.left > 5 or info.left < 0 then return end
    notify(('До конца срока на посту {FF6E6E}%d дн.{FFFFFF} (до %s). Запрос на продление подаётся не позднее %s.'):format(
        info.left, os.date('%d.%m', info.finish), os.date('%d.%m', info.finish - 3 * 86400)))
end

local update = {
    versionUrl = 'https://raw.githubusercontent.com/a-faction/timeshot/main/version.json',
    scriptUrl = 'https://raw.githubusercontent.com/a-faction/timeshot/main/moonloader/TimeShot.lua',
    infoPath = getWorkingDirectory() .. '\\config\\TimeShot_version.json',
    filePath = getWorkingDirectory() .. '\\config\\TimeShot_update.lua',
    stage = nil,
    manual = false,
    latest = nil,
    notes = '',
    status = 'ещё не проверялось',
    waiting = false,
    startedAt = 0,
    checkedAt = 0,
}

function update.number(version)
    local major, minor, patch = tostring(version):match('^(%d+)%.(%d+)%.?(%d*)')
    return (tonumber(major) or 0) * 1000000 + (tonumber(minor) or 0) * 1000 + (tonumber(patch) or 0)
end

function update.current()
    return tostring(thisScript().version)
end

function update.download(url, path, stage)
    os.remove(path)
    update.waiting, update.startedAt = true, os.clock()
    local status = require('moonloader').download_status
    downloadUrlToFile(url .. '?t=' .. os.time(), path, function(_, code)
        if code == status.STATUS_ENDDOWNLOADDATA then update.stage = stage end
    end)
end

function update.check(manual)
    update.manual = manual
    update.status = 'проверяю…'
    update.download(update.versionUrl, update.infoPath, 'info')
end

function update.readInfo()
    local f = io.open(update.infoPath, 'r')
    if not f then return nil end
    local ok, info = pcall(decodeJson, f:read('*a'))
    f:close()
    os.remove(update.infoPath)
    if ok and type(info) == 'table' and info.version then return info end
end

function update.install()
    local f = io.open(update.filePath, 'rb')
    if not f then return false end
    local body = f:read('*a')
    f:close()
    os.remove(update.filePath)

    local version = body:match("script_version%('([%d%.]+)'%)")
    if #body < 20000 or not body:find("script_name('TimeShot')", 1, true) or not version
        or update.number(version) <= update.number(update.current()) then
        return false
    end

    local path = thisScript().path
    local current = io.open(path, 'rb')
    if current then
        local backup = io.open(path .. '.bak', 'wb')
        if backup then
            backup:write(current:read('*a'))
            backup:close()
        end
        current:close()
    end
    local target = io.open(path, 'wb')
    if not target then return false end
    target:write(body)
    target:close()
    return true, version
end

function update.process()
    local stage = update.stage
    if not stage then
        if update.waiting and os.clock() - update.startedAt > 20 then
            update.waiting = false
            update.status = 'не удалось связаться с GitHub'
            if update.manual then notify('Не удалось проверить обновления: нет ответа от GitHub.') end
        end
        return
    end
    update.stage, update.waiting, update.checkedAt = nil, false, os.time()

    if stage == 'info' then
        local info = update.readInfo()
        if not info then
            update.status = 'не удалось прочитать данные о версии'
            if update.manual then notify('Не удалось проверить обновления.') end
            return
        end
        update.latest = tostring(info.version)
        update.notes = type(info.notes) == 'string' and info.notes or ''
        if update.number(update.latest) <= update.number(update.current()) then
            update.status = 'установлена последняя версия'
            if update.manual then notify('Установлена последняя версия — ' .. update.current() .. '.') end
            return
        end
        if cfg.autoUpdate or update.manual then
            update.status = 'скачиваю версию ' .. update.latest
            notify('Найдена версия {4FA3FF}' .. update.latest .. '{FFFFFF}, скачиваю.')
            update.download(update.scriptUrl, update.filePath, 'file')
        else
            update.status = 'доступна версия ' .. update.latest
            notify('Доступна версия {4FA3FF}' .. update.latest .. '{FFFFFF}. Обновить: /tupdate')
        end
        return
    end

    local ok, version = update.install()
    if not ok then
        update.status = 'файл обновления не прошёл проверку'
        return notify('Файл обновления не прошёл проверку, оставляю текущую версию.')
    end
    notify('Обновлено до версии {4FA3FF}' .. version .. '{FFFFFF}'
        .. (update.notes ~= '' and (': ' .. update.notes) or '.') .. ' Перезагружаюсь.')
    saveConfig()
    thisScript():reload()
end

local function tick()
    local now = os.time()
    local delta = now - lastTick
    lastTick = now
    if delta > 0 and delta <= 5 and sampGetGamestate() == 3 then
        local day = os.date('%Y-%m-%d')
        local hour = tonumber(os.date('%H'))
        cfg.online[day] = (cfg.online[day] or 0) + delta
        if hour >= 8 and hour < 22 then cfg.onlineClean[day] = (cfg.onlineClean[day] or 0) + delta end
    end

    update.process()
    if booking.step ~= 0 and os.clock() - booking.startedAt > (booking.step == 4 and 2.5 or 8) then
        if booking.step < 4 then booking.status = 'сервер не открыл /lmenu' end
        booking.step = 0
    end

    if cfg.interviewRemind then
        local me = myNick()
        for _, entry in ipairs(cfg.slots) do
            if type(entry) == 'table' and entry.nick == me and type(entry.t) == 'number' then
                local left = entry.t - now
                local text
                if left <= 300 and left > 0 and not entry.soon then
                    entry.soon = true
                    text = ('Через %d мин твоё собеседование — в {4FA3FF}%s{FFFFFF}.'):format(
                        math.ceil(left / 60), os.date('%H:%M', entry.t))
                elseif left <= 0 and left > -180 and not entry.started then
                    entry.started = true
                    text = 'Собеседование началось. Сделай скриншот с /time: {4FA3FF}/t{FFFFFF}, папка «Собеседование».'
                end
                if text then
                    stateDirty = true
                    notify(text)
                    pcall(function() ffi.load('winmm').PlaySoundA('SystemAsterisk', nil, 0x10001) end)
                end
            end
        end
    end

    ticks = ticks + 1
    if ticks % 60 == 0 then
        refreshStats()
        saveConfig()
        stateDirty = false
    elseif stateDirty and ticks % 5 == 0 then
        saveConfig()
        stateDirty = false
    end

    if cfg.members and now - members.lastRequest >= cfg.membersInterval and not busy and not pending and not binder.running
        and booking.step == 0
        and not sampIsDialogActive() and not sampIsChatInputActive() and not isPauseMenuActive() then
        requestMembers()
    end

    local hour = tonumber(os.date('%H'))
    if (hour == 20 or hour == 22) and deadlineDay() then
        local key = os.date('%Y-%m-%d ') .. hour
        if lastReminder ~= key then
            lastReminder = key
            remindDeadline()
        end
    end
end

local function afkTick()
    local away = isPauseMenuActive() or ffi.C.GetForegroundWindow() ~= gameWindow
    if not away or not cfg.afkWarn then
        afk.since, afk.warned = nil, 0
        return
    end
    afk.since = afk.since or os.time()
    local elapsed = os.time() - afk.since
    if (elapsed >= 480 and afk.warned < 1) or (elapsed >= 540 and afk.warned < 2) then
        afk.warned = afk.warned + 1
        ffi.load('winmm').PlaySoundA('SystemExclamation', nil, 0x10001)
        ffi.C.FlashWindow(gameWindow, 1)
    end
end

local LOWER_MAP = {}
do
    local lower = {}
    for ch in ('абвгдеёжзийклмнопрстуфхцчшщъыьэюя'):gmatch('[\208\209][\128-\191]') do lower[#lower + 1] = ch end
    local i = 0
    for ch in ('АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ'):gmatch('[\208\209][\128-\191]') do
        i = i + 1
        LOWER_MAP[ch] = lower[i]
    end
end

local function lowerRu(s)
    return (s:lower():gsub('[\208\209][\128-\191]', LOWER_MAP))
end

local INLINE_RULES = {
    { pattern = '%*%*(.-)%*%*', style = 'bold' },
    { pattern = '`(.-)`', style = 'code' },
    { pattern = '%*([^%*%s][^%*]-)%*', style = 'italic' },
}

local function stripInline(text)
    return (text:gsub('%*%*(.-)%*%*', '%1'):gsub('`(.-)`', '%1'):gsub('%*([^%*%s][^%*]-)%*', '%1'))
end

local function parseInline(text)
    local segments, pos = {}, 1
    while pos <= #text do
        local best
        for _, rule in ipairs(INLINE_RULES) do
            local s, e, inner = text:find(rule.pattern, pos)
            if s and (not best or s < best.s) then best = { s = s, e = e, inner = inner, style = rule.style } end
        end
        if not best then break end
        if best.s > pos then segments[#segments + 1] = { text = text:sub(pos, best.s - 1), style = 'normal' } end
        if best.inner ~= '' then segments[#segments + 1] = { text = best.inner, style = best.style } end
        pos = best.e + 1
    end
    if pos <= #text then segments[#segments + 1] = { text = text:sub(pos), style = 'normal' } end
    return segments
end

local function tokenize(text)
    local tokens, glue = {}, false
    for _, segment in ipairs(parseInline(text)) do
        local pos = 1
        while true do
            local s, e = segment.text:find('%S+', pos)
            if not s then
                if pos <= #segment.text then glue = true end
                break
            end
            if s > pos then glue = true end
            local word, style = segment.text:sub(s, e), segment.style
            if style == 'normal' and word:find('^#[^%s%p]') then style = 'tag' end
            tokens[#tokens + 1] = { text = word, style = style, space = glue }
            glue = false
            pos = e + 1
        end
    end
    return tokens
end

local function parseMarkdown(text)
    local blocks, inCode = {}, false
    local function content(kind, body, marker, indent)
        local block = { kind = kind, marker = marker, indent = indent }
        if body:find('[%*`]') or (' ' .. body):find('%s#[^%s%p]') then
            block.tokens = tokenize(body)
        else
            block.text = body
        end
        blocks[#blocks + 1] = block
    end
    for line in (text .. '\n'):gmatch('(.-)\n') do
        local trimmed = line:gsub('%s+$', '')
        if trimmed:find('^```') then
            inCode = not inCode
        elseif inCode then
            blocks[#blocks + 1] = { kind = 'code', text = line }
        elseif trimmed == '' then
            blocks[#blocks + 1] = { kind = 'blank' }
        elseif trimmed:find('^%-%-%-+$') or trimmed:find('^%*%*%*+$') then
            blocks[#blocks + 1] = { kind = 'rule' }
        else
            local level, heading = trimmed:match('^(#+)%s+(.*)$')
            local bullet = trimmed:match('^%s*[%-%*]%s+(.*)$')
            local number, numbered = trimmed:match('^%s*(%d+[%.%)])%s+(.*)$')
            local quote = trimmed:match('^>%s?(.*)$')
            if level then
                blocks[#blocks + 1] = { kind = 'heading', level = math.min(#level, 3), text = stripInline(heading) }
            elseif bullet then
                content('bullet', bullet, '•', 18)
            elseif number then
                content('bullet', numbered, number, 30)
            elseif quote then
                content('quote', quote, nil, 14)
            else
                content('text', trimmed)
            end
        end
    end
    return blocks
end

local function isUtf8(s)
    local i, n = 1, #s
    while i <= n do
        local c = s:byte(i)
        local len = c < 0x80 and 1 or (c >= 0xC2 and c < 0xE0) and 2 or (c >= 0xE0 and c < 0xF0) and 3
            or (c >= 0xF0 and c < 0xF5) and 4 or 0
        if len == 0 then return false end
        for j = i + 1, i + len - 1 do
            local b = s:byte(j)
            if not b or b < 0x80 or b > 0xBF then return false end
        end
        i = i + len
    end
    return true
end

local function setBuffer(buffer, text)
    ffi.fill(buffer, ffi.sizeof(buffer))
    ffi.copy(buffer, text, math.min(#text, ffi.sizeof(buffer) - 1))
end

local function notePath(name)
    return NOTES_DIR .. '\\' .. name .. '.txt'
end

local function readNote(name)
    local text = fs.read(notePath(name))
    if not text then return nil end
    if text:sub(1, 3) == '\239\187\191' then text = text:sub(4) end
    if not isUtf8(text) then text = u8(text) end
    return (text:gsub('\r\n', '\n'))
end

local function refreshNotes()
    local list, tagSet = {}, {}
    for _, entry in ipairs(listDir(NOTES_DIR)) do
        local fileName = entry.name:match('^(.+)%.[tT][xX][tT]$')
        if fileName and not entry.isDir then
            local name = fileName
            local text = readNote(name) or ''
            local note = { name = name, hay = lowerRu(name .. '\n' .. text), tags = {} }
            for tag in (' ' .. text:gsub('\n', ' \n ')):gmatch('%s(#[^%s%p]+)') do
                tag = lowerRu(tag)
                note.tags[tag] = true
                tagSet[tag] = true
            end
            list[#list + 1] = note
        end
    end
    table.sort(list, function(a, b) return a.hay < b.hay end)
    local tags = {}
    for tag in pairs(tagSet) do tags[#tags + 1] = tag end
    table.sort(tags)
    table.insert(tags, 1, 'Все')
    ns.list, ns.tags = list, tags
    if ns.tag and not tagSet[ns.tag] then ns.tag = nil end
end

local function openNote(name)
    local text = readNote(name)
    if not text then
        notify('Не удалось открыть заметку «' .. name .. '».')
        return refreshNotes()
    end
    ns.current, ns.editing, ns.confirm, ns.view = name, false, false, text
    ns.doc = parseMarkdown(text)
    ns.cursor.pos, ns.cursor.s, ns.cursor.e = #text, #text, #text
    setBuffer(ns.title, name)
    setBuffer(ns.text, text)
    if #text >= ffi.sizeof(ns.text) then notify('Заметка длиннее 64 КБ — в редакторе она обрезана, не сохраняй её отсюда.') end
end

local function newNote()
    ns.current, ns.editing, ns.confirm, ns.view = nil, true, false, ''
    ns.cursor.pos, ns.cursor.s, ns.cursor.e = 0, 0, 0
    setBuffer(ns.title, '')
    setBuffer(ns.text, '')
end

local function saveNote()
    local name = cleanName(ffi.string(ns.title))
    if name == '' then return notify('Введи название заметки.') end
    if name ~= ns.current and fs.exists(notePath(name)) then
        return notify('Заметка с таким названием уже есть.')
    end
    if not ensureDir(NOTES_DIR) then return notify('Не удалось создать папку заметок.') end
    local text = ffi.string(ns.text)
    if not fs.write(notePath(name), (text:gsub('\n', '\r\n'))) then return notify('Не удалось сохранить заметку.') end
    if ns.current and ns.current ~= name then fs.remove(notePath(ns.current)) end
    ns.current, ns.editing, ns.confirm, ns.view = name, false, false, text
    ns.doc = parseMarkdown(text)
    refreshNotes()
end

local function deleteNote()
    if ns.current then fs.remove(notePath(ns.current)) end
    ns.current, ns.editing, ns.confirm, ns.view = nil, false, false, ''
    refreshNotes()
end

local function takeAvatar(reopenMenu)
    if busy or pending then return notify('Сначала закончи со скриншотом.') end
    busy = true
    lua_thread.create(function()
        wait(450)
        local x, y, z = getCharCoordinates(PLAYER_PED)
        local centerX, top = convert3DCoordsToScreen(x, y, z + 1.0)
        local _, bottom = convert3DCoordsToScreen(x, y, z - 0.1)
        local size = math.floor(math.max(96, math.abs(bottom - top)))
        local crop = { x = math.floor(centerX - size / 2), y = math.floor(math.min(top, bottom)), size = size }
        local ok, err = captureScreen(avatar.path, crop)
        busy = false
        if ok then
            avatar.dirty = true
            notify('Аватар обновлён.')
        else
            notify('Не удалось снять аватар: ' .. tostring(err))
        end
        if reopenMenu then menuWindow[0] = true end
    end)
end

local RESERVED_COMMANDS = { t = true, tmenu = true, td = true, tn = true, tnotes = true, tstop = true, tavatar = true,
    tupdate = true }

local function expandBindLine(line, extra)
    local nick = myNick()
    local _, id = sampGetPlayerIdByCharHandle(PLAYER_PED)
    local values = {
        nick = (nick:gsub('_', ' ')),
        id = tostring(id or ''),
        rank = cfg.myRank,
        tag = cfg.ownTag,
        time = os.date('%H:%M'),
        date = os.date('%d.%m.%Y'),
    }
    for key, value in pairs(extra or {}) do values[key] = value end
    return (line:gsub('{(%a+)}', function(key) return values[key] end))
end

local function splitBindLine(line, limit)
    if #line <= limit then return { line } end
    local prefix = line:match('^(/%S+%s+)') or ''
    local parts, current = {}, prefix
    for word in line:sub(#prefix + 1):gmatch('%S+') do
        if current ~= prefix and #current + #word + 1 > limit then
            parts[#parts + 1] = current
            current = prefix .. word
        elseif current == prefix then
            current = prefix .. word
        else
            current = current .. ' ' .. word
        end
    end
    if current ~= prefix then parts[#parts + 1] = current end
    return parts
end

local function bindLines(bind, extra)
    local lines = {}
    for raw in (bind.text .. '\n'):gmatch('(.-)\r?\n') do
        local line = raw:gsub('^%s+', ''):gsub('%s+$', '')
        if line ~= '' and line:sub(1, 2) ~= '//' then
            for _, part in ipairs(splitBindLine(cp(expandBindLine(line, extra)), 115)) do lines[#lines + 1] = part end
        end
    end
    return lines
end

local function runBind(bind, extra)
    if binder.running then
        return notify('Уже идёт бинд «' .. binder.name .. '». Остановить: /tstop')
    end
    if not extra and (bind.text:find('{tid}', 1, true) or bind.text:find('{tname}', 1, true)) then
        return notify('Бинд «' .. bind.name .. '» работает с игроком рядом — запускай его из кругового меню.')
    end
    local lines = bindLines(bind, extra)
    if #lines == 0 then return notify('В бинде «' .. bind.name .. '» нет строк.') end
    local delay = math.max(tonumber(bind.delay) or 2500, 500)
    binder.running, binder.stop, binder.name, binder.index, binder.total = true, false, bind.name, 0, #lines
    lua_thread.create(function()
        for i, line in ipairs(lines) do
            if binder.stop then break end
            binder.index = i
            sampSendChat(line)
            if i < #lines then
                local resume = os.clock() + delay / 1000
                while os.clock() < resume and not binder.stop do wait(50) end
            end
        end
        if not binder.stop then wait(1200) end
        notify(binder.stop and 'Бинд остановлен.' or ('Бинд «' .. bind.name .. '» завершён.'))
        binder.running = false
    end)
end

local function registerBinds()
    for _, command in ipairs(binder.commands) do sampUnregisterChatCommand(command) end
    binder.commands = {}
    for _, bind in ipairs(cfg.binds) do
        if type(bind) == 'table' and type(bind.cmd) == 'string' and bind.cmd ~= '' and not RESERVED_COMMANDS[bind.cmd] then
            sampRegisterChatCommand(bind.cmd, function() runBind(bind) end)
            binder.commands[#binder.commands + 1] = bind.cmd
        end
    end
end

local function selectBind(index)
    local bind = cfg.binds[index]
    bs.index, bs.confirm = index, false
    setBuffer(bs.name, bind.name or '')
    setBuffer(bs.command, bind.cmd or '')
    setBuffer(bs.text, bind.text or '')
    bs.delay[0] = tonumber(bind.delay) or 2500
    bs.key = tonumber(bind.key) or 0
    bs.wheel[0] = bind.wheel == true
end

local function newBind()
    bs.index, bs.confirm = nil, false
    setBuffer(bs.name, '')
    setBuffer(bs.command, '')
    setBuffer(bs.text, '')
    bs.delay[0] = 2500
    bs.key = 0
    bs.wheel[0] = false
end

local function saveBind()
    local name = ffi.string(bs.name):gsub('^%s+', ''):gsub('%s+$', '')
    local command = ffi.string(bs.command):gsub('%s', ''):gsub('^/+', ''):lower()
    if name == '' then
        notify('Введи название бинда.')
        return false
    end
    if command ~= '' and not command:match('^[%w_]+$') then
        notify('Команда бинда: только латиница, цифры и «_».')
        return false
    end
    if RESERVED_COMMANDS[command] then
        notify('Команда /' .. command .. ' занята самим скриптом.')
        return false
    end
    for i, other in ipairs(cfg.binds) do
        if i ~= bs.index and command ~= '' and other.cmd == command then
            notify('Команда /' .. command .. ' уже у бинда «' .. tostring(other.name) .. '».')
            return false
        end
    end
    local bind = { name = name, cmd = command, delay = bs.delay[0], text = ffi.string(bs.text), key = bs.key or 0,
        wheel = bs.wheel[0] }
    if bs.index then
        cfg.binds[bs.index] = bind
    else
        cfg.binds[#cfg.binds + 1] = bind
        bs.index = #cfg.binds
    end
    setBuffer(bs.command, command)
    saveConfig()
    registerBinds()
    return true
end

local function deleteBind()
    if bs.index then
        table.remove(cfg.binds, bs.index)
        saveConfig()
        registerBinds()
    end
    newBind()
end

local wheel = { open = new.bool(false), target = nil, targets = {}, index = 1, items = {}, prompt = nil, rank = new.int(1),
    reason = new.char[64]() }

function wheel.findTargets()
    local list, seen = {}, {}
    local aimed, ped = getCharPlayerIsTargeting(PLAYER_HANDLE)
    if aimed and ped then
        local found, id = sampGetPlayerIdByCharHandle(ped)
        if found then
            list[1] = { id = id, nick = sampGetPlayerNickname(id), distance = -1 }
            seen[id] = true
        end
    end
    local mx, my, mz = getCharCoordinates(PLAYER_PED)
    for _, other in ipairs(getAllChars()) do
        if other ~= PLAYER_PED then
            local found, id = sampGetPlayerIdByCharHandle(other)
            if found and not seen[id] then
                local x, y, z = getCharCoordinates(other)
                local distance = getDistanceBetweenCoords3d(mx, my, mz, x, y, z)
                if distance <= 6 then
                    seen[id] = true
                    list[#list + 1] = { id = id, nick = sampGetPlayerNickname(id), distance = distance }
                end
            end
        end
    end
    table.sort(list, function(a, b) return a.distance < b.distance end)
    return list
end

function wheel.cycle(step)
    if #wheel.targets < 2 then return end
    wheel.index = (wheel.index - 1 + step) % #wheel.targets + 1
    wheel.target = wheel.targets[wheel.index]
end

function wheel.show()
    if wheel.open[0] then
        wheel.open[0] = false
        return
    end
    local items = {}
    for _, bind in ipairs(cfg.binds) do
        if type(bind) == 'table' and bind.wheel == true and #items < 8 then items[#items + 1] = bind end
    end
    if #items == 0 then return notify('В круговом меню пусто: отметь нужные бинды галочкой «В круговом меню».') end
    local targets = wheel.findTargets()
    if #targets == 0 then return notify('Круговое меню: рядом нет игрока — подойди ближе или наведи на него прицел.') end
    wheel.items, wheel.prompt = items, nil
    wheel.targets, wheel.index, wheel.target = targets, 1, targets[1]
    wheel.open[0] = true
end

function wheel.run(bind)
    local target = wheel.target
    wheel.open[0], wheel.prompt = false, nil
    runBind(bind, {
        tid = tostring(target.id),
        tname = (target.nick:gsub('_', ' ')),
        trank = tostring(wheel.rank[0]),
        reason = (ffi.string(wheel.reason):gsub('^%s+', ''):gsub('%s+$', '')),
    })
end

function wheel.choose(bind)
    local needRank = bind.text:find('{trank}', 1, true) ~= nil
    local needReason = bind.text:find('{reason}', 1, true) ~= nil
    if needRank or needReason then
        wheel.prompt = { bind = bind, rank = needRank, reason = needReason }
    else
        wheel.run(bind)
    end
end

local sens = { unit = 0.00001, memory = nil, startX = nil, startY = nil }

function sens.read()
    if not sens.memory then sens.memory = ffi.cast('float*', 0xB6EC18) end
    return sens.memory[1], sens.memory[0]
end

function sens.capture()
    local x, y = sens.read()
    sens.startX, sens.startY = x, y
    if cfg.sensX <= 0 then cfg.sensX = math.max(5, math.min(1000, math.floor(x / sens.unit + 0.5))) end
    if cfg.sensY <= 0 then cfg.sensY = math.max(5, math.min(1000, math.floor(y / sens.unit + 0.5))) end
end

function sens.apply()
    if not cfg.sens or not sens.startX then return end
    sens.memory[1] = cfg.sensX * sens.unit
    sens.memory[0] = cfg.sensY * sens.unit
end

function sens.restore()
    if sens.startX then sens.memory[1], sens.memory[0] = sens.startX, sens.startY end
end

local hotkeys = {
    capture = nil,
    seen = {},
    skipEscape = false,
    names = {
        [0x09] = 'Tab', [0x0D] = 'Enter', [0x20] = 'Пробел', [0x21] = 'PgUp', [0x22] = 'PgDn', [0x23] = 'End',
        [0x24] = 'Home', [0x25] = 'Влево', [0x26] = 'Вверх', [0x27] = 'Вправо', [0x28] = 'Вниз', [0x2D] = 'Insert',
        [0x6A] = 'Num*', [0x6B] = 'Num+', [0x6D] = 'Num-', [0x6E] = 'Num.', [0x6F] = 'Num/',
        [0xBA] = ';', [0xBB] = '=', [0xBC] = ',', [0xBD] = '-', [0xBE] = '.', [0xBF] = '/', [0xC0] = '`',
        [0xDB] = '[', [0xDC] = '\\', [0xDD] = ']', [0xDE] = "'",
        [0x01] = 'ЛКМ', [0x02] = 'ПКМ', [0x04] = 'СКМ', [0x05] = 'Мышь 4', [0x06] = 'Мышь 5',
    },
}

function hotkeys.name(code)
    code = tonumber(code) or 0
    if code == 0 then return 'не задана' end
    local key = code % 0x100
    local name = hotkeys.names[key]
    if not name then
        if (key >= 0x30 and key <= 0x39) or (key >= 0x41 and key <= 0x5A) then
            name = string.char(key)
        elseif key >= 0x70 and key <= 0x87 then
            name = 'F' .. (key - 0x6F)
        elseif key >= 0x60 and key <= 0x69 then
            name = 'Num' .. (key - 0x60)
        else
            name = 'клавиша ' .. key
        end
    end
    local flags = math.floor(code / 0x100)
    return (flags % 2 == 1 and 'Ctrl+' or '') .. (math.floor(flags / 2) % 2 == 1 and 'Alt+' or '')
        .. (math.floor(flags / 4) % 2 == 1 and 'Shift+' or '') .. name
end

function hotkeys.code(key, system)
    local function held(modifier) return ffi.C.GetKeyState(modifier) < 0 end
    return key + (held(0x11) and 0x100 or 0) + ((system or held(0x12)) and 0x200 or 0) + (held(0x10) and 0x400 or 0)
end

function hotkeys.assign(code)
    local target = hotkeys.capture
    hotkeys.capture = nil
    if target == 'bind' then
        bs.key = code
    elseif target then
        cfg.keys[target] = code
        saveConfig()
    end
end

function hotkeys.fire(code)
    if code == cfg.keys.menu then
        menuWindow[0] = not menuWindow[0]
        if menuWindow[0] then refreshStats() end
    end
    if code == cfg.keys.shot then cmdShot() end
    if code == cfg.keys.wheel then wheel.show() end
    if code == cfg.keys.radio then radioWindow[0] = true end
    for _, bind in ipairs(cfg.binds) do
        if type(bind) == 'table' and tonumber(bind.key) == code then
            runBind(bind)
            break
        end
    end
end

function hotkeys.message(msg, key, lparam)
    local pressed = msg == 0x100 or msg == 0x104
    local released = msg == 0x101 or msg == 0x105
    if not pressed and not released then return false end
    if released then
        local handled = hotkeys.seen[key]
        hotkeys.seen[key] = nil
        if handled then return false end
    else
        hotkeys.seen[key] = true
    end
    local alt = (msg == 0x104 or msg == 0x105) and bit.band(tonumber(lparam) or 0, 0x20000000) ~= 0
    if hotkeys.capture then
        if key == 0x10 or key == 0x11 or key == 0x12 or key == 0x5B or key == 0x5C or (key >= 0xA0 and key <= 0xA5) then
            return true
        end
        if key == 0x1B then
            hotkeys.capture, hotkeys.skipEscape = nil, true
        elseif key == 0x08 or key == 0x2E then
            hotkeys.assign(0)
        else
            hotkeys.assign(hotkeys.code(key, alt))
        end
        return true
    end
    if pressed and bit.band(tonumber(lparam) or 0, 0x40000000) ~= 0 then return false end
    if isPauseMenuActive() or sampIsChatInputActive() or sampIsDialogActive() then return false end
    if radioWindow[0] and cfg.keys.radio ~= 0 and hotkeys.code(key, alt) == cfg.keys.radio then
        radioWindow[0] = false
        return false
    end
    if pickWindow[0] or radioWindow[0] or (menuWindow[0] and inputActive) or wheel.prompt then return false end
    local code = hotkeys.code(key, alt)
    hotkeys.fire(code)
    if code == cfg.keys.menu then consumeWindowMessage(true, false) end
    return false
end


local function centerNextWindow()
    local sx, sy = getScreenResolution()
    imgui.SetNextWindowPos(imgui.ImVec2(sx / 2, sy / 2), imgui.Cond.Always, imgui.ImVec2(0.5, 0.5))
end

local function takeNewName()
    local text = ffi.string(newName)
    ffi.fill(newName, ffi.sizeof(newName))
    return text
end

local function rgba(r, g, b, a)
    return imgui.ImVec4(r / 255, g / 255, b / 255, a or 1)
end

local COLOR = {
    window = rgba(21, 22, 27, 0.96),
    panel = rgba(30, 32, 39),
    card = rgba(44, 47, 57),
    cardHover = rgba(58, 62, 75),
    cardActive = rgba(70, 75, 91),
    accent = rgba(255, 255, 255),
    accentHover = rgba(226, 229, 236),
    accentActive = rgba(200, 204, 214),
    text = rgba(255, 255, 255),
    dim = rgba(140, 144, 158),
    dark = rgba(21, 22, 27),
    border = rgba(255, 255, 255, 0.06),
    good = rgba(92, 214, 140),
    stripe = rgba(255, 255, 255, 0.035),
    danger = rgba(255, 92, 92),
    dangerHover = rgba(255, 92, 92, 0.14),
    dangerActive = rgba(255, 92, 92, 0.24),
    clear = rgba(0, 0, 0, 0),
    onAccent = rgba(21, 22, 27),
    sidebar = rgba(15, 16, 20, 0.98),
}

local BUTTON = {
    card = { COLOR.card, COLOR.cardHover, COLOR.cardActive, COLOR.text },
    primary = { COLOR.accent, COLOR.accentHover, COLOR.accentActive, COLOR.onAccent },
    danger = { COLOR.clear, COLOR.dangerHover, COLOR.dangerActive, COLOR.danger },
    nav = { COLOR.clear, COLOR.card, COLOR.cardHover, COLOR.dim },
}

local theme = {
    accents = {
        { 'Белый', 255, 255, 255 },
        { 'Синий', 79, 140, 255 },
        { 'Зелёный', 61, 201, 128 },
        { 'Фиолетовый', 155, 109, 255 },
        { 'Оранжевый', 255, 159, 67 },
        { 'Красный', 255, 71, 87 },
    },
}

function theme.apply()
    local preset = theme.accents[cfg.accent] or theme.accents[1]
    local r, g, b = preset[2] / 255, preset[3] / 255, preset[4] / 255
    COLOR.accent.x, COLOR.accent.y, COLOR.accent.z = r, g, b
    COLOR.accentHover.x, COLOR.accentHover.y, COLOR.accentHover.z = r + (1 - r) * 0.18, g + (1 - g) * 0.18, b + (1 - b) * 0.18
    COLOR.accentActive.x, COLOR.accentActive.y, COLOR.accentActive.z = r * 0.84, g * 0.84, b * 0.84
    local light = 0.299 * r + 0.587 * g + 0.114 * b > 0.62
    local tone = light and 0.09 or 1
    COLOR.onAccent.x, COLOR.onAccent.y, COLOR.onAccent.z = tone, tone, tone

    local colors, Col = imgui.GetStyle().Colors, imgui.Col
    colors[Col.CheckMark] = COLOR.accent
    colors[Col.SliderGrab] = COLOR.accent
    colors[Col.SliderGrabActive] = COLOR.accentHover
    colors[Col.TextSelectedBg] = imgui.ImVec4(r, g, b, 0.35)
end

local PAD = 24
local fonts = {}
local glyphRanges

imgui.OnInitialize(function()
    local io = imgui.GetIO()
    io.IniFilename = nil

    local builder = imgui.ImFontGlyphRangesBuilder()
    builder:AddRanges(io.Fonts:GetGlyphRangesCyrillic())
    builder:AddText('—–«»×·•№“”„‘’…→←')
    glyphRanges = imgui.ImVector_ImWchar()
    builder:BuildRanges(glyphRanges)
    local function loadFont(size, ...)
        for _, file in ipairs({ ... }) do
            local path = getFolderPath(0x14) .. '\\' .. file
            if doesFileExist(path) then
                return io.Fonts:AddFontFromFileTTF(path, size, nil, glyphRanges[0].Data)
            end
        end
    end
    fonts.body = loadFont(15, 'segoeui.ttf')
    fonts.bold = loadFont(13, 'segoeuib.ttf')
    fonts.title = loadFont(22, 'segoeuib.ttf')
    fonts.strong = loadFont(15, 'segoeuib.ttf')
    fonts.italic = loadFont(15, 'segoeuii.ttf')
    fonts.heading = loadFont(18, 'segoeuib.ttf')
    fonts.nav = loadFont(14, 'segoeuib.ttf')

    local style = imgui.GetStyle()
    style.WindowRounding = 18
    style.WindowBorderSize = 0
    style.WindowPadding = imgui.ImVec2(PAD, 22)
    style.FrameRounding = 10
    style.FrameBorderSize = 0
    style.FramePadding = imgui.ImVec2(10, 6)
    style.ItemSpacing = imgui.ImVec2(8, 8)
    style.GrabRounding = 8
    style.GrabMinSize = 14
    style.ChildRounding = 12
    style.ScrollbarRounding = 8
    style.ScrollbarSize = 10

    local colors, Col = style.Colors, imgui.Col
    colors[Col.Text] = COLOR.text
    colors[Col.TextDisabled] = COLOR.dim
    colors[Col.WindowBg] = COLOR.window
    colors[Col.Border] = COLOR.border
    colors[Col.Separator] = COLOR.border
    colors[Col.FrameBg] = COLOR.card
    colors[Col.FrameBgHovered] = COLOR.cardHover
    colors[Col.FrameBgActive] = COLOR.cardActive
    colors[Col.Button] = COLOR.card
    colors[Col.ButtonHovered] = COLOR.cardHover
    colors[Col.ButtonActive] = COLOR.cardActive
    colors[Col.ChildBg] = COLOR.panel
    colors[Col.ScrollbarBg] = COLOR.clear
    colors[Col.ScrollbarGrab] = COLOR.cardHover
    colors[Col.ScrollbarGrabHovered] = COLOR.cardActive
    colors[Col.ScrollbarGrabActive] = COLOR.cardActive
    colors[Col.CheckMark] = COLOR.accent
    colors[Col.SliderGrab] = COLOR.accent
    colors[Col.SliderGrabActive] = COLOR.accentHover
    colors[Col.PlotHistogram] = COLOR.good
    colors[Col.TextSelectedBg] = rgba(255, 255, 255, 0.25)
    theme.apply()
end)

local function txt(text)
    imgui.TextUnformatted(text)
end

local function dim(text)
    imgui.TextDisabled('%s', text)
end

local function colored(color, text)
    imgui.TextColored(color, '%s', text)
end

local function gap(height)
    imgui.Dummy(imgui.ImVec2(0, height or 2))
end

local function button(kind, text, width, height)
    local look = BUTTON[kind]
    imgui.PushStyleColor(imgui.Col.Button, look[1])
    imgui.PushStyleColor(imgui.Col.ButtonHovered, look[2])
    imgui.PushStyleColor(imgui.Col.ButtonActive, look[3])
    imgui.PushStyleColor(imgui.Col.Text, look[4])
    local clicked = imgui.Button(text, imgui.ImVec2(width, height or 0))
    imgui.PopStyleColor(4)
    return clicked
end

local CARD_PAD = 14
local leftEdge = PAD

local function alignRight(width, fromRight)
    imgui.SameLine(leftEdge + width - fromRight)
end

local function valueRow(width, left, right, color)
    txt(left)
    alignRight(width, imgui.CalcTextSize(right).x)
    colored(color or COLOR.text, right)
end

local function label(text)
    if fonts.bold then imgui.PushFont(fonts.bold) end
    dim(text)
    if fonts.bold then imgui.PopFont() end
end

local function divider(width)
    local p = imgui.GetCursorScreenPos()
    imgui.GetWindowDrawList():AddLine(imgui.ImVec2(p.x, p.y), imgui.ImVec2(p.x + width, p.y),
        imgui.GetColorU32Vec4(COLOR.border), 1)
    imgui.Dummy(imgui.ImVec2(0, 1))
end

local function card(width, title, body)
    if title then label(title) end
    local draw = imgui.GetWindowDrawList()
    local origin = imgui.GetCursorScreenPos()
    draw:ChannelsSplit(2)
    draw:ChannelsSetCurrent(1)
    imgui.BeginGroup()
    imgui.Dummy(imgui.ImVec2(width, CARD_PAD - 8))
    imgui.Indent(CARD_PAD)
    leftEdge = CARD_PAD
    local ok, err = pcall(body, width - CARD_PAD * 2)
    leftEdge = PAD
    imgui.Unindent(CARD_PAD)
    imgui.Dummy(imgui.ImVec2(width, CARD_PAD - 8))
    imgui.EndGroup()
    local corner = imgui.GetItemRectMax()
    draw:ChannelsSetCurrent(0)
    draw:AddRectFilled(origin, imgui.ImVec2(origin.x + width, corner.y), imgui.GetColorU32Vec4(COLOR.panel), 12)
    draw:ChannelsMerge()
    if not ok then error(err, 0) end
    gap(4)
end

local function tableView(width, columns, rows)
    local draw = imgui.GetWindowDrawList()
    local offsets, x = {}, 0
    for i, column in ipairs(columns) do
        offsets[i] = x
        x = x + column.width * width
    end
    local function cell(i, text, color)
        local shift = offsets[i]
        if columns[i].right then shift = shift + columns[i].width * width - imgui.CalcTextSize(text).x - 6 end
        if i > 1 then
            imgui.SameLine(leftEdge + shift)
        elseif shift > 0 then
            imgui.SetCursorPosX(imgui.GetCursorPosX() + shift)
        end
        colored(color or COLOR.text, text)
    end

    if fonts.bold then imgui.PushFont(fonts.bold) end
    for i, column in ipairs(columns) do cell(i, column.title, COLOR.dim) end
    if fonts.bold then imgui.PopFont() end
    divider(width)

    local lineHeight = imgui.CalcTextSize('A').y
    for r, row in ipairs(rows) do
        if r % 2 == 0 then
            local p = imgui.GetCursorScreenPos()
            draw:AddRectFilled(imgui.ImVec2(p.x - 8, p.y - 4), imgui.ImVec2(p.x + width + 8, p.y + lineHeight + 4),
                imgui.GetColorU32Vec4(COLOR.stripe), 6)
        end
        for i = 1, #columns do
            local value = row[i]
            if type(value) == 'table' then
                cell(i, tostring(value[1]), value[2])
            else
                cell(i, tostring(value or ''))
            end
        end
    end
end

local function toggle(text, key)
    toggles[key] = toggles[key] or new.bool(cfg[key])
    toggles[key][0] = cfg[key]
    if imgui.Checkbox(text, toggles[key]) then
        cfg[key] = toggles[key][0]
        saveConfig()
        if key == 'weekly' then refreshStats() end
    end
end

function hotkeys.button(target, code, width)
    local capturing = hotkeys.capture == target
    if button(capturing and 'primary' or 'card', (capturing and 'нажми клавишу…' or hotkeys.name(code)) .. '##key_' .. target, width) then
        hotkeys.capture = (not capturing) and target or nil
    end
end
local function slider(key, min, max, format, width)
    sliders[key] = sliders[key] or new.int(cfg[key])
    sliders[key][0] = cfg[key]
    imgui.PushItemWidth(width)
    if imgui.SliderInt('##slider_' .. key, sliders[key], min, max, format) then
        cfg[key] = sliders[key][0]
        cfgDirty = true
    end
    imgui.PopItemWidth()
end

local function chips(id, tags, selected, width)
    local picked, x = nil, 0
    imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, imgui.ImVec2(10, 5))
    for i, tag in ipairs(tags) do
        local w = imgui.CalcTextSize(tag).x + 20
        if i > 1 then
            if x + w > width then x = 0 else imgui.SameLine(0, 6) end
        end
        if button(tag == selected and 'primary' or 'card', tag .. '##' .. id .. i, w) then picked = tag end
        x = x + w + 6
    end
    imgui.PopStyleVar(1)
    return picked
end

local function beginWindow(id, width, title, subtitle, open, height, showIdentity)
    centerNextWindow()
    local flags = imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize
    if height then
        imgui.SetNextWindowSize(imgui.ImVec2(width + PAD * 2, height), imgui.Cond.Always)
        flags = flags + imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoScrollWithMouse
    else
        flags = flags + imgui.WindowFlags.AlwaysAutoResize
    end
    if fonts.body then imgui.PushFont(fonts.body) end
    imgui.Begin(id, open, flags)

    if showIdentity then
        local back = imgui.GetCursorPos()
        local nick = myNick()
        local details = (cfg.myRank ~= '' and (cfg.myRank .. '  ·  ') or '') .. os.date('%d.%m.%Y  %H:%M:%S')
        if fonts.strong then imgui.PushFont(fonts.strong) end
        imgui.SetCursorPos(imgui.ImVec2(PAD + width - imgui.CalcTextSize(nick).x, back.y + 4))
        txt(nick)
        if fonts.strong then imgui.PopFont() end
        imgui.SetCursorPos(imgui.ImVec2(PAD + width - imgui.CalcTextSize(details).x, back.y + 30))
        dim(details)
        imgui.SetCursorPos(back)
    end

    if fonts.title then imgui.PushFont(fonts.title) end
    txt(title)
    if fonts.title then imgui.PopFont() end
    dim(subtitle)
    imgui.Dummy(imgui.ImVec2(width, 2))
    divider(width)
    gap(4)
end

local function endWindow(width, open, closeLabel)
    gap(2)
    divider(width)
    gap(2)
    imgui.AlignTextToFramePadding()
    dim('by ' .. AUTHOR)
    if fonts.bold then imgui.PushFont(fonts.bold) end
    local keyWidth = 48
    alignRight(width, keyWidth + 10 + imgui.CalcTextSize(closeLabel).x)
    txt(closeLabel)
    alignRight(width, keyWidth)
    if button('primary', 'Esc##close', keyWidth) then open[0] = false end
    if fonts.bold then imgui.PopFont() end
    imgui.End()
    if fonts.body then imgui.PopFont() end
end

local function newFolderRow(id, width, buttonLabel, buttonWidth)
    imgui.PushItemWidth(width - buttonWidth - 8)
    imgui.InputText('##new' .. id, newName, ffi.sizeof(newName))
    imgui.PopItemWidth()
    imgui.SameLine()
    if button('primary', buttonLabel .. '##add' .. id, buttonWidth) then return takeNewName() end
end

imgui.OnFrame(function() return pickWindow[0] end, function()
    local W = 360
    beginWindow('##timeshot_pick', W, 'КУДА СОХРАНИТЬ?', 'Скриншот готов — выбери папку отчёта', pickWindow)

    card(W, 'ПАПКИ', function(w)
        if #cfg.categories == 0 then
            dim('Папок пока нет — создай первую ниже.')
        end
        imgui.PushStyleVarVec2(imgui.StyleVar.ButtonTextAlign, imgui.ImVec2(0.05, 0.5))
        for i, name in ipairs(cfg.categories) do
            if button('card', name .. '##pick' .. i, w, 40) then savePending(name) end
        end
        imgui.PopStyleVar(1)
    end)

    card(W, 'ПОДПАПКА (НЕОБЯЗАТЕЛЬНО)', function(w)
        imgui.PushItemWidth(w)
        imgui.InputText('##sub', subName, ffi.sizeof(subName))
        imgui.PopItemWidth()
        local sub = cleanName(ffi.string(subName))
        dim((cfg.weekly and weekFolder() .. ' / ' or '') .. '<папка>' .. (sub ~= '' and ' / ' .. sub or ''))
    end)

    card(W, 'НОВАЯ ПАПКА', function(w)
        local typed = newFolderRow('pick', w, 'Создать', 100)
        if typed then
            local name, err = addCategory(typed)
            if name then savePending(name) else notify(err) end
        end
    end)

    endWindow(W, pickWindow, 'ОТМЕНА')

    if not pickWindow[0] then discardPending() end
end)

local tabs = {}

function tabs.foldersTab(W)
    local removeIndex
    card(W, cfg.weekly and ('НЕДЕЛЯ ' .. weekFolder()) or 'ТЕКУЩАЯ НЕДЕЛЯ', function(w)
        if #cfg.categories == 0 then
            dim('Папок пока нет — создай первую ниже.')
        end
        for i, name in ipairs(cfg.categories) do
            if i > 1 then divider(w) end
            local count = weekCount(name)
            local countText = count > 0 and (count .. ' скр.') or 'пусто'
            imgui.AlignTextToFramePadding()
            txt(name)
            alignRight(w, 188 + imgui.CalcTextSize(countText).x)
            colored(count > 0 and COLOR.dim or COLOR.danger, countText)
            alignRight(w, 176)
            if button('card', 'Открыть##open' .. i, 84) then openFolder(categoryDir(name)) end
            alignRight(w, 84)
            if button('danger', 'Убрать##del' .. i, 84) then removeIndex = i end
        end
    end)
    if removeIndex then
        cfg.hidden[cfg.categories[removeIndex]] = true
        table.remove(cfg.categories, removeIndex)
        saveConfig()
    end
    dim('«Убрать» скрывает папку из списка, скриншоты остаются.')
    gap(4)

    card(W, 'НОВАЯ ПАПКА', function(w)
        local typed = newFolderRow('menu', w, 'Создать', 100)
        if typed then
            local name, err = addCategory(typed)
            if not name then notify(err) end
        end
    end)

    if button('card', 'Открыть папку со всеми отчётами', W) then openFolder(BASE_DIR) end
end

function tabs.reportTab(W)
    local dates = weekDates()
    local half = (W - 8) / 2

    card(W, 'СРОК НА ПОСТУ', function(w)
        imgui.AlignTextToFramePadding()
        txt('Дата назначения')
        imgui.SameLine(CARD_PAD + 130)
        imgui.PushItemWidth(120)
        if imgui.InputText('##term_start', term.input, ffi.sizeof(term.input)) then
            cfg.termStart = ffi.string(term.input)
            cfgDirty = true
        end
        imgui.PopItemWidth()
        imgui.SameLine()
        if button('card', 'Сегодня', 90) then
            cfg.termStart = os.date('%d.%m.%Y')
            ffi.fill(term.input, ffi.sizeof(term.input))
            ffi.copy(term.input, cfg.termStart)
            saveConfig()
        end
        for _, days in ipairs({ 15, 30, 60 }) do
            imgui.SameLine()
            if button(cfg.termDays == days and 'primary' or 'card', days .. ' дн.##term' .. days, 70) then
                cfg.termDays = days
                saveConfig()
            end
        end
        slider('termExtra', 0, 10, 'дни неактива, которые прибавляются к сроку: %d', w)

        local info = term.info()
        if not info then
            dim('Укажи дату в формате ДД.ММ.ГГГГ — и здесь появится счётчик срока.')
            return
        end
        imgui.ProgressBar(math.max(0, math.min(info.passed / info.total, 1)), imgui.ImVec2(w, 8), '')
        valueRow(w, 'Идёт день', math.max(info.day, 0) .. ' из ' .. info.total)
        divider(w)
        valueRow(w, 'Осталось', info.left >= 0 and (info.left .. ' дн.') or 'срок истёк',
            info.left <= 5 and COLOR.danger or COLOR.text)
        divider(w)
        valueRow(w, 'Конец срока', os.date('%d.%m.%Y', info.finish), COLOR.dim)
        divider(w)
        valueRow(w, 'Запрос на продление — не позднее', os.date('%d.%m.%Y', info.finish - 3 * 86400),
            info.left <= 5 and COLOR.danger or COLOR.dim)
        divider(w)
        valueRow(w, 'Минимум 15 дней на посту', info.passed >= 15 and 'пройдено'
            or ('будет ' .. os.date('%d.%m.%Y', info.start + 15 * 86400)), info.passed >= 15 and COLOR.good or COLOR.dim)
    end)

    card(W, 'НЕДЕЛЯ', function(w)
        valueRow(w, weekFolder(), 'сдать до 23:59 ' .. dates[7]:sub(9, 10) .. '.' .. dates[7]:sub(6, 7),
            deadlineDay() and COLOR.danger or COLOR.dim)
    end)

    card(W, 'СОБЕСЕДОВАНИЯ СЕГОДНЯ', function(w)
        local done = interviewsToday()
        valueRow(w, 'Проведено по скриншотам', done .. ' / ' .. cfg.interviewNorm,
            done >= cfg.interviewNorm and COLOR.good or COLOR.danger)
        divider(w)
        dim('Пауза больше 20 минут — новое собеседование.')
    end)

    card(W, 'ОНЛАЙН ЗА НЕДЕЛЮ', function(w)
        local seconds = weekOnline(cfg.online)
        local hours = seconds / 3600
        local status, nextAt, ok = onlineStatus(hours)
        imgui.ProgressBar(math.min(hours / 30, 1), imgui.ImVec2(w, 8), '')

        local names = cfg.weekStart == 1 and { 'Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс' }
            or { 'Вс', 'Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб' }
        local todayDate = os.date('%Y-%m-%d')
        local rows = {}
        for i, day in ipairs(dates) do
            local future = day > todayDate
            local color = (day == todayDate and COLOR.text) or COLOR.dim
            rows[i] = {
                { names[i] .. (day == todayDate and '  ·  сегодня' or ''), color },
                { day:sub(9, 10) .. '.' .. day:sub(6, 7), color },
                { future and '—' or formatDuration(cfg.online[day] or 0), color },
                { future and '—' or formatDuration(cfg.onlineClean[day] or 0), color },
            }
        end
        rows[#rows + 1] = {
            'Итого', '', formatDuration(seconds), formatDuration(weekOnline(cfg.onlineClean)),
        }
        tableView(w, {
            { title = 'ДЕНЬ', width = 0.34 },
            { title = 'ДАТА', width = 0.16 },
            { title = 'ОНЛАЙН', width = 0.25, right = true },
            { title = 'С 8:00 ДО 22:00', width = 0.25, right = true },
        }, rows)
        divider(w)
        valueRow(w, 'Сейчас по правилам', status, ok and COLOR.good or COLOR.danger)
        if nextAt then
            divider(w)
            valueRow(w, 'До отметки ' .. nextAt .. ' ч', formatDuration(nextAt * 3600 - seconds), COLOR.dim)
        end
        divider(w)
        label('ПРАВКА ОНЛАЙНА ЗА ДЕНЬ')
        local edit = onlineEdit
        local chosen = false
        for _, day in ipairs(dates) do
            if day == edit.day and day <= todayDate then chosen = true end
        end
        if not chosen then edit.day = todayDate end
        local first = true
        for i, day in ipairs(dates) do
            if day <= todayDate then
                if not first then imgui.SameLine(0, 6) end
                first = false
                if button(day == edit.day and 'primary' or 'card', names[i] .. ' ' .. day:sub(9, 10) .. '.' .. day:sub(6, 7) .. '##oe' .. i,
                    (w - 36) / 7) then
                    edit.day, edit.busy = day, false
                end
            end
        end

        if not edit.busy then
            local total, clean = cfg.online[edit.day] or 0, cfg.onlineClean[edit.day] or 0
            edit.hours[0], edit.minutes[0] = math.floor(total / 3600), math.floor(total % 3600 / 60)
            edit.cleanHours[0], edit.cleanMinutes[0] = math.floor(clean / 3600), math.floor(clean % 3600 / 60)
        end
        local side = (w - 8) / 2
        local changed, active = false, false
        local function field(id, value, max, format)
            imgui.PushItemWidth(side)
            if imgui.SliderInt(id, value, 0, max, format) then changed = true end
            if imgui.IsItemActive() then active = true end
            imgui.PopItemWidth()
        end
        field('##oe_hours', edit.hours, 24, 'всего: %d ч')
        imgui.SameLine()
        field('##oe_minutes', edit.minutes, 59, '%d мин')
        field('##oe_clean_hours', edit.cleanHours, 14, 'из них с 8:00 до 22:00: %d ч')
        imgui.SameLine()
        field('##oe_clean_minutes', edit.cleanMinutes, 59, '%d мин')
        edit.busy = active
        if changed then
            local total = math.min(edit.hours[0] * 3600 + edit.minutes[0] * 60, 86400)
            local clean = math.min(edit.cleanHours[0] * 3600 + edit.cleanMinutes[0] * 60, total, 14 * 3600)
            cfg.online[edit.day], cfg.onlineClean[edit.day] = total, clean
            cfgDirty = true
        end
        dim('Выбери день и выставь, сколько реально отстоял — например, за дни до установки скрипта. Сверяй с /time.')
    end)

    card(W, 'ДОКАЗАТЕЛЬСТВА НАКАЗАНИЙ', function(w)
        valueRow(w, 'Старше 5 дней, можно удалять', stats.oldPunish .. ' из ' .. stats.punishTotal, COLOR.dim)
    end)

    if button('primary', 'Собрать отчёт', half) then buildReport() end
    imgui.SameLine()
    if button('card', 'Открыть журнал', half) then
        local path = rootDir() .. '\\Журнал.txt'
        if fs.exists(path) then openPath(path) else notify('Журнал за эту неделю пока пуст.') end
    end
end

function tabs.govTab(W)

    card(W, 'МОЙ ТЕГ В РАЦИИ', function(w)
        local picked = chips('own', ORG_TAGS, cfg.ownTag, w)
        if picked then
            cfg.ownTag = picked
            saveConfig()
        end
    end)

    card(W, 'РАСПИСАНИЕ СОБЕСЕДОВАНИЙ', function(w)
        local me = myNick()
        local now, t = os.time(), os.date('*t')
        local first = os.time({ year = t.year, month = t.month, day = t.day, hour = t.hour, min = 5, sec = 0 })
        local bookable = first + 3600
        local rows = {}
        for i = 0, 11 do
            local slot = first + i * 600
            if slot > now then
                local owner = slotOwner(slot)
                local status, color
                if owner then
                    status, color = (owner == me and 'занято вами' or ('занято: ' .. owner)), COLOR.danger
                elseif slot >= bookable then
                    status, color = 'свободно', COLOR.good
                else
                    status, color = 'свободно, но занять уже нельзя', COLOR.dim
                end
                rows[#rows + 1] = {
                    { os.date('%H:%M', slot), owner and COLOR.text or (slot >= bookable and COLOR.text or COLOR.dim) },
                    { 'через ' .. math.ceil((slot - now) / 60) .. ' мин', COLOR.dim },
                    { status, color },
                }
            end
        end
        tableView(w, {
            { title = 'ВРЕМЯ', width = 0.18 },
            { title = 'КОГДА', width = 0.24 },
            { title = 'СТАТУС', width = 0.58 },
        }, rows)
        gap(2)
        dim('Видны назначения, которые прошли в чате при тебе. Занять можно только слоты следующего часа.')
    end)

    card(W, 'НАЗНАЧИТЬ СОБЕСЕДОВАНИЕ В /lmenu', function(w)
        local me = myNick()
        local slots = upcomingSlots()
        local valid = false
        for _, slot in ipairs(slots) do
            if slot == booking.slot and not slotOwner(slot) then valid = true end
        end
        if not valid then booking.slot = nearestFreeSlot() end

        label('ВРЕМЯ — СЛОТЫ СЛЕДУЮЩЕГО ЧАСА')
        local taken = {}
        for i, slot in ipairs(slots) do
            if i > 1 then imgui.SameLine(0, 6) end
            local owner = slotOwner(slot)
            local kind = owner and 'danger' or (slot == booking.slot and 'primary' or 'card')
            if button(kind, os.date('%H:%M', slot) .. '##slot' .. i, (w - 30) / 6) and not owner then booking.slot = slot end
            if owner then taken[#taken + 1] = os.date('%H:%M', slot) .. ' — ' .. (owner == me and 'вы' or owner) end
        end
        imgui.PushTextWrapPos(imgui.GetCursorPosX() + w)
        dim(#taken > 0 and ('Занято: ' .. table.concat(taken, ',  ')) or 'Занятых слотов в чате при тебе не было.')
        imgui.PopTextWrapPos()

        gap()
        label('МЕСТО')
        imgui.PushItemWidth(w)
        imgui.InputText('##booking_place', booking.place, ffi.sizeof(booking.place))
        imgui.PopItemWidth()

        local length = #cp((ffi.string(booking.place):gsub('^%s+', ''):gsub('%s+$', '')))
        local fits = length >= 2 and length <= 20
        if fits then
            dim('Символов: ' .. length .. ' из 20')
        else
            colored(COLOR.danger, 'Сервер принимает место длиной от 2 до 20 символов, сейчас ' .. length .. '.')
        end

        gap()
        local ready = booking.slot ~= nil and fits and booking.step == 0
        local caption = booking.slot and ('Занять ' .. os.date('%H:%M', booking.slot)) or 'Свободных слотов нет'
        if button(ready and 'primary' or 'card', caption .. '##book', w) and ready then booking.start() end
        if booking.status ~= '' then
            colored(booking.ok and COLOR.good or COLOR.dim, 'Состояние: ' .. booking.status)
        end
        dim('Скрипт сам пройдёт /lmenu → Собеседования → Назначить и введёт время и место.')
        divider(w)
        toggle('Напоминать о моём собеседовании за 5 минут и в момент начала', 'interviewRemind')
    end)

    card(W, 'ГОС. ВОЛНА /gov', function(w)
        local remaining = govReadyAt() - os.time()
        if remaining > 0 then
            valueRow(w, 'Можно подавать', 'через ' .. countdown(remaining) .. ' (в ' .. os.date('%H:%M', govReadyAt()) .. ')', COLOR.danger)
        else
            valueRow(w, 'Можно подавать', 'сейчас', COLOR.good)
        end
        local last = math.max(cfg.gov.lastOther or 0, cfg.gov.lastOwn or 0)
        if last > 0 and type(cfg.gov.lastNick) == 'string' then
            divider(w)
            valueRow(w, 'Последняя волна', os.date('%H:%M', last) .. ' — ' .. cfg.gov.lastNick
                .. (cfg.gov.lastWasOwn and ' (своя)' or ''), COLOR.dim)
        end
    end)
    dim('Слоты и волны видны только те, что прошли в чате при тебе.')
    gap(4)

    if button('primary', 'Открыть рацию /d', W) then radioWindow[0] = true end
end

function tabs.shotSettings(W)
    card(W, 'ПАПКИ ПО НЕДЕЛЯМ', function(w)
        toggle('Раскладывать скриншоты по неделям', 'weekly')
        if cfg.weekly then
            local side = (w - 8) / 2
            if button(cfg.weekStart == 1 and 'primary' or 'card', 'Пн — Вс', side) then
                cfg.weekStart = 1
                saveConfig()
                refreshStats()
            end
            imgui.SameLine()
            if button(cfg.weekStart == 0 and 'primary' or 'card', 'Вс — Сб', side) then
                cfg.weekStart = 0
                saveConfig()
                refreshStats()
            end
            dim('Текущая неделя: ' .. weekFolder())
        end
    end)

    card(W, 'ЗАДЕРЖКА МЕЖДУ /time И СКРИНШОТОМ', function(w)
        slider('delay', 200, 3000, '%d мс', w)
        dim('Увеличь, если /time не успевает появиться на скриншоте.')
    end)

    card(W, 'АВТОСКРИНШОТ С /time И ЗАПИСЬ В ЖУРНАЛ', function(w)
        toggle('Кадровые действия: приём, увольнение, ранги', 'autoStaff')
        divider(w)
        toggle('Наказания: /demoute, /dismiss, /gwarn', 'autoPunish')
        divider(w)
        toggle('Команды МЮ: /su, /ticket, /take', 'autoJustice')
    end)
end

function tabs.widgetsTab(W)
    card(W, 'СЧЁТЧИК ОНЛАЙНА', function(w)
        local side = (w - 8) / 2
        toggle('Показывать на экране##hud', 'hud')
        divider(w)
        label('ЧТО ПОКАЗЫВАТЬ')
        toggle('Онлайн за сегодня', 'hudToday')
        toggle('Онлайн за неделю', 'hudWeek')
        toggle('Сколько осталось до нормы', 'hudNorm')
        toggle('Статус по правилам', 'hudStatus')
        toggle('Собеседования за сегодня', 'hudInterviews')
        toggle('Ник и должность', 'hudNick')
        toggle('Текущее время', 'hudTime')
        divider(w)
        label('ПОЛОЖЕНИЕ И РАЗМЕР')
        slider('hudX', 0, 100, 'по горизонтали: %d%%', side)
        imgui.SameLine()
        slider('hudY', 0, 100, 'по вертикали: %d%%', side)
        slider('hudSize', 11, 32, 'размер текста: %d', w)
    end)

    card(W, 'СПИСОК СОСТАВА', function(w)
        local side = (w - 8) / 2
        toggle('Показывать на экране##members', 'members')
        dim('Пока включено, скрипт сам запрашивает /members с заданным интервалом.')
        divider(w)
        label('ЧТО ПОКАЗЫВАТЬ В СТРОКЕ')
        toggle('Должность и ранг', 'membersRank')
        toggle('ID игрока', 'membersId')
        toggle('Отметка AFK', 'membersAfk')
        divider(w)
        label('ПОЛОЖЕНИЕ, РАЗМЕР И ОБНОВЛЕНИЕ')
        slider('membersX', 0, 100, 'по горизонтали: %d%%', side)
        imgui.SameLine()
        slider('membersY', 0, 100, 'по вертикали: %d%%', side)
        slider('membersSize', 10, 28, 'размер текста: %d', side)
        imgui.SameLine()
        slider('membersMax', 5, 60, 'строк на экране: %d', side)
        slider('membersInterval', 10, 120, 'обновлять каждые %d с', side)
        imgui.SameLine()
        slider('membersNorm', 0, 30, 'норма онлайна: %d', side)
    end)

    card(W, 'ГОС. ВОЛНА', function(w)
        toggle('Свободный слот и кулдаун /gov вверху экрана', 'widget')
    end)
end

function tabs.generalTab(W)
    card(W, 'ОБНОВЛЕНИЯ', function(w)
        toggle('Обновлять автоматически при запуске', 'autoUpdate')
        divider(w)
        imgui.AlignTextToFramePadding()
        txt('Установлена версия ' .. update.current())
        alignRight(w, 210)
        if button('primary', 'Проверить обновление', 210) then update.check(true) end
        local checked = update.checkedAt > 0 and ('  ·  ' .. os.date('%H:%M:%S', update.checkedAt)) or ''
        local fresh = update.latest ~= nil and update.number(update.latest) > update.number(update.current())
        colored(fresh and COLOR.good or COLOR.dim, 'Состояние: ' .. update.status .. checked)
        if fresh and update.notes ~= '' then dim('Что нового: ' .. update.notes) end
    end)

    card(W, 'ЧУВСТВИТЕЛЬНОСТЬ МЫШИ', function(w)
        local before = cfg.sens
        toggle('Задавать чувствительность отдельно по горизонтали и вертикали', 'sens')
        if before and not cfg.sens then sens.restore() end
        if cfg.sens then
            local side = (w - 8) / 2
            slider('sensX', 5, 1000, 'по горизонтали: %d', side)
            imgui.SameLine()
            slider('sensY', 5, 1000, 'по вертикали: %d', side)
            if button('card', 'Сделать вертикаль как горизонталь', side) then
                cfg.sensY = cfg.sensX
                saveConfig()
            end
            imgui.SameLine()
            if button('card', 'Вернуть значения игры', side) and sens.startX then
                cfg.sensX = math.max(5, math.min(1000, math.floor(sens.startX / sens.unit + 0.5)))
                cfg.sensY = math.max(5, math.min(1000, math.floor(sens.startY / sens.unit + 0.5)))
                saveConfig()
            end
        end
        local x, y = sens.read()
        dim(('Сейчас в игре: горизонталь %d, вертикаль %d. Чем больше число, тем быстрее камера.'):format(
            math.floor(x / sens.unit + 0.5), math.floor(y / sens.unit + 0.5)))
    end)

    card(W, 'ГОРЯЧИЕ КЛАВИШИ', function(w)
        imgui.AlignTextToFramePadding()
        txt('Скриншот с /time, как команда /t')
        alignRight(w, 190)
        hotkeys.button('shot', cfg.keys.shot, 190)
        divider(w)
        imgui.AlignTextToFramePadding()
        txt('Открыть и закрыть это меню')
        alignRight(w, 190)
        hotkeys.button('menu', cfg.keys.menu, 190)
        divider(w)
        imgui.AlignTextToFramePadding()
        txt('Круговое меню действий с игроком')
        alignRight(w, 190)
        hotkeys.button('wheel', cfg.keys.wheel, 190)
        divider(w)
        imgui.AlignTextToFramePadding()
        txt('Рация департамента, как команда /td')
        alignRight(w, 190)
        hotkeys.button('radio', cfg.keys.radio, 190)
        dim('Нажми кнопку, затем клавишу — можно с Ctrl, Alt или Shift. Esc — отмена, Backspace — убрать.')
        dim('Клавиши для биндов задаются в разделе «Биндер». В чате и окнах клавиши не срабатывают.')
    end)

    card(W, 'ЦВЕТ АКЦЕНТА', function(w)
        local draw = imgui.GetWindowDrawList()
        for i, preset in ipairs(theme.accents) do
            if i > 1 then imgui.SameLine(0, 10) end
            local swatch = imgui.ImVec4(preset[2] / 255, preset[3] / 255, preset[4] / 255, 1)
            imgui.PushStyleColor(imgui.Col.Button, swatch)
            imgui.PushStyleColor(imgui.Col.ButtonHovered, swatch)
            imgui.PushStyleColor(imgui.Col.ButtonActive, swatch)
            if imgui.Button('##accent' .. i, imgui.ImVec2(34, 34)) then
                cfg.accent = i
                theme.apply()
                saveConfig()
            end
            imgui.PopStyleColor(3)
            if cfg.accent == i then
                local a, b = imgui.GetItemRectMin(), imgui.GetItemRectMax()
                draw:AddRect(imgui.ImVec2(a.x - 3, a.y - 3), imgui.ImVec2(b.x + 3, b.y + 3),
                    imgui.GetColorU32Vec4(COLOR.text), 12, 15, 2)
            end
        end
        local name = (theme.accents[cfg.accent] or theme.accents[1])[1]
        imgui.SameLine(0, 16)
        imgui.AlignTextToFramePadding()
        dim(name)
    end)

    card(W, 'АВАТАР В МЕНЮ', function(w)
        local side = (w - 8) / 2
        if button('primary', 'Сфотографировать персонажа', side) then
            menuWindow[0] = false
            takeAvatar(true)
        end
        imgui.SameLine()
        if button('card', 'Убрать фото', side) then
            os.remove(avatar.ansi)
            avatar.dirty = true
        end
        dim('Перед этим разверни камеру лицом к персонажу. Меню закроется на секунду.')
    end)

    card(W, 'AFK', function(w)
        toggle('Звуковой сигнал на 8-й и 9-й минуте AFK', 'afkWarn')
    end)

    card(W, 'КОМАНДЫ', function(w)
        local commands = {
            { '/t', 'скриншот с /time и выбором папки' },
            { '/tmenu', 'это меню' },
            { '/td', 'рация департамента' },
            { '/tn', 'заметки' },
            { '/tstop', 'остановить бинд' },
            { '/tavatar', 'сфотографировать персонажа для аватара' },
            { '/tupdate', 'проверить обновление' },
        }
        for i, command in ipairs(commands) do
            if i > 1 then divider(w) end
            valueRow(w, command[1], command[2], COLOR.dim)
        end
    end)
end

function tabs.membersTab(W)
    card(W, 'ДАННЫЕ ИЗ /members', function(w)
        imgui.AlignTextToFramePadding()
        txt('Обновлено: ' .. (members.at > 0 and os.date('%H:%M:%S', members.at) or 'ещё нет'))
        alignRight(w, 170)
        if button('card', 'Обновить сейчас', 170) then lua_thread.create(requestMembers) end
        dim('Список на экране и автообновление включаются в разделе «Виджеты».')
    end)

    local title = 'В СЕТИ — ' .. #members.list .. (members.fraction ~= '' and ('  ·  ' .. members.fraction) or '')
    card(W, title, function(w)
        if #members.list == 0 then
            dim('Список пуст. Нажми «Обновить сейчас».')
        end
        local rows = {}
        for i, member in ipairs(members.list) do
            local color = member.working and COLOR.text or COLOR.dim
            rows[i] = {
                { i, COLOR.dim },
                { member.nick .. (member.you and '  (вы)' or ''), color },
                { member.id, COLOR.dim },
                { member.rank, color },
                { member.rankNumber, color },
                { member.warns, member.warns > 0 and COLOR.danger or COLOR.dim },
                { member.afk > 0 and member.afk or '—', member.afk > 0 and COLOR.danger or COLOR.dim },
                { member.working and 'да' or 'нет', member.working and COLOR.good or COLOR.dim },
            }
        end
        tableView(w, {
            { title = '№', width = 0.05 },
            { title = 'НИК', width = 0.31 },
            { title = 'ID', width = 0.07 },
            { title = 'ДОЛЖНОСТЬ', width = 0.27 },
            { title = 'РАНГ', width = 0.07, right = true },
            { title = 'ВЫГ.', width = 0.07, right = true },
            { title = 'AFK', width = 0.08, right = true },
            { title = 'ФОРМА', width = 0.08, right = true },
        }, rows)
    end)
end

local MD_COLOR = { code = rgba(255, 209, 102), tag = rgba(110, 168, 255) }

local function renderTokens(tokens, width)
    local spaceWidth = imgui.CalcTextSize(' ').x
    local x = 0
    for i, token in ipairs(tokens) do
        local font = (token.style == 'bold' and fonts.strong) or (token.style == 'italic' and fonts.italic) or nil
        if font then imgui.PushFont(font) end
        token.width = token.width or imgui.CalcTextSize(token.text).x
        if i > 1 then
            local space = token.space and spaceWidth or 0
            if x + space + token.width > width then
                x = 0
            else
                imgui.SameLine(0, space)
                x = x + space
            end
        end
        local color = MD_COLOR[token.style]
        if color then colored(color, token.text) else txt(token.text) end
        if font then imgui.PopFont() end
        x = x + token.width
    end
end

local function renderContent(block, width)
    if block.tokens then
        renderTokens(block.tokens, width)
    else
        imgui.PushTextWrapPos(imgui.GetCursorPosX() + width)
        txt(block.text)
        imgui.PopTextWrapPos()
    end
end

local function renderMarkdown(blocks, width)
    imgui.PushStyleVarVec2(imgui.StyleVar.ItemSpacing, imgui.ImVec2(0, 0))
    for _, block in ipairs(blocks) do
        if block.kind == 'blank' then
            gap(8)
        elseif block.kind == 'rule' then
            gap(5)
            divider(width)
            gap(5)
        elseif block.kind == 'heading' then
            local font = (block.level == 1 and fonts.title) or (block.level == 2 and fonts.heading) or fonts.strong
            gap(4)
            if font then imgui.PushFont(font) end
            imgui.PushTextWrapPos(imgui.GetCursorPosX() + width)
            txt(block.text)
            imgui.PopTextWrapPos()
            if font then imgui.PopFont() end
            gap(4)
        elseif block.kind == 'code' then
            colored(MD_COLOR.code, block.text)
        elseif block.kind == 'text' then
            renderContent(block, width)
            gap(3)
        else
            local baseX = imgui.GetCursorPosX()
            local top = imgui.GetCursorScreenPos()
            if block.marker then
                dim(block.marker)
                imgui.SameLine(baseX + block.indent)
            else
                imgui.SetCursorPosX(baseX + block.indent)
            end
            imgui.BeginGroup()
            if block.kind == 'quote' then imgui.PushStyleColor(imgui.Col.Text, COLOR.dim) end
            renderContent(block, width - block.indent)
            if block.kind == 'quote' then imgui.PopStyleColor(1) end
            imgui.EndGroup()
            if block.kind == 'quote' then
                local bottom = imgui.GetItemRectMax()
                imgui.GetWindowDrawList():AddRectFilled(top, imgui.ImVec2(top.x + 3, bottom.y),
                    imgui.GetColorU32Vec4(COLOR.cardActive), 2)
            end
            gap(3)
        end
    end
    imgui.PopStyleVar(1)
end

local NOTE_TOOLS = {
    { 'Ж', { wrap = '**' } },
    { 'К', { wrap = '*' } },
    { 'Код', { wrap = '`' } },
    { 'H1', { line = '# ' } },
    { 'H2', { line = '## ' } },
    { 'H3', { line = '### ' } },
    { 'Список', { line = '- ' } },
    { '1.', { line = '1. ' } },
    { 'Цитата', { line = '> ' } },
    { 'Линия', { insert = '\n---\n' } },
    { '#тег', { insert = '#' } },
}

local function applyNoteEdit(data, op)
    local length = data.BufTextLen
    local pos = math.min(ns.cursor.pos, length)
    local from = math.min(ns.cursor.s, ns.cursor.e, length)
    local to = math.min(math.max(ns.cursor.s, ns.cursor.e), length)
    if op.wrap then
        if from ~= to then
            data:InsertChars(to, op.wrap)
            data:InsertChars(from, op.wrap)
            data.CursorPos = to + #op.wrap * 2
        else
            data:InsertChars(pos, op.wrap .. op.wrap)
            data.CursorPos = pos + #op.wrap
        end
    elseif op.line then
        local start = pos
        while start > 0 and data.Buf[start - 1] ~= 10 do start = start - 1 end
        data:InsertChars(start, op.line)
        data.CursorPos = pos + #op.line
    else
        data:InsertChars(pos, op.insert)
        data.CursorPos = pos + #op.insert
    end
    data.SelectionStart, data.SelectionEnd = data.CursorPos, data.CursorPos
end

local callbackReady, noteCallback = pcall(ffi.cast, 'ImGuiInputTextCallback', function(data)
    pcall(function()
        if ns.pending then
            local op = ns.pending
            ns.pending = nil
            applyNoteEdit(data, op)
        end
        ns.cursor.pos, ns.cursor.s, ns.cursor.e = data.CursorPos, data.SelectionStart, data.SelectionEnd
    end)
    return 0
end)

local function noteEditor(width, height)
    if not callbackReady then
        imgui.InputTextMultiline('##note_text', ns.text, ffi.sizeof(ns.text), imgui.ImVec2(width, height + 35))
        return
    end
    imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, imgui.ImVec2(10, 5))
    for i, tool in ipairs(NOTE_TOOLS) do
        if i > 1 then imgui.SameLine(0, 6) end
        if button('card', tool[1] .. '##tool' .. i, 0) then
            ns.pending = tool[2]
            ns.refocus = true
        end
    end
    imgui.PopStyleVar(1)
    if ns.refocus then
        ns.refocus = false
        imgui.SetKeyboardFocusHere()
    end
    imgui.InputTextMultiline('##note_text', ns.text, ffi.sizeof(ns.text), imgui.ImVec2(width, height),
        imgui.InputTextFlags.CallbackAlways, noteCallback)
end
pcall(jit.off, noteEditor, true)
pcall(jit.off, imgui.InputTextMultiline, true)

local function noteVisible(note, query)
    if ns.tag and not note.tags[ns.tag] then return false end
    return query == '' or note.hay:find(query, 1, true) ~= nil
end

function tabs.notesPanel(W)
    local LIST = 220
    local w = W - LIST - 12
    local childFlags = imgui.WindowFlags.AlwaysUseWindowPadding
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(10, 10))

    imgui.BeginGroup()
    if button('primary', '+ Новая заметка', LIST) then newNote() end
    imgui.PushItemWidth(LIST)
    imgui.InputText('##note_search', ns.search, ffi.sizeof(ns.search))
    imgui.PopItemWidth()
    if ns.search[0] == 0 and not imgui.IsItemActive() then
        local corner = imgui.GetItemRectMin()
        imgui.GetWindowDrawList():AddText(imgui.ImVec2(corner.x + 10, corner.y + 6),
            imgui.GetColorU32Vec4(COLOR.dim), 'Поиск по названию и тексту')
    end
    local query = lowerRu(ffi.string(ns.search))
    imgui.BeginChild('##notes_list', imgui.ImVec2(LIST, imgui.GetContentRegionAvail().y), false, childFlags)
    if #ns.tags > 1 then
        local picked = chips('tagfilter', ns.tags, ns.tag or 'Все', LIST - 30)
        if picked then ns.tag = picked ~= 'Все' and picked or nil end
        gap(1)
        divider(LIST - 30)
        gap(1)
    end
    local shown = 0
    imgui.PushStyleVarVec2(imgui.StyleVar.ButtonTextAlign, imgui.ImVec2(0.06, 0.5))
    for i, note in ipairs(ns.list) do
        if noteVisible(note, query) then
            shown = shown + 1
            if button(note.name == ns.current and 'primary' or 'card', note.name .. '##note' .. i, LIST - 30) then
                openNote(note.name)
            end
        end
    end
    imgui.PopStyleVar(1)
    if shown == 0 then dim(#ns.list == 0 and 'Пока пусто.' or 'Ничего не найдено.') end
    imgui.EndChild()
    imgui.EndGroup()

    imgui.SameLine(0, 12)
    imgui.BeginGroup()
    if ns.editing then
        label('НАЗВАНИЕ')
        imgui.PushItemWidth(w)
        imgui.InputText('##note_title', ns.title, ffi.sizeof(ns.title))
        imgui.PopItemWidth()
        label('ТЕКСТ')
        noteEditor(w, imgui.GetContentRegionAvail().y - 95)
        dim('Выдели текст и нажми кнопку — или кнопка вставит разметку в место курсора.')
        if button('primary', 'Сохранить', 150) then saveNote() end
        imgui.SameLine()
        if button('card', 'Отмена', 120) then
            if ns.current then openNote(ns.current) else ns.editing = false end
        end
    elseif ns.current then
        label(ns.current)
        imgui.BeginChild('##note_view', imgui.ImVec2(w, imgui.GetContentRegionAvail().y - 36), false, childFlags)
        renderMarkdown(ns.doc, w - 34)
        imgui.EndChild()
        if button('primary', 'Редактировать', 150) then ns.editing = true end
        imgui.SameLine()
        if button('danger', ns.confirm and 'Точно удалить?' or 'Удалить', 150) then
            if ns.confirm then deleteNote() else ns.confirm = true end
        end
        imgui.SameLine()
        if button('card', 'Открыть папку', 150) then openFolder(NOTES_DIR) end
    else
        imgui.BeginChild('##note_empty', imgui.ImVec2(w, imgui.GetContentRegionAvail().y), false, childFlags)
        txt('Выбери заметку слева или создай новую.')
        imgui.PushTextWrapPos(0)
        dim('Заметки хранятся обычными .txt в папке «Заметки» рядом с отчётами — туда можно положить и свои файлы.')
        imgui.PopTextWrapPos()
        if button('card', 'Открыть папку', 150) then openFolder(NOTES_DIR) end
        imgui.EndChild()
    end
    imgui.EndGroup()

    imgui.PopStyleVar(1)
end

function tabs.binderPanel(W)
    local LIST = 220
    local w = W - LIST - 12
    local childFlags = imgui.WindowFlags.AlwaysUseWindowPadding
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(10, 10))

    imgui.BeginGroup()
    if button('primary', '+ Новый бинд', LIST) then newBind() end
    imgui.BeginChild('##binds_list', imgui.ImVec2(LIST, imgui.GetContentRegionAvail().y), false, childFlags)
    if #cfg.binds == 0 then dim('Пока пусто.') end
    imgui.PushStyleVarVec2(imgui.StyleVar.ButtonTextAlign, imgui.ImVec2(0.06, 0.5))
    for i, bind in ipairs(cfg.binds) do
        local title = tostring(bind.name) .. (bind.cmd ~= '' and ('   /' .. bind.cmd) or '')
            .. ((tonumber(bind.key) or 0) ~= 0 and ('   [' .. hotkeys.name(bind.key) .. ']') or '')
        if button(i == bs.index and 'primary' or 'card', title .. '##bind' .. i, LIST - 30) then selectBind(i) end
    end
    imgui.PopStyleVar(1)
    imgui.EndChild()
    imgui.EndGroup()

    imgui.SameLine(0, 12)
    imgui.BeginGroup()
    if binder.running then
        imgui.AlignTextToFramePadding()
        colored(COLOR.good, ('Идёт «%s»: строка %d из %d'):format(binder.name, binder.index, binder.total))
        imgui.SameLine(w - 130)
        if button('danger', 'Остановить', 130) then binder.stop = true end
    end

    label('НАЗВАНИЕ')
    imgui.SameLine(w - 300)
    label('КОМАНДА')
    imgui.SameLine(w - 150)
    label('КЛАВИША')
    imgui.PushItemWidth(w - 312)
    imgui.InputText('##bind_name', bs.name, ffi.sizeof(bs.name))
    imgui.PopItemWidth()
    imgui.SameLine(w - 300)
    imgui.PushItemWidth(142)
    imgui.InputText('##bind_command', bs.command, ffi.sizeof(bs.command))
    imgui.PopItemWidth()
    if bs.command[0] == 0 and not imgui.IsItemActive() then
        local corner = imgui.GetItemRectMin()
        imgui.GetWindowDrawList():AddText(imgui.ImVec2(corner.x + 10, corner.y + 6),
            imgui.GetColorU32Vec4(COLOR.dim), 'например: lek1')
    end
    imgui.SameLine(w - 150)
    hotkeys.button('bind', bs.key or 0, 150)

    label('ЗАДЕРЖКА МЕЖДУ СТРОКАМИ')
    imgui.PushItemWidth(w)
    imgui.SliderInt('##bind_delay', bs.delay, 500, 10000, '%d мс')
    imgui.PopItemWidth()

    imgui.Checkbox('Показывать в круговом меню — действие с игроком рядом', bs.wheel)

    label('ТЕКСТ — КАЖДАЯ СТРОКА УХОДИТ ОТДЕЛЬНЫМ СООБЩЕНИЕМ')
    local hints = {
        'Подстановки: {nick} {id} {rank} {tag} {time} {date}. Строки с // пропускаются, длинные делятся сами. Стоп: /tstop',
        'Для кругового меню: {tid} и {tname} — ID и имя игрока рядом, {trank} и {reason} — скрипт спросит ранг и причину.',
    }
    local reserved = 8 + 27
    for _, hint in ipairs(hints) do reserved = reserved + imgui.CalcTextSize(hint, nil, false, w).y + 8 end
    imgui.InputTextMultiline('##bind_text', bs.text, ffi.sizeof(bs.text),
        imgui.ImVec2(w, math.max(80, imgui.GetContentRegionAvail().y - reserved)))
    imgui.PushTextWrapPos(imgui.GetCursorPosX() + w)
    for _, hint in ipairs(hints) do dim(hint) end
    imgui.PopTextWrapPos()

    if button('primary', 'Сохранить', 130) then saveBind() end
    imgui.SameLine()
    if button('card', 'Сохранить и запустить', 190) then
        if saveBind() then runBind(cfg.binds[bs.index]) end
    end
    if bs.index then
        imgui.SameLine()
        if button('danger', bs.confirm and 'Точно удалить?' or 'Удалить', 140) then
            if bs.confirm then deleteBind() else bs.confirm = true end
        end
    end
    imgui.EndGroup()

    imgui.PopStyleVar(1)
end

local games = {
    tab = 10,
    mode = 'ttt',
    ttt = { board = {}, over = nil, wins = 0, losses = 0, draws = 0 },
    snake = { cols = 26, rows = 17, cell = 22 },
    lines = { { 1, 2, 3 }, { 4, 5, 6 }, { 7, 8, 9 }, { 1, 4, 7 }, { 2, 5, 8 }, { 3, 6, 9 }, { 1, 5, 9 }, { 3, 5, 7 } },
    keys = {
        [0x25] = { -1, 0 }, [0x41] = { -1, 0 },
        [0x27] = { 1, 0 }, [0x44] = { 1, 0 },
        [0x26] = { 0, -1 }, [0x57] = { 0, -1 },
        [0x28] = { 0, 1 }, [0x53] = { 0, 1 },
    },
}

function games.tttReset()
    local state = games.ttt
    for i = 1, 9 do state.board[i] = 0 end
    state.over = nil
end

function games.tttResult()
    local board = games.ttt.board
    for _, line in ipairs(games.lines) do
        local mark = board[line[1]]
        if mark ~= 0 and mark == board[line[2]] and mark == board[line[3]] then return mark end
    end
    for i = 1, 9 do
        if board[i] == 0 then return nil end
    end
    return 3
end

function games.tttFinish()
    local state = games.ttt
    state.over = games.tttResult()
    if state.over == 1 then
        state.wins = state.wins + 1
    elseif state.over == 2 then
        state.losses = state.losses + 1
    elseif state.over == 3 then
        state.draws = state.draws + 1
    end
    return state.over ~= nil
end

function games.tttBot()
    local board = games.ttt.board
    for _, mark in ipairs({ 2, 1 }) do
        for _, line in ipairs(games.lines) do
            local count, empty = 0, nil
            for _, cell in ipairs(line) do
                if board[cell] == mark then count = count + 1 elseif board[cell] == 0 then empty = cell end
            end
            if count == 2 and empty and (mark == 2 or math.random() < 0.85) then return empty end
        end
    end
    if board[5] == 0 and math.random() < 0.8 then return 5 end
    local free = {}
    for i = 1, 9 do
        if board[i] == 0 then free[#free + 1] = i end
    end
    return free[math.random(#free)]
end

function games.tttClick(cell)
    local state = games.ttt
    if state.over or state.board[cell] ~= 0 then return end
    state.board[cell] = 1
    if games.tttFinish() then return end
    state.board[games.tttBot()] = 2
    games.tttFinish()
end

function games.snakeFood()
    local snake = games.snake
    for _ = 1, 500 do
        local x, y = math.random(0, snake.cols - 1), math.random(0, snake.rows - 1)
        local free = true
        for _, part in ipairs(snake.body) do
            if part[1] == x and part[2] == y then
                free = false
                break
            end
        end
        if free then
            snake.food = { x, y }
            return
        end
    end
end

function games.snakeReset()
    local snake = games.snake
    local cx, cy = math.floor(snake.cols / 2), math.floor(snake.rows / 2)
    snake.body = { { cx, cy }, { cx - 1, cy }, { cx - 2, cy } }
    snake.dir, snake.turn = { 1, 0 }, { 1, 0 }
    snake.alive, snake.started, snake.paused = true, false, false
    snake.score, snake.interval, snake.last = 0, 0.13, os.clock()
    games.snakeFood()
end

function games.snakeStep()
    local snake = games.snake
    snake.dir = snake.turn
    local head = snake.body[1]
    local x, y = head[1] + snake.dir[1], head[2] + snake.dir[2]
    local hit = x < 0 or y < 0 or x >= snake.cols or y >= snake.rows
    for i = 1, #snake.body - 1 do
        if snake.body[i][1] == x and snake.body[i][2] == y then hit = true end
    end
    if hit then
        snake.alive = false
        if snake.score > cfg.snakeBest then
            cfg.snakeBest = snake.score
            saveConfig()
        end
        return
    end
    table.insert(snake.body, 1, { x, y })
    if x == snake.food[1] and y == snake.food[2] then
        snake.score = snake.score + 1
        snake.interval = math.max(0.06, snake.interval * 0.97)
        games.snakeFood()
    else
        table.remove(snake.body)
    end
end

function games.key(key)
    local snake = games.snake
    if games.mode ~= 'snake' or not snake.body then return false end
    local turn = games.keys[key]
    if turn then
        if snake.alive and not (turn[1] == -snake.dir[1] and turn[2] == -snake.dir[2]) then
            snake.turn = turn
            if not snake.started then snake.started, snake.last = true, os.clock() end
        end
        return true
    end
    if key == 0x20 then
        if snake.alive and snake.started then snake.paused = not snake.paused end
        return true
    end
    if key == 0x0D then
        if not snake.alive then games.snakeReset() end
        return true
    end
    return false
end

function games.drawTtt(W)
    local state = games.ttt
    if #state.board == 0 then games.tttReset() end
    local draw = imgui.GetWindowDrawList()
    local cell, space = 112, 8
    local left = math.floor((W - (cell * 3 + space * 2)) / 2)

    local status = (state.over == 1 and 'Победа!') or (state.over == 2 and 'Победил бот') or (state.over == 3 and 'Ничья')
        or 'Твой ход — ты играешь крестиками'
    local color = (state.over == 1 and COLOR.good) or (state.over == 2 and COLOR.danger) or COLOR.text
    if fonts.heading then imgui.PushFont(fonts.heading) end
    imgui.SetCursorPosX(imgui.GetCursorPosX() + (W - imgui.CalcTextSize(status).x) / 2)
    colored(color, status)
    if fonts.heading then imgui.PopFont() end
    gap(6)

    for row = 0, 2 do
        for column = 0, 2 do
            local index = row * 3 + column + 1
            if column == 0 then
                imgui.SetCursorPosX(imgui.GetCursorPosX() + left)
            else
                imgui.SameLine(0, space)
            end
            if button('card', '##ttt' .. index, cell, cell) then games.tttClick(index) end
            local a, b = imgui.GetItemRectMin(), imgui.GetItemRectMax()
            local mark = state.board[index]
            if mark == 1 then
                local c = imgui.GetColorU32Vec4(COLOR.accent)
                draw:AddLine(imgui.ImVec2(a.x + 28, a.y + 28), imgui.ImVec2(b.x - 28, b.y - 28), c, 6)
                draw:AddLine(imgui.ImVec2(b.x - 28, a.y + 28), imgui.ImVec2(a.x + 28, b.y - 28), c, 6)
            elseif mark == 2 then
                draw:AddCircle(imgui.ImVec2((a.x + b.x) / 2, (a.y + b.y) / 2), 30, imgui.GetColorU32Vec4(COLOR.text), 48, 6)
            end
        end
    end

    gap(8)
    local summary = ('Победы: %d     Поражения: %d     Ничьи: %d'):format(state.wins, state.losses, state.draws)
    imgui.SetCursorPosX(imgui.GetCursorPosX() + (W - imgui.CalcTextSize(summary).x) / 2)
    dim(summary)
    gap(4)
    imgui.SetCursorPosX(imgui.GetCursorPosX() + (W - 200) / 2)
    if button('primary', 'Новая игра', 200) then games.tttReset() end
end

function games.drawSnake(W)
    local snake = games.snake
    if not snake.body then games.snakeReset() end
    if snake.alive and snake.started and not snake.paused then
        local steps = 0
        while os.clock() - snake.last >= snake.interval and steps < 3 and snake.alive do
            snake.last = snake.last + snake.interval
            steps = steps + 1
            games.snakeStep()
        end
        if steps == 3 then snake.last = os.clock() end
    end

    local best = 'Рекорд: ' .. cfg.snakeBest
    txt('Счёт: ' .. snake.score)
    imgui.SameLine(W - imgui.CalcTextSize(best).x)
    dim(best)
    gap(2)

    local draw = imgui.GetWindowDrawList()
    local size = snake.cell
    local width, height = snake.cols * size, snake.rows * size
    imgui.SetCursorPosX(imgui.GetCursorPosX() + math.floor((W - width) / 2))
    local origin = imgui.GetCursorScreenPos()
    draw:AddRectFilled(origin, imgui.ImVec2(origin.x + width, origin.y + height), imgui.GetColorU32Vec4(COLOR.panel), 10)
    draw:AddRect(imgui.ImVec2(origin.x - 1, origin.y - 1), imgui.ImVec2(origin.x + width + 1, origin.y + height + 1),
        imgui.GetColorU32Vec4(COLOR.border), 10)

    local food = snake.food
    draw:AddCircleFilled(imgui.ImVec2(origin.x + food[1] * size + size / 2, origin.y + food[2] * size + size / 2),
        size / 2 - 4, imgui.GetColorU32Vec4(COLOR.good), 16)
    local bodyColor, headColor = imgui.GetColorU32Vec4(COLOR.accentActive), imgui.GetColorU32Vec4(COLOR.accent)
    for i = #snake.body, 1, -1 do
        local part = snake.body[i]
        local x, y = origin.x + part[1] * size, origin.y + part[2] * size
        draw:AddRectFilled(imgui.ImVec2(x + 2, y + 2), imgui.ImVec2(x + size - 2, y + size - 2),
            i == 1 and headColor or bodyColor, 5)
    end

    local message = (not snake.alive and 'Игра окончена — Enter или кнопка «Заново»')
        or (not snake.started and 'Стрелки или WASD — старт')
        or (snake.paused and 'Пауза — пробел')
    if message then
        if fonts.heading then imgui.PushFont(fonts.heading) end
        local textSize = imgui.CalcTextSize(message)
        local x, y = origin.x + (width - textSize.x) / 2, origin.y + (height - textSize.y) / 2
        draw:AddRectFilled(imgui.ImVec2(x - 14, y - 8), imgui.ImVec2(x + textSize.x + 14, y + textSize.y + 8),
            imgui.GetColorU32Vec4(COLOR.window), 10)
        draw:AddText(imgui.ImVec2(x, y), imgui.GetColorU32Vec4(COLOR.text), message)
        if fonts.heading then imgui.PopFont() end
    end
    imgui.Dummy(imgui.ImVec2(width, height))

    gap(4)
    dim('Управление: стрелки или WASD, пробел — пауза. Персонаж на этой вкладке не двигается.')
    if button('primary', 'Заново', 160) then games.snakeReset() end
end

function tabs.gamesPanel(W)
    local half = (W - 8) / 2
    if button(games.mode == 'ttt' and 'primary' or 'card', 'Крестики-нолики', half) then games.mode = 'ttt' end
    imgui.SameLine()
    if button(games.mode == 'snake' and 'primary' or 'card', 'Змейка', half) then games.mode = 'snake' end
    gap(8)
    if games.mode == 'ttt' then games.drawTtt(W) else games.drawSnake(W) end
end

local NOTES_TAB = 6
local NAV = {
    { 'Скриншоты', 'Папки скриншотов', tabs.foldersTab, group = 'ОТЧЁТНОСТЬ' },
    { 'Отчёт', 'Отчёт за неделю', tabs.reportTab },
    { 'Состав', 'Состав в сети', tabs.membersTab, group = 'ОРГАНИЗАЦИЯ' },
    { 'Гос. волна', 'Гос. волна и рация', tabs.govTab },
    { 'Биндер', 'Биндер', tabs.binderPanel, fixed = true, group = 'ИНСТРУМЕНТЫ' },
    { 'Заметки', 'Заметки', tabs.notesPanel, fixed = true },
    { 'Автоскриншоты', 'Настройки скриншотов', tabs.shotSettings, group = 'НАСТРОЙКИ' },
    { 'Виджеты', 'Виджеты на экране', tabs.widgetsTab },
    { 'Общие', 'Общие настройки', tabs.generalTab },
    { 'Таймкиллеры', 'Таймкиллеры', tabs.gamesPanel, fixed = true, group = 'ОТДЫХ' },
}
for i, item in ipairs(NAV) do
    item.section = item.group or NAV[i - 1].section
end
local function initials(nick)
    local first, second = nick:match('^(%a)[^_]*_?(%a?)')
    return ((first or '?') .. (second or '')):upper()
end

local function sidebar(width, height)
    local draw = imgui.GetWindowDrawList()
    local origin = imgui.GetCursorScreenPos()
    local left = imgui.GetCursorPosX()
    local nick = myNick()

    local function centered(text, font, faded)
        if font then imgui.PushFont(font) end
        imgui.SetCursorPosX(left + math.max(0, (width - imgui.CalcTextSize(text).x) / 2))
        if faded then dim(text) else txt(text) end
        if font then imgui.PopFont() end
    end

    if avatar.dirty then
        avatar.dirty = false
        if avatar.texture then
            pcall(imgui.ReleaseTexture, avatar.texture)
            avatar.texture = nil
        end
        if doesFileExist(avatar.ansi) then
            local ok, texture = pcall(imgui.CreateTextureFromFile, avatar.ansi)
            if ok then avatar.texture = texture end
        end
    end
    local radius = 32
    local center = imgui.ImVec2(origin.x + width / 2, origin.y + radius)
    if avatar.texture then
        draw:AddImageRounded(avatar.texture, imgui.ImVec2(center.x - radius, center.y - radius),
            imgui.ImVec2(center.x + radius, center.y + radius), imgui.ImVec2(0, 0), imgui.ImVec2(1, 1), 0xFFFFFFFF, radius)
    else
        draw:AddCircleFilled(center, radius, imgui.GetColorU32Vec4(COLOR.accent), 48)
        if fonts.title then imgui.PushFont(fonts.title) end
        local letters = initials(nick)
        local size = imgui.CalcTextSize(letters)
        draw:AddText(imgui.ImVec2(center.x - size.x / 2, center.y - size.y / 2), imgui.GetColorU32Vec4(COLOR.onAccent), letters)
        if fonts.title then imgui.PopFont() end
    end
    imgui.Dummy(imgui.ImVec2(width, radius * 2))

    imgui.PushStyleVarVec2(imgui.StyleVar.ItemSpacing, imgui.ImVec2(8, 3))
    centered(nick ~= '' and nick or 'TimeShot', fonts.strong)
    centered(cfg.myRank ~= '' and cfg.myRank or 'должность уточняется', fonts.bold, true)
    local termInfo = term.info()
    if termInfo and termInfo.left >= 0 then
        centered('срок: день ' .. termInfo.day .. ' из ' .. termInfo.total, fonts.bold, true)
    end
    centered(os.date('%d.%m.%Y  %H:%M:%S'), fonts.bold, true)
    imgui.PopStyleVar(1)
    gap(2)
    divider(width)
    gap(2)

    if fonts.nav then imgui.PushFont(fonts.nav) end
    imgui.PushStyleVarVec2(imgui.StyleVar.ButtonTextAlign, imgui.ImVec2(0, 0.5))
    imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, imgui.ImVec2(14, 5))
    imgui.PushStyleVarVec2(imgui.StyleVar.ItemSpacing, imgui.ImVec2(8, 3))
    for i, item in ipairs(NAV) do
        if item.group then
            if i > 1 then gap(5) end
            if fonts.bold then imgui.PushFont(fonts.bold) end
            imgui.SetCursorPosX(left + 4)
            dim(item.group)
            if fonts.bold then imgui.PopFont() end
        end
        local selected = menuTab == i
        local p = imgui.GetCursorScreenPos()
        if button(selected and 'card' or 'nav', item[1] .. '##nav' .. i, width, 26) then
            menuTab = i
            if i == NOTES_TAB then refreshNotes() end
        end
        if selected then
            draw:AddRectFilled(imgui.ImVec2(p.x, p.y + 6), imgui.ImVec2(p.x + 3, p.y + 20),
                imgui.GetColorU32Vec4(COLOR.accent), 2)
        end
    end
    imgui.PopStyleVar(3)
    if fonts.nav then imgui.PopFont() end

    if fonts.bold then imgui.PushFont(fonts.bold) end
    imgui.SetCursorPosY(height - 22 - 25 - 20)
    dim('версия ' .. tostring(thisScript().version))
    imgui.SetCursorPosY(height - 22 - 25)
    imgui.AlignTextToFramePadding()
    dim('by ' .. AUTHOR)
    imgui.SameLine(width - 40)
    if button('primary', 'Esc##close', 40) then menuWindow[0] = false end
    if fonts.bold then imgui.PopFont() end
end

imgui.OnFrame(function() return menuWindow[0] end, function(self)
    local SIDE, W, H = 148, 740, 700
    self.LockPlayer = menuTab == games.tab
    local contentX = PAD + SIDE + 28
    centerNextWindow()
    imgui.SetNextWindowSize(imgui.ImVec2(contentX + W + PAD, H), imgui.Cond.Always)
    if fonts.body then imgui.PushFont(fonts.body) end
    imgui.Begin('##timeshot_menu', menuWindow, imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoCollapse
        + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoScrollWithMouse)

    local corner = imgui.GetWindowPos()
    imgui.GetWindowDrawList():AddLine(imgui.ImVec2(corner.x + PAD + SIDE + 14, corner.y + 22),
        imgui.ImVec2(corner.x + PAD + SIDE + 14, corner.y + H - 22), imgui.GetColorU32Vec4(COLOR.border), 1)

    imgui.BeginGroup()
    sidebar(SIDE, H)
    imgui.EndGroup()

    imgui.SameLine(contentX)
    imgui.BeginGroup()
    local item = NAV[menuTab] or NAV[1]
    label(item.section)
    if fonts.title then imgui.PushFont(fonts.title) end
    txt(item[2])
    if fonts.title then imgui.PopFont() end
    gap(1)
    divider(W)
    gap(2)

    imgui.PushStyleColor(imgui.Col.ChildBg, COLOR.clear)
    if item.fixed then
        imgui.BeginChild('##menu_fixed', imgui.ImVec2(W, imgui.GetContentRegionAvail().y), false,
            imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoScrollWithMouse)
        imgui.PopStyleColor(1)
        item[3](W)
    else
        imgui.BeginChild('##menu_content', imgui.ImVec2(W, imgui.GetContentRegionAvail().y), false)
        imgui.PopStyleColor(1)
        item[3](W - 16)
    end
    imgui.EndChild()
    imgui.EndGroup()
    inputActive = imgui.IsAnyItemActive()

    if cfgDirty and not imgui.IsMouseDown(0) then
        cfgDirty = false
        saveConfig()
    end
    imgui.End()
    if fonts.body then imgui.PopFont() end
end)

local overlaysAllowed
do
    local cursor = ffi.new('TS_CURSORINFO')
    overlaysAllowed = function()
        if not isSampAvailable() or isPauseMenuActive() or sampGetGamestate() ~= 3 then return false end
        if pickWindow[0] or radioWindow[0] or wheel.open[0] then return false end
        if menuWindow[0] then return true end
        if sampIsDialogActive() or sampIsCursorActive() or sampIsScoreboardOpen() then return false end
        cursor.cbSize = ffi.sizeof(cursor)
        if ffi.C.GetCursorInfo(cursor) ~= 0 and bit.band(cursor.flags, 1) ~= 0 then return false end
        return true
    end
end

function wheel.drawPrompt(sx, sy)
    local prompt = wheel.prompt
    local W = 360
    imgui.SetNextWindowPos(imgui.ImVec2(sx / 2, sy / 2), imgui.Cond.Always, imgui.ImVec2(0.5, 0.5))
    imgui.Begin('##timeshot_wheel_prompt', nil, imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize
        + imgui.WindowFlags.NoMove + imgui.WindowFlags.AlwaysAutoResize + imgui.WindowFlags.NoSavedSettings)
    if fonts.heading then imgui.PushFont(fonts.heading) end
    txt(prompt.bind.name)
    if fonts.heading then imgui.PopFont() end
    dim((wheel.target.nick:gsub('_', ' ')) .. ' [' .. wheel.target.id .. ']')
    imgui.Dummy(imgui.ImVec2(W, 2))
    if prompt.rank then
        label('НОВЫЙ РАНГ')
        imgui.PushItemWidth(W)
        imgui.SliderInt('##wheel_rank', wheel.rank, 1, 9, 'ранг %d')
        imgui.PopItemWidth()
    end
    if prompt.reason then
        label('ПРИЧИНА')
        imgui.PushItemWidth(W)
        imgui.InputText('##wheel_reason', wheel.reason, ffi.sizeof(wheel.reason))
        imgui.PopItemWidth()
    end
    gap(2)
    local filled = not prompt.reason or ffi.string(wheel.reason):match('%S') ~= nil
    local half = (W - 8) / 2
    if button(filled and 'primary' or 'card', 'Выполнить', half) and filled then wheel.run(prompt.bind) end
    imgui.SameLine()
    if button('card', 'Отмена', half) then wheel.open[0], wheel.prompt = false, nil end
    imgui.End()
end

imgui.OnFrame(function() return wheel.open[0] end, function()
    if not wheel.target or #wheel.items == 0 then
        wheel.open[0] = false
        return
    end
    local sx, sy = getScreenResolution()
    if fonts.body then imgui.PushFont(fonts.body) end
    if wheel.prompt then
        wheel.drawPrompt(sx, sy)
        if fonts.body then imgui.PopFont() end
        return
    end

    imgui.SetNextWindowPos(imgui.ImVec2(0, 0), imgui.Cond.Always)
    imgui.SetNextWindowSize(imgui.ImVec2(sx, sy), imgui.Cond.Always)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(0, 0))
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 0)
    imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0, 0, 0, 0.35))
    imgui.Begin('##timeshot_wheel', nil, imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoMove
        + imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoSavedSettings)

    local draw = imgui.GetWindowDrawList()
    local cx, cy = sx / 2, sy / 2
    local inner, outer = 78, 220
    local count = #wheel.items
    local step = 2 * math.pi / count
    local start = -math.pi / 2 - step / 2
    local mouse = imgui.GetMousePos()
    local dx, dy = mouse.x - cx, mouse.y - cy
    local distance = math.sqrt(dx * dx + dy * dy)
    local hovered
    if distance >= inner and distance <= outer + 30 then
        hovered = math.floor(((math.atan2(dy, dx) - start) % (2 * math.pi)) / step) + 1
        if hovered > count then hovered = count end
    end

    local function point(radius, angle)
        return imgui.ImVec2(cx + math.cos(angle) * radius, cy + math.sin(angle) * radius)
    end
    local idle, active = imgui.GetColorU32Vec4(COLOR.window), imgui.GetColorU32Vec4(COLOR.accent)
    local textIdle, textActive = imgui.GetColorU32Vec4(COLOR.text), imgui.GetColorU32Vec4(COLOR.onAccent)
    if fonts.strong then imgui.PushFont(fonts.strong) end
    for i = 1, count do
        local from, to = start + (i - 1) * step + 0.015, start + i * step - 0.015
        local pieces = math.max(4, math.ceil((to - from) / 0.08))
        local fill = i == hovered and active or idle
        for piece = 0, pieces - 1 do
            local a, b = from + (to - from) * piece / pieces, from + (to - from) * (piece + 1) / pieces
            draw:AddQuadFilled(point(inner, a), point(outer, a), point(outer, b), point(inner, b), fill)
        end

        local name = tostring(wheel.items[i].name)
        local first, second = name, nil
        if imgui.CalcTextSize(name).x > 130 then
            local cut = name:find(' ', math.floor(#name / 2), true) or name:find(' ', 1, true)
            if cut then first, second = name:sub(1, cut - 1), name:sub(cut + 1) end
        end
        local middle = point((inner + outer) / 2, (from + to) / 2)
        local color = i == hovered and textActive or textIdle
        local size = imgui.CalcTextSize(first)
        local top = middle.y - (second and size.y or size.y / 2)
        draw:AddText(imgui.ImVec2(middle.x - size.x / 2, top), color, first)
        if second then
            local size2 = imgui.CalcTextSize(second)
            draw:AddText(imgui.ImVec2(middle.x - size2.x / 2, top + size.y + 2), color, second)
        end
    end
    if fonts.strong then imgui.PopFont() end

    draw:AddCircleFilled(imgui.ImVec2(cx, cy), inner - 8, imgui.GetColorU32Vec4(COLOR.panel), 48)
    local who = (wheel.target.nick:gsub('_', ' '))
    local whoSize = imgui.CalcTextSize(who)
    draw:AddText(imgui.ImVec2(cx - whoSize.x / 2, cy - whoSize.y - 1), textIdle, who)
    local idText = 'ID ' .. wheel.target.id
    local idSize = imgui.CalcTextSize(idText)
    draw:AddText(imgui.ImVec2(cx - idSize.x / 2, cy + 2), imgui.GetColorU32Vec4(COLOR.dim), idText)
    local many = #wheel.targets > 1
    if many then
        local counter = wheel.index .. ' из ' .. #wheel.targets
        local counterSize = imgui.CalcTextSize(counter)
        draw:AddText(imgui.ImVec2(cx - counterSize.x / 2, cy + 22), imgui.GetColorU32Vec4(COLOR.accent), counter)
    end
    local hint = many and 'ЛКМ — выбрать     колёсико или клик по центру — другой игрок     ПКМ или Esc — закрыть'
        or 'ЛКМ — выбрать     ПКМ или Esc — закрыть'
    local hintSize = imgui.CalcTextSize(hint)
    draw:AddText(imgui.ImVec2(cx - hintSize.x / 2, cy + outer + 26), imgui.GetColorU32Vec4(COLOR.text), hint)

    local found, ped = sampGetCharHandleBySampPlayerId(wheel.target.id)
    if found and doesCharExist(ped) and isCharOnScreen(ped) then
        local x, y, z = getCharCoordinates(ped)
        local px, py = convert3DCoordsToScreen(x, y, z + 1.1)
        local marker = imgui.GetColorU32Vec4(COLOR.accent)
        draw:AddTriangleFilled(imgui.ImVec2(px - 10, py - 22), imgui.ImVec2(px + 10, py - 22), imgui.ImVec2(px, py - 6), marker)
        local tag = who .. ' [' .. wheel.target.id .. ']'
        local tagSize = imgui.CalcTextSize(tag)
        draw:AddText(imgui.ImVec2(px - tagSize.x / 2, py - 26 - tagSize.y), marker, tag)
    end

    local scroll = imgui.GetIO().MouseWheel
    if scroll ~= 0 then
        wheel.cycle(scroll > 0 and -1 or 1)
    elseif imgui.IsMouseClicked(0) and distance < inner then
        wheel.cycle(1)
    elseif hovered and imgui.IsMouseClicked(0) then
        wheel.choose(wheel.items[hovered])
    elseif imgui.IsMouseClicked(1) then
        wheel.open[0] = false
    end

    imgui.End()
    imgui.PopStyleColor(1)
    imgui.PopStyleVar(2)
    if fonts.body then imgui.PopFont() end
end)

local hud = imgui.OnFrame(function()
    return cfg.hud and overlaysAllowed()
end, function()
    local sx, sy = getScreenResolution()
    local fx, fy = cfg.hudX / 100, cfg.hudY / 100
    imgui.SetNextWindowPos(imgui.ImVec2(sx * fx, sy * fy), imgui.Cond.Always, imgui.ImVec2(fx, fy))
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(14, 10))
    imgui.PushStyleVarVec2(imgui.StyleVar.ItemSpacing, imgui.ImVec2(8, 4))
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 12)
    if fonts.title then imgui.PushFont(fonts.title) end
    imgui.Begin('##timeshot_hud', nil, imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoMove
        + imgui.WindowFlags.AlwaysAutoResize + imgui.WindowFlags.NoInputs + imgui.WindowFlags.NoFocusOnAppearing
        + imgui.WindowFlags.NoSavedSettings)
    imgui.SetWindowFontScale(cfg.hudSize / (fonts.title and 22 or 14))

    local week = weekOnline(cfg.online)
    local status, _, ok = onlineStatus(week / 3600)
    local rows = {}
    if cfg.hudToday then rows[#rows + 1] = { 'СЕГОДНЯ', formatDuration(cfg.online[os.date('%Y-%m-%d')] or 0) } end
    if cfg.hudWeek then rows[#rows + 1] = { 'ЗА НЕДЕЛЮ', formatDuration(week) } end
    if cfg.hudNorm then
        local left = 21 * 3600 - week
        rows[#rows + 1] = { 'ДО НОРМЫ', left > 0 and formatDuration(left) or 'выполнена', left > 0 and COLOR.text or COLOR.good }
    end
    if cfg.hudStatus then rows[#rows + 1] = { 'СТАТУС', status, ok and COLOR.good or COLOR.danger } end
    if cfg.hudInterviews then
        local done = interviewsToday()
        rows[#rows + 1] = { 'СОБЕСЕДОВАНИЯ', done .. ' / ' .. cfg.interviewNorm, done >= cfg.interviewNorm and COLOR.good or COLOR.danger }
    end
    if cfg.hudNick then
        rows[#rows + 1] = { 'НИК', myNick() }
        if cfg.myRank ~= '' then rows[#rows + 1] = { 'ДОЛЖНОСТЬ', cfg.myRank } end
    end
    if cfg.hudTime then rows[#rows + 1] = { 'ВРЕМЯ', os.date('%H:%M:%S') } end
    if #rows == 0 then rows[1] = { 'ОНЛАЙН', formatDuration(week) } end

    local labelWidth = 0
    for _, row in ipairs(rows) do labelWidth = math.max(labelWidth, imgui.CalcTextSize(row[1]).x) end
    for _, row in ipairs(rows) do
        dim(row[1])
        imgui.SameLine(14 + labelWidth + cfg.hudSize)
        colored(row[3] or COLOR.text, row[2])
    end

    imgui.End()
    if fonts.title then imgui.PopFont() end
    imgui.PopStyleVar(3)
end)
hud.HideCursor = true

local roster = imgui.OnFrame(function()
    return cfg.members and overlaysAllowed()
end, function()
    local sx, sy = getScreenResolution()
    local fx, fy = cfg.membersX / 100, cfg.membersY / 100
    imgui.SetNextWindowPos(imgui.ImVec2(sx * fx, sy * fy), imgui.Cond.Always, imgui.ImVec2(fx, fy))
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(14, 10))
    imgui.PushStyleVarVec2(imgui.StyleVar.ItemSpacing, imgui.ImVec2(8, 3))
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 12)
    if fonts.title then imgui.PushFont(fonts.title) end
    imgui.Begin('##timeshot_roster', nil, imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoMove
        + imgui.WindowFlags.AlwaysAutoResize + imgui.WindowFlags.NoInputs + imgui.WindowFlags.NoFocusOnAppearing
        + imgui.WindowFlags.NoSavedSettings)
    imgui.SetWindowFontScale(cfg.membersSize / (fonts.title and 22 or 14))

    local total = #members.list
    dim('СОСТАВ В СЕТИ')
    imgui.SameLine()
    if cfg.membersNorm > 0 then
        colored(total >= cfg.membersNorm and COLOR.good or COLOR.danger, total .. ' / ' .. cfg.membersNorm)
    else
        txt(tostring(total))
    end

    local shown = math.min(total, cfg.membersMax)
    local nickWidth, rankWidth = 0, 0
    local lines = {}
    for i = 1, shown do
        local member = members.list[i]
        local line = {
            member = member,
            nick = member.nick .. (cfg.membersId and (' [' .. member.id .. ']') or ''),
            rank = cfg.membersRank and (member.rankNumber .. '  ' .. member.rank) or nil,
        }
        nickWidth = math.max(nickWidth, imgui.CalcTextSize(line.nick).x)
        if line.rank then rankWidth = math.max(rankWidth, imgui.CalcTextSize(line.rank).x) end
        lines[i] = line
    end
    local step = cfg.membersSize
    local nickX = 14 + (cfg.membersRank and (math.max(rankWidth, imgui.CalcTextSize('РАНГ').x) + step) or 0)
    local afkX = nickX + math.max(nickWidth, imgui.CalcTextSize('НИК').x) + step
    if shown > 0 then
        if cfg.membersRank then
            dim('РАНГ')
            imgui.SameLine(nickX)
        end
        dim('НИК')
        if cfg.membersAfk then
            imgui.SameLine(afkX)
            dim('AFK')
        end
        local p = imgui.GetCursorScreenPos()
        local right = p.x + afkX - 14 + (cfg.membersAfk and imgui.CalcTextSize('AFK 0000').x or 0)
        imgui.GetWindowDrawList():AddLine(imgui.ImVec2(p.x, p.y), imgui.ImVec2(right, p.y),
            imgui.GetColorU32Vec4(COLOR.border), 1)
        imgui.Dummy(imgui.ImVec2(right - p.x, 2))
    end
    for i, line in ipairs(lines) do
        if i % 2 == 0 then
            local p = imgui.GetCursorScreenPos()
            imgui.GetWindowDrawList():AddRectFilled(imgui.ImVec2(p.x - 6, p.y - 1),
                imgui.ImVec2(p.x + afkX - 14 + (cfg.membersAfk and imgui.CalcTextSize('AFK 0000').x or 0) + 6,
                    p.y + imgui.CalcTextSize('A').y + 1), imgui.GetColorU32Vec4(COLOR.stripe), 4)
        end
        if line.rank then
            dim(line.rank)
            imgui.SameLine(nickX)
        end
        colored(line.member.working and COLOR.text or COLOR.dim, line.nick)
        if cfg.membersAfk and line.member.afk > 0 then
            imgui.SameLine(afkX)
            colored(COLOR.danger, tostring(line.member.afk))
        end
    end
    if total > shown then dim('и ещё ' .. (total - shown)) end
    if members.at == 0 then dim('ждём первый /members…') end

    imgui.End()
    if fonts.title then imgui.PopFont() end
    imgui.PopStyleVar(3)
end)
roster.HideCursor = true

imgui.OnFrame(function() return radioWindow[0] end, function()
    local W = 480
    local from = cfg.ownTag ~= '' and ('От: [' .. cfg.ownTag .. ']') or 'Свой тег не выбран: /tmenu, вкладка «Гос»'
    beginWindow('##timeshot_radio', W, 'РАЦИЯ /d', from, radioWindow)

    card(W, 'КОМУ', function(w)
        local picked = chips('to', RADIO_TAGS, radioTarget, w)
        if picked then radioTarget = picked end
    end)

    local entered, message
    card(W, 'СООБЩЕНИЕ', function(w)
        imgui.PushItemWidth(w)
        entered = imgui.InputText('##radio', radioText, ffi.sizeof(radioText), imgui.InputTextFlags.EnterReturnsTrue)
        imgui.PopItemWidth()
        message = ffi.string(radioText)
        dim(('/d [%s] - [%s]: %s'):format(cfg.ownTag ~= '' and cfg.ownTag or '?', radioTarget, message))
    end)

    if (button('primary', 'Отправить в рацию', W) or entered) and message:match('%S') then
        if sendRadio(radioTarget, message) then
            ffi.fill(radioText, ffi.sizeof(radioText))
            radioWindow[0] = false
        end
    end
    endWindow(W, radioWindow, 'ЗАКРЫТЬ')
end)

local widget = imgui.OnFrame(function()
    return cfg.widget and overlaysAllowed()
end, function()
    local sx = getScreenResolution()
    imgui.SetNextWindowPos(imgui.ImVec2(sx / 2, 10), imgui.Cond.Always, imgui.ImVec2(0.5, 0))
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(14, 8))
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 12)
    if fonts.bold then imgui.PushFont(fonts.bold) end
    imgui.Begin('##timeshot_widget', nil, imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoMove
        + imgui.WindowFlags.AlwaysAutoResize + imgui.WindowFlags.NoInputs + imgui.WindowFlags.NoFocusOnAppearing
        + imgui.WindowFlags.NoSavedSettings)

    local slot = nearestFreeSlot()
    dim('СЛОТ')
    imgui.SameLine()
    txt(slot and os.date('%H:%M', slot) or 'все заняты')
    imgui.SameLine(0, 18)
    dim('ГОС. ВОЛНА')
    imgui.SameLine()
    local remaining = govReadyAt() - os.time()
    if remaining > 0 then colored(COLOR.danger, 'через ' .. countdown(remaining)) else colored(COLOR.good, 'можно') end

    imgui.End()
    if fonts.bold then imgui.PopFont() end
    imgui.PopStyleVar(2)
end)
widget.HideCursor = true

function onWindowMessage(msg, wparam, lparam)
    if msg == 0x112 and bit.band(tonumber(wparam) or 0, 0xFFF0) == 0xF100 then
        consumeWindowMessage(true, false)
        return
    end
    if hotkeys.message(msg, wparam, lparam) then
        consumeWindowMessage(true, true)
        return
    end
    if hotkeys.skipEscape and wparam == 0x1B and msg == 0x101 then
        hotkeys.skipEscape = false
        consumeWindowMessage(true, true)
        return
    end
    if (msg == 0x100 or msg == 0x101) and menuWindow[0] and menuTab == games.tab and not pickWindow[0] and not radioWindow[0] then
        local known = games.keys[wparam] or wparam == 0x20 or wparam == 0x0D
        if known and games.mode == 'snake' then
            consumeWindowMessage(true, false)
            if msg == 0x100 then games.key(wparam) end
            return
        end
    end
    if msg == 0x113 and wparam == AFK_TIMER then
        consumeWindowMessage(true, true)
        pcall(afkTick)
        return
    end
    if (msg == 0x100 or msg == 0x101) and wparam == 0x1B and not isPauseMenuActive()
        and (pickWindow[0] or menuWindow[0] or radioWindow[0] or wheel.open[0]) then
        if menuWindow[0] and not pickWindow[0] and not radioWindow[0]
            and (inputActive or (menuTab == NOTES_TAB and ns.editing)) then
            consumeWindowMessage(true, true)
            return
        end
        consumeWindowMessage(true, false)
        if msg == 0x101 then
            if wheel.open[0] then
                wheel.open[0], wheel.prompt = false, nil
            elseif pickWindow[0] then
                discardPending()
            elseif radioWindow[0] then
                radioWindow[0] = false
            else
                menuWindow[0] = false
            end
        end
    end
end

function onScriptTerminate(script)
    if script == thisScript() then
        if gameWindow then ffi.C.KillTimer(gameWindow, AFK_TIMER) end
        if cfg.sens then pcall(sens.restore) end
        saveConfig()
    end
end

function main()
    if not isSampLoaded() or not isSampfuncsLoaded() then return end
    while not isSampAvailable() do wait(100) end

    math.randomseed(os.time())
    loadConfig()
    ffi.copy(booking.place, cfg.interviewPlace:sub(1, 90))
    ffi.copy(term.input, cfg.termStart:sub(1, 15))
    ensureDir(BASE_DIR)
    fs.remove(TEMP_FILE)
    refreshStats()

    gameWindow = ffi.cast('void*', readMemory(0x00C8CF88, 4, false))
    ffi.C.SetTimer(gameWindow, AFK_TIMER, 1000, nil)

    pcall(sens.capture)
    lua_thread.create(function()
        while true do
            wait(0)
            sens.apply()
        end
    end)

    sampRegisterChatCommand('t', cmdShot)
    sampRegisterChatCommand('tmenu', function()
        menuWindow[0] = not menuWindow[0]
        if menuWindow[0] then
            refreshStats()
            if cfg.myRank == '' and not members.asked then
                members.asked = true
                requestMembers()
            end
        end
    end)
    sampRegisterChatCommand('td', function() radioWindow[0] = not radioWindow[0] end)
    sampRegisterChatCommand('tstop', function()
        if binder.running then binder.stop = true else notify('Сейчас ни один бинд не запущен.') end
    end)
    sampRegisterChatCommand('tavatar', function() takeAvatar(false) end)
    sampRegisterChatCommand('tupdate', function() update.check(true) end)
    registerBinds()
    local function toggleNotes()
        if menuWindow[0] and menuTab == NOTES_TAB then
            menuWindow[0] = false
        else
            menuTab = NOTES_TAB
            menuWindow[0] = true
            refreshNotes()
            refreshStats()
        end
    end
    sampRegisterChatCommand('tn', toggleNotes)
    sampRegisterChatCommand('tnotes', toggleNotes)
    local function shortcut(code, command)
        return '{4FA3FF}' .. (code ~= 0 and hotkeys.name(code) or command) .. '{FFFFFF}'
    end
    sampAddChatMessage(cp('TimeShot {FFFFFF}' .. update.current() .. ' {808080}by {FFD166}jalisco {808080}— скрипт загружен'), 0x4FA3FF)
    local hints = {
        shortcut(cfg.keys.menu, '/tmenu') .. ' меню',
        shortcut(cfg.keys.shot, '/t') .. ' скриншот с /time',
        shortcut(cfg.keys.radio, '/td') .. ' рация департамента',
    }
    if cfg.keys.wheel ~= 0 then hints[#hints + 1] = shortcut(cfg.keys.wheel, '') .. ' действия с игроком рядом' end
    sampAddChatMessage(cp(table.concat(hints, ' {808080}| ')), 0xFFFFFF)

    wait(3000)
    if BASE_FALLBACK then
        notify('Папка в «Документах» недоступна, скриншоты и заметки сохраняю в {4FA3FF}moonloader\\TimeShot')
    end
    if deadlineDay() then remindDeadline() end
    term.remind()
    update.check(false)

    while true do
        wait(1000)
        tick()
    end
end
