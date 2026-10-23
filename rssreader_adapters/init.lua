--[[--
Adapter registry (spec 2026-10-08, section 3.2). Adding a backend = one module
in rssreader_adapters/ plus one line in BACKENDS.

Adapter contract. A module exports new(client, account, env) -> adapter table.
Failing calls return false, message, err_kind with err_kind one of
"auth" | "network" | "not_found" | "other" (rssreader_adapters/common.fail maps
client messages). Article records: id, feed_id, feed_title, title, link,
author, published (unix time), content_html, snippet, image_url, is_read,
is_starred.

Required:
  fetchTree()                -> true, { folders = { {id, title, unread} },
                                        feeds = { {id, title, folder_id, folder_title, unread} } }
                                (unread = server count, nil = unknown and the stored count stays)
  fetchUnread(feed_id, limit, continuation) -> true, { articles, all_ids?, continuation? }
                                newest first. feed_id can be a special id (common.SPECIAL:
                                "@all", "@today", "@starred"). continuation = opaque token of
                                the next page from the previous result, nil at the end
  applyAction(action)        -> true | false, err, kind. action = { action = "read" |
                                "unread" | "star" | "unstar", article_id }
  supports(feature)          -> bool. Features: "star", "today", "ids"

Optional extensions (the sync checks for them):
  result.all_ids             fetchUnread of a backend without server state (local feeds):
                             ids of ALL stories still in the feed. The sync forgets other
                             rows of the feed and counts unread articles itself.
  applyActions(action, article_ids) -> true | false, err, kind   one action for many
                             articles in one request. The sync sends up to Sync.ACTION_BATCH
                             ids per call and uses applyAction when the backend refuses the call.
  fetchStarred(limit)        -> true, { articles }   starred articles, read or not
                             (the sync uses it when supports("star")).
  fetchUnreadIds(feed_id, cap), fetchStarredIds(cap)   with supports("ids"):
                             -> true, set (id -> true) of ALL unread items of the feed /
                             ALL starred items of the account, ids in the same form as the
                             articles. false when there are more than `cap` (never use an
                             incomplete set). Sync step 3b reconciles with them.
  fetchIdList(feed_id, opts), fetchByIds(ids)   with supports("ids") (spec 2026-10-13):
                             -> true, { ids } every item id of the feed / special id, newest
                             first. opts = { unread_only (false: read items too), cap }. false
                             over cap. -> true, { articles } exactly these articles (any order).
]]

local Store = require("rssreader_store")

local Adapters = {}

local function localClient(accounts)
    return { store = accounts.local_store, fetch = require("rssreader_feed_fetcher").fetch }
end

-- account.type -> adapter module and how to get its client from rssreader_accounts
local BACKENDS = {
    freshrss = { module = "rssreader_adapters/freshrss", client = function(accounts, account) return accounts:getFreshRSSClient(account) end },
    ["local"] = { module = "rssreader_adapters/local", client = localClient },
}

function Adapters.supports(account_type)
    return BACKENDS[account_type] ~= nil
end

--- Store key "<type>:<name>" of a configured account.
function Adapters.accountKey(account)
    return Store.accountKey(account.type, account.name)
end

--- Adapter of a configured account, or nil, err. Passes `env` on to the adapter (e.g. { now = fn }).
function Adapters.forAccount(account, accounts_module, env)
    local backend = BACKENDS[type(account) == "table" and account.type or nil]
    if not backend then
        return nil, "no offline adapter for account type: " .. tostring(type(account) == "table" and account.type)
    end
    local client, err = backend.client(accounts_module, account)
    if not client then
        return nil, err
    end
    return require(backend.module).new(client, account, env)
end

return Adapters
