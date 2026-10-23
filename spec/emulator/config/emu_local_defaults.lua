-- Emulator only (copied to rssreader_local_defaults.lua outside the repo by spec/emulator/run.sh).
-- Feeds are served by a local HTTP server from spec/emulator/make_feeds.py output.
local base = "http://127.0.0.1:8765/feeds/"
return {
    accounts = {
        ["Test Feeds"] = {
            groups = {
                {
                    title = "novel",
                    feeds = {
                        { title = "Void Herald", url = base .. "void-herald.xml" },
                        { title = "The Long and Winding Chronicle of Everything That Happened Today", url = base .. "long-chronicle.xml" },
                    },
                },
                {
                    title = "Science & Technology News Digest",
                    feeds = {
                        { title = "Orbital Mechanics Daily", url = base .. "orbital.xml" },
                        { title = "Lab Notes", url = base .. "lab-notes.xml" },
                    },
                },
            },
        },
        ["Second"] = {
            feeds = {
                { title = "Loose Ends", url = base .. "loose-ends.xml" },
            },
        },
    },
}
