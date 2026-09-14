local Srunix = _G.Srunix
local VFS = Srunix.VFS
local SB = Srunix.SB
local Utils = Srunix.Utils
local Users = Srunix.Users

-- ============================================================
-- LOGGING
-- ============================================================
local function srunixLog(category, message)
    local ok, f = pcall(fs.open, "/srunix/var/log/srunix.log", "a")
    if not ok or not f then return end
    local t = (os.time and os.time()) or 0
    local d = (os.day and os.day()) or 0
    local u = (Srunix and Srunix.user) or "?"
    pcall(function()
        f.writeLine(string.format("[d%d t%d] [%s] [%s] %s", d, t, u, category, message or ""))
    end)
    f.close()
end
_G.srunixLog = srunixLog

-- LOG-ROTATION-MARKER
do
    local logDir = "/srunix/var/log"
    if not fs.exists(logDir) then pcall(fs.makeDir, logDir) end
    local currentLog = logDir .. "/srunix.log"
    if fs.exists(currentLog) then
        local sz = fs.getSize(currentLog) or 0
        if sz > 0 then
            local prevLog = logDir .. "/prev.log"
            if fs.exists(prevLog) then pcall(fs.delete, prevLog) end
            pcall(fs.move, currentLog, prevLog)
        end
    end
    local f = fs.open(currentLog, "w")
    if f then
        f.writeLine("=== Srunix shell started ===")
        f.close()
    end
end



-- ============================================================
-- PRINT FAMILY
-- ============================================================
local function cat(...)
    local n = select("#", ...)
    local t = {}
    for i = 1, n do t[i] = tostring(select(i, ...)) end
    return table.concat(t, "\t")
end

local function col(x)
    if Srunix and Srunix.colorOverride then return Srunix.colorOverride end
    return x
end

local function spr(...)     SB.addLine(cat(...), col(colors.white)) end
local function sprOk(...)   SB.addLine(cat(...), col(colors.lime)) end
local function sprErr(...)  local m = cat(...) SB.addLine(m, col(colors.red)) srunixLog("ERR", m) end
local function sprWarn(...) SB.addLine(cat(...), col(colors.yellow)) end
local function sprInfo(...) SB.addLine(cat(...), col(colors.cyan)) end
local function sprHead(...) SB.addLine(cat(...), col(colors.cyan)) end
local function sprc(c, ...) SB.addLine(cat(...), col(c)) end

Srunix.print = spr
Srunix.env.print = spr
Srunix.env.sprc = sprc

local function sprCmd(cmd, argstr, desc)
    argstr = argstr or ""
    desc = desc or ""
    local segs = {
        {text = "  ", color = col(colors.white)},
        {text = cmd, color = col(colors.purple)},
    }
    if argstr ~= "" then
        table.insert(segs, {text = " " .. argstr, color = col(colors.lime)})
    end
    local len = 2 + #cmd
    if argstr ~= "" then len = len + 1 + #argstr end
    if desc ~= "" then
        local pad = 32 - len
        if pad < 2 then pad = 2 end
        table.insert(segs, {text = string.rep(" ", pad) .. "- " .. desc, color = col(colors.white)})
    end
    SB.addSegments(segs)
end

local function sprUsage(usage)
    local cmd, rest = usage:match("^(%S+)%s*(.*)$")
    if not cmd then spr(usage) return end
    local segs = {{text = cmd, color = col(colors.purple)}}
    if rest and rest ~= "" then
        table.insert(segs, {text = " " .. rest, color = col(colors.lime)})
    end
    SB.addSegments(segs)
end

-- ============================================================
-- HISTORY
-- ============================================================
local HIST_LIMIT = 200

local function historyPath()
    if not Srunix.home then return nil end
    return Srunix.home .. "/.srunix_history"
end

local function loadHistory()
    Srunix.history = {}
    local p = historyPath()
    if not p or not fs.exists(p) then return end
    local f = fs.open(p, "r")
    if not f then return end
    local data = f.readAll()
    f.close()
    for line in (data .. "\n"):gmatch("([^\n]*)\n") do
        if line ~= "" then table.insert(Srunix.history, line) end
    end
end

local function saveHistory()
    local p = historyPath()
    if not p then return end
    if Srunix.home and not fs.exists(Srunix.home) then
        pcall(fs.makeDir, Srunix.home)
    end
    local f = fs.open(p, "w")
    if not f then return end
    local start = math.max(1, #Srunix.history - HIST_LIMIT + 1)
    local out = {}
    for i = start, #Srunix.history do
        table.insert(out, Srunix.history[i])
    end
    f.write(table.concat(out, "\n"))
    f.close()
end

local function pushHistory(cmd)
    if not cmd or cmd == "" then return end
    if #Srunix.history > 0 and Srunix.history[#Srunix.history] == cmd then return end
    table.insert(Srunix.history, cmd)
    if #Srunix.history > HIST_LIMIT then
        table.remove(Srunix.history, 1)
    end
    saveHistory()
end

loadHistory()

-- ============================================================
-- INPUT
-- ============================================================
local function split(str)
    local t = {}
    for w in str:gmatch("%S+") do table.insert(t, w) end
    return t
end

local function promptColor()
    if Srunix.uid == 0 then return colors.lightBlue end
    return colors.lime
end

local function drawPromptLine()
    local h = select(2, term.getSize())
    term.setBackgroundColor(colors.black)
    term.setCursorPos(1, h)
    term.clearLine()
    term.setTextColor(SB.colorOverride or SB.pendingPromptColor or colors.white)
    term.write(SB.pendingPrompt)
    term.setTextColor(SB.colorOverride or SB.pendingInputColor or colors.white)
    term.write(SB.pendingInput)
end

-- Physical key codes -> characters (layout-independent).
-- The same physical key gives the same code no matter the keyboard layout.
local KEY_LETTERS = {
    [keys.a]="a",[keys.b]="b",[keys.c]="c",[keys.d]="d",[keys.e]="e",
    [keys.f]="f",[keys.g]="g",[keys.h]="h",[keys.i]="i",[keys.j]="j",
    [keys.k]="k",[keys.l]="l",[keys.m]="m",[keys.n]="n",[keys.o]="o",
    [keys.p]="p",[keys.q]="q",[keys.r]="r",[keys.s]="s",[keys.t]="t",
    [keys.u]="u",[keys.v]="v",[keys.w]="w",[keys.x]="x",[keys.y]="y",
    [keys.z]="z",
}
local KEY_DIGITS = {
    [keys.zero]="0",[keys.one]="1",[keys.two]="2",[keys.three]="3",
    [keys.four]="4",[keys.five]="5",[keys.six]="6",[keys.seven]="7",
    [keys.eight]="8",[keys.nine]="9",
}
local KEY_SYMBOLS = {
    [keys.space]=" ",
    [keys.minus]="-",[keys.equals]="=",
    [keys.leftBracket]="[",[keys.rightBracket]="]",
    [keys.backslash]="\\",[keys.semicolon]=";",
    [keys.apostrophe]="'",[keys.comma]=",",
    [keys.period]=".",[keys.slash]="/",[keys.grave]="`",
}
local KEY_SYMBOLS_SHIFT = {
    [keys.zero]=")",[keys.one]="!",[keys.two]="@",[keys.three]="#",
    [keys.four]="$",[keys.five]="%",[keys.six]="^",[keys.seven]="&",
    [keys.eight]="*",[keys.nine]="(",
    [keys.minus]="_",[keys.equals]="+",
    [keys.leftBracket]="{",[keys.rightBracket]="}",
    [keys.backslash]="|",[keys.semicolon]=":",
    [keys.apostrophe]="\"",[keys.comma]="<",
    [keys.period]=">",[keys.slash]="?",[keys.grave]="~",
    [keys.space]=" ",
}

local function keyToChar(code, shift)
    local l = KEY_LETTERS[code]
    if l then
        if shift then return l:upper() end
        return l
    end
    if shift then
        local s = KEY_SYMBOLS_SHIFT[code]
        if s then return s end
        local d = KEY_DIGITS[code]
        if d then return d end
    else
        local d = KEY_DIGITS[code]
        if d then return d end
        local s = KEY_SYMBOLS[code]
        if s then return s end
    end
    return nil
end

local function sread(prompt)
    local buf = ""
    SB.pendingPrompt = prompt or ""
    SB.pendingPromptColor = promptColor()
    SB.pendingInputColor = colors.white
    SB.pendingInput = ""
    SB.redraw()
    pcall(term.setCursorBlink, true)

    local histIdx = #Srunix.history + 1
    local savedBuf = ""
    local shiftDown = false

    while true do
        local event, p1 = os.pullEvent()
        if event == "key" then
            if p1 == keys.leftShift or p1 == keys.rightShift then
                shiftDown = true
            elseif p1 == keys.enter or p1 == keys.numPadEnter then
                SB.pendingPrompt = ""
                SB.pendingInput = ""
                SB.pendingPromptColor = nil
                SB.pendingInputColor = nil
                return buf
            elseif p1 == keys.backspace then
                if #buf > 0 then
                    buf = buf:sub(1, -2)
                    SB.pendingInput = buf
                    drawPromptLine()
                end
            elseif p1 == keys.up then
                if #Srunix.history > 0 then
                    if histIdx == #Srunix.history + 1 then
                        savedBuf = buf
                        histIdx = #Srunix.history
                        buf = Srunix.history[histIdx] or ""
                    elseif histIdx > 1 then
                        histIdx = histIdx - 1
                        buf = Srunix.history[histIdx] or ""
                    end
                    SB.pendingInput = buf
                    drawPromptLine()
                end
            elseif p1 == keys.down then
                if histIdx < #Srunix.history then
                    histIdx = histIdx + 1
                    buf = Srunix.history[histIdx] or ""
                elseif histIdx == #Srunix.history then
                    histIdx = histIdx + 1
                    buf = savedBuf
                end
                SB.pendingInput = buf
                drawPromptLine()
            else
                local ch = keyToChar(p1, shiftDown)
                if ch then
                    buf = buf .. ch
                    SB.pendingInput = buf
                    drawPromptLine()
                    histIdx = #Srunix.history + 1
                end
            end
        elseif event == "key_up" then
            if p1 == keys.leftShift or p1 == keys.rightShift then
                shiftDown = false
            end
        elseif event == "char" then
            -- Ignored: char events would double with key events,
            -- and don't fire for Cyrillic anyway. We rely on "key" only.
        elseif event == "paste" then
            buf = buf .. p1
            SB.pendingInput = buf
            drawPromptLine()
            histIdx = #Srunix.history + 1
        elseif event == "mouse_scroll" then
            SB.handleScroll(p1)
            drawPromptLine()
        end
    end
end

Srunix.env.sread = sread

-- ============================================================
-- EXTERNAL COMMANDS
-- ============================================================

local function resolveCommand(cmd)
    if type(cmd) ~= "string" or cmd == "" then return nil end

    local candidates = {}

    if cmd:match("^%.") or cmd:match("^/") or cmd:match("^%a:") then
        candidates[#candidates + 1] = cmd
        if not cmd:match("%.lua$") then
            candidates[#candidates + 1] = cmd .. ".lua"
        end
    else
        local cwd = Srunix.cwd or "C:\\"
        if cwd:sub(-1) ~= "\\" then cwd = cwd .. "\\" end

        candidates[#candidates + 1] = cwd .. cmd .. ".lua"
        candidates[#candidates + 1] = cwd .. cmd
        candidates[#candidates + 1] = "/srunix/bin/" .. cmd .. ".lua"
        candidates[#candidates + 1] = "/srunix/bin/" .. cmd
        candidates[#candidates + 1] = "/rom/programs/" .. cmd .. ".lua"
        candidates[#candidates + 1] = "/rom/programs/" .. cmd
        candidates[#candidates + 1] = "/rom/programs/fun/" .. cmd .. ".lua"
        candidates[#candidates + 1] = "/rom/programs/fun/" .. cmd
        candidates[#candidates + 1] = "/rom/programs/advanced/" .. cmd .. ".lua"
        candidates[#candidates + 1] = "/rom/apis/" .. cmd .. ".lua"
    end

    for _, c in ipairs(candidates) do
        local real = VFS.realpath(c)
        if fs.exists(real) and not fs.isDir(real) then
            return real
        end
    end
    return nil
end

local function isCCProgram(realPath)
    return realPath:sub(1, 5) == "/rom/"
end

local function tryExternal(cmd, args)
    local real = resolveCommand(cmd)
    if not real then return false end

    if not Users.canAccess(Srunix.user, Srunix.uid, real, "x") then
        sprErr("Permission denied: " .. cmd)
        return true
    end

    if isCCProgram(real) then
        local ok, compat = pcall(dofile, "/srunix/kernel/compat.lua")
        if not ok or not compat then
            sprErr("compat.lua not found, cannot run: " .. cmd)
            return true
        end
        local progArgs = {}
        for i = 2, #args do progArgs[#progArgs + 1] = args[i] end
        compat.run(real, table.unpack(progArgs))
        return true
    end

    local f = fs.open(real, "r")
    if not f then return false end
    local code = f.readAll()
    f.close()

    local chunk, err = load(code, "@" .. real, "t")
    if not chunk then
        sprErr("compile: " .. tostring(err))
        return true
    end

    Srunix.args = args or {}

    local progArgs = {}
    for i = 2, #(args or {}) do progArgs[#progArgs + 1] = args[i] end

    local ok, runerr = pcall(function()
        parallel.waitForAny(function()
            chunk(table.unpack(progArgs))
        end)
    end)
    if not ok then sprErr(tostring(runerr)) end
    return true
end

-- ============================================================
-- HELPERS
-- ============================================================
local function cmd_cd(args)
    if not args[2] then spr(Srunix.cwd) return end
    local target = args[2]
    if target == ".." then
        local drive, parts = VFS.parse(Srunix.cwd)
        table.remove(parts)
        local newcwd = drive .. "\\"
        if #parts > 0 then
            newcwd = drive .. "\\" .. table.concat(parts, "\\") .. "\\"
        end
        Srunix.cwd = newcwd
        return
    end
    local test
    if target:match("^%a:") then
        test = target
    else
        test = Srunix.cwd .. (Srunix.cwd:sub(-1) == "\\" and "" or "\\") .. target
    end
    if VFS.isDir(test) then
        Srunix.cwd = test
        if Srunix.cwd:sub(-1) ~= "\\" then Srunix.cwd = Srunix.cwd .. "\\" end
    else
        sprErr("The system cannot find the path specified.")
    end
end

local function formatMode(mode)
    local function bits(n)
        local r = (n >= 4) and "r" or "-"
        local w = (n == 2 or n == 3 or n == 6 or n == 7) and "w" or "-"
        local x = (n % 2 == 1) and "x" or "-"
        return r .. w .. x
    end
    local o = math.floor(mode / 64) % 8
    local g = math.floor(mode / 8) % 8
    local t = mode % 8
    return bits(o) .. bits(g) .. bits(t)
end

local function lsLong(path)
    local items = VFS.list(path)
    table.sort(items)
    for _, name in ipairs(items) do
        local full = path
        if full:sub(-1) ~= "\\" then full = full .. "\\" end
        full = full .. name
        local real = VFS.realpath(full)
        local p = Users.getPerms(real)
        local owner, group, mode
        if p then
            owner, group, mode = p.owner, p.group, p.mode
        else
            owner, group = "root", "root"
            mode = fs.isDir(real) and tonumber("755", 8) or tonumber("644", 8)
        end
        local isdir = fs.isDir(real)
        local line = string.format("%s%s %-8s %-8s %s%s",
            isdir and "d" or "-", formatMode(mode), owner, group, name, isdir and "/" or "")
        if isdir then sprc(colors.cyan, line)
        else spr(line) end
    end
end

-- ============================================================
-- MAIN LOOP
-- ============================================================
SB.init()
sprHead("Srunix " .. (Srunix.version or "?"))
spr("Booted as: " .. Srunix.user .. " (uid=" .. Srunix.uid .. ")")
spr("Type 'help' for a list of commands.")
spr("")

while true do
    local line = sread(Srunix.user .. "@srunix " .. Srunix.cwd .. ">")
    SB.addLine(Srunix.user .. "@srunix " .. Srunix.cwd .. ">" .. (line or ""), col(promptColor()))

    if line and line ~= "" then
        srunixLog("CMD", line)
        pushHistory(line)
        local args = split(line)
        local cmd = args[1]:lower()

        if cmd == "dir" or cmd == "ls" then
            if args[2] == "-l" or args[2] == "/l" then
                lsLong(args[3] or Srunix.cwd)
            else
                local items = VFS.list(args[2] or Srunix.cwd)
                table.sort(items)
                if cmd == "dir" then
                    sprHead(" Directory of " .. (args[2] or Srunix.cwd))
                    spr("")
                end
                for _, n in ipairs(items) do
                    local full = (args[2] or Srunix.cwd)
                    if full:sub(-1) ~= "\\" then full = full .. "\\" end
                    full = full .. n
                    if VFS.isDir(full) then sprc(colors.cyan, "   " .. n)
                    else spr("   " .. n) end
                end
            end

        elseif cmd == "cd" or cmd == "chdir" then
            cmd_cd(args)

        elseif cmd == "type" or cmd == "cat" then
            if not args[2] then sprWarn("specify a file")
            else
                local data = VFS.read(args[2])
                if data then spr(data) else sprErr("File not found or permission denied") end
            end

        elseif cmd == "del" or cmd == "rm" then
            if not args[2] then sprWarn("specify a file")
            elseif VFS.delete(args[2]) then sprOk("Deleted: " .. args[2])
            else sprErr("File not found or permission denied") end

        elseif cmd == "copy" or cmd == "cp" then
            if not args[2] or not args[3] then sprWarn("copy <source> <destination>")
            else
                local data = VFS.read(args[2])
                if data then
                    if VFS.write(args[3], data) then sprOk("Copied")
                    else sprErr("Permission denied") end
                else sprErr("Source not found or permission denied") end
            end

        elseif cmd == "move" or cmd == "mv" then
            if not args[2] or not args[3] then sprWarn("move <source> <destination>")
            else
                local data = VFS.read(args[2])
                if data then
                    if VFS.write(args[3], data) and VFS.delete(args[2]) then sprOk("Moved")
                    else sprErr("Permission denied") end
                else sprErr("Source not found or permission denied") end
            end

        elseif cmd == "md" or cmd == "mkdir" then
            if args[2] then
                if VFS.mkdir(args[2]) then sprOk("Folder created")
                else sprErr("Permission denied") end
            else sprWarn("md <name>") end

        elseif cmd == "pwd" then spr(Srunix.cwd)
        elseif cmd == "echo" then spr(table.concat(args, " ", 2))

        elseif cmd == "colorall" or cmd == "color" then
            local c = args[2] and args[2]:lower()
            if not c or c == "reset" or c == "off" or c == "default" then
                SB.colorOverride = nil
                sprOk("Color override cleared.")
            elseif c == "status" or c == "show" then
                if SB.colorOverride then
                    sprc(colors.white, "Color override active.")
                else
                    spr("No color override.")
                end
            elseif Utils.colorNames[c] then
                SB.colorOverride = Utils.colorNames[c]
                SB.addLine("All output now " .. c .. ".", SB.colorOverride)
                SB.addLine("Type 'colorall reset' to restore.", SB.colorOverride)
            else
                sprErr("Unknown color: " .. tostring(c))
                spr("Available: " .. table.concat(Utils.colorOrder, " "))
            end

        elseif cmd == "clear" or cmd == "cls" then
            SB.lines = {}
            SB.scrollOffset = 0
            SB.redraw()

        elseif cmd == "colors" then
            sprHead("=== Srunix color palette ===")
            for _, name in ipairs(Utils.colorOrder) do
                local val = Utils.colorNames[name]
                local mark = (val ~= colors.black) and "*" or " "
                sprc(val, string.format(" %s %-12s = %5d", mark, name, val))
            end
            spr("")
            spr("(* = used in random selection)")

        elseif cmd == "loglevel" then
            local lvl = args[2]
            if not lvl then
                spr("Current log level: " .. (Utils.logLevelNames[Utils.currentLogLevel] or "?"))
            else
                lvl = lvl:upper()
                if Utils.logLevels[lvl] then
                    Utils.currentLogLevel = Utils.logLevels[lvl]
                    sprOk("Log level set to " .. lvl)
                else
                    sprErr("Invalid level. Use: error | warn | info | debug")
                end
            end

        elseif cmd == "history" then
            if args[2] == "-c" then
                Srunix.history = {}
                saveHistory()
                sprOk("History cleared.")
            else
                for i, h in ipairs(Srunix.history) do
                    sprc(colors.gray, string.format("%4d  ", i))
                    spr(h)
                end
            end

        elseif cmd == "run" then
            if args[2] then
                if not tryExternal(args[2], {table.unpack(args, 3)}) then
                    sprErr("run: '" .. args[2] .. "' not found")
                end
            else sprWarn("run <file>") end

        elseif cmd == "login" then
            local name = args[2]
            if not name then name = sread("login: ") end
            if not name or name == "" then name = "root" end
            local pass = sread("Password: ")
            if Users.authenticate(name, pass) then
                Users.setCurrent(name)
                sprOk("Login successful as " .. name)
                loadHistory()
            else
                sprErr("Login incorrect")
            end

        elseif cmd == "logout" then
            if Srunix.uid == 0 and Srunix.user == "root" then
                sprWarn("Already root")
            else
                Users.setCurrent("root")
                sprOk("Logged out, now root")
                loadHistory()
            end

        elseif cmd == "whoami" then spr(Srunix.user)

        elseif cmd == "id" then
            spr("uid=" .. Srunix.uid .. "(" .. Srunix.user .. ") gid=" .. Srunix.gid)

        elseif cmd == "users" then
            local names, info = Users.listUsers()
            for _, n in ipairs(names) do
                local line2 = string.format("%-12s uid=%-5d gid=%-5d home=%s",
                    n, info[n].uid, info[n].gid, info[n].home)
                if info[n].uid == 0 then sprc(colors.cyan, line2)
                else spr(line2) end
            end

        elseif cmd == "useradd" then
            if Srunix.uid ~= 0 then sprErr("Permission denied")
            elseif not args[2] then sprWarn("usage: useradd <name>")
            else
                local name = args[2]
                local _, info = Users.listUsers()
                local maxuid = 999
                for _, u in pairs(info) do
                    if u.uid > maxuid then maxuid = u.uid end
                end
                local uid = maxuid + 1
                local home = "/srunix/home/" .. name
                local ok, err = Users.addUser(name, uid, 1000, home)
                if ok then
                    fs.makeDir(home)
                    sprOk("User " .. name .. " created (uid=" .. uid .. ")")
                else sprErr("useradd: " .. tostring(err)) end
            end

        elseif cmd == "userdel" then
            if Srunix.uid ~= 0 then sprErr("Permission denied")
            elseif not args[2] then sprWarn("usage: userdel <name>")
            else
                local ok, err = Users.deleteUser(args[2])
                if ok then sprOk("User " .. args[2] .. " deleted")
                else sprErr("userdel: " .. tostring(err)) end
            end

        elseif cmd == "passwd" then
            local target = args[2] or Srunix.user
            if target ~= Srunix.user and Srunix.uid ~= 0 then
                sprErr("Permission denied: only root can change others' passwords")
            else
                local p1 = sread("New password: ")
                local p2 = sread("Repeat: ")
                if p1 ~= p2 then sprErr("Passwords do not match")
                else
                    Users.setPassword(target, p1)
                    sprOk("Password changed for " .. target)
                end
            end

        elseif cmd == "chmod" then
            if not args[2] or not args[3] then sprWarn("usage: chmod <mode> <file>")
            else
                local real = VFS.realpath(args[3])
                if not fs.exists(real) then
                    sprErr("chmod: no such file: " .. args[3])
                else
                    local p = Users.getPerms(real)
                    local owner = p and p.owner or Srunix.user
                    local group = p and p.group or "users"
                    if Srunix.uid ~= 0 and Srunix.user ~= owner then
                        sprErr("chmod: permission denied")
                    else
                        local mode = tonumber(args[2], 8)
                        if not mode then sprErr("chmod: invalid mode")
                        else
                            Users.setPerms(real, owner, group, mode)
                            sprOk("Mode changed: " .. args[3] .. " -> " .. args[2])
                        end
                    end
                end
            end

        elseif cmd == "chown" then
            if not args[2] or not args[3] then sprWarn("usage: chown <user>[:group] <file>")
            elseif Srunix.uid ~= 0 then sprErr("chown: permission denied (root only)")
            else
                local real = VFS.realpath(args[3])
                if not fs.exists(real) then
                    sprErr("chown: no such file: " .. args[3])
                else
                    local newowner, newgroup = args[2]:match("^([^:]+):?(.*)$")
                    if newgroup == "" then newgroup = nil end
                    local p = Users.getPerms(real)
                    local owner = newowner or (p and p.owner) or "root"
                    local group = newgroup or (p and p.group) or "root"
                    local mode = (p and p.mode) or tonumber("644", 8)
                    Users.setPerms(real, owner, group, mode)
                    sprOk("Owner changed: " .. args[3] .. " -> " .. owner .. ":" .. group)
                end
            end

        elseif cmd == "log" then
            local logDir = "/srunix/var/log"
            local sub = args[2] or "tail"
            if sub == "clear" then
                local f = fs.open(logDir .. "/srunix.log", "w")
                if f then f.close() end
                sprOk("Log cleared.")
            elseif sub == "prev" then
                local pp = logDir .. "/prev.log"
                if not fs.exists(pp) then
                    sprWarn("No prev log.")
                else
                    local f = fs.open(pp, "r")
                    local data = f.readAll()
                    f.close()
                    spr(data)
                end
            elseif sub == "cat" then
                local f = fs.open(logDir .. "/srunix.log", "r")
                if not f then sprWarn("No log.") return end
                local data = f.readAll()
                f.close()
                spr(data)
            elseif sub == "dir" or sub == "ls" then
                if fs.exists(logDir) then
                    for _, name in ipairs(fs.list(logDir)) do
                        local sz = fs.getSize(logDir .. "/" .. name) or 0
                        spr(string.format("  %-20s %6d bytes", name, sz))
                    end
                else
                    sprWarn("No log dir.")
                end
            else
                local f = fs.open(logDir .. "/srunix.log", "r")
                if not f then sprWarn("No log.") return end
                local lines = {}
                for line in f.readLine do lines[#lines+1] = line end
                f.close()
                local start = math.max(1, #lines - 19)
                for i = start, #lines do spr(lines[i]) end
                spr("")
                spr("Total: "..#lines.." lines. 'log cat' for all, 'log prev' for previous boot.")
            end

        elseif cmd == "ver" then
            sprHead("Srunix " .. (Srunix.version or "?"))
            spr("Host: " .. (Srunix.hostname or "?"))
            spr("User: " .. Srunix.user)

        elseif cmd == "help" then
            local sub = args[2] and args[2]:lower()
            if sub == "make-root" then sub = "makeroot" end

            local CMD_HELP = {
                morse = {"morse <text>", "  Encode or decode Morse code.", "  Auto-detect: numbers/dots = decode, letters = encode."},
                about = {"about", "  Show system info with ASCII art."},
                neofetch = {"neofetch", "  Alias for about."},
                colorall = {"colorall <color>", "  Override ALL output color.", "  colorall reset - restore normal colors."},
                diag = {"diag", "  Save diagnostics to /srunix/diag.txt."},
                log = {"log [tail|cat|clear]", "  Control log file at /srunix/var/log/srunix.log."},
                scan = {"scan", "  Check startup.lua and key files for changes."},
                pic = {"pic [list|last|random|<name>|<N>]", "  Show images.", "  Default: list. Use Q to exit list, Q to exit image."},
                srun = {"srun [n]", "  Print SRUN n times."},
                cube = {"cube [size] [color] [mode]", "  Rotating 3D cube."},
                textnum = {"textnum <word>", "  Letters to number."},
                print = {"print <msg> [color] [size]", "  Colored message."},
                chmod = {"chmod <mode> <file>", "  Change permissions."},
                chown = {"chown <user>[:<group>] <file>", "  Change owner (root)."},
                history = {"history [-c]", "  Command history."},
                colors = {"colors", "  Show color palette."},
                loglevel = {"loglevel [level]", "  Set log level."},
                monitor = {"monitor <cmd>", "  status/attach/detach/scale."},
                applypatch = {"applypatch [file]", "  Apply patch + reboot."},
                ap = {"ap [file]", "  Alias for applypatch."},
                run = {"run <file>", "  Run program from /srunix/bin/."},
                clear = {"clear", "  Clear screen."},
                exit = {"exit", "  Shut down."},
                help = {"help [command]", "  Show help."},
            }

            if sub and CMD_HELP[sub] then
                sprHead("=== help: " .. sub .. " ===")
                for i, line2 in ipairs(CMD_HELP[sub]) do
                    if i == 1 then sprUsage(line2) else spr(line2) end
                end
            else
                if sub then
                    sprWarn("No detailed help for '" .. sub .. "'")
                    spr("")
                end
                sprHead("=== Srunix help ===")

                sprHead("File ops:")
                sprCmd("dir", "[path]", "list files")
                sprCmd("ls", "[-l] [path]", "list files (long with -l)")
                sprCmd("cd", "[path]", "change directory")
                sprCmd("cat", "<file>", "show file")
                sprCmd("del", "<file>", "delete file")
                sprCmd("copy", "<src> <dst>", "copy file")
                sprCmd("move", "<src> <dst>", "move / rename")
                sprCmd("mkdir", "<name>", "create folder")

                sprHead("Programs:")
                sprCmd("srun", "[n]", "print SRUN n times")
                sprCmd("cube", "[size] [color] [mode]", "rotating 3D cube")
                sprCmd("textnum", "<word>", "letters to number")
                sprCmd("pic", "[list|last|random]", "image viewer")
                sprCmd("print", "<msg> [color] [size]", "colored message")
                sprCmd("morse", "<text>", "Morse encode/decode")

                sprHead("Users:")
                sprCmd("login", "[user]", "log in")
                sprCmd("logout", "", "back to root")
                sprCmd("whoami", "", "current user")
                sprCmd("id", "", "show uid/gid")
                sprCmd("users", "", "list users")
                sprCmd("useradd", "<name>", "create user")
                sprCmd("passwd", "[user]", "change password")

                sprHead("Permissions:")
                sprCmd("chmod", "<mode> <file>", "change mode")
                sprCmd("chown", "<user>[:<grp>] <file>", "change owner")

                sprHead("System:")
                sprCmd("about", "", "system info + art")
                sprCmd("neofetch", "", "alias for about")
                sprCmd("colorall", "<color>", "override all colors")
                                                                sprCmd("history", "[-c]", "command history")
                sprCmd("colors", "", "color palette")
                sprCmd("loglevel", "[lvl]", "error|warn|info|debug")
                sprCmd("clear", "", "clear screen")
                sprCmd("exit", "", "shutdown")

                spr("")
                spr("For details: help <command>")
                spr("Example: help cube, help pic")
                spr("")
                sprWarn("Up/Down - history | Q in list/image - exit")
            end

        elseif cmd == "exit" or cmd == "quit" then
            sprWarn("Shutting down Srunix...")
            return

        else
            if not tryExternal(cmd, {table.unpack(args, 2)}) then
                sprErr("'" .. cmd .. "' is not a command. Try 'help'.")
            end
        end
    end
end
