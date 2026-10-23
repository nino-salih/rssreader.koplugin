-- Emulator only, demo mode (RSSREADER_EMU_DEMO=1 spec/emulator/run.sh DIR).
-- run.sh copies it to rssreader_configuration.lua outside the repo. One local account
-- with public-domain books: no real server, no credentials.
return {
    accounts = {
        { name = "Library", type = "local", active = true },
    },
}
