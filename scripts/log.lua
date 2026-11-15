-- ============================================================
-- 统一日志：只写 log.txt（Isaac.DebugString），不向控制台打印
-- 发布版不产生控制台输出（避免刷屏）；排查问题请查看游戏目录下的 log.txt
-- ============================================================

local Log = {}

function Log.Write(text)
    if Isaac == nil or Isaac.DebugString == nil then
        return
    end
    pcall(function()
        Isaac.DebugString(tostring(text))
    end)
end

return Log
