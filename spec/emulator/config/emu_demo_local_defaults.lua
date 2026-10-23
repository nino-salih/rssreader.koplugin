-- Emulator only, demo mode (copied to rssreader_local_defaults.lua outside the repo by
-- spec/emulator/run.sh). A local HTTP server on port 8766 serves the feeds of
-- spec/emulator/make_demo_feeds.py (one article per book chapter).
local base = "http://127.0.0.1:8766/feeds/"
return {
    accounts = {
        ["Library"] = {
            groups = {
                {
                    title = "Classics",
                    feeds = {
                        { title = "Moby-Dick", url = base .. "moby-dick.xml" },
                        { title = "Pride and Prejudice", url = base .. "pride-and-prejudice.xml" },
                        { title = "Alice's Adventures in Wonderland", url = base .. "alice.xml" },
                        { title = "The Adventures of Sherlock Holmes", url = base .. "sherlock-holmes.xml" },
                    },
                },
                {
                    title = "Adventure",
                    feeds = {
                        { title = "Treasure Island", url = base .. "treasure-island.xml" },
                        { title = "The Time Machine", url = base .. "time-machine.xml" },
                    },
                },
            },
        },
    },
}
