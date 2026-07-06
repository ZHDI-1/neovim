local t = require('test.unit.testutil')

local ffi = t.ffi
local eq = t.eq
local ok = t.ok
local itp = t.gen_itp(it)

ffi.cdef([[
typedef struct piece_tree_node PieceTreeNode;
typedef bool (*PieceTreeSpanCallback)(const char *data, size_t len, void *ctx);
typedef bool (*PieceTreeMatchCallback)(size_t offset, void *ctx);
typedef struct {
  const char *original;
  size_t original_len;
  const size_t *original_line_starts;
  size_t original_index_count;
  size_t original_index_stride;
  size_t add_len;
  size_t add_cap;
  void *add_chunks;
  void *add_tail;
  PieceTreeNode *root;
  void *node_blocks;
  PieceTreeNode *free_nodes;
  PieceTreeNode *retired_nodes;
  size_t node_count;
  size_t node_capacity;
  size_t retired_node_count;
  size_t reader_count;
  size_t span_ref_count;
  uint64_t revision;
} PieceTree;
typedef struct {
  const char *data;
  size_t len;
  size_t offset;
} PieceTreeSpan;
typedef struct {
  PieceTree *owner;
  PieceTreeSpan *items;
  size_t count;
  size_t logical_start;
  size_t byte_len;
  uint64_t revision;
} PieceTreeSpanVec;
typedef struct {
  size_t byte_len;
  size_t newline_count;
  size_t line_count;
  uint64_t revision;
} PieceTreeSnapshot;
]])

local lib = t.cimport('./src/nvim/piece_tree.h')

local function cbuf(s)
  local len = math.max(#s, 1)
  local buf = ffi.new('char[?]', len)
  if #s > 0 then
    ffi.copy(buf, s, #s)
  end
  return buf
end

local function new_tree(original)
  local tree = ffi.gc(ffi.new('PieceTree[1]'), function(ptr)
    lib.piece_tree_clear(ptr)
  end)
  local original_buf = cbuf(original)
  lib.piece_tree_init(tree, original_buf, #original)
  return { tree = tree, original = original_buf }
end

local function new_uninit_tree()
  return ffi.gc(ffi.new('PieceTree[1]'), function(ptr)
    lib.piece_tree_clear(ptr)
  end)
end

local function read_tree(tree)
  local len = tonumber(lib.piece_tree_byte_len(tree))
  local buf = ffi.new('char[?]', math.max(len, 1))
  local copied = tonumber(lib.piece_tree_read(tree, 0, buf, len))
  eq(len, copied)
  return ffi.string(buf, len)
end

local function collect_spans(tree, offset, len)
  local spansp = ffi.new('PieceTreeSpan *[1]')
  local countp = ffi.new('size_t[1]')
  ok(lib.piece_tree_collect_spans(tree, offset, len, spansp, countp))
  local spans = spansp[0]
  if spans ~= ffi.cast('PieceTreeSpan *', 0) then
    spans = ffi.gc(spans, lib.piece_tree_free_spans)
  end
  return spans, tonumber(countp[0])
end

local function collect_span_vec(tree, offset, len)
  local vec = ffi.gc(ffi.new('PieceTreeSpanVec[1]'), function(ptr)
    lib.piece_tree_span_vec_clear(ptr)
  end)
  ok(lib.piece_tree_collect_span_vec(tree, offset, len, vec))
  return vec
end

local function read_spans(spans, count)
  local parts = {}
  for i = 0, count - 1 do
    parts[#parts + 1] = ffi.string(spans[i].data, spans[i].len)
  end
  return table.concat(parts)
end

local function read_span_vec(vec)
  return read_spans(vec[0].items, tonumber(vec[0].count))
end

local function newline_count(s)
  local _, count = s:gsub('\n', '')
  return count
end

local function line_count(s)
  local nls = newline_count(s)
  if #s == 0 then
    return 1
  end
  if s:sub(-1) == '\n' then
    return nls
  end
  return nls + 1
end

local function line_start_for_lnum(s, lnum)
  if lnum < 1 or lnum > line_count(s) then
    return nil
  end
  if lnum == 1 then
    return 0
  end

  local seen = 0
  for i = 1, #s do
    if s:sub(i, i) == '\n' then
      seen = seen + 1
      if seen == lnum - 1 then
        return i
      end
    end
  end
  return nil
end

local function line_bounds_for_lnum(s, lnum)
  local start = line_start_for_lnum(s, lnum)
  if start == nil then
    return nil
  end

  if lnum < line_count(s) then
    return start, line_start_for_lnum(s, lnum + 1) - 1
  end
  if #s > 0 and s:sub(-1) == '\n' then
    return start, #s - 1
  end
  return start, #s
end

local function lnum_for_offset(s, off)
  if off > #s then
    return nil
  end
  if #s == 0 then
    return 1, 0
  end
  if off == #s and s:sub(-1) == '\n' then
    local lnum = line_count(s)
    return lnum, line_start_for_lnum(s, lnum)
  end

  local prefix = s:sub(1, off)
  local lnum = newline_count(prefix) + 1
  return lnum, line_start_for_lnum(s, lnum)
end

local function check_tree(tree, shadow)
  local initial_readers = tonumber(tree[0].reader_count)

  ok(lib.piece_tree_check(tree))
  eq(#shadow, tonumber(lib.piece_tree_byte_len(tree)))
  eq(newline_count(shadow), tonumber(lib.piece_tree_newline_count(tree)))
  eq(line_count(shadow), tonumber(lib.piece_tree_line_count(tree)))
  eq(shadow, read_tree(tree))

  for lnum = 1, line_count(shadow) do
    local offp = ffi.new('size_t[1]')
    ok(lib.piece_tree_line_start(tree, lnum, offp))
    eq(line_start_for_lnum(shadow, lnum), tonumber(offp[0]))

    local startp = ffi.new('size_t[1]')
    local endp = ffi.new('size_t[1]')
    ok(lib.piece_tree_line_bounds(tree, lnum, startp, endp))
    local start, end_ = line_bounds_for_lnum(shadow, lnum)
    eq(start, tonumber(startp[0]))
    eq(end_, tonumber(endp[0]))
  end

  for off = 0, #shadow do
    local lnump = ffi.new('size_t[1]')
    local startp = ffi.new('size_t[1]')
    ok(lib.piece_tree_lnum_for_offset(tree, off, lnump, startp))
    local lnum, start = lnum_for_offset(shadow, off)
    eq(lnum, tonumber(lnump[0]))
    eq(start, tonumber(startp[0]))
  end

  eq(initial_readers, tonumber(tree[0].reader_count))
end

local function insert_shadow(s, off, text)
  return s:sub(1, off) .. text .. s:sub(off + 1)
end

local function delete_shadow(s, off, len)
  return s:sub(1, off) .. s:sub(off + len + 1)
end

local function replace_shadow(s, off, len, text)
  return insert_shadow(delete_shadow(s, off, len), off, text)
end

local function find_literal(tree, offset, len, pat)
  local offp = ffi.new('size_t[1]')
  local found = lib.piece_tree_find_literal(tree, offset, len, pat, #pat, offp)
  if not found then
    return nil
  end
  return tonumber(offp[0])
end

local function find_shadow(s, offset, len, pat)
  if #pat == 0 or offset > #s or len > #s - offset or #pat > len then
    return nil
  end
  local match = s:sub(offset + 1, offset + len):find(pat, 1, true)
  if match == nil then
    return nil
  end
  return offset + match - 1
end

local function find_all_shadow(s, offset, len, pat)
  if #pat == 0 or offset > #s or len > #s - offset or #pat > len then
    return nil
  end

  local matches = {}
  local start = 1
  local haystack = s:sub(offset + 1, offset + len)
  while start <= #haystack do
    local match = haystack:find(pat, start, true)
    if match == nil then
      break
    end
    matches[#matches + 1] = offset + match - 1
    start = match + #pat
  end
  return matches
end

local function find_literals(tree, offset, len, pat, stop_after, reader_tree)
  local matches = {}
  local cb = ffi.cast('PieceTreeMatchCallback', function(match_offset, _)
    if reader_tree ~= nil then
      eq(0, tonumber(reader_tree[0].reader_count))
      eq(1, tonumber(reader_tree[0].span_ref_count))
    end
    matches[#matches + 1] = tonumber(match_offset)
    return stop_after == nil or #matches < stop_after
  end)
  local ok_ = lib.piece_tree_find_literals(tree, offset, len, pat, #pat, cb, nil)
  cb:free()
  if reader_tree ~= nil then
    eq(0, tonumber(reader_tree[0].reader_count))
    eq(0, tonumber(reader_tree[0].span_ref_count))
  end
  return ok_, matches
end

describe('piece tree', function()
  itp('initializes from borrowed original storage', function()
    local empty = ffi.gc(ffi.new('PieceTree[1]'), function(ptr)
      lib.piece_tree_clear(ptr)
    end)
    lib.piece_tree_init(empty, nil, 0)
    check_tree(empty, '')

    local w = new_tree('alpha\nbeta\ngamma')
    check_tree(w.tree, 'alpha\nbeta\ngamma')
    eq(1, tonumber(lib.piece_tree_node_count(w.tree)))
  end)

  itp('rebases borrowed original storage without changing add storage', function()
    local w = new_tree('abc\ndef')
    ok(lib.piece_tree_insert(w.tree, 3, 'X', 1))
    check_tree(w.tree, 'abcX\ndef')
    local revision = tonumber(w.tree[0].revision)

    local wrong_len = cbuf('ABC\nDE')
    eq(false, lib.piece_tree_rebase_original(w.tree, wrong_len, 6))
    check_tree(w.tree, 'abcX\ndef')

    local active_reader = cbuf('ABC\nDEF')
    lib.piece_tree_reader_enter(w.tree)
    eq(false, lib.piece_tree_rebase_original(w.tree, active_reader, 7))
    lib.piece_tree_reader_leave(w.tree)
    check_tree(w.tree, 'abcX\ndef')

    local span_vec = collect_span_vec(w.tree, 0, 3)
    eq(1, tonumber(w.tree[0].span_ref_count))
    local active_span = cbuf('ABC\nDEF')
    eq(false, lib.piece_tree_rebase_original(w.tree, active_span, 7))
    lib.piece_tree_span_vec_clear(span_vec)
    eq(0, tonumber(w.tree[0].span_ref_count))
    check_tree(w.tree, 'abcX\ndef')

    local new_original = cbuf('ABC\nDEF')
    ok(lib.piece_tree_rebase_original(w.tree, new_original, 7))
    eq(revision, tonumber(w.tree[0].revision))
    check_tree(w.tree, 'ABCX\nDEF')
  end)

  itp('inserts at beginning, middle, and end', function()
    local w = new_tree('alpha\ngamma')
    local shadow = 'alpha\ngamma'

    ok(lib.piece_tree_insert(w.tree, 0, '>', 1))
    shadow = insert_shadow(shadow, 0, '>')
    check_tree(w.tree, shadow)

    ok(lib.piece_tree_insert(w.tree, 7, 'beta\n', 5))
    shadow = insert_shadow(shadow, 7, 'beta\n')
    check_tree(w.tree, shadow)

    ok(lib.piece_tree_insert(w.tree, #shadow, '\nomega', 6))
    shadow = insert_shadow(shadow, #shadow, '\nomega')
    check_tree(w.tree, shadow)
  end)

  itp('extends adjacent insert runs in the tail add piece without transient nodes', function()
    local w = new_tree('abcd')
    local shadow = 'abcd'
    local null = ffi.cast('void *', 0)

    ok(lib.piece_tree_insert(w.tree, 2, 'x', 1))
    shadow = insert_shadow(shadow, 2, 'x')
    check_tree(w.tree, shadow)

    local node_count = tonumber(lib.piece_tree_node_count(w.tree))
    local node_capacity = tonumber(lib.piece_tree_node_capacity(w.tree))
    eq(1, tonumber(w.tree[0].add_len))
    eq(0, tonumber(lib.piece_tree_free_node_count(w.tree)))
    ok(w.tree[0].free_nodes == null)

    for i = 1, 32 do
      local text = string.char(96 + ((i - 1) % 26) + 1)
      ok(lib.piece_tree_insert(w.tree, 2 + i, text, #text))
      shadow = insert_shadow(shadow, 2 + i, text)
      check_tree(w.tree, shadow)
      eq(node_count, tonumber(lib.piece_tree_node_count(w.tree)))
      eq(node_capacity, tonumber(lib.piece_tree_node_capacity(w.tree)))
      eq(i + 1, tonumber(w.tree[0].add_len))
      eq(0, tonumber(lib.piece_tree_free_node_count(w.tree)))
      ok(w.tree[0].free_nodes == null)
    end
  end)

  itp('deletes ranges across piece boundaries', function()
    local w = new_tree('0123456789')
    local shadow = '0123456789'

    ok(lib.piece_tree_insert(w.tree, 5, 'abc\ndef', 7))
    shadow = insert_shadow(shadow, 5, 'abc\ndef')
    check_tree(w.tree, shadow)

    ok(lib.piece_tree_delete(w.tree, 3, 10))
    shadow = delete_shadow(shadow, 3, 10)
    check_tree(w.tree, shadow)

    ok(lib.piece_tree_delete(w.tree, 0, #shadow))
    shadow = ''
    check_tree(w.tree, shadow)
  end)

  itp('reuses nodes from the tree arena after deletes', function()
    local w = new_tree('abcdef')
    local capacity = tonumber(lib.piece_tree_node_capacity(w.tree))
    ok(capacity > 0)

    for _ = 1, capacity * 2 do
      ok(lib.piece_tree_insert(w.tree, 3, 'XYZ', 3))
      check_tree(w.tree, 'abcXYZdef')
      ok(lib.piece_tree_delete(w.tree, 3, 3))
      check_tree(w.tree, 'abcdef')
    end

    eq(1, tonumber(lib.piece_tree_node_count(w.tree)))
    eq(capacity, tonumber(lib.piece_tree_node_capacity(w.tree)))
  end)

  itp('blocks mutations while read guards are active', function()
    local w = new_tree('abcdef')
    check_tree(w.tree, 'abcdef')

    lib.piece_tree_reader_enter(w.tree)
    eq(1, tonumber(w.tree[0].reader_count))

    eq(false, lib.piece_tree_insert(w.tree, 3, 'XYZ', 3))
    eq(false, lib.piece_tree_delete(w.tree, 3, 2))
    eq(false, lib.piece_tree_replace(w.tree, 3, 2, 'XYZ', 3))
    check_tree(w.tree, 'abcdef')

    lib.piece_tree_reader_leave(w.tree)
    eq(0, tonumber(w.tree[0].reader_count))
    ok(lib.piece_tree_insert(w.tree, 3, 'XYZ', 3))
    check_tree(w.tree, 'abcXYZdef')
  end)

  itp('reclaims manually retired nodes only after readers leave', function()
    local w = new_tree('abcdef')
    local null = ffi.cast('void *', 0)
    ok(lib.piece_tree_insert(w.tree, 3, 'XYZ', 3))
    ok(lib.piece_tree_delete(w.tree, 3, 3))
    check_tree(w.tree, 'abcdef')

    local retired_count = tonumber(lib.piece_tree_free_node_count(w.tree))
    ok(retired_count > 0)
    w.tree[0].retired_nodes = w.tree[0].free_nodes
    w.tree[0].retired_node_count = retired_count
    w.tree[0].free_nodes = null

    lib.piece_tree_reader_enter(w.tree)
    eq(false, lib.piece_tree_reclaim_retired(w.tree))
    eq(0, tonumber(lib.piece_tree_reclaim_retired_budget(w.tree, 1)))
    eq(retired_count, tonumber(lib.piece_tree_retired_node_count(w.tree)))
    ok(w.tree[0].retired_nodes ~= null)
    ok(w.tree[0].free_nodes == null)

    lib.piece_tree_reader_leave(w.tree)
    eq(1, tonumber(lib.piece_tree_reclaim_retired_budget(w.tree, 1)))
    eq(retired_count - 1, tonumber(lib.piece_tree_retired_node_count(w.tree)))
    eq(1, tonumber(lib.piece_tree_free_node_count(w.tree)))

    ok(lib.piece_tree_reclaim_retired(w.tree))
    eq(0, tonumber(lib.piece_tree_retired_node_count(w.tree)))
    ok(w.tree[0].retired_nodes == null)
    ok(w.tree[0].free_nodes ~= null)
    eq(retired_count, tonumber(lib.piece_tree_free_node_count(w.tree)))
    check_tree(w.tree, 'abcdef')
  end)

  itp('validates arena ownership for active, free, and retired nodes', function()
    local w = new_tree('abcdef')
    local null = ffi.cast('void *', 0)
    ok(lib.piece_tree_insert(w.tree, 3, 'XYZ', 3))
    ok(lib.piece_tree_delete(w.tree, 3, 3))
    check_tree(w.tree, 'abcdef')
    ok(w.tree[0].free_nodes ~= null)

    local saved_free = w.tree[0].free_nodes
    w.tree[0].free_nodes = w.tree[0].root
    eq(false, lib.piece_tree_check(w.tree))
    w.tree[0].free_nodes = saved_free
    ok(lib.piece_tree_check(w.tree))

    local saved_retired = w.tree[0].retired_nodes
    local saved_retired_count = tonumber(w.tree[0].retired_node_count)
    w.tree[0].retired_nodes = w.tree[0].root
    w.tree[0].retired_node_count = 1
    eq(false, lib.piece_tree_check(w.tree))
    w.tree[0].retired_nodes = saved_retired
    w.tree[0].retired_node_count = saved_retired_count
    ok(lib.piece_tree_check(w.tree))

    ok(w.tree[0].retired_nodes == null)
    w.tree[0].retired_node_count = saved_retired_count + 1
    eq(false, lib.piece_tree_check(w.tree))
    w.tree[0].retired_node_count = saved_retired_count
    ok(lib.piece_tree_check(w.tree))
  end)

  itp('replaces ranges and preserves neighboring original pieces', function()
    local w = new_tree('line1\nline2\nline3\nline4')
    local shadow = 'line1\nline2\nline3\nline4'

    ok(lib.piece_tree_replace(w.tree, 6, 11, 'TWO\nTHREE', 9))
    shadow = replace_shadow(shadow, 6, 11, 'TWO\nTHREE')
    check_tree(w.tree, shadow)

    ok(lib.piece_tree_replace(w.tree, 0, 4, 'LINE', 4))
    shadow = replace_shadow(shadow, 0, 4, 'LINE')
    check_tree(w.tree, shadow)
  end)

  itp('counts each replace as one logical revision', function()
    local w = new_tree('abcdef')
    check_tree(w.tree, 'abcdef')
    eq(0, tonumber(w.tree[0].revision))

    ok(lib.piece_tree_insert(w.tree, 3, 'X', 1))
    check_tree(w.tree, 'abcXdef')
    eq(1, tonumber(w.tree[0].revision))

    ok(lib.piece_tree_delete(w.tree, 3, 1))
    check_tree(w.tree, 'abcdef')
    eq(2, tonumber(w.tree[0].revision))

    ok(lib.piece_tree_replace(w.tree, 1, 3, 'XYZ', 3))
    check_tree(w.tree, 'aXYZef')
    eq(3, tonumber(w.tree[0].revision))

    ok(lib.piece_tree_replace(w.tree, 1, 0, '!', 1))
    check_tree(w.tree, 'a!XYZef')
    eq(4, tonumber(w.tree[0].revision))

    ok(lib.piece_tree_replace(w.tree, 1, 1, '', 0))
    check_tree(w.tree, 'aXYZef')
    eq(5, tonumber(w.tree[0].revision))

    ok(lib.piece_tree_replace(w.tree, 1, 0, '', 0))
    check_tree(w.tree, 'aXYZef')
    eq(5, tonumber(w.tree[0].revision))

    eq(false, lib.piece_tree_replace(w.tree, 100, 1, 'bad', 3))
    check_tree(w.tree, 'aXYZef')
    eq(5, tonumber(w.tree[0].revision))
  end)

  itp('captures snapshot metadata and rejects stale revision reads', function()
    local w = new_tree('one\ntwo')
    local shadow = 'one\ntwo'
    local snapshot = ffi.new('PieceTreeSnapshot[1]')
    ok(lib.piece_tree_snapshot(w.tree, snapshot))

    eq(#shadow, tonumber(snapshot[0].byte_len))
    eq(newline_count(shadow), tonumber(snapshot[0].newline_count))
    eq(line_count(shadow), tonumber(snapshot[0].line_count))
    eq(0, tonumber(snapshot[0].revision))

    local startp = ffi.new('size_t[1]')
    ok(lib.piece_tree_line_start_at_revision(w.tree, 2, snapshot[0].revision, startp))
    eq(line_start_for_lnum(shadow, 2), tonumber(startp[0]))

    local vec = ffi.gc(ffi.new('PieceTreeSpanVec[1]'), function(ptr)
      lib.piece_tree_span_vec_clear(ptr)
    end)
    ok(lib.piece_tree_collect_span_vec_at_revision(w.tree, 0, #shadow, snapshot[0].revision, vec))
    eq(#shadow, tonumber(vec[0].byte_len))
    eq(tonumber(snapshot[0].revision), tonumber(vec[0].revision))
    eq(shadow, read_span_vec(vec))

    ok(lib.piece_tree_insert(w.tree, #shadow, '\nthree', 6))
    shadow = shadow .. '\nthree'
    check_tree(w.tree, shadow)

    eq(false, lib.piece_tree_line_start_at_revision(w.tree, 2, snapshot[0].revision, startp))
    local stale_vec = ffi.new('PieceTreeSpanVec[1]')
    eq(false, lib.piece_tree_collect_span_vec_at_revision(w.tree, 0, #shadow,
                                                          snapshot[0].revision, stale_vec))
    eq(0, tonumber(stale_vec[0].count))
    eq(0, tonumber(stale_vec[0].byte_len))
    ok(stale_vec[0].items == ffi.cast('PieceTreeSpan *', 0))

    ok(lib.piece_tree_snapshot(w.tree, snapshot))
    eq(#shadow, tonumber(snapshot[0].byte_len))
    eq(newline_count(shadow), tonumber(snapshot[0].newline_count))
    eq(line_count(shadow), tonumber(snapshot[0].line_count))
    eq(1, tonumber(snapshot[0].revision))

    lib.piece_tree_span_vec_clear(vec)
    eq(0, tonumber(w.tree[0].span_ref_count))
  end)

  itp('reads partial ranges across pieces', function()
    local w = new_tree('abcdef')
    ok(lib.piece_tree_insert(w.tree, 3, 'XYZ', 3))
    check_tree(w.tree, 'abcXYZdef')

    local buf = ffi.new('char[?]', 5)
    eq(0, tonumber(w.tree[0].reader_count))
    eq(5, tonumber(lib.piece_tree_read(w.tree, 2, buf, 5)))
    eq(0, tonumber(w.tree[0].reader_count))
    eq('cXYZd', ffi.string(buf, 5))
  end)

  itp('iterates byte spans across pieces', function()
    local w = new_tree('abcdef')
    local shadow = 'abcdef'

    ok(lib.piece_tree_insert(w.tree, 3, 'XYZ', 3))
    shadow = insert_shadow(shadow, 3, 'XYZ')
    ok(lib.piece_tree_insert(w.tree, 0, '>', 1))
    shadow = insert_shadow(shadow, 0, '>')
    check_tree(w.tree, shadow)

    local spans = {}
    local cb = ffi.cast('PieceTreeSpanCallback', function(data, len, _)
      eq(0, tonumber(w.tree[0].reader_count))
      eq(1, tonumber(w.tree[0].span_ref_count))
      spans[#spans + 1] = ffi.string(data, len)
      return true
    end)
    ok(lib.piece_tree_for_each_span(w.tree, 1, #shadow - 2, cb, nil))
    cb:free()
    eq(0, tonumber(w.tree[0].reader_count))
    eq(0, tonumber(w.tree[0].span_ref_count))

    eq(shadow:sub(2, #shadow - 1), table.concat(spans))
    ok(#spans > 1)

    local calls = 0
    local stop_cb = ffi.cast('PieceTreeSpanCallback', function(_, _, _)
      eq(0, tonumber(w.tree[0].reader_count))
      eq(1, tonumber(w.tree[0].span_ref_count))
      calls = calls + 1
      return false
    end)
    eq(false, lib.piece_tree_for_each_span(w.tree, 0, #shadow, stop_cb, nil))
    stop_cb:free()
    eq(0, tonumber(w.tree[0].reader_count))
    eq(0, tonumber(w.tree[0].span_ref_count))
    eq(1, calls)

    calls = 0
    local count_cb = ffi.cast('PieceTreeSpanCallback', function(_, _, _)
      calls = calls + 1
      return true
    end)
    ok(lib.piece_tree_for_each_span(w.tree, #shadow, 0, count_cb, nil))
    eq(0, tonumber(w.tree[0].reader_count))
    eq(0, calls)
    eq(false, lib.piece_tree_for_each_span(w.tree, #shadow + 1, 0, count_cb, nil))
    count_cb:free()
  end)

  itp('allows mutation while public span callbacks consume leased spans', function()
    local w = new_tree('abcdef')
    local shadow = 'abcdef'

    ok(lib.piece_tree_insert(w.tree, 3, 'XYZ', 3))
    shadow = insert_shadow(shadow, 3, 'XYZ')
    check_tree(w.tree, shadow)

    local captured = {}
    local mutated = false
    local cb = ffi.cast('PieceTreeSpanCallback', function(data, len, _)
      eq(0, tonumber(w.tree[0].reader_count))
      eq(1, tonumber(w.tree[0].span_ref_count))
      if not mutated then
        mutated = true
        ok(lib.piece_tree_insert(w.tree, 0, '>', 1))
      end
      captured[#captured + 1] = ffi.string(data, len)
      return true
    end)
    ok(lib.piece_tree_for_each_span(w.tree, 0, #shadow, cb, nil))
    cb:free()

    eq(shadow, table.concat(captured))
    shadow = insert_shadow(shadow, 0, '>')
    check_tree(w.tree, shadow)
    eq(0, tonumber(w.tree[0].reader_count))
    eq(0, tonumber(w.tree[0].span_ref_count))
  end)

  itp('collects stable span vectors for later processing', function()
    local w = new_tree('abcdef\njkl')
    local shadow = 'abcdef\njkl'

    ok(lib.piece_tree_insert(w.tree, 3, 'XYZ\n', 4))
    shadow = insert_shadow(shadow, 3, 'XYZ\n')
    ok(lib.piece_tree_insert(w.tree, #shadow, '\ntail', 5))
    shadow = insert_shadow(shadow, #shadow, '\ntail')
    check_tree(w.tree, shadow)

    local start = 1
    local len = #shadow - 2
    eq(0, tonumber(w.tree[0].span_ref_count))
    local spans, count = collect_spans(w.tree, start, len)
    eq(0, tonumber(w.tree[0].span_ref_count))
    local snapshot_revision = tonumber(w.tree[0].revision)
    local span_vec = collect_span_vec(w.tree, start, len)
    eq(1, tonumber(w.tree[0].span_ref_count))
    ok(span_vec[0].owner == w.tree)
    ok(count > 1)
    eq(shadow:sub(start + 1, start + len), read_spans(spans, count))
    eq(count, tonumber(span_vec[0].count))
    eq(start, tonumber(span_vec[0].logical_start))
    eq(len, tonumber(span_vec[0].byte_len))
    eq(snapshot_revision, tonumber(span_vec[0].revision))
    eq(shadow:sub(start + 1, start + len), read_span_vec(span_vec))

    local offset = start
    for i = 0, count - 1 do
      eq(offset, tonumber(spans[i].offset))
      eq(offset, tonumber(span_vec[0].items[i].offset))
      offset = offset + tonumber(spans[i].len)
    end
    eq(start + len, offset)

    ok(lib.piece_tree_delete(w.tree, 0, #shadow))
    ok(lib.piece_tree_insert(w.tree, 0, 'replacement', 11))
    check_tree(w.tree, 'replacement')
    ok(tonumber(w.tree[0].revision) > snapshot_revision)
    eq(shadow:sub(start + 1, start + len), read_spans(spans, count))
    eq(shadow:sub(start + 1, start + len), read_span_vec(span_vec))

    local empty_spans, empty_count = collect_spans(w.tree, 0, 0)
    local empty_vec = collect_span_vec(w.tree, 0, 0)
    eq(2, tonumber(w.tree[0].span_ref_count))
    ok(empty_vec[0].owner == w.tree)
    eq(0, empty_count)
    eq('', read_spans(empty_spans, empty_count))
    eq(0, tonumber(empty_vec[0].count))
    eq(0, tonumber(empty_vec[0].logical_start))
    eq(0, tonumber(empty_vec[0].byte_len))
    eq(tonumber(w.tree[0].revision), tonumber(empty_vec[0].revision))
    eq('', read_span_vec(empty_vec))

    local clear_vec = collect_span_vec(w.tree, 0, #('replacement'))
    eq(3, tonumber(w.tree[0].span_ref_count))
    ok(tonumber(clear_vec[0].count) > 0)
    lib.piece_tree_span_vec_clear(clear_vec)
    eq(2, tonumber(w.tree[0].span_ref_count))
    eq(0, tonumber(clear_vec[0].count))
    eq(0, tonumber(clear_vec[0].logical_start))
    eq(0, tonumber(clear_vec[0].byte_len))
    ok(clear_vec[0].items == ffi.cast('PieceTreeSpan *', 0))

    local spansp = ffi.new('PieceTreeSpan *[1]')
    local countp = ffi.new('size_t[1]')
    eq(false, lib.piece_tree_collect_spans(w.tree, 100, 0, spansp, countp))
    eq(0, tonumber(countp[0]))

    local bad_vec = ffi.new('PieceTreeSpanVec[1]')
    eq(false, lib.piece_tree_collect_span_vec(w.tree, 100, 0, bad_vec))
    eq(2, tonumber(w.tree[0].span_ref_count))
    ok(bad_vec[0].owner == ffi.cast('PieceTree *', 0))
    eq(0, tonumber(bad_vec[0].count))
    eq(0, tonumber(bad_vec[0].logical_start))
    eq(0, tonumber(bad_vec[0].byte_len))
    ok(bad_vec[0].items == ffi.cast('PieceTreeSpan *', 0))

    lib.piece_tree_span_vec_clear(empty_vec)
    eq(1, tonumber(w.tree[0].span_ref_count))
    lib.piece_tree_span_vec_clear(span_vec)
    eq(0, tonumber(w.tree[0].span_ref_count))
  end)

  itp('disposes storage incrementally after span leases are released', function()
    local w = new_tree('abcdef')
    local inserted = string.rep('x', 9000)
    local null = ffi.cast('void *', 0)

    ok(lib.piece_tree_insert(w.tree, 3, inserted, #inserted))
    ok(w.tree[0].node_blocks ~= null)
    ok(w.tree[0].add_chunks ~= null)

    local vec = collect_span_vec(w.tree, 0, 3)
    eq(1, tonumber(lib.piece_tree_storage_ref_count(w.tree)))

    local budget = ffi.new('size_t[1]', 1)
    eq(false, lib.piece_tree_dispose_budget(w.tree, budget))
    eq(1, tonumber(budget[0]))
    ok(w.tree[0].node_blocks ~= null)
    ok(w.tree[0].add_chunks ~= null)

    lib.piece_tree_span_vec_clear(vec)
    eq(0, tonumber(lib.piece_tree_storage_ref_count(w.tree)))

    budget[0] = 0
    eq(false, lib.piece_tree_dispose_budget(w.tree, budget))
    ok(w.tree[0].node_blocks ~= null)
    ok(w.tree[0].add_chunks ~= null)

    budget[0] = 1
    eq(false, lib.piece_tree_dispose_budget(w.tree, budget))
    eq(0, tonumber(budget[0]))
    ok(w.tree[0].node_blocks == null)
    ok(w.tree[0].add_chunks ~= null)
    eq(0, tonumber(w.tree[0].node_capacity))

    budget[0] = 1
    eq(true, lib.piece_tree_dispose_budget(w.tree, budget))
    eq(0, tonumber(w.tree[0].node_capacity))
    ok(w.tree[0].node_blocks == null)
    ok(w.tree[0].add_chunks == null)
  end)

  itp('clones compact composition with independent add storage', function()
    local w = new_tree('alpha\nomega\n')
    local shadow = 'alpha\nomega\n'
    local null = ffi.cast('void *', 0)

    ok(lib.piece_tree_insert(w.tree, 6, 'beta\n', 5))
    shadow = insert_shadow(shadow, 6, 'beta\n')
    ok(lib.piece_tree_insert(w.tree, #shadow, 'tail\n', 5))
    shadow = insert_shadow(shadow, #shadow, 'tail\n')
    ok(lib.piece_tree_replace(w.tree, 0, 5, 'ALPHA', 5))
    shadow = replace_shadow(shadow, 0, 5, 'ALPHA')
    eq(15, tonumber(w.tree[0].add_len))
    eq(15, tonumber(lib.piece_tree_add_live_len(w.tree)))
    ok(lib.piece_tree_delete(w.tree, 6, 5))
    shadow = delete_shadow(shadow, 6, 5)
    check_tree(w.tree, shadow)
    eq(15, tonumber(w.tree[0].add_len))
    eq(10, tonumber(lib.piece_tree_add_live_len(w.tree)))

    local source_add_chunks = w.tree[0].add_chunks
    ok(source_add_chunks ~= null)

    local clone = new_uninit_tree()
    ok(lib.piece_tree_clone_compact(clone, w.tree))
    check_tree(clone, shadow)
    eq(10, tonumber(clone[0].add_len))
    eq(10, tonumber(lib.piece_tree_add_live_len(clone)))
    eq(tonumber(w.tree[0].revision), tonumber(clone[0].revision))
    eq(0, tonumber(lib.piece_tree_free_node_count(clone)))
    eq(0, tonumber(clone[0].retired_node_count))
    ok(clone[0].free_nodes == null)
    ok(clone[0].retired_nodes == null)
    ok(clone[0].add_chunks ~= null)
    ok(clone[0].add_chunks ~= source_add_chunks)
    ok(tonumber(lib.piece_tree_node_count(clone)) <= tonumber(lib.piece_tree_node_count(w.tree)))

    local clone_with_reader = new_uninit_tree()
    lib.piece_tree_reader_enter(w.tree)
    ok(lib.piece_tree_clone_compact(clone_with_reader, w.tree))
    eq(1, tonumber(w.tree[0].reader_count))
    lib.piece_tree_reader_leave(w.tree)
    check_tree(clone_with_reader, shadow)

    lib.piece_tree_clear(w.tree)
    check_tree(clone, shadow)
    check_tree(clone_with_reader, shadow)
  end)

  itp('clones compact composition from a leased span vector', function()
    local w = new_tree('alpha\nomega\n')
    local shadow = 'alpha\nomega\n'

    ok(lib.piece_tree_insert(w.tree, 6, 'beta\n', 5))
    shadow = insert_shadow(shadow, 6, 'beta\n')
    ok(lib.piece_tree_replace(w.tree, 0, 5, 'ALPHA', 5))
    shadow = replace_shadow(shadow, 0, 5, 'ALPHA')
    check_tree(w.tree, shadow)

    local captured = shadow
    local vec = collect_span_vec(w.tree, 0, #captured)
    local captured_revision = tonumber(vec[0].revision)
    eq(1, tonumber(w.tree[0].span_ref_count))

    ok(lib.piece_tree_delete(w.tree, 0, 6))
    shadow = delete_shadow(shadow, 0, 6)
    ok(lib.piece_tree_insert(w.tree, 0, 'changed\n', 8))
    shadow = insert_shadow(shadow, 0, 'changed\n')
    check_tree(w.tree, shadow)

    local clone = new_uninit_tree()
    ok(lib.piece_tree_clone_compact_from_span_vec(clone, w.tree, vec))
    check_tree(clone, captured)
    eq(captured_revision, tonumber(clone[0].revision))
    eq(tonumber(lib.piece_tree_add_live_len(clone)), tonumber(clone[0].add_len))

    lib.piece_tree_span_vec_clear(vec)
    eq(0, tonumber(w.tree[0].span_ref_count))
    check_tree(clone, captured)
  end)

  itp('stores appended text in multiple add chunks', function()
    local w = new_tree('start\nend')
    local first = string.rep('a', 5000) .. 'BOUNDARY-'
    local second = 'CROSS\n' .. string.rep('b', 32)
    local shadow = 'start\nend'

    ok(lib.piece_tree_insert(w.tree, 6, first, #first))
    shadow = insert_shadow(shadow, 6, first)
    ok(lib.piece_tree_insert(w.tree, 6 + #first, second, #second))
    shadow = insert_shadow(shadow, 6 + #first, second)
    check_tree(w.tree, shadow)

    local null = ffi.cast('void *', 0)
    eq(#first + #second, tonumber(w.tree[0].add_len))
    ok(tonumber(w.tree[0].add_cap) >= tonumber(w.tree[0].add_len))
    ok(w.tree[0].add_chunks ~= null)
    ok(w.tree[0].add_tail ~= null)
    ok(w.tree[0].add_chunks ~= w.tree[0].add_tail)

    local boundary = 'BOUNDARY-CROSS'
    local boundary_offset = 6 + #first - #'BOUNDARY-'
    eq(boundary_offset, find_literal(w.tree, 0, #shadow, boundary))

    local buf = ffi.new('char[?]', #boundary)
    eq(#boundary, tonumber(lib.piece_tree_read(w.tree, boundary_offset, buf, #boundary)))
    eq(boundary, ffi.string(buf, #boundary))
  end)

  itp('grows add chunks geometrically after the tail chunk fills', function()
    local w = new_tree('')
    local shadow = ''
    local chunk = string.rep('x', 4096)

    ok(lib.piece_tree_insert(w.tree, #shadow, chunk, #chunk))
    shadow = insert_shadow(shadow, #shadow, chunk)
    ok(lib.piece_tree_check(w.tree))
    eq(shadow, read_tree(w.tree))
    eq(4096, tonumber(w.tree[0].add_cap))

    ok(lib.piece_tree_insert(w.tree, #shadow, chunk, #chunk))
    shadow = insert_shadow(shadow, #shadow, chunk)
    ok(lib.piece_tree_check(w.tree))
    eq(shadow, read_tree(w.tree))
    eq(4096 + 8192, tonumber(w.tree[0].add_cap))

    local double_chunk = string.rep('y', 8192)
    ok(lib.piece_tree_insert(w.tree, #shadow, double_chunk, #double_chunk))
    shadow = insert_shadow(shadow, #shadow, double_chunk)
    ok(lib.piece_tree_check(w.tree))
    eq(shadow, read_tree(w.tree))
    eq(4096 + 8192 + 16384, tonumber(w.tree[0].add_cap))
    eq(#shadow, tonumber(w.tree[0].add_len))
  end)

  itp('finds literals across piece boundaries', function()
    local w = new_tree('abcdij')
    local shadow = 'abcdij'

    ok(lib.piece_tree_insert(w.tree, 4, 'efgh', 4))
    shadow = insert_shadow(shadow, 4, 'efgh')
    check_tree(w.tree, shadow)

    eq(0, tonumber(w.tree[0].reader_count))
    eq(2, find_literal(w.tree, 0, #shadow, 'cdef'))
    eq(0, tonumber(w.tree[0].reader_count))
    eq(6, find_literal(w.tree, 0, #shadow, 'ghij'))
    eq(3, find_literal(w.tree, 0, #shadow, 'defghi'))
    eq(7, find_literal(w.tree, 0, #shadow, 'h'))
    eq(nil, find_literal(w.tree, 0, #shadow, 'xyz'))

    eq(nil, find_literal(w.tree, 0, 3, 'cdef'))
    eq(2, find_literal(w.tree, 2, 6, 'cdef'))
    eq(nil, find_literal(w.tree, #shadow + 1, 0, 'a'))
    eq(nil, find_literal(w.tree, 0, #shadow, ''))

    local repeated = new_tree('ababzz')
    local repeated_shadow = 'ababzz'
    ok(lib.piece_tree_insert(repeated.tree, 4, 'aca', 3))
    repeated_shadow = insert_shadow(repeated_shadow, 4, 'aca')
    check_tree(repeated.tree, repeated_shadow)
    eq(0, find_literal(repeated.tree, 0, #repeated_shadow, 'ababaca'))
  end)

  itp('collects non-overlapping literal matches across pieces', function()
    local w = new_tree('abefabef')
    local shadow = 'abefabef'

    ok(lib.piece_tree_insert(w.tree, 2, 'cd', 2))
    shadow = insert_shadow(shadow, 2, 'cd')
    ok(lib.piece_tree_insert(w.tree, 8, 'cd', 2))
    shadow = insert_shadow(shadow, 8, 'cd')
    check_tree(w.tree, shadow)

    local ok_, matches_ = find_literals(w.tree, 0, #shadow, 'cdef', nil, w.tree)
    ok(ok_)
    eq({ 2, 8 }, matches_)

    ok_, matches_ = find_literals(w.tree, 0, #shadow, 'a')
    ok(ok_)
    eq({ 0, 6 }, matches_)

    ok_, matches_ = find_literals(w.tree, 3, 4, 'defa')
    ok(ok_)
    eq({ 3 }, matches_)

    local repeated = new_tree('aaaa')
    local repeated_shadow = 'aaaa'
    ok(lib.piece_tree_insert(repeated.tree, 2, 'aa', 2))
    repeated_shadow = insert_shadow(repeated_shadow, 2, 'aa')
    check_tree(repeated.tree, repeated_shadow)

    ok_, matches_ = find_literals(repeated.tree, 0, #repeated_shadow, 'aa')
    ok(ok_)
    eq({ 0, 2, 4 }, matches_)

    ok_, matches_ = find_literals(repeated.tree, 0, #repeated_shadow, 'aa', 2)
    eq(false, ok_)
    eq({ 0, 2 }, matches_)

    ok_, matches_ = find_literals(w.tree, 0, #shadow, '')
    eq(false, ok_)
    eq({}, matches_)
  end)

  itp('allows mutation while literal match callbacks consume leased spans', function()
    local w = new_tree('abefabef')
    local shadow = 'abefabef'

    ok(lib.piece_tree_insert(w.tree, 2, 'cd', 2))
    shadow = insert_shadow(shadow, 2, 'cd')
    ok(lib.piece_tree_insert(w.tree, 8, 'cd', 2))
    shadow = insert_shadow(shadow, 8, 'cd')
    check_tree(w.tree, shadow)

    local captured = shadow
    local matches = {}
    local mutated = false
    local cb = ffi.cast('PieceTreeMatchCallback', function(match_offset, _)
      eq(0, tonumber(w.tree[0].reader_count))
      eq(1, tonumber(w.tree[0].span_ref_count))
      if not mutated then
        mutated = true
        ok(lib.piece_tree_insert(w.tree, 0, '>', 1))
      end
      matches[#matches + 1] = tonumber(match_offset)
      return true
    end)
    ok(lib.piece_tree_find_literals(w.tree, 0, #captured, 'cdef', 4, cb, nil))
    cb:free()

    eq({ 2, 8 }, matches)
    shadow = insert_shadow(shadow, 0, '>')
    check_tree(w.tree, shadow)
    eq(0, tonumber(w.tree[0].reader_count))
    eq(0, tonumber(w.tree[0].span_ref_count))
  end)

  itp('uses a borrowed sparse original line index', function()
    local original = 'aa\nbb\ncc\ndd\n'
    local tree = ffi.gc(ffi.new('PieceTree[1]'), function(ptr)
      lib.piece_tree_clear(ptr)
    end)
    local original_buf = cbuf(original)
    local starts = ffi.new('size_t[2]', { 0, 6 })
    lib.piece_tree_init_with_line_index(tree, original_buf, #original, starts, 2, 2, 4)

    check_tree(tree, original)
    ok(lib.piece_tree_insert(tree, 6, 'XX\n', 3))
    check_tree(tree, 'aa\nbb\nXX\ncc\ndd\n')
    ok(lib.piece_tree_delete(tree, 3, 3))
    check_tree(tree, 'aa\nXX\ncc\ndd\n')
  end)

  itp('rejects out-of-range edits without changing content', function()
    local w = new_tree('abc')
    check_tree(w.tree, 'abc')

    eq(false, lib.piece_tree_insert(w.tree, 4, 'x', 1))
    check_tree(w.tree, 'abc')

    eq(false, lib.piece_tree_delete(w.tree, 2, 2))
    check_tree(w.tree, 'abc')

    eq(false, lib.piece_tree_replace(w.tree, 2, 2, 'x', 1))
    check_tree(w.tree, 'abc')
  end)

  itp('matches a byte-string oracle under random edits', function()
    local w = new_tree('root\n')
    local shadow = 'root\n'
    local seed = 0x12345678
    local alphabet = {
      'a',
      'b',
      'c',
      '\n',
      'XYZ',
      '123\n456',
      '',
      'longer text\nwith line',
    }

    local function rand(limit)
      seed = (seed * 1664525 + 1013904223) % 4294967296
      return (seed % limit) + 1
    end

    for _ = 1, 700 do
      local op = rand(3)
      if op == 1 or #shadow == 0 then
        local text = alphabet[rand(#alphabet)]
        local off = rand(#shadow + 1) - 1
        ok(lib.piece_tree_insert(w.tree, off, text, #text))
        shadow = insert_shadow(shadow, off, text)
      elseif op == 2 then
        local off = rand(#shadow) - 1
        local len = rand(#shadow - off) - 1
        ok(lib.piece_tree_delete(w.tree, off, len))
        shadow = delete_shadow(shadow, off, len)
      else
        local off = rand(#shadow) - 1
        local len = rand(#shadow - off) - 1
        local text = alphabet[rand(#alphabet)]
        ok(lib.piece_tree_replace(w.tree, off, len, text, #text))
        shadow = replace_shadow(shadow, off, len, text)
      end
      check_tree(w.tree, shadow)

      for _, pat in ipairs({ 'a', '\n', 'XYZ', '123\n456', 'text\nwith', 'missing' }) do
        eq(find_shadow(shadow, 0, #shadow, pat), find_literal(w.tree, 0, #shadow, pat))
        local expected = find_all_shadow(shadow, 0, #shadow, pat)
        local ok_, matches_ = find_literals(w.tree, 0, #shadow, pat)
        if expected == nil then
          eq(false, ok_)
        else
          ok(ok_)
          eq(expected, matches_)
        end
      end
    end
  end)
end)
