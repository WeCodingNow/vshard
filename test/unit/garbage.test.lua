test_run = require('test_run').new()
vshard = require('vshard')
fiber = require('fiber')
engine = test_run:get_cfg('engine')

test_run:cmd("setopt delimiter ';'")
function show_sharded_spaces()
    local result = {}
    for k, space in pairs(vshard.storage._sharded_spaces()) do
        table.insert(result, space.name)
    end
    table.sort(result)
    return result
end;
test_run:cmd("setopt delimiter ''");

vshard.storage.internal.shard_index = 'bucket_id'

--
-- Find nothing if no bucket_id anywhere, or there is no index
-- by it, or bucket_id is not unsigned.
--

s = box.schema.create_space('test', {engine = engine})
_ = s:create_index('pk')
--
-- gh-96: public API to see all sharded spaces.
--
show_sharded_spaces()

sk = s:create_index('bucket_id', {parts = {{2, 'string'}}})
show_sharded_spaces()

-- Bucket id must be the first part of an index.
sk:drop()
sk = s:create_index('bucket_id', {parts = {{1, 'unsigned'}, {2, 'unsigned'}}})
show_sharded_spaces()

-- Ok to find sharded space.
sk:drop()

--
-- gh-74: allow to choose any name for shard indexes.
--
sk = s:create_index('vbuckets', {parts = {{2, 'unsigned'}}, unique = false})
vshard.storage.internal.shard_index = 'vbuckets'
show_sharded_spaces()
sk:drop()
vshard.storage.internal.shard_index = 'bucket_id'

sk = s:create_index('bucket_id', {parts = {{2, 'unsigned'}}, unique = false})
show_sharded_spaces()

s2 = box.schema.create_space('test2', {engine = engine})
pk2 = s2:create_index('pk')
sk2 = s2:create_index('bucket_id', {parts = {{2, 'unsigned'}}, unique = false})
show_sharded_spaces()

s:drop()
s2:drop()

--
-- gh-111: cache sharded spaces based on schema version
--
cached_spaces = vshard.storage.internal.cached_find_sharded_spaces()
cached_spaces == vshard.storage.internal.cached_find_sharded_spaces()
s = box.schema.create_space('test', {engine = engine})
cached_spaces == vshard.storage.internal.cached_find_sharded_spaces()
s:drop()

--
-- Test garbage buckets deletion from space.
--
format = {}
format[1] = {name = 'id', type = 'unsigned'}
format[2] = {name = 'status', type = 'string'}
format[3] = {name = 'destination', type = 'string', is_nullable = true}
_bucket = box.schema.create_space('_bucket', {format = format})
_ = _bucket:create_index('pk')
_ = _bucket:create_index('status', {parts = {{2, 'string'}}, unique = false})
_bucket:replace{1, vshard.consts.BUCKET.ACTIVE}
_bucket:replace{2, vshard.consts.BUCKET.RECEIVING}
_bucket:replace{3, vshard.consts.BUCKET.ACTIVE}

s = box.schema.create_space('test', {engine = engine})
pk = s:create_index('pk')
sk = s:create_index('bucket_id', {parts = {{2, 'unsigned'}}, unique = false})
s:replace{1, 1}
s:replace{2, 1}
s:replace{3, 2}
s:replace{4, 2}

gc_bucket_drop = vshard.storage.internal.gc_bucket_drop
s2 = box.schema.create_space('test2', {engine = engine})
pk2 = s2:create_index('pk')
sk2 = s2:create_index('bucket_id', {parts = {{2, 'unsigned'}}, unique = false})
s2:replace{1, 1}
s2:replace{3, 3}

test_run:cmd("setopt delimiter ';'")
function fill_spaces_with_garbage()
    s:replace{5, 100}
    s:replace{6, 100}
    s:replace{7, 4}
    s:replace{8, 5}
    for i = 9, 1107 do s:replace{i, 200} end
    s2:replace{4, 200}
    s2:replace{5, 100}
    s2:replace{5, 300}
    s2:replace{6, 4}
    s2:replace{7, 5}
    s2:replace{7, 6}
    _bucket:replace{4, vshard.consts.BUCKET.SENT, 'destination1'}
    _bucket:replace{5, vshard.consts.BUCKET.GARBAGE}
    _bucket:replace{6, vshard.consts.BUCKET.GARBAGE, 'destination2'}
    _bucket:replace{200, vshard.consts.BUCKET.GARBAGE}
end;
test_run:cmd("setopt delimiter ''");

fill_spaces_with_garbage()

#s2:select{}
#s:select{}
route_map = {}
gc_bucket_drop(vshard.consts.BUCKET.GARBAGE, route_map)
route_map
#s2:select{}
#s:select{}
route_map = {}
gc_bucket_drop(vshard.consts.BUCKET.SENT, route_map)
route_map
s2:select{}
s:select{}
-- Nothing deleted - update collected generation.
route_map = {}
gc_bucket_drop(vshard.consts.BUCKET.GARBAGE, route_map)
gc_bucket_drop(vshard.consts.BUCKET.SENT, route_map)
route_map
#s2:select{}
#s:select{}

--
-- Test continuous garbage collection via background fiber.
--
fill_spaces_with_garbage()
_ = _bucket:on_replace(function()                                               \
    local gen = vshard.storage.internal.bucket_generation                       \
    vshard.storage.internal.bucket_generation = gen + 1                         \
    vshard.storage.internal.bucket_generation_cond:broadcast()                  \
end)
f = fiber.create(vshard.storage.internal.gc_bucket_f)
-- Wait until garbage collection is finished.
test_run:wait_cond(function() return s2:count() == 3 and s:count() == 6 end)
s:select{}
s2:select{}
-- Check garbage bucket is deleted by background fiber.
_bucket:select{}
--
-- Test deletion of 'sent' buckets after a specified timeout.
--
_bucket:replace{2, vshard.consts.BUCKET.SENT}
-- Wait deletion after a while.
test_run:wait_cond(function() return not _bucket:get{2} end)
_bucket:select{}
s:select{}
s2:select{}

--
-- Test full lifecycle of a bucket.
--
_bucket:replace{4, vshard.consts.BUCKET.ACTIVE}
s:replace{5, 4}
s:replace{6, 4}
_bucket:replace{4, vshard.consts.BUCKET.SENT}
test_run:wait_cond(function() return not _bucket:get{4} end)

--
-- Test WAL errors during deletion from _bucket.
--
function rollback_on_delete(old, new) if old ~= nil and new == nil then box.rollback() end end
_ = _bucket:on_replace(rollback_on_delete)
_bucket:replace{4, vshard.consts.BUCKET.SENT}
s:replace{5, 4}
s:replace{6, 4}
test_run:wait_log('default', 'Error during garbage collection step',            \
                  65536, 10)
test_run:wait_cond(function() return #sk:select{4} == 0 end)
s:select{}
_bucket:select{}
_ = _bucket:on_replace(nil, rollback_on_delete)
test_run:wait_cond(function() return not _bucket:get{4} end)

f:cancel()

--
-- Test API function to delete a specified bucket data.
--
util = require('util')

delete_garbage = vshard.storage._bucket_delete_garbage
util.check_error(delete_garbage)

-- Delete an existing garbage bucket.
_bucket:replace{4, vshard.consts.BUCKET.SENT}
s:replace{5, 4}
s:replace{6, 4}
delete_garbage(4)
s:select{}

-- Delete a not existing garbage bucket.
_ = _bucket:delete{4}
s:replace{5, 4}
s:replace{6, 4}
delete_garbage(4)
s:select{}

-- Fail to delete a not garbage bucket.
_bucket:replace{4, vshard.consts.BUCKET.ACTIVE}
s:replace{5, 4}
s:replace{6, 4}
util.check_error(delete_garbage, 4)
util.check_error(delete_garbage, 4, 10000)
-- 'Force' option ignores this error.
delete_garbage(4, {force = true})
s:select{}

--
-- Test huge bucket count deletion.
--
for i = 1, 2000 do _bucket:replace{i, vshard.consts.BUCKET.GARBAGE} s:replace{i, i} s2:replace{i, i} end
#_bucket:select{}
#s:select{}
#s2:select{}
f = fiber.create(vshard.storage.internal.gc_bucket_f)
test_run:wait_cond(function() return _bucket:count() == 0 end)
_bucket:select{}
s:select{}
s2:select{}
f:cancel()

s2:drop()
s:drop()
_bucket:drop()
