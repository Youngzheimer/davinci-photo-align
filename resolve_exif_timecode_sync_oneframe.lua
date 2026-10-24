-- DaVinci Resolve: assign Start TC to stills from camera capture timestamps.
-- Select exactly ONE reference video + one or more still images in the Media Pool.
-- Run from Workspace > Scripts > Utility (or the Resolve Lua console).
--
-- Requires ExifTool: macOS Homebrew: brew install exiftool
-- This changes Resolve Media Pool Start TC values only; it does NOT rewrite source EXIF.
-- DRY_RUN defaults to true. Inspect the output first, then set DRY_RUN=false and rerun.
--
-- Timestamp comparison uses camera-local wall-clock values, without converting QuickTime UTC.
-- This is appropriate when photos/video were recorded in the same local timezone. If the
-- video's metadata timestamp is wrong/UTC while photo EXIF is local, set the override below.

-- ============================ USER CONFIGURATION =============================
local REFERENCE_VIDEO_TC = "01:00:00:00"
local DRY_RUN = false
local SET_REFERENCE_VIDEO_TC = true
local VIDEO_START_DATETIME_OVERRIDE = "" -- e.g. "2026-10-24 14:10:00", else read video metadata
local MAX_ABS_OFFSET_SECONDS = 12 * 60 * 60

local EXIFTOOL_CANDIDATES = {
    "/opt/homebrew/bin/exiftool",
    "/usr/local/bin/exiftool",
    "/usr/bin/exiftool",
}

local VIDEO_EXTENSIONS = {
    [".mov"] = true, [".mp4"] = true, [".m4v"] = true, [".mxf"] = true,
    [".avi"] = true, [".mts"] = true, [".m2ts"] = true, [".mpg"] = true,
    [".mpeg"] = true, [".mkv"] = true, [".webm"] = true, [".3gp"] = true,
    [".braw"] = true, [".r3d"] = true, [".crm"] = true, [".ari"] = true,
}
local IMAGE_EXTENSIONS = {
    [".jpg"] = true, [".jpeg"] = true, [".heic"] = true, [".heif"] = true,
    [".png"] = true, [".tif"] = true, [".tiff"] = true, [".bmp"] = true,
    [".dng"] = true, [".arw"] = true, [".srf"] = true, [".sr2"] = true,
    [".cr2"] = true, [".cr3"] = true, [".nef"] = true, [".nrw"] = true,
    [".orf"] = true, [".rw2"] = true, [".raf"] = true, [".pef"] = true,
    [".srw"] = true, [".3fr"] = true, [".fff"] = true, [".iiq"] = true,
    [".mos"] = true, [".mef"] = true, [".mrw"] = true, [".x3f"] = true,
}

-- ExifTool columns are returned in this exact order by the command below.
local TAG_COLUMNS = {
    "QuickTime:CreationDate", "Keys:CreationDate", "EXIF:DateTimeOriginal",
    "QuickTime:CreateDate", "QuickTime:MediaCreateDate", "QuickTime:TrackCreateDate",
    "XMP:CreateDate", "XMP:DateCreated", "EXIF:CreateDate", "EXIF:DateTimeDigitized",
    "QuickTime:DateTimeOriginal", "Composite:SubSecDateTimeOriginal", "EXIF:SubSecTimeOriginal",
}
local VIDEO_PRIORITY = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12}
local PHOTO_PRIORITY = {12, 3, 9, 1, 2, 8, 7, 10, 11, 4, 5, 6}

-- ================================= HELPERS ===================================
-- Keep output in memory as well as print() so it can be written to a visible report.
local REPORT_LINES = {}
local function fail(message)
    error(message, 0)
end

local function log(message)
    message = tostring(message or "")
    REPORT_LINES[#REPORT_LINES + 1] = message
    print(message)
end

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function shell_quote(s)
    -- POSIX shell escaping; Resolve is usually running on macOS/Linux here.
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function file_exists(path)
    local f = io.open(path, "rb")
    if f then f:close(); return true end
    return false
end

local function find_exiftool()
    for _, path in ipairs(EXIFTOOL_CANDIDATES) do
        if file_exists(path) then return path end
    end
    local pipe = io.popen("command -v exiftool 2>/dev/null", "r")
    if pipe then
        local path = trim(pipe:read("*l") or "")
        pipe:close()
        if path ~= "" then return path end
    end
    return nil
end

local function normalize_path(path)
    path = trim(path)
    path = path:gsub("^file://", "")
    return path
end

local function get_clip_property(clip, key)
    local ok, value = pcall(function() return clip:GetClipProperty(key) end)
    if ok and value ~= nil then return trim(value) end
    return ""
end

local function clip_path(clip)
    for _, key in ipairs({"File Path", "Filepath", "Source File", "Full Path"}) do
        local path = normalize_path(get_clip_property(clip, key))
        if path ~= "" and file_exists(path) then return path end
    end
    return nil
end

local function clip_name(clip, fallback)
    local ok, name = pcall(function() return clip:GetName() end)
    if ok and name and tostring(name) ~= "" then return tostring(name) end
    return fallback or "(unknown clip)"
end

local function extension(path)
    local ext = path:match("(%.[^%.%/\\]+)$") or ""
    return string.lower(ext)
end

local function classify(path)
    local ext = extension(path)
    if VIDEO_EXTENSIONS[ext] then return "video" end
    if IMAGE_EXTENSIONS[ext] then return "image" end
    return "unsupported"
end

local function split_tabs(line)
    local output, start = {}, 1
    while true do
        local idx = string.find(line, "\t", start, true)
        if not idx then
            output[#output + 1] = string.sub(line, start)
            break
        end
        output[#output + 1] = string.sub(line, start, idx - 1)
        start = idx + 1
    end
    return output
end

local function read_exiftool(path, exiftool)
    local tags = {
        "-QuickTime:CreationDate", "-Keys:CreationDate", "-EXIF:DateTimeOriginal",
        "-QuickTime:CreateDate", "-QuickTime:MediaCreateDate", "-QuickTime:TrackCreateDate",
        "-XMP:CreateDate", "-XMP:DateCreated", "-EXIF:CreateDate", "-EXIF:DateTimeDigitized",
        "-QuickTime:DateTimeOriginal", "-Composite:SubSecDateTimeOriginal", "-EXIF:SubSecTimeOriginal",
    }
    local command = shell_quote(exiftool) .. " -T -api QuickTimeUTC=0 " .. table.concat(tags, " ") ..
        " -- " .. shell_quote(path) .. " 2>/dev/null"
    local pipe = io.popen(command, "r")
    if not pipe then fail("ExifTool 실행을 시작하지 못함: " .. path) end
    local line = pipe:read("*l") or ""
    local close_ok = pipe:close()
    if line == "" then fail("ExifTool에서 날짜 메타데이터를 반환하지 않음: " .. path) end
    local values = split_tabs(line)
    local metadata = {}
    for i, tag in ipairs(TAG_COLUMNS) do
        metadata[tag] = trim(values[i] or "")
    end
    metadata["_exiftool_close"] = tostring(close_ok)
    return metadata
end

local function parse_wall_datetime(value)
    value = trim(value)
    if value == "" or value == "-" then return nil end
    -- Accept EXIF YYYY:MM:DD HH:MM:SS[.fraction] and ISO YYYY-MM-DDTHH:MM:SS[.fraction]+TZ.
    local y, mo, d, h, mi, s, frac = value:match(
        "(%d%d%d%d)[%:%/%-](%d%d)[%:%/%-](%d%d)[ T](%d%d):(%d%d):(%d%d)[%.,]?([%d]*)"
    )
    if not y then return nil end
    y, mo, d, h, mi, s = tonumber(y), tonumber(mo), tonumber(d), tonumber(h), tonumber(mi), tonumber(s)
    if not y or y < 1990 or y > 2100 or mo < 1 or mo > 12 or d < 1 or d > 31 or
       h > 23 or mi > 59 or s > 59 then return nil end
    local fraction = 0
    if frac and frac ~= "" then fraction = tonumber("0." .. frac) or 0 end
    -- Validate day/month including leap years through a simple round-trip date check.
    local leap = (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0
    local month_days = {31, leap and 29 or 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}
    if d > month_days[mo] then return nil end

    -- Gregorian civil date -> day number. This deliberately ignores timezone/DST and compares
    -- wall-clock times from the recording devices rather than using the Mac's local timezone.
    local yy = y - (mo <= 2 and 1 or 0)
    local era = math.floor(yy / 400)
    local yoe = yy - era * 400
    local mp = mo + (mo > 2 and -3 or 9)
    local doy = math.floor((153 * mp + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    local days = era * 146097 + doe
    return days * 86400 + h * 3600 + mi * 60 + s + fraction
end

local function timestamp_for(metadata, kind)
    local priority = kind == "video" and VIDEO_PRIORITY or PHOTO_PRIORITY
    for _, index in ipairs(priority) do
        local tag = TAG_COLUMNS[index]
        local raw = metadata[tag]
        local timestamp = parse_wall_datetime(raw)
        if timestamp then
            -- EXIF subseconds may be stored separately from DateTimeOriginal.
            if index == 3 and raw:find("[%.,]%d+") == nil then
                local subsec = metadata["EXIF:SubSecTimeOriginal"] or ""
                local digits = subsec:gsub("%D", "")
                if digits ~= "" then timestamp = timestamp + (tonumber("0." .. digits) or 0) end
            end
            return timestamp, tag, raw
        end
    end
    local diagnostic = {}
    for _, tag in ipairs(TAG_COLUMNS) do
        local value = metadata[tag]
        if value and value ~= "" and value ~= "-" then
            diagnostic[#diagnostic + 1] = tag .. "=" .. value
        end
    end
    return nil, nil, (#diagnostic > 0 and table.concat(diagnostic, "; ") or "시간 관련 태그 없음")
end

local function parse_fps(value)
    local text = tostring(value or "")
    local upper = string.upper(text)
    local token = text:match("(%d+%.?%d*)")
    if not token then fail("프레임률을 해석할 수 없음: " .. text) end
    local n = tonumber(token)
    if math.abs(n - 23.976) < 0.01 then return 24000 / 1001, 24, upper:find("DF", 1, true) ~= nil end
    if math.abs(n - 29.97) < 0.01 then return 30000 / 1001, 30, upper:find("DF", 1, true) ~= nil end
    if math.abs(n - 47.952) < 0.01 then return 48000 / 1001, 48, upper:find("DF", 1, true) ~= nil end
    if math.abs(n - 59.94) < 0.01 then return 60000 / 1001, 60, upper:find("DF", 1, true) ~= nil end
    if math.abs(n - 119.88) < 0.01 then return 120000 / 1001, 120, upper:find("DF", 1, true) ~= nil end
    return n, math.floor(n + 0.5), upper:find("DF", 1, true) ~= nil
end

local function parse_tc(tc)
    local h, m, s, f = tostring(tc or ""):match("^(%d%d):(%d%d):(%d%d)[:;](%d%d%d?)$")
    h, m, s, f = tonumber(h), tonumber(m), tonumber(s), tonumber(f)
    if not h then fail("타임코드는 HH:MM:SS:FF 형식이어야 함: " .. tostring(tc)) end
    if h >= 24 or m >= 60 or s >= 60 then fail("유효하지 않은 타임코드: " .. tostring(tc)) end
    return h, m, s, f
end

local function tc_to_frames(tc, nominal, drop)
    local h, m, s, f = parse_tc(tc)
    if f >= nominal then fail("프레임 번호가 FPS보다 큼: " .. tc) end
    if drop > 0 and (m % 10 ~= 0) and s == 0 and f < drop then
        fail("드롭프레임에서 생략되는 타임코드: " .. tc)
    end
    local total_minutes = h * 60 + m
    local frames = ((h * 3600 + m * 60 + s) * nominal) + f
    if drop > 0 then frames = frames - drop * (total_minutes - math.floor(total_minutes / 10)) end
    return frames
end

local function frames_to_tc(frame_count, nominal, drop)
    local frames_per_24h = nominal * 24 * 60 * 60
    local frame_number = frame_count
    if drop > 0 then
        local frames_per_10m = nominal * 600 - drop * 9
        frames_per_24h = frames_per_24h - drop * (24 * 60 - 24 * 6)
        local ten_min_chunks = math.floor(frame_count / frames_per_10m)
        local remainder = frame_count % frames_per_10m
        frame_number = frame_count + drop * 9 * ten_min_chunks
        frame_number = frame_number + drop * math.max(0, math.floor((remainder - drop) / (nominal * 60 - drop)))
    end
    if frame_count < 0 or frame_count >= frames_per_24h then
        fail("계산된 타임코드가 24시간 범위를 벗어남 (frames=" .. tostring(frame_count) .. ")")
    end
    local ff = frame_number % nominal
    local total_seconds = math.floor(frame_number / nominal)
    local ss = total_seconds % 60
    local mm = math.floor(total_seconds / 60) % 60
    local hh = math.floor(total_seconds / 3600) % 24
    return string.format("%02d:%02d:%02d:%02d", hh, mm, ss, ff)
end

local function round_half_away_from_zero(value)
    if value >= 0 then return math.floor(value + 0.5) end
    return math.ceil(value - 0.5)
end

local function normalize_tc(value)
    value = trim(value):gsub(";", ":")
    local h, m, s, f = value:match("^(%d%d?):(%d%d?):(%d%d?):(%d%d%d?)$")
    if h then return string.format("%02d:%02d:%02d:%02d", tonumber(h), tonumber(m), tonumber(s), tonumber(f)) end
    return value
end

local function set_tc(clip, new_tc)
    local result = clip:SetClipProperty("Start TC", new_tc)
    local actual = get_clip_property(clip, "Start TC")
    if result == false or normalize_tc(actual) ~= normalize_tc(new_tc) then
        fail("Start TC 검증 실패: 요청=" .. new_tc .. ", API 반환=" .. tostring(result) .. ", 실제값=" .. tostring(actual))
    end
end

-- ================================= MAIN ======================================
local function main()
    -- Scripts launched from Workspace > Scripts already receive the global `resolve`
    -- object in supported builds. Prefer it; bmd.scriptapp("Resolve") is mainly a
    -- bootstrap for standalone scripts and may return nil in some builds/contexts.
    local resolve_api = resolve -- read Resolve's injected global before declaring locals
    local connection_notes = {}

    local function usable_api(candidate, label)
        if candidate == nil then
            connection_notes[#connection_notes + 1] = label .. "=nil"
            return nil
        end
        local ok_pm, pm = pcall(function() return candidate:GetProjectManager() end)
        if ok_pm and pm ~= nil then
            connection_notes[#connection_notes + 1] = label .. "=OK"
            return candidate
        end
        connection_notes[#connection_notes + 1] = label .. " exists, GetProjectManager failed: " .. tostring(pm)
        return nil
    end

    resolve_api = usable_api(resolve_api, "global resolve")

    -- Fall back to the conventional lookup only if the injected object was unavailable.
    if not resolve_api then
        if bmd and type(bmd.scriptapp) == "function" then
            local ok_connect, candidate = pcall(function() return bmd.scriptapp("Resolve") end)
            if ok_connect then
                resolve_api = usable_api(candidate, "bmd.scriptapp(Resolve)")
            else
                connection_notes[#connection_notes + 1] = "bmd.scriptapp raised: " .. tostring(candidate)
            end
        else
            connection_notes[#connection_notes + 1] = "bmd/scriptapp unavailable (bmd type=" .. type(bmd) .. ")"
        end
    end

    if not resolve_api then
        fail("DaVinci Resolve API에 연결할 수 없음.\n" ..
            "진단: " .. table.concat(connection_notes, "; ") .. "\n" ..
            "Resolve 앱 안의 Workspace > Scripts 메뉴에서 실행했는지 확인하세요. " ..
            "무료 Resolve 21.1 이상에서는 빌드에 따라 scripting API가 제한될 수 있습니다.")
    end

    local project_manager = resolve_api:GetProjectManager()
    local project = project_manager and project_manager:GetCurrentProject() or nil
    if not project then fail("열린 프로젝트가 없음") end
    local media_pool = project:GetMediaPool()
    if not media_pool then fail("Media Pool에 접근할 수 없음") end
    local selected = media_pool:GetSelectedClips()
    if not selected or #selected == 0 then
        fail("Media Pool에서 기준 영상 1개와 사진들을 함께 선택한 뒤 실행하세요. 선택이 없으면 아무 작업도 하지 않습니다.")
    end

    local records, unsupported = {}, {}
    for _, clip in ipairs(selected) do
        local path = clip_path(clip)
        if not path then
            unsupported[#unsupported + 1] = clip_name(clip) .. " (파일 경로를 못 읽음)"
        else
            local kind = classify(path)
            if kind == "unsupported" then
                unsupported[#unsupported + 1] = clip_name(clip, path) .. " (확장자 " .. extension(path) .. ")"
            else
                records[#records + 1] = {
                    clip = clip, path = path, kind = kind, name = clip_name(clip, path),
                    old_tc = get_clip_property(clip, "Start TC"),
                }
            end
        end
    end
    if #unsupported > 0 then
        fail("선택에 처리할 수 없는 항목이 있음. 영상 1개 + 사진만 선택하세요:\n  - " .. table.concat(unsupported, "\n  - "))
    end
    local videos, photos = {}, {}
    for _, item in ipairs(records) do
        if item.kind == "video" then videos[#videos + 1] = item else photos[#photos + 1] = item end
    end
    if #videos ~= 1 then fail("선택한 영상은 정확히 1개여야 함 (현재 " .. #videos .. ")") end
    if #photos == 0 then fail("사진 파일이 선택되지 않음") end
    for _, item in ipairs(records) do
        if item.old_tc == "" then fail("기존 Start TC를 읽지 못해 안전하게 진행할 수 없음: " .. item.name) end
    end

    local project_fps_setting = tostring(project:GetSetting("timelineFrameRate") or "")
    local project_fps, nominal_fps, fps_string_df = parse_fps(project_fps_setting)
    local drop_setting = tostring(project:GetSetting("timelineDropFrameTimecode") or "0")
    local drop_enabled = fps_string_df or drop_setting == "1" or string.lower(drop_setting) == "true"
    local drop_frames = 0
    if drop_enabled then
        if nominal_fps == 30 and math.abs(project_fps - 30000 / 1001) < 0.01 then
            drop_frames = 2
        elseif nominal_fps == 60 and math.abs(project_fps - 60000 / 1001) < 0.01 then
            drop_frames = 4
        else
            fail("Drop Frame은 29.97 DF/59.94 DF만 지원함: " .. project_fps_setting)
        end
    end

    local video = videos[1]
    local video_fps_text = get_clip_property(video.clip, "FPS")
    if video_fps_text == "" then fail("기준 영상의 FPS를 Resolve에서 읽지 못해 중단함") end
    local video_fps = parse_fps(video_fps_text)
    if math.abs(video_fps - project_fps) > 0.0001 then
        fail("기준 영상 FPS(" .. video_fps_text .. ")와 타임라인 FPS(" .. project_fps_setting .. ")가 다름. 타임라인 FPS를 기준 영상에 맞추고 다시 실행하세요.")
    end

    local exiftool = find_exiftool()
    if not exiftool then fail("ExifTool을 찾지 못함. 터미널에서 'brew install exiftool' 실행 후 재시도하세요.") end

    local video_time, video_tag, video_raw
    if trim(VIDEO_START_DATETIME_OVERRIDE) ~= "" then
        video_time = parse_wall_datetime(VIDEO_START_DATETIME_OVERRIDE)
        if not video_time then fail("VIDEO_START_DATETIME_OVERRIDE 형식 오류: YYYY-MM-DD HH:MM:SS 사용") end
        video_tag, video_raw = "사용자 지정 override", VIDEO_START_DATETIME_OVERRIDE
    else
        local metadata = read_exiftool(video.path, exiftool)
        video_time, video_tag, video_raw = timestamp_for(metadata, "video")
        if not video_time then
            fail("영상 녹화 시각을 EXIF/QuickTime 메타데이터에서 찾지 못함.\n파일=" .. video.path .. "\n관련 태그=" .. tostring(video_raw) .. "\nVIDEO_START_DATETIME_OVERRIDE에 실제 시작 시각을 입력하세요.")
        end
    end

    local anchor_frames = tc_to_frames(REFERENCE_VIDEO_TC, nominal_fps, drop_frames)
    local planned = {}
    for _, item in ipairs(photos) do
        local metadata = read_exiftool(item.path, exiftool)
        local photo_time, photo_tag, photo_raw = timestamp_for(metadata, "photo")
        if not photo_time then fail("사진 촬영 시각을 읽지 못함: " .. item.path .. "\n관련 태그=" .. tostring(photo_raw)) end
        local delta = photo_time - video_time
        if math.abs(delta) > MAX_ABS_OFFSET_SECONDS then
            fail(string.format("영상과 사진 시각 차이가 %.1f시간 한도를 초과함: %s / delta=%+.3fs. 시간대나 메타데이터를 확인하세요.", MAX_ABS_OFFSET_SECONDS / 3600, item.name, delta))
        end
        local delta_frames = round_half_away_from_zero(delta * project_fps)
        item.timestamp = photo_time
        item.timestamp_tag = photo_tag
        item.timestamp_raw = photo_raw
        item.delta = delta
        item.delta_frames = delta_frames
        item.target_frame = anchor_frames + delta_frames
        planned[#planned + 1] = item
    end

    -- Keep photos chronological, then give every photo its own frame.
    -- When multiple photos resolve to the same frame (including identical EXIF times),
    -- move later entries forward one frame at a time instead of aborting the run.
    table.sort(planned, function(a, b)
        if a.timestamp == b.timestamp then return a.name < b.name end
        return a.timestamp < b.timestamp
    end)

    local previous_frame = nil
    for _, item in ipairs(planned) do
        local assigned_frame = item.target_frame
        if previous_frame ~= nil and assigned_frame <= previous_frame then
            assigned_frame = previous_frame + 1
        end
        item.frame_adjustment = assigned_frame - item.target_frame
        item.new_tc = frames_to_tc(assigned_frame, nominal_fps, drop_frames)
        previous_frame = assigned_frame
    end

    -- Retain a diagnostic check, but duplicate timecodes are no longer fatal.
    local by_tc, duplicates = {}, {}
    for _, item in ipairs(planned) do
        by_tc[item.new_tc] = by_tc[item.new_tc] or {}
        table.insert(by_tc[item.new_tc], item.name)
    end
    for tc, names in pairs(by_tc) do
        if #names > 1 then duplicates[#duplicates + 1] = {tc = tc, names = names} end
    end

    log(string.rep("=", 88))
    log("DaVinci Resolve EXIF → Start TC 계산 결과")
    log("FPS: " .. project_fps_setting .. " (nominal " .. nominal_fps .. ", DF=" .. tostring(drop_frames > 0) .. ")")
    log("기준 영상: " .. video.name)
    log("영상 녹화 시각: " .. video_raw .. " [" .. video_tag .. "]")
    log("영상 Start TC: " .. video.old_tc .. " → " .. (SET_REFERENCE_VIDEO_TC and REFERENCE_VIDEO_TC or "변경 안 함"))
    log("모드: " .. (DRY_RUN and "DRY RUN (변경 없음)" or "실제 적용"))
    log(string.rep("-", 88))
    for _, item in ipairs(planned) do
        local sign = item.delta >= 0 and "+" or ""
        local adjustment_note = item.frame_adjustment > 0
            and string.format(" (중복 프레임 해소: +%d frame)", item.frame_adjustment)
            or ""
        log(string.format("%s\n  촬영 시각: %s [%s]\n  영상 시작 대비: %s%.3fs (%s%d frames)\n  Start TC: %s → %s%s",
            item.name, item.timestamp_raw, item.timestamp_tag, sign, item.delta, sign, item.delta_frames,
            item.old_tc, item.new_tc, adjustment_note))
    end
    if #duplicates > 0 then
        log("[경고] 순차 프레임 배정 후에도 같은 Start TC가 발견되었습니다:")
        for _, group in ipairs(duplicates) do log("  " .. group.tc .. ": " .. table.concat(group.names, ", ")) end
    end

    local changes = {}
    if SET_REFERENCE_VIDEO_TC then
        changes[#changes + 1] = {clip = video.clip, name = video.name, old_tc = video.old_tc, new_tc = REFERENCE_VIDEO_TC}
    end
    for _, item in ipairs(planned) do
        changes[#changes + 1] = {clip = item.clip, name = item.name, old_tc = item.old_tc, new_tc = item.new_tc}
    end
    if DRY_RUN then
        log("DRY_RUN=true: 아무것도 수정하지 않았습니다. 출력이 맞으면 파일 상단 DRY_RUN=false로 바꿔 재실행하세요.")
        return
    end

    local attempted = {}
    local ok, err = pcall(function()
        for _, change in ipairs(changes) do
            attempted[#attempted + 1] = change -- include partial writes in rollback
            set_tc(change.clip, change.new_tc)
            log("적용 확인: " .. change.name .. " → " .. change.new_tc)
        end
    end)
    if not ok then
        log("[오류] 적용 중 실패: " .. tostring(err))
        log("시도한 항목을 기존 Start TC로 복원합니다...")
        local rollback_errors = {}
        for i = #attempted, 1, -1 do
            local change = attempted[i]
            local rollback_ok, rollback_err = pcall(function() set_tc(change.clip, change.old_tc) end)
            if not rollback_ok then rollback_errors[#rollback_errors + 1] = change.name .. " (" .. tostring(rollback_err) .. ")" end
        end
        if #rollback_errors > 0 then
            log("[중요] 자동 복원 실패 항목; Media Pool에서 직접 확인하세요:\n  - " .. table.concat(rollback_errors, "\n  - "))
        else
            log("시도한 항목을 모두 이전 Start TC로 복원했습니다.")
        end
        fail("작업 실패. 성공으로 간주하지 마세요.")
    end
    log("완료: 기준 영상 1개와 사진 " .. #planned .. "개에 Start TC를 설정하고 읽어서 검증했습니다.")
    log("원본 사진 EXIF는 변경하지 않았습니다. Resolve Media Pool 내부 Start TC만 변경했습니다.")
end

local ok, err = pcall(main)
if not ok then
    log("\n[중단] " .. tostring(err))
end

-- Write a durable, user-visible report. Try Desktop first, then /tmp as a fallback.
local function write_report()
    local home = os.getenv("HOME") or "/tmp"
    local candidates = {
        home .. "/Desktop/resolve_exif_timecode_sync.log",
        "/tmp/resolve_exif_timecode_sync.log",
    }
    local report_path, report_file, last_error = nil, nil, nil
    for _, candidate in ipairs(candidates) do
        local f, open_error = io.open(candidate, "w")
        if f then
            report_path, report_file = candidate, f
            break
        end
        last_error = open_error
    end
    if not report_file then
        -- No report file could be created; keep the error visible in the in-app dialog.
        return nil, "로그 파일을 만들 수 없습니다: " .. tostring(last_error)
    end

    report_file:write("DaVinci Resolve EXIF → Start TC 결과\n")
    report_file:write("실행 시각: " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n")
    report_file:write("결과: " .. (ok and "스크립트가 오류 없이 종료됨" or "오류로 중단됨") .. "\n")
    report_file:write(string.rep("=", 88) .. "\n")
    for _, line in ipairs(REPORT_LINES) do
        report_file:write(line .. "\n")
    end
    report_file:flush()
    report_file:close()
    return report_path, nil
end

local report_path, report_error = write_report()
local dialog_message
if report_error then
    dialog_message = ok
        and "실행은 끝났지만 로그 파일을 만들 수 없습니다. Resolve 콘솔을 확인하세요."
        or "오류로 중단되었고 로그 파일도 만들 수 없습니다. Resolve 콘솔을 확인하세요."
else
    dialog_message = ok
        and "실행 결과를 로그 파일로 저장했습니다. 확인을 누르면 전체 결과를 TextEdit에서 엽니다."
        or "스크립트가 오류로 중단되었습니다. 확인을 누르면 오류 로그를 TextEdit에서 엽니다."
end

-- A native macOS alert makes it clear that the dry-run finished; opening the report after
-- dismissal exposes the full per-photo timestamp/TC table and any error details.
local osascript = "/usr/bin/osascript"
local alert_script = 'display dialog "' .. dialog_message ..
    '" with title "Resolve EXIF Timecode Sync" buttons {"확인"} default button "확인"'

if file_exists(osascript) then
    pcall(os.execute, osascript .. " -e " .. shell_quote(alert_script) .. " >/dev/null 2>&1")
end
if report_path and file_exists("/usr/bin/open") then
    pcall(os.execute, "/usr/bin/open -a TextEdit " .. shell_quote(report_path) .. " >/dev/null 2>&1")
end
