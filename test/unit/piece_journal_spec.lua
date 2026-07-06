local t = require('test.unit.testutil')

local ffi = t.ffi
local eq = t.eq
local ok = t.ok
local itp = t.gen_itp(it)

local lib = t.cimport('./src/nvim/piece_journal.h')

local OK = 0
local INCOMPLETE = 1
local CORRUPT = 2
local INSERT = 1
local DELETE = 2
local REPLACE = 3
local NOEOL = 1

local function encode_header(fields)
  local path = fields.path or ''
  local header = ffi.new('PieceJournalHeader', {
    path = path,
    path_len = #path,
    original_dev = fields.original_dev or 10,
    original_ino = fields.original_ino or 20,
    original_size = fields.original_size or 30,
    original_mtime_sec = fields.original_mtime_sec or 40,
    original_mtime_nsec = fields.original_mtime_nsec or 50,
    text_size = fields.text_size or 30,
    line_count = fields.line_count or 3,
    flags = fields.flags or 0,
  })
  local size = tonumber(lib.piece_journal_header_encoded_size(header))
  ok(size > 0)
  local buf = ffi.new('char[?]', size)
  local written = ffi.new('size_t[1]')
  ok(lib.piece_journal_header_encode(header, buf, size, written))
  eq(size, tonumber(written[0]))
  return buf, size
end

local function encode_record(fields)
  local text = fields.insert_text or ''
  local record = ffi.new('PieceJournalRecord', {
    op = fields.op,
    revision = fields.revision,
    offset = fields.offset or 0,
    delete_len = fields.delete_len or 0,
    insert_len = fields.insert_len or #text,
    insert_text = text,
    text_size_after = fields.text_size_after or 0,
    line_count_after = fields.line_count_after or 1,
    flags_after = fields.flags_after or 0,
  })
  local size = tonumber(lib.piece_journal_record_encoded_size(record))
  ok(size > 0)
  local buf = ffi.new('char[?]', size)
  local written = ffi.new('size_t[1]')
  ok(lib.piece_journal_record_encode(record, buf, size, written))
  eq(size, tonumber(written[0]))
  return buf, size
end

describe('piece journal', function()
  itp('roundtrips file headers', function()
    local buf, size = encode_header({
      path = '/tmp/large.log',
      original_dev = 123,
      original_ino = 456,
      original_size = 789,
      original_mtime_sec = 111,
      original_mtime_nsec = 222,
      text_size = 789,
      line_count = 42,
      flags = NOEOL,
    })

    local decoded = ffi.new('PieceJournalHeader[1]')
    local consumed = ffi.new('size_t[1]')
    eq(OK, tonumber(lib.piece_journal_header_decode(buf, size, decoded, consumed)))
    eq(size, tonumber(consumed[0]))
    eq('/tmp/large.log', ffi.string(decoded[0].path, decoded[0].path_len))
    eq(123, tonumber(decoded[0].original_dev))
    eq(456, tonumber(decoded[0].original_ino))
    eq(789, tonumber(decoded[0].original_size))
    eq(111, tonumber(decoded[0].original_mtime_sec))
    eq(222, tonumber(decoded[0].original_mtime_nsec))
    eq(789, tonumber(decoded[0].text_size))
    eq(42, tonumber(decoded[0].line_count))
    eq(NOEOL, tonumber(decoded[0].flags))
  end)

  itp('roundtrips edit records', function()
    local buf, size = encode_record({
      op = REPLACE,
      revision = 7,
      offset = 1024,
      delete_len = 9,
      insert_text = 'new\ntext',
      text_size_after = 4096,
      line_count_after = 88,
      flags_after = NOEOL,
    })

    local decoded = ffi.new('PieceJournalRecord[1]')
    local consumed = ffi.new('size_t[1]')
    eq(OK, tonumber(lib.piece_journal_record_decode(buf, size, decoded, consumed)))
    eq(size, tonumber(consumed[0]))
    eq(REPLACE, tonumber(decoded[0].op))
    eq(7, tonumber(decoded[0].revision))
    eq(1024, tonumber(decoded[0].offset))
    eq(9, tonumber(decoded[0].delete_len))
    eq(8, tonumber(decoded[0].insert_len))
    eq('new\ntext', ffi.string(decoded[0].insert_text, decoded[0].insert_len))
    eq(4096, tonumber(decoded[0].text_size_after))
    eq(88, tonumber(decoded[0].line_count_after))
    eq(NOEOL, tonumber(decoded[0].flags_after))
  end)

  itp('decodes appended records by consumed size', function()
    local first, first_size = encode_record({
      op = INSERT,
      revision = 1,
      offset = 0,
      insert_text = 'hello\n',
      text_size_after = 12,
      line_count_after = 2,
    })
    local second, second_size = encode_record({
      op = DELETE,
      revision = 2,
      offset = 5,
      delete_len = 1,
      text_size_after = 11,
      line_count_after = 1,
    })
    local total = first_size + second_size
    local stream = ffi.new('char[?]', total)
    ffi.copy(stream, first, first_size)
    ffi.copy(stream + first_size, second, second_size)

    local decoded = ffi.new('PieceJournalRecord[1]')
    local consumed = ffi.new('size_t[1]')
    eq(OK, tonumber(lib.piece_journal_record_decode(stream, total, decoded, consumed)))
    eq(first_size, tonumber(consumed[0]))
    eq(INSERT, tonumber(decoded[0].op))
    eq('hello\n', ffi.string(decoded[0].insert_text, decoded[0].insert_len))

    eq(
      OK,
      tonumber(
        lib.piece_journal_record_decode(stream + consumed[0], total - consumed[0], decoded, consumed)
      )
    )
    eq(second_size, tonumber(consumed[0]))
    eq(DELETE, tonumber(decoded[0].op))
    eq(1, tonumber(decoded[0].delete_len))
  end)

  itp('roundtrips replacements with empty inserted text', function()
    local buf, size = encode_record({
      op = REPLACE,
      revision = 3,
      offset = 12,
      delete_len = 5,
      insert_len = 0,
      text_size_after = 20,
      line_count_after = 2,
    })

    local decoded = ffi.new('PieceJournalRecord[1]')
    local consumed = ffi.new('size_t[1]')
    eq(OK, tonumber(lib.piece_journal_record_decode(buf, size, decoded, consumed)))
    eq(size, tonumber(consumed[0]))
    eq(REPLACE, tonumber(decoded[0].op))
    eq(0, tonumber(decoded[0].insert_len))
    eq(nil, decoded[0].insert_text)
  end)

  itp('treats torn final writes as incomplete', function()
    local buf, size = encode_record({
      op = INSERT,
      revision = 1,
      offset = 0,
      insert_text = 'partial',
      text_size_after = 7,
      line_count_after = 1,
    })

    local decoded = ffi.new('PieceJournalRecord[1]')
    eq(INCOMPLETE, tonumber(lib.piece_journal_record_decode(buf, size - 1, decoded, nil)))
  end)

  itp('rejects checksum corruption', function()
    local buf, size = encode_record({
      op = INSERT,
      revision = 1,
      offset = 0,
      insert_text = 'abc',
      text_size_after = 3,
      line_count_after = 1,
    })
    buf[82] = string.byte('z')

    local decoded = ffi.new('PieceJournalRecord[1]')
    eq(CORRUPT, tonumber(lib.piece_journal_record_decode(buf, size, decoded, nil)))
  end)

  itp('rejects invalid operation shapes before encoding', function()
    local invalid = ffi.new('PieceJournalRecord', {
      op = DELETE,
      revision = 1,
      offset = 0,
      delete_len = 1,
      insert_len = 1,
      insert_text = 'x',
      text_size_after = 1,
      line_count_after = 1,
    })
    eq(0, tonumber(lib.piece_journal_record_encoded_size(invalid)))
  end)
end)
