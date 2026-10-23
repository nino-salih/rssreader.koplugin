-- Emulator only (copied to rssreader_configuration.lua outside the repo by spec/emulator/run.sh).
-- Two local test accounts: no real server, no credentials.
return {
    accounts = {
        { name = "Test Feeds", type = "local", active = true },
        { name = "Second", type = "local", active = true },
    },
}
