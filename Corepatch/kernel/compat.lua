local compat = {}

local Srunix = _G.Srunix
if not Srunix then
    error("Srunix compat: kernel not loaded (_G.Srunix missing)")
end

local SB   = Srunix.SB
local VFS  = Srunix.VFS
local Utils= Srunix.Utils
local Users= Srunix.Users

local _origTerm = _G.originalTerm or _G.term
local _origFs   = _G.fs
local _origOs   = _G.os
local _origColors = _G.colors
local _origKeys   = _G.keys

local vc = {
    x = 1,
    y = 1,
    textColor = colors.white,
    bgColor   = colors.black,
    lines = {},
    width = 51,
    height = 19,
}

local function newLine(width)
    local l = {}
    for i = 1, width do
        l[i] = { char = " ", fg = vc.textColor, bg = vc.bgColor }
    end
    return l
end

local function ensureLine(y)
    while #vc.lines < y do
        table.insert(vc.lines, newLine(vc.width))
    end
    return vc.lines[y]
end

local function ensureSize()
    local w, h = _origTerm.getSize()
    vc.width  = w
    vc.height = h
    for i = 1, #vc.lines do
        local old = vc.lines[i]
        local nl = newLine(w)
        for j = 1, math.min(#old, w) do nl[j] = old[j] end
        vc.lines[i] = nl
    end
end

local function flushToSB()
    for y = 1, #vc.lines do
        local line = vc.lines[y]
        local segs = {}
        local cur = nil
        for x = 1, #line do
            local c = line[x]
            local ch = c.char
            if ch ~= " " or c.bg ~= colors.black then
                if cur and cur.fg == c.fg and cur.bg == c.bg then
                    cur.text = cur.text .. ch
                else
                    cur = { text = ch, fg = c.fg, bg = c.bg }
                    table.insert(segs, cur)
                end
            else
                if cur and cur.fg == c.fg and cur.bg == c.bg then
                    cur.text = cur.text .. ch
                else
                    cur = { text = ch, fg = c.fg, bg = c.bg }
                    table.insert(segs, cur)
                end
            end
        end
        while #segs > 0 and segs[#segs].text:match("^%s*$") do
            table.remove(segs)
        end
        if #segs > 0 then
            SB.addSegments(segs)
        else
            SB.addLine("")
        end
    end
end

local vterm = {}

function vterm.getSize()
    ensureSize()
    return vc.width, vc.height
end

function vterm.getCursorPos()
    return vc.x, vc.y
end

function vterm.setCursorPos(x, y)
    if type(x) ~= "number" or type(y) ~= "number" then return end
    vc.x = math.max(1, math.min(vc.width,  x))
    vc.y = math.max(1, math.min(vc.height, y))
end

function vterm.setCursorBlink(_)
end

function vterm.getTextColor() return vc.textColor end
function vterm.getBackgroundColor() return vc.bgColor end
function vterm.setTextColor(c)   vc.textColor = c or colors.white end
function vterm.setBackgroundColor(c) vc.bgColor = c or colors.black end

function vterm.isColor() return true end
function vterm.isColour() return true end

function vterm.clear()
    ensureSize()
    for y = 1, vc.height do
        vc.lines[y] = newLine(vc.width)
    end
    vc.x, vc.y = 1, 1
end

function vterm.clearLine()
    local line = ensureLine(vc.y)
    for x = 1, vc.width do
        line[x] = { char = " ", fg = vc.textColor, bg = vc.bgColor }
    end
    vc.x = 1
end

function vterm.write(s)
    ensureSize()
    s = tostring(s or "")
    local line = ensureLine(vc.y)
    for i = 1, #s do
        local ch = s:sub(i, i)
        if ch == "\n" then
            vc.x = 1
            vc.y = vc.y + 1
            if vc.y > vc.height then
                table.remove(vc.lines, 1)
                table.insert(vc.lines, newLine(vc.width))
                vc.y = vc.height
            end
            line = ensureLine(vc.y)
        elseif ch == "\r" then
            vc.x = 1
        else
            if vc.x > vc.width then
                vc.x = 1
                vc.y = vc.y + 1
                if vc.y > vc.height then
                    table.remove(vc.lines, 1)
                    table.insert(vc.lines, newLine(vc.width))
                    vc.y = vc.height
                end
                line = ensureLine(vc.y)
            end
            line[vc.x] = { char = ch, fg = vc.textColor, bg = vc.bgColor }
            vc.x = vc.x + 1
        end
    end
end

function vterm.scroll(n)
    ensureSize()
    n = n or 1
    for _ = 1, n do
        table.remove(vc.lines, 1)
        table.insert(vc.lines, newLine(vc.width))
    end
end
local vfs = {}

local function realFromAny(path)
    if type(path) ~= "string" then return path end
    if path:match("^%a:") then return path end
    if path:sub(1, 1) == "/" then
        return "C:" .. path:gsub("/", "\\")
    end
    local cwd = Srunix.cwd or "C:\\"
    if cwd:sub(-1) ~= "\\" then cwd = cwd .. "\\" end
    return cwd .. path:gsub("/", "\\")
end

function vfs.exists(p)  return VFS.exists(realFromAny(p)) end
function vfs.isDir(p)   return VFS.isDir(realFromAny(p)) end

function vfs.list(p)
    local r = realFromAny(p)
    local items = VFS.list(r)
    return items
end

function vfs.open(p, mode)
    local real = realFromAny(p)
    local full = VFS.realpath(real)
    mode = mode or "r"
    if mode == "r" or mode == "rb" then
        if not VFS.exists(real) then return nil end
        local data = VFS.read(real)
        if not data then return nil end
        local pos = 1
        return {
            readAll = function() local d = data; data = ""; return d end,
            read    = function() return data end,
            readLine= function()
                local nl = data:find("\n", pos, true)
                if not nl then
                    local rest = data:sub(pos); pos = #data + 1
                    if rest == "" then return nil end
                    return rest
                end
                local line = data:sub(pos, nl - 1)
                pos = nl + 1
                return line
            end,
            close   = function() end,
            seek    = function(whence, off)
                if whence == "set" then pos = off + 1
                elseif whence == "cur" then pos = pos + off
                elseif whence == "end" then pos = #data + off + 1 end
                if pos < 1 then pos = 1 end
                return pos - 1
            end,
        }
    elseif mode == "w" or mode == "wb" or mode == "a" or mode == "ab" then
        local buf = ""
        if mode:sub(1,1) == "a" and VFS.exists(real) then
            buf = VFS.read(real) or ""
        end
        return {
            write = function(s) buf = buf .. tostring(s) end,
            writeLine = function(s) buf = buf .. tostring(s) .. "\n" end,
            flush = function() VFS.write(real, buf) end,
            close = function() VFS.write(real, buf) end,
        }
    end
    return nil
end

function vfs.delete(p)  return VFS.delete(realFromAny(p)) end
function vfs.makeDir(p) return VFS.mkdir(realFromAny(p)) end
function vfs.move(a, b)
    local data = VFS.read(realFromAny(a))
    if not data then return false end
    if VFS.write(realFromAny(b), data) and VFS.delete(realFromAny(a)) then
        return true
    end
    return false
end
function vfs.copy(a, b)
    local data = VFS.read(realFromAny(a))
    if not data then return false end
    return VFS.write(realFromAny(b), data)
end
function vfs.getSize(p)
    local data = VFS.read(realFromAny(p))
    if not data then return 0 end
    return #data
end
function vfs.getDrive(p) return "hdd" end
function vfs.getFreeSpace(_) return 1000000 end
function vfs.combine(a, b)
    if a:sub(-1) == "/" then return a .. b end
    return a .. "/" .. b
end
function vfs.getName(p)
    return p:match("([^/\\]+)$") or p
end
function vfs.getDir(p)
    local dir = p:match("^(.*)[/\\][^/\\]+$")
    return dir or ""
end
function vfs.isReadOnly(_) return false end
function vfs.attributes(p)
    local real = VFS.realpath(realFromAny(p))
    return {
        size = vfs.getSize(p),
        isDir = fs.isDir(real),
        modification = 0,
        created = 0,
    }
end

local vshell = {}

function vshell.run(cmd, ...)
    local args = {...}
    local full = cmd
    for _, a in ipairs(args) do full = full .. " " .. tostring(a) end
    local SB = SB
    SB.addLine("$ " .. full, colors.lightGray)
    local file = "/srunix/bin/" .. cmd:match("^(%S+)") .. ".lua"
    if fs.exists(file) then
        local f = fs.open(file, "r"); local code = f.readAll(); f.close()
        local chunk = load(code, file, "t")
        if chunk then
            Srunix.args = args
            parallel.waitForAny(chunk)
        end
    else
        SB.addLine("compat: not found: " .. cmd, colors.red)
    end
end

function vshell.exit() end
function vshell.dir() return Srunix.cwd end
function vshell.setDir(d) Srunix.cwd = d end
function vshell.path() return Srunix.cwd end
function vshell.resolve(p)
    return VFS.realpath(realFromAny(p))
end
function vshell.resolveProgram(p)
    return VFS.realpath(realFromAny(p))
end
function vshell.complete(s)
    local dir, prefix = s:match("^(.*[/\\])([^/\\]*)$")
    if not dir then dir, prefix = "", s end
    local items = VFS.list(realFromAny(dir == "" and Srunix.cwd or dir))
    local out = {}
    for _, n in ipairs(items) do
        if n:sub(1, #prefix) == prefix then table.insert(out, n) end
    end
    return out
end
function vshell.completeProgram(s) return vshell.complete(s) end

function compat.install()
    ensureSize()

    _G.term = vterm

    local proxyFs = {}
    for k, v in pairs(_origFs) do proxyFs[k] = v end
    for k, v in pairs(vfs) do proxyFs[k] = v end
    _G.fs = proxyFs

    _G.shell = vshell

    _G.print = function(...)
        local n = select("#", ...)
        local t = {}
        for i = 1, n do t[i] = tostring(select(i, ...)) end
        vterm.write(table.concat(t, "\t"))
        vterm.write("\n")
    end

    _G.write = function(s) vterm.write(tostring(s or "")) end

    _G.read = function(replaceChar, history)
        local s = Srunix.env and Srunix.env.sread and Srunix.env.sread("") or ""
        return s
    end

    local origOs = _origOs
    _G.os = setmetatable({
        version = function() return "Srunix" end,
        pullEvent = origOs.pullEvent,
        pullEventRaw = origOs.pullEventRaw,
        queueEvent = origOs.queueEvent,
        startTimer = origOs.startTimer,
        cancelTimer = origOs.cancelTimer,
        sleep = origOs.sleep,
        time = origOs.time,
        day  = origOs.day,
        epoch= origOs.epoch,
        setAlarm = origOs.setAlarm,
        cancelAlarm = origOs.cancelAlarm,
        shutdown = origOs.shutdown,
        reboot = origOs.reboot,
        getComputerID = origOs.getComputerID,
        computerID = origOs.computerID,
        getComputerLabel = origOs.getComputerLabel,
        setComputerLabel = origOs.setComputerLabel,
        clock = origOs.clock,
    }, {__index = origOs})

end

function compat.uninstall()
    _G.term = _origTerm
    _G.fs   = _origFs
    _G.os   = _origOs
    _G.shell= nil
end

function compat.run(path, ...)
    local realPath = VFS.realpath(realFromAny(path))
    if not fs.exists(realPath) then
        SB.addLine("compat: not found: " .. realPath, colors.red)
        return false
    end

    local saved = {
        term   = _G.term,
        fs     = _G.fs,
        shell  = _G.shell,
        os     = _G.os,
        print  = _G.print,
        write  = _G.write,
        read   = _G.read,
    }

    compat.install()
    vterm.clear()

    local f = fs.open(realPath, "r")
    local code = f.readAll()
    f.close()

    Srunix.args = {...}
    Srunix.env.arg = {...}

    local chunk, err = load(code, "@" .. realPath, "t")
    if not chunk then
        SB.addLine("compat: compile error: " .. tostring(err), colors.red)
        compat.uninstall()
        return false
    end

    local ok, runerr = pcall(chunk)

    flushToSB()
    if not ok then
        SB.addLine("compat: runtime error: " .. tostring(runerr), colors.red)
    end

    compat.uninstall()

    return ok
end

return compat