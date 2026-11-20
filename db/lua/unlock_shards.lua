-- Unlocks shards for a given consumer group and service id.
--
-- Keys:
--   KEYS[1] = shard lock prefix (e.g. "FACET:STREAM:SHARDLOCK")
--
-- Args:
--   ARGV[1] = consumer group name (domain)
--   ARGV[2] = service id (unique instance identifier)
--   ARGV[3] = shard count
--   ARGV[4..] = pairs of [stream_name, bitmask_flag]
--
-- Only unlocks shards whose current lock holder matches service_id.

local group_name = ARGV[1]
local service_id = ARGV[2]
local shard_count = tonumber(ARGV[3])
local stream_count = (#ARGV - 3) / 2

for stream_id = 1, stream_count do
    local stream_name = ARGV[2 + 2 * stream_id]
    local flags = tonumber(ARGV[2 + 2 * stream_id + 1])

    for i = 0, shard_count - 1 do
        if bit.band(flags, bit.lshift(1, i)) ~= 0 then
            local key = KEYS[1] .. ':' .. stream_name .. ":" .. i .. ':' .. group_name
            local value = redis.call('GET', key)

            if value == service_id then
                redis.call('DEL', key)
            end
        end
    end
end

return '1'
