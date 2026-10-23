--[[--
Card list of the cache mode from the server's id list (spec 2026-10-13, section 5).

The list of a FreshRSS feed, folder or special comes as the complete id list
(newest first). The sync loads article texts in blocks along the load sequence (the
id list in the sort direction). The list shows the stored rows of the covered ids,
sorted by publish date like every card list. One placeholder follows for each id
that is not loaded yet, so the page count is correct from the start.

Pure: no I/O. rssreader_sync loads the data, rssreader_ui_tree connects it to the UI.
]]

local LiveList = {}

--- Id lists of several feeds as one list, newest first. FreshRSS long ids end in
-- 16 hex digits of the arrival time (microseconds), so they compare as strings.
function LiveList.merge(lists)
    if #lists == 1 then
        return lists[1]
    end
    local merged = {}
    for _, list in ipairs(lists) do
        for _, id in ipairs(list) do
            table.insert(merged, id)
        end
    end
    table.sort(merged, function(a, b) return a > b end)
    return merged
end

--- Load sequence: the id list (newest first) in the sort direction. `sort_desc`
-- nil = descending, the default of the card lists.
function LiveList.order(ids, sort_desc)
    if sort_desc ~= false then
        return ids
    end
    local reversed = {}
    for index = #ids, 1, -1 do
        table.insert(reversed, ids[index])
    end
    return reversed
end

--- Card list: the `rows` (from the store, already filtered and sorted) whose id
-- is among the first `covered` ids of `ordered`, then a placeholder
-- { id, account, placeholder = true } for every id after them. Covered ids
-- without a row (filtered out, or the server did not deliver them) drop out.
function LiveList.build(rows, ordered, covered, account)
    local in_range = {}
    for index = 1, math.min(covered, #ordered) do
        in_range[ordered[index]] = true
    end
    local list = {}
    for _, row in ipairs(rows) do
        if in_range[row.id] then
            table.insert(list, row)
        end
    end
    for index = covered + 1, #ordered do
        table.insert(list, { id = ordered[index], account = account, placeholder = true })
    end
    return list
end

--- True when page `page` (per_page cards) of `list` holds a placeholder.
function LiveList.pageNeedsLoad(list, page, per_page)
    for index = (page - 1) * per_page + 1, math.min(#list, page * per_page) do
        if list[index].placeholder then
            return true
        end
    end
    return false
end

--- The next block of `ordered` after the first `covered` ids: ids, new covered count.
function LiveList.nextBlock(ordered, covered, size)
    local block = {}
    local last = math.min(#ordered, covered + size)
    for index = covered + 1, last do
        table.insert(block, ordered[index])
    end
    return block, math.max(covered, last)
end

--- `ids` in consecutive chunks of at most `size` (one request each).
function LiveList.chunks(ids, size)
    local chunks = {}
    for first = 1, #ids, size do
        local chunk = {}
        for index = first, math.min(first + size - 1, #ids) do
            table.insert(chunk, ids[index])
        end
        table.insert(chunks, chunk)
    end
    return chunks
end

return LiveList
