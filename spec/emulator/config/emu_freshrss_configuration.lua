-- Emulator only, real-server mode (RSSREADER_EMU_FRESHRSS=1 spec/emulator/run.sh DIR).
-- run.sh copies it to a temporary config folder outside the repo (rssreader_configuration.lua)
-- and deletes that folder after the run. It holds no credentials: KOReader reads them from the
-- environment (RSSREADER_TEST_FRESHRSS_URL / _USER / _PASSWORD) when it loads this file.
-- With RSSREADER_EMU_IMGPROXY=1 the images go through the image proxy of
-- RSSREADER_TEST_IMGPROXY_URL / _USER / _PASSWORD (also read from the environment).
local function imageProxy()
    if os.getenv("RSSREADER_EMU_IMGPROXY") ~= "1" then
        return nil
    end
    return {
        url = os.getenv("RSSREADER_TEST_IMGPROXY_URL"),
        username = os.getenv("RSSREADER_TEST_IMGPROXY_USER"),
        password = os.getenv("RSSREADER_TEST_IMGPROXY_PASSWORD"),
    }
end

return {
    accounts = {
        {
            name = "FreshRSS",
            type = "freshrss",
            active = true,
            auth = {
                base_url = os.getenv("RSSREADER_TEST_FRESHRSS_URL"),
                username = os.getenv("RSSREADER_TEST_FRESHRSS_USER"),
                password = os.getenv("RSSREADER_TEST_FRESHRSS_PASSWORD"),
            },
        },
    },
    image_proxy = imageProxy(),
}
