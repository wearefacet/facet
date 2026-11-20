-- Locks the shards of a stream for a given consumer group and service id.
--
-- Keys:
--   KEYS[1] = shard lock prefix (e.g. "FACET:STREAM:SHARDLOCK")
--
-- Args:
--   ARGV[1] = consumer group name (domain)
--   ARGV[2] = service id (unique instance identifier)
--   ARGV[3] = shard count (number of partitions)
--   ARGV[4..] = stream names (channels to lock)
--
-- Returns:
--   Array of [stream_name, bitmask_flag] pairs where each flag has bit i set
--   when shard i was successfully locked.

local group_name = ARGV[1]
local service_id = ARGV[2]
local shard_count = tonumber(ARGV[3])
local stream_count = #ARGV - 3

local out = {}
local idx = 1

for s = 1, stream_count do
    local stream_name = ARGV[3 + s]
    local flag = 0

    for i = 0, shard_count - 1 do
        local key = KEYS[1] .. ':' .. stream_name .. ":" .. i .. ':' .. group_name
        local value = redis.call('GET', key)

        local set_value = false

        if value == false then
            -- Not locked, we can acquire
            set_value = true
        else
            -- Locked — check if the locker is still alive
            local is_alive = redis.call('GET', KEYS[1] .. ':SERVICE_LIVENESS:' .. value)
            set_value = not is_alive
        end

        if set_value then
            redis.call('SET', key, service_id, 'EX', 3200)
            flag = bit.bor(flag, bit.lshift(1, i))
        end
    end

    out[idx] = stream_name
    out[idx + 1] = flag
    idx = idx + 2
end

return out
