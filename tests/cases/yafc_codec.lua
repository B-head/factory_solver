-- Headless coverage for the YAFC codec's Factorio-independent layers: the
-- vendored LibDeflate raw inflate/deflate and the standard base64 codec. These
-- have no `helpers` / `prototypes` dependency, so they run in the inner loop.
--
-- The YAFC string -> payload mapping (yafc_codec.yafc_to_payload) and the JSON
-- envelope decode both need Factorio (`helpers.json_to_table`, storage.virtuals,
-- the prototype tables), so they are covered by the smoke suite's
-- codec_yafc_roundtrip / yafc_real_sample fixtures instead.

local base64 = require "manage/base64"
local LibDeflate = require "lib/libdeflate"
local json = require "manage/json"

-- A real YAFC-CE "ProjectPage" share string (a pyanodon nuclear sample),
-- base64( raw-DEFLATE( "YAFC\nProjectPage\n<ver>\n\n\n" .. <JSON> ) ). Used to
-- prove the decode chain end-to-end against data this codec did not produce.
local YAFC_SAMPLE =
[==[inR0c+YKKMrPSk0uCUhMT+Uy0jM01zPQM+Di4gIAAAD//+1b2W7jNhT9lULPpuE4CRL7qZhBAwRo2rTNS1HMwxV1JbGhRJaLFwT5915KcpbOFHZkEU1n9CbR1LkSD5dzFz8kXNUOa3e31Zgsk98h59MblaGc0hOZ506o+g5SickkKbzIqM+CL045P4UUMD3LZtkC8sXi4uJykZ7ML8/gnHoKQqWe1w6rae25RDDMQqUbmBqqYOonz7/7bdfWvUWyfEhwo6HOkCw543GSSFHf22T5x0NSKJXR1UPiwBTodga8gVr4iikTkP7yIIXb0o+/tFfTWpkKZPI4SaBSPhhhJ3QtC2WEK6tkOXuc/Ct4YSBDdsL8gdCzNyLPIyBrtc7QYDYs9JUk+qeeaS81m53Eg57Hgz4dfKy3KKVaMw73ODi2Z/PT8+FRu+WSe5SM0+sPbiFDWtQuzL+Yplpmbcp0qawuwdEyHfxTCL7UimbP8G+upXeqGR6NRm1ENvwEejYRCT/M0MsosGez4Udc1Jm3zgiQzCq5CufN8PNRZcDAlhGQHUL1/cn5LBb0PAr0y/UZYWdvwZVR3jLgpE8iWRA1sgLs4HN9Tc09QT9NEoNcaGzVUXv9ysKvTdPBGqZVbbWXcpJkaLkROsi/XROtl+bJFwZ+aJqmfwKdgMbbEs0eE+EkeIVwq9ZopihJmxrBw2N7AMQGsw9eyEzUhW0GpWm6aoBzkBa7luu6IA0kGlXZfkDT3MnaXVtKUO4FXttqS7W+Uw7k9c9PoFgHGfwkSx0UjfWK4CQ+P+nTgiaj3t2vgPab2gWKPoVpcABLjPqEwYzFlqg0cLcjjFX3e8XcyNoe1kjFs6icWaQnMzDbkbZBFtuhbkxvwsjl5XRoFMw6CE+My2wQvvYpiJGv93GYHepwj3y9F75IfZUNabEY4yVWgpPvpSW907gfHsWX1UQLa4NPB8SeepOmwThB8VvyrSh+gwacGhXjkUvtjUGx3twBBX8qcrszlpPeV6QdSerPv12p/5CkJMqeR04K6xrPue3xhThUlwFZ0ReyrtMBH/+xc9eDg95a/LG1RBOjz7y5QV7SlOF2arAhcloiuFizZpeu6Wy9dbr0CjF/vefq0wiwTNgm6BiLt4rGYdyaj2OLeolK1dvnkGU0MUQ/GZH7AkchdBRlr1Mcjas9cvbON0XtDW7Y02Jbqb1h+/5xM4rKpem4MR7LWJdlEfyQJEtvtuiMdEIGH+PbVakDUxUtYFbqfCTp6FMrFju4Aq0ab30k6XhpYZFKNKJqizHOMvhG+FndYVy3awys/O8CK5+v89LnOQU7ox2aNXpnKBkIqVWmryxty1LSQ9XY1yt13lzPNQZX/kO2DqyM6x/uLgSl2sf0xJE0caVoOYWCQEYFgcwptr/ksL/s2bIQy2a4CSHuYiwf68/bzvdlqRKUqGNril6aQF/DZUQC/2F49Df6MihVwUI5KKXrSNVEImxNxdVjxd+eDZL05YusYS6kvKH6X0N33VkZUqtX1HwL2xT4fSeqJE1/+u9UI3k7rfQq4djefamHvUWzk1TJ8nKSqBUaQyX7Hw3ktI4/tL3obR4fg9blRlFSbXlx/vg3]==]

---@param msg string
---@param cond any
local function check(cond, msg)
    if not cond then error(msg, 2) end
end

return {
    {
        name = "base64 round-trips arbitrary bytes",
        run = function()
            local samples = {
                "",
                "f", "fo", "foo", "foob", "fooba", "foobar",
                "YAFC\nProjectPage\n0.0.0.0\n\n\n{}",
            }
            for _, s in ipairs(samples) do
                check(base64.decode(base64.encode(s)) == s,
                    "base64 round-trip mismatch for sample of length " .. #s)
            end

            -- Every byte value 0..255 must survive (binary safety).
            local all_bytes = {}
            for b = 0, 255 do all_bytes[#all_bytes + 1] = string.char(b) end
            local blob = table.concat(all_bytes)
            check(base64.decode(base64.encode(blob)) == blob,
                "base64 round-trip lost a byte across the full 0..255 range")
        end,
    },
    {
        name = "base64 decode matches a known vector",
        run = function()
            -- "Man" -> "TWFu" is the canonical RFC 4648 example.
            check(base64.encode("Man") == "TWFu", "base64 encode vector wrong")
            check(base64.decode("TWFu") == "Man", "base64 decode vector wrong")
            -- Padding cases.
            check(base64.encode("M") == "TQ==", "single-byte padding wrong")
            check(base64.encode("Ma") == "TWE=", "two-byte padding wrong")
        end,
    },
    {
        name = "LibDeflate raw deflate round-trips text",
        run = function()
            local text = string.rep("YAFC ProjectPage 12345 {} []", 200)
            local compressed = LibDeflate:CompressDeflate(text)
            check(type(compressed) == "string" and #compressed > 0,
                "CompressDeflate produced nothing")
            local restored = LibDeflate:DecompressDeflate(compressed)
            check(restored == text, "raw deflate round-trip changed the data")
        end,
    },
    {
        name = "real YAFC sample decodes to a ProductionTable envelope",
        run = function()
            local raw = base64.decode(YAFC_SAMPLE)
            check(#raw > 0, "base64 decode of the sample produced no bytes")

            local text = LibDeflate:DecompressDeflate(raw)
            check(type(text) == "string", "inflate of the YAFC sample failed")

            check(text:sub(1, 16) == "YAFC\nProjectPage",
                "decoded sample does not start with the YAFC ProjectPage header")
            check(text:find("Yafc.Model.ProductionTable", 1, true) ~= nil,
                "decoded sample is not a ProductionTable")
            check(text:find("Mechanics.reactor.heat", 1, true) ~= nil,
                "decoded sample lost its reactor-heat pseudo-recipe")
        end,
    },
    {
        name = "json encoder emits arrays, null, and the YAFC modules shape",
        run = function()
            -- The two shapes helpers.table_to_json cannot produce, and the whole
            -- reason this encoder exists: empty array and explicit null.
            check(json.encode(json.array({})) == "[]", "empty array not []")
            check(json.encode(json.null) == "null", "null sentinel not null")
            check(json.encode(json.array({ 1, 2 })) == "[1,2]", "number array wrong")

            -- A plain (untagged) empty table is an object, distinct from an array.
            check(json.encode({}) == "{}", "empty object not {}")

            -- The exact ModuleTemplate shape YAFC expects for a module-less row's
            -- non-null case: explicit null beacon + empty [] lists. Keys sort.
            local modules = {
                beacon = json.null,
                list = json.array({}),
                beaconList = json.array({}),
            }
            check(json.encode(modules) == '{"beacon":null,"beaconList":[],"list":[]}',
                "module template shape wrong: " .. json.encode(modules))

            -- Numbers: integers without a decimal, fractions preserved.
            check(json.encode(2) == "2", "integer formatting wrong")
            check(json.encode(0.5) == "0.5", "fraction formatting wrong")
            check(json.encode(true) == "true" and json.encode(false) == "false",
                "boolean formatting wrong")

            -- String escaping for the characters JSON requires.
            check(json.encode('a"b\\c') == '"a\\"b\\\\c"', "string escaping wrong")
            check(json.encode("x\ny") == '"x\\ny"', "newline escaping wrong")

            -- Nesting: an array of objects, like content.recipes.
            check(json.encode(json.array({ { fixedCount = 2 } })) == '[{"fixedCount":2}]',
                "array of objects wrong")
        end,
    },
}
