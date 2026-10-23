local Common = require("rssreader_adapters/common")

describe("rssreader_adapters/common", function()
    describe("errorKind", function()
        it("maps HTTP status codes", function()
            assert.equals("auth", Common.errorKind("FreshRSS request failed (HTTP 401 - Unauthorized)"))
            assert.equals("auth", Common.errorKind("FreshRSS login failed (HTTP 403 - Forbidden)"))
            assert.equals("not_found", Common.errorKind("HTTP/1.1 404 Not Found"))
            assert.equals("other", Common.errorKind("FreshRSS request failed (HTTP 500 - Server Error)"))
        end)

        it("maps connection failures to network", function()
            assert.equals("network", Common.errorKind("FreshRSS request failed (HTTP timeout - nil)"))
            assert.equals("network", Common.errorKind("FreshRSS login failed (HTTP connection refused - nil)"))
            assert.equals("network", Common.errorKind("host or service not provided, or not known"))
        end)

        it("maps missing credentials to auth and the rest to other", function()
            assert.equals("auth", Common.errorKind("Missing FreshRSS credentials."))
            assert.equals("other", Common.errorKind("Unable to parse FreshRSS JSON response"))
            assert.equals("other", Common.errorKind(nil))
        end)

        it("fail returns false, message, kind", function()
            local ok, err, kind = Common.fail("HTTP 404")
            assert.is_false(ok)
            assert.equals("HTTP 404", err)
            assert.equals("not_found", kind)
        end)
    end)

    describe("text helpers", function()
        it("turns HTML into plain text", function()
            local html = "<style>p{}</style><p>Hello&nbsp;<b>world</b> &amp; more</p>\n<script>x()</script><p>&#8222;Zitat&#x201C;</p>"
            assert.equals("Hello world & more „Zitat“", Common.plainText(html))
        end)

        it("cuts snippets on UTF-8 boundaries", function()
            assert.equals("äöü…", Common.snippet("<p>äöüß</p>", 3))
            assert.equals("short", Common.snippet("short", 10))
            assert.is_nil(Common.snippet("<img src='x'>", 10))
        end)

        it("collects image URLs in order, without duplicates and data URIs", function()
            local html = [[<p><img src="https://a/1.jpg?x=1&amp;y=2"><img data-src='/rel/2.png' src="data:image/gif;base64,AA">]]
                .. [[<img src="https://a/1.jpg?x=1&amp;y=2"><img width="1" height="1" src="https://pixel/t.gif"></p>]]
            assert.same({ "https://a/1.jpg?x=1&y=2", "https://site.example/rel/2.png" },
                Common.imageUrls(html, "https://site.example/post/7"))
            assert.equals("https://a/1.jpg?x=1&y=2", Common.firstImageUrl(html, nil))
        end)

        it("resolves relative URLs", function()
            local base = "https://site.example/blog/post.html"
            assert.equals("https://cdn.example/x.png", Common.resolveUrl("//cdn.example/x.png", base))
            assert.equals("https://site.example/x.png", Common.resolveUrl("/x.png", base))
            assert.equals("https://site.example/blog/x.png", Common.resolveUrl("x.png", base))
            assert.equals("http://other/x.png", Common.resolveUrl("http://other/x.png", base))
            assert.is_nil(Common.resolveUrl("x.png", nil))
        end)
    end)

    describe("parseDate", function()
        it("parses numbers in seconds, milliseconds and microseconds", function()
            assert.equals(1700000000, Common.parseDate(1700000000))
            assert.equals(1700000000, Common.parseDate(1700000000123))
            assert.equals(1700000000, Common.parseDate("1700000000000000"))
        end)

        it("parses RFC 822 dates with zones", function()
            assert.equals(1055217600, Common.parseDate("Tue, 10 Jun 2003 04:00:00 GMT"))
            assert.equals(1055217600, Common.parseDate("Tue, 10 Jun 2003 06:00:00 +0200"))
            assert.equals(1055217600, Common.parseDate("10 Jun 2003 00:00:00 EDT"))
        end)

        it("parses ISO 8601 dates", function()
            assert.equals(1071340202, Common.parseDate("2003-12-13T18:30:02Z"))
            assert.equals(1071340202, Common.parseDate("2003-12-13T19:30:02.25+01:00"))
            assert.equals(1071273600, Common.parseDate("2003-12-13"))
        end)

        it("returns nil for garbage", function()
            assert.is_nil(Common.parseDate("yesterday"))
            assert.is_nil(Common.parseDate(nil))
        end)
    end)

    describe("storyKey", function()
        it("prefers ids, then links, then a hash of title, date and content", function()
            assert.equals("g1", Common.storyKey({ guid = "g1", permalink = "https://x" }))
            assert.equals("https://x", Common.storyKey({ permalink = "https://x" }))
            local key = Common.storyKey({ story_title = "T", date = "D", story_content = "C" })
            assert.matches("^local:%x+$", key)
            assert.equals(key, Common.storyKey({ story_title = "T", date = "D", story_content = "C" }))
            assert.is_nil(Common.storyKey("x"))
        end)
    end)

    it("sorts newest first and keeps the order of undated entries", function()
        local sorted = Common.sortNewestFirst({
            { id = "a", published = 1 }, { id = "b" }, { id = "c", published = 3 }, { id = "d" },
        })
        local ids = {}
        for _, item in ipairs(sorted) do
            table.insert(ids, item.id)
        end
        assert.same({ "c", "a", "b", "d" }, ids)
    end)
end)
