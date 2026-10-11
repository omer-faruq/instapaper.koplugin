--- DocCache stale-entry guard.
-- DocCache:serialize() sorts its snapshot of disk cache files by access time and
-- crashes ("attempt to compare number with nil") when one of those files can no
-- longer be stat'ed, e.g. right after waking from a long sleep. Reported as a
-- crash on closing the reader to open a freshly downloaded article.
--   1. Entries that can't be stat'ed are dropped before the original serialize.
--   2. While it runs, a missing file's "size" reads as 0, so a file that vanishes
--      mid-run can't crash the trim loop (`cached_size - nil`).
--   3. Anything else it throws is logged instead of crashing KOReader: the disk
--      cache is optional, the reader is closing anyway.
-- Harmless once fixed upstream: it only touches entries that are already invalid.

local DocCache = require("document/doccache")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

-- Shared with plugins and user patches that ship the same guard, so serialize is
-- wrapped only once.
if not DocCache._stale_entry_guard_v2 then
    DocCache._stale_entry_guard_v2 = true
    local orig_serialize = DocCache.serialize

    DocCache.serialize = function(self, ...)
        if self.cached then
            for key, file in pairs(self.cached) do
                if not lfs.attributes(file, "access") then
                    logger.warn("DocCache: dropping stale cache entry", file)
                    self.cached[key] = nil
                end
            end
        end

        local orig_attributes = lfs.attributes
        lfs.attributes = function(path, request, ...)
            local value = orig_attributes(path, request, ...)
            if value == nil and request == "size" then
                return 0
            end
            return value
        end
        local ok, err = pcall(orig_serialize, self, ...)
        lfs.attributes = orig_attributes
        if not ok then
            logger.warn("DocCache: serialize failed, skipping", err)
        end
    end
end
