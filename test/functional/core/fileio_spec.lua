local t = require('test.testutil')
local n = require('test.functional.testnvim')()
local Screen = require('test.functional.ui.screen')
local uv = vim.uv

local assert_log = t.assert_log
local assert_nolog = t.assert_nolog
local pcall_err = t.pcall_err
local clear = n.clear
local command = n.command
local eq = t.eq
local neq = t.neq
local ok = t.ok
local feed = n.feed
local exec_capture = n.exec_capture
local fn = n.fn
local nvim_prog = n.nvim_prog
local poke_eventloop = n.poke_eventloop
local request = n.request
local retry = t.retry
local rmdir = n.rmdir
local matches = t.matches
local api = n.api
local mkdir = t.mkdir
local sleep = vim.uv.sleep
local read_file = t.read_file
local trim = vim.trim
local currentdir = n.fn.getcwd
local assert_alive = n.assert_alive
local check_close = n.check_close
local expect_exit = n.expect_exit
local write_file = t.write_file
local feed_command = n.feed_command
local skip = t.skip
local is_os = t.is_os
local set_session = n.set_session

describe('fileio', function()
  before_each(function() end)
  after_each(function()
    check_close()
    os.remove('Xtest_startup_shada')
    os.remove('Xtest_startup_file1')
    os.remove('Xtest_startup_file1~')
    os.remove('Xtest_startup_file2')
    os.remove('Xtest_startup_file2~')
    os.remove('Xtest_mmap_readfile')
    os.remove('Xtest_mmap_readfile~')
    os.remove('Xtest_mmap_saved_journal')
    os.remove('Xtest_mmap_noeol')
    os.remove('Xtest_mmap_empty_delete_written')
    os.remove('Xtest_mmap_noeol_written')
    os.remove('Xtest_mmap_range_noeol_written')
    os.remove('Xtest_mmap_range_written')
    os.remove('Xtest_mmap_written')
    os.remove('Xtest_тест.md')
    os.remove('Xtest-u8-int-max')
    os.remove('Xtest-overwrite-forced')
    rmdir('Xtest_startup_swapdir')
    rmdir('Xtest_backupdir')
    rmdir('Xtest_backupdir with spaces')
  end)

  local args = { '--clean', '--cmd', 'set nofsync directory=Xtest_startup_swapdir' }
  --- Starts a new nvim session and returns an attached screen.
  local function startup()
    local argv = vim.iter({ args, '--embed' }):flatten():totable()
    local screen_nvim = n.new_session(false, { args = argv, merge = false })
    set_session(screen_nvim)
    local screen = Screen.new(70, 10)
    screen:set_default_attr_ids({
      [1] = { foreground = Screen.colors.NvimDarkGrey4 },
      [2] = { background = Screen.colors.NvimDarkGrey1, foreground = Screen.colors.NvimLightGrey3 },
      [3] = { foreground = Screen.colors.NvimLightCyan },
    })
    return screen
  end

  it('opens large UTF-8 files with mmap and supports edits', function()
    local lines = {}
    for i = 1, 40000 do
      lines[i] = ('line%d ascii text for mmap smoke'):format(i)
    end
    lines[1000] = ''
    lines[1001] = 'after empty mmap line'

    local function line2byte(lnum)
      local byte = 1
      for i = 1, lnum - 1 do
        byte = byte + #lines[i] + 1
      end
      return byte
    end

    local function replace_slice(line, start_col, end_col, replacement)
      return line:sub(1, start_col) .. replacement .. line:sub(end_col + 1)
    end

    local function text_size()
      return #table.concat(lines, '\n') + 1
    end

    local function expect_mmap_piece(min_revision, text_size)
      local stats = api.nvim__buf_stats(0)
      eq(true, stats.mmap_active)
      eq(1, stats.mmap_storage_refs)
      eq(1, stats.mmap_line_index_refs)
      eq(true, stats.mmap_piece_tree)
      ok(stats.mmap_piece_revision >= min_revision)
      ok(stats.mmap_piece_write_fast_count >= 0)
      ok(stats.mmap_piece_write_clone_range_count >= 0)
      ok(stats.mmap_piece_write_copy_range_count >= 0)
      ok(stats.mmap_piece_compact_count >= 0)
      ok(stats.mmap_piece_node_capacity >= stats.mmap_piece_nodes)
      ok(stats.mmap_piece_node_capacity
         >= stats.mmap_piece_nodes + stats.mmap_piece_free_nodes
         + stats.mmap_piece_retired_nodes)
      eq(0, stats.mmap_piece_retired_nodes)
      eq(false, stats.mmap_piece_reclaim_scheduled)
      eq(false, stats.mmap_piece_gc_worker_active)
      if text_size == nil or text_size > 0 then
        ok(stats.mmap_piece_nodes > 0)
      end
      if min_revision > 0 then
        ok(stats.mmap_piece_add_cap >= stats.mmap_piece_add_len)
        ok(stats.mmap_piece_add_len > 0)
      end
      if text_size ~= nil then
        eq(text_size, stats.mmap_text_size)
      end
      return stats
    end

    write_file('Xtest_mmap_readfile', table.concat(lines, '\n') .. '\n', false)
    write_file('Xtest_mmap_noeol', table.concat(lines, '\n'), false)

    clear({ args = { '-n', '-u', 'NONE', '-i', 'NONE' } })
    command('edit Xtest_mmap_readfile')
    expect_mmap_piece(0)
    eq(40000, fn.line('$'))
    eq(lines[1], fn.getline(1))
    eq(lines[40000], fn.getline(40000))
    eq(#lines[1] + 2, fn.line2byte(2))
    eq('', fn.getline(1000))
    eq(line2byte(1001), fn.line2byte(1001))
    eq(1001, fn.byte2line(fn.line2byte(1001)))
    eq(40000, fn.byte2line(fn.line2byte(40000)))

    command("call setline(2, 'changed')")
    lines[2] = 'changed'
    expect_mmap_piece(1)
    eq('changed', fn.getline(2))
    eq(40000, fn.line('$'))
    eq(line2byte(3), fn.line2byte(3))
    eq(3, fn.byte2line(fn.line2byte(3)))

    command('call cursor(2, 1)')
    command('normal! rZ')
    lines[2] = 'Zhanged'
    expect_mmap_piece(1)
    eq('Zhanged', fn.getline(2))
    eq(line2byte(3), fn.line2byte(3))

    command("call append(2, 'inserted')")
    table.insert(lines, 3, 'inserted')
    expect_mmap_piece(1)
    eq(40001, fn.line('$'))
    eq('inserted', fn.getline(3))
    eq(line2byte(4), fn.line2byte(4))

    command('3delete _')
    table.remove(lines, 3)
    expect_mmap_piece(1)
    eq(40000, fn.line('$'))
    eq(line2byte(3), fn.line2byte(3))

    api.nvim_buf_set_lines(0, 3, 3, false, { 'api inserted' })
    table.insert(lines, 4, 'api inserted')
    expect_mmap_piece(1)
    eq(40001, fn.line('$'))
    eq('api inserted', fn.getline(4))
    eq(line2byte(5), fn.line2byte(5))

    api.nvim_buf_set_lines(0, 3, 4, false, {})
    table.remove(lines, 4)
    expect_mmap_piece(1)
    eq(40000, fn.line('$'))
    eq(line2byte(4), fn.line2byte(4))

    local before_compact = api.nvim__buf_stats(0)
    ok(before_compact.mmap_piece_add_len > 0)
    eq(true, api.nvim__buf_compact_mmap_piece_tree(0))
    local compact_stats = api.nvim__buf_stats(0)
    eq(before_compact.mmap_piece_compact_count + 1, compact_stats.mmap_piece_compact_count)
    eq(text_size(), compact_stats.mmap_text_size)
    eq(lines[1], fn.getline(1))
    eq(lines[40000], fn.getline(40000))
    poke_eventloop()
    retry(nil, 1000, function()
      local stats = api.nvim__buf_stats(0)
      eq(1, stats.mmap_storage_refs)
      eq(1, stats.mmap_line_index_refs)
      eq(false, stats.mmap_piece_reclaim_scheduled)
      eq(false, stats.mmap_piece_gc_worker_active)
    end)
    expect_mmap_piece(1, text_size())

    local auto_compact_before = expect_mmap_piece(1, text_size())
    local dead_payload = string.rep('q', 5000)
    api.nvim_buf_set_lines(0, 10, 10, false, { dead_payload })
    table.insert(lines, 11, dead_payload)
    expect_mmap_piece(1, text_size())
    api.nvim_buf_set_lines(0, 10, 11, false, {})
    table.remove(lines, 11)
    retry(nil, 1000, function()
      poke_eventloop()
      local stats = api.nvim__buf_stats(0)
      eq(auto_compact_before.mmap_piece_compact_count + 1, stats.mmap_piece_compact_count)
      eq(1, stats.mmap_storage_refs)
      eq(1, stats.mmap_line_index_refs)
      eq(false, stats.mmap_piece_reclaim_scheduled)
      eq(false, stats.mmap_piece_gc_worker_active)
      eq(text_size(), stats.mmap_text_size)
    end)
    expect_mmap_piece(1, text_size())

    api.nvim_buf_set_text(0, 4, 4, 4, 9, { 'TEXT' })
    lines[5] = replace_slice(lines[5], 4, 9, 'TEXT')
    expect_mmap_piece(1)
    eq(lines[5], fn.getline(5))
    eq(line2byte(6), fn.line2byte(6))

    api.nvim_buf_set_text(0, 4, 4, 4, 4, { ' split-left', 'split-right ' })
    local split_suffix = lines[5]:sub(5)
    lines[5] = lines[5]:sub(1, 4) .. ' split-left'
    table.insert(lines, 6, 'split-right ' .. split_suffix)
    expect_mmap_piece(1)
    eq(40001, fn.line('$'))
    eq(lines[5], fn.getline(5))
    eq(lines[6], fn.getline(6))
    eq(line2byte(7), fn.line2byte(7))

    api.nvim_buf_set_text(0, 4, 5, 5, 6, { 'JOIN' })
    lines[5] = lines[5]:sub(1, 5) .. 'JOIN' .. lines[6]:sub(7)
    table.remove(lines, 6)
    expect_mmap_piece(1)
    eq(40000, fn.line('$'))
    eq(lines[5], fn.getline(5))
    eq(line2byte(6), fn.line2byte(6))

    command("call append('$', 'tail inserted')")
    table.insert(lines, 'tail inserted')
    local tail_stats = expect_mmap_piece(1)
    local tail_nodes = tail_stats.mmap_piece_nodes
    local tail_free_nodes = tail_stats.mmap_piece_free_nodes
    eq(40001, fn.line('$'))
    eq('tail inserted', fn.getline(40001))
    eq(line2byte(40001), fn.line2byte(40001))

    for i = 1, 5 do
      local text = ('tail append run %d'):format(i)
      command("call append('$', '" .. text .. "')")
      table.insert(lines, text)
      tail_stats = expect_mmap_piece(1)
      eq(tail_nodes, tail_stats.mmap_piece_nodes)
      eq(tail_free_nodes, tail_stats.mmap_piece_free_nodes)
      eq(#lines, fn.line('$'))
      eq(text, fn.getline(#lines))
      eq(line2byte(#lines), fn.line2byte(#lines))
    end

    for _ = 1, 6 do
      command('$delete _')
      table.remove(lines)
      expect_mmap_piece(1)
    end
    eq(40000, fn.line('$'))
    eq(lines[40000], fn.getline(40000))

    local write_stats = expect_mmap_piece(1)
    command('write')
    local written_stats = expect_mmap_piece(1)
    eq(write_stats.mmap_piece_write_fast_count + 1,
      written_stats.mmap_piece_write_fast_count)
    matches('^line1 ascii text for mmap smoke\nZhanged\nline3 ascii text for mmap smoke',
      read_file('Xtest_mmap_readfile'))

    write_stats = written_stats
    command('write Xtest_mmap_written')
    written_stats = expect_mmap_piece(1)
    eq(write_stats.mmap_piece_write_fast_count + 1,
      written_stats.mmap_piece_write_fast_count)
    matches('^line1 ascii text for mmap smoke\nZhanged\nline3 ascii text for mmap smoke',
      read_file('Xtest_mmap_written'))

    write_stats = written_stats
    command('3,5write Xtest_mmap_range_written')
    written_stats = expect_mmap_piece(1)
    eq(write_stats.mmap_piece_write_fast_count + 1,
      written_stats.mmap_piece_write_fast_count)
    eq(table.concat({ lines[3], lines[4], lines[5] }, '\n') .. '\n',
      read_file('Xtest_mmap_range_written'))

    command("call setline(3, 'nowritebackup mmap write')")
    lines[3] = 'nowritebackup mmap write'
    command('set nowritebackup nobackup backupcopy=yes')
    write_stats = expect_mmap_piece(1)
    command('write')
    written_stats = expect_mmap_piece(1)
    eq(write_stats.mmap_piece_write_fast_count + 1,
      written_stats.mmap_piece_write_fast_count)
    eq(nil, uv.fs_stat('Xtest_mmap_readfile~'))
    matches('^line1 ascii text for mmap smoke\nZhanged\nnowritebackup mmap write',
      read_file('Xtest_mmap_readfile'))
    command('set writebackup backupcopy& backup&')

    mkdir('Xtest_startup_swapdir')
    command('set undodir=Xtest_startup_swapdir// undofile')
    command("call setline(4, 'undofile mmap write')")
    lines[4] = 'undofile mmap write'
    write_stats = expect_mmap_piece(1)
    command('write')
    written_stats = expect_mmap_piece(1)
    eq(write_stats.mmap_piece_write_fast_count + 1,
      written_stats.mmap_piece_write_fast_count)
    matches('^line1 ascii text for mmap smoke\nZhanged\nnowritebackup mmap write\n'
      .. 'undofile mmap write', read_file('Xtest_mmap_readfile'))

    local undo_file = fn.undofile(fn.expand('%:p'))
    neq('', undo_file)
    neq(nil, uv.fs_stat(undo_file))
    command('bwipe!')
    command('set undodir=Xtest_startup_swapdir// undofile')
    command('edit Xtest_mmap_readfile')
    command('rundo ' .. fn.fnameescape(undo_file))
    command('earlier 1f')
    eq('line4 ascii text for mmap smoke', fn.getline(4))
    command('later 1f')
    eq('undofile mmap write', fn.getline(4))
    command('set noundofile undodir&')

    command('edit! Xtest_mmap_noeol')
    expect_mmap_piece(0)
    eq(40000, fn.line('$'))
    eq(0, fn.eval('&endofline'))
    eq(lines[40000], fn.getline(40000))
    eq(40000, fn.byte2line(fn.line2byte(40000)))

    command("call append('$', 'tail without eol')")
    expect_mmap_piece(1)
    eq(40001, fn.line('$'))
    eq('tail without eol', fn.getline(40001))
    eq(0, fn.eval('&endofline'))
    eq(40001, fn.byte2line(fn.line2byte(40001)))

    command('setlocal nofixeol')
    write_stats = expect_mmap_piece(1)
    command('write Xtest_mmap_noeol_written')
    written_stats = expect_mmap_piece(1)
    eq(write_stats.mmap_piece_write_fast_count + 1,
      written_stats.mmap_piece_write_fast_count)
    local nofixeol_written = read_file('Xtest_mmap_noeol_written')
    matches('\ntail without eol$', nofixeol_written)
    eq(nil, nofixeol_written:match('\n$'))

    write_stats = written_stats
    command('$write Xtest_mmap_range_noeol_written')
    written_stats = expect_mmap_piece(1)
    eq(write_stats.mmap_piece_write_fast_count + 1,
      written_stats.mmap_piece_write_fast_count)
    eq('tail without eol', read_file('Xtest_mmap_range_noeol_written'))
    command('setlocal fixeol')

    command('%delete _')
    expect_mmap_piece(1, 0)
    eq(1, fn.line('$'))
    eq('', fn.getline(1))

    command("call setline(1, 'after empty mmap delete')")
    expect_mmap_piece(1)
    eq(1, fn.line('$'))
    eq('after empty mmap delete', fn.getline(1))
    write_stats = expect_mmap_piece(1)
    command('write Xtest_mmap_empty_delete_written')
    written_stats = expect_mmap_piece(1)
    eq(write_stats.mmap_piece_write_fast_count + 1,
      written_stats.mmap_piece_write_fast_count)
    eq('after empty mmap delete\n', read_file('Xtest_mmap_empty_delete_written'))
  end)

  it('keeps mmap piece tree active across API text boundary edits', function()
    local lines = {}
    for i = 1, 45000 do
      lines[i] = ('row%05d alpha beta gamma'):format(i)
    end
    lines[2] = 'abcde'
    lines[3] = ''
    lines[4] = 'vwxyz'
    lines[22000] = 'middle-left|middle-right'

    local function text_size()
      local size = 0
      for i = 1, #lines do
        size = size + #lines[i] + 1
      end
      return size
    end

    local function line2byte(lnum)
      local byte = 1
      for i = 1, lnum - 1 do
        byte = byte + #lines[i] + 1
      end
      return byte
    end

    local function slice_lines(start_lnum, end_lnum)
      local out = {}
      for i = start_lnum, end_lnum do
        out[#out + 1] = lines[i]
      end
      return out
    end

    local function set_text_shadow(start_row, start_col, end_row, end_col, replacement)
      local start_lnum = start_row + 1
      local end_lnum = end_row + 1
      local prefix = lines[start_lnum]:sub(1, start_col)
      local suffix = lines[end_lnum]:sub(end_col + 1)
      local new_lines = {}

      if #replacement == 1 then
        new_lines[1] = prefix .. replacement[1] .. suffix
      else
        new_lines[1] = prefix .. replacement[1]
        for i = 2, #replacement - 1 do
          new_lines[#new_lines + 1] = replacement[i]
        end
        new_lines[#new_lines + 1] = replacement[#replacement] .. suffix
      end

      for _ = start_lnum, end_lnum do
        table.remove(lines, start_lnum)
      end
      for i = #new_lines, 1, -1 do
        table.insert(lines, start_lnum, new_lines[i])
      end
    end

    local function set_lines_shadow(start_row, end_row, replacement)
      local start_lnum = start_row + 1
      for _ = start_row + 1, end_row do
        table.remove(lines, start_lnum)
      end
      for i = #replacement, 1, -1 do
        table.insert(lines, start_lnum, replacement[i])
      end
    end

    local function expect_mmap_shadow(min_revision)
      local stats = api.nvim__buf_stats(0)
      eq(true, stats.mmap_active)
      eq(1, stats.mmap_storage_refs)
      eq(1, stats.mmap_line_index_refs)
      eq(true, stats.mmap_piece_tree)
      ok(stats.mmap_piece_revision >= min_revision)
      ok(stats.mmap_piece_write_fast_count >= 0)
      ok(stats.mmap_piece_write_clone_range_count >= 0)
      ok(stats.mmap_piece_write_copy_range_count >= 0)
      ok(stats.mmap_piece_compact_count >= 0)
      eq(false, stats.mmap_piece_reclaim_scheduled)
      eq(false, stats.mmap_piece_gc_worker_active)
      eq(text_size(), stats.mmap_text_size)
      eq(#lines, fn.line('$'))
      eq(slice_lines(1, 8), api.nvim_buf_get_lines(0, 0, 8, true))
      eq(slice_lines(21998, 22002), api.nvim_buf_get_lines(0, 21997, 22002, true))

      for _, lnum in ipairs({ 1, 2, 3, 4, 5, 8, 21998, 22000, 22002, #lines }) do
        eq(lines[lnum], fn.getline(lnum))
        eq(line2byte(lnum), fn.line2byte(lnum))
        eq(lnum, fn.byte2line(fn.line2byte(lnum)))
      end

      return stats
    end

    local function apply_set_text(start_row, start_col, end_row, end_col, replacement)
      api.nvim_buf_set_text(0, start_row, start_col, end_row, end_col, replacement)
      set_text_shadow(start_row, start_col, end_row, end_col, replacement)
      expect_mmap_shadow(1)
    end

    local function apply_set_lines(start_row, end_row, replacement)
      api.nvim_buf_set_lines(0, start_row, end_row, false, replacement)
      set_lines_shadow(start_row, end_row, replacement)
      expect_mmap_shadow(1)
    end

    write_file('Xtest_mmap_readfile', table.concat(lines, '\n') .. '\n', false)

    clear({ args = { '-n', '-u', 'NONE', '-i', 'NONE' } })
    command('edit Xtest_mmap_readfile')
    expect_mmap_shadow(0)

    apply_set_text(0, 0, 0, 0, { 'HEAD-' })
    apply_set_text(0, 0, 0, 0, { 'new-first', '' })
    apply_set_text(1, #lines[2], 1, #lines[2], { '', 'after-second' })
    apply_set_text(2, #lines[3], 3, 0, { '' })
    apply_set_text(4, 2, 6, 3, { 'left', 'inside', 'right' })
    apply_set_text(21999, 6, 21999, 17, { 'CENTER' })
    apply_set_lines(1, 3, { 'line-boundary-A', '', 'line-boundary-B' })
    apply_set_lines(21998, 22001, { 'bulk-middle' })

    local write_stats = expect_mmap_shadow(1)
    command('write Xtest_mmap_written')
    local written_stats = expect_mmap_shadow(1)
    eq(write_stats.mmap_piece_write_fast_count + 1,
      written_stats.mmap_piece_write_fast_count)
    eq(table.concat(lines, '\n') .. '\n', read_file('Xtest_mmap_written'))
  end)

  it('keeps mmap piece tree active for UTF-8 multiline regex search', function()
    local lines = {}
    for i = 1, 42000 do
      lines[i] = ('regex mmap row %05d plain ascii'):format(i)
    end

    local function text_size()
      return #table.concat(lines, '\n') + 1
    end

    local function expect_mmap_regex(min_revision)
      local stats = api.nvim__buf_stats(0)
      eq(true, stats.mmap_active)
      eq(true, stats.mmap_piece_tree)
      ok(stats.mmap_piece_revision >= min_revision)
      eq(text_size(), stats.mmap_text_size)
      eq(0, stats.virt_blocks)
      return stats
    end

    write_file('Xtest_mmap_readfile', table.concat(lines, '\n') .. '\n', false)

    clear({ args = { '-n', '-u', 'NONE', '-i', 'NONE' } })
    command('edit Xtest_mmap_readfile')
    expect_mmap_regex(0)

    api.nvim_buf_set_lines(0, 20999, 21002, false, {
      'αβγ piece-start',
      'piece-tail Ω regex',
      'piece suffix line',
    })
    lines[21000] = 'αβγ piece-start'
    lines[21001] = 'piece-tail Ω regex'
    lines[21002] = 'piece suffix line'

    local edit_stats = expect_mmap_regex(1)
    local pattern = [[αβγ piece-start\_s\+piece-tail Ω regex]]
    for _, engine in ipairs({ 1, 2 }) do
      command('set regexpengine=' .. engine)
      command('normal! gg0')
      eq(21000, fn.search(pattern, 'W'))
      local forward_stats = expect_mmap_regex(1)
      eq(edit_stats.mmap_piece_revision, forward_stats.mmap_piece_revision)

      command('normal! G$')
      eq(21000, fn.search(pattern, 'bW'))
      local backward_stats = expect_mmap_regex(1)
      eq(edit_stats.mmap_piece_revision, backward_stats.mmap_piece_revision)
    end
    command('set regexpengine&')
  end)

  it('uses mmap literal candidates for forward and backward regex search', function()
    local lines = {}
    for i = 1, 42000 do
      lines[i] = ('regex prefilter row %05d plain ascii'):format(i)
    end

    write_file('Xtest_mmap_readfile', table.concat(lines, '\n') .. '\n', false)

    clear({ args = { '-n', '-u', 'NONE', '-i', 'NONE' } })
    command('edit Xtest_mmap_readfile')
    local stats = api.nvim__buf_stats(0)
    eq(true, stats.mmap_active)
    eq(true, stats.mmap_piece_tree)

    api.nvim_buf_set_lines(0, 40999, 41000, false, {
      'regex prefilter-target-12345 suffix',
    })
    stats = api.nvim__buf_stats(0)
    eq(true, stats.mmap_active)
    eq(true, stats.mmap_piece_tree)
    local prefilter_count = stats.mmap_search_prefilter_count
    local prefilter_miss_count = stats.mmap_search_prefilter_miss_count

    command('set regexpengine=1')
    command('normal! gg0')
    eq(0, fn.search([[.*prefilter-target-\d\+]], 'W', 100))
    command('set regexpengine&')

    stats = api.nvim__buf_stats(0)
    eq(true, stats.mmap_active)
    eq(true, stats.mmap_piece_tree)
    eq(0, stats.virt_blocks)
    eq(prefilter_count, stats.mmap_search_prefilter_count)
    eq(prefilter_miss_count + 1, stats.mmap_search_prefilter_miss_count)
    prefilter_miss_count = stats.mmap_search_prefilter_miss_count

    command('set regexpengine=1')
    command([[silent! 1,100s/.*prefilter-target-\d\+/range miss/]])
    command('set regexpengine&')
    eq('regex prefilter-target-12345 suffix', fn.getline(41000))

    stats = api.nvim__buf_stats(0)
    eq(true, stats.mmap_active)
    eq(true, stats.mmap_piece_tree)
    eq(0, stats.virt_blocks)
    eq(prefilter_count, stats.mmap_search_prefilter_count)
    eq(prefilter_miss_count + 1, stats.mmap_search_prefilter_miss_count)
    prefilter_miss_count = stats.mmap_search_prefilter_miss_count

    command('set regexpengine=1')
    command('normal! gg0')
    eq(41000, fn.search([[.*prefilter-target-\d\+]], 'W'))
    command('set regexpengine&')

    stats = api.nvim__buf_stats(0)
    eq(true, stats.mmap_active)
    eq(true, stats.mmap_piece_tree)
    eq(0, stats.virt_blocks)
    ok(stats.mmap_search_prefilter_count > prefilter_count)

    api.nvim_buf_set_lines(0, 39899, 39900, false, {
      'substitute mmap-subregex-12345 suffix',
    })
    stats = api.nvim__buf_stats(0)
    prefilter_count = stats.mmap_search_prefilter_count
    prefilter_miss_count = stats.mmap_search_prefilter_miss_count

    command('set regexpengine=1')
    command([[%s/.*mmap-subregex-\d\+/substitution hit/]])
    command('set regexpengine&')
    eq('substitution hit suffix', fn.getline(39900))

    stats = api.nvim__buf_stats(0)
    eq(true, stats.mmap_active)
    eq(true, stats.mmap_piece_tree)
    eq(0, stats.virt_blocks)
    ok(stats.mmap_search_prefilter_count > prefilter_count)
    eq(prefilter_miss_count + 1, stats.mmap_search_prefilter_miss_count)

    prefilter_count = stats.mmap_search_prefilter_count
    command('set regexpengine=1')
    command('normal! G$')
    eq(41000, fn.search([[.*prefilter-target-\d\+]], 'bW'))
    command('set regexpengine&')

    stats = api.nvim__buf_stats(0)
    eq(true, stats.mmap_active)
    eq(true, stats.mmap_piece_tree)
    eq(0, stats.virt_blocks)
    ok(stats.mmap_search_prefilter_count > prefilter_count)
  end)

  it('keeps mmap piece tree active for literal substitute fast path', function()
    local lines = {}
    local payload = string.rep('x', 900)
    for i = 1, 1600 do
      lines[i] = ('zz row %05d a a %s'):format(i, payload)
    end

    write_file('Xtest_mmap_readfile', table.concat(lines, '\n') .. '\n', false)

    clear({ args = { '-n', '-u', 'NONE', '-i', 'NONE' } })
    command('edit Xtest_mmap_readfile')
    local stats = api.nvim__buf_stats(0)
    eq(true, stats.mmap_active)
    eq(true, stats.mmap_piece_tree)
    eq(0, stats.virt_blocks)
    local literal_count = stats.mmap_substitute_literal_count

    command([[%s/a/b/g]])
    eq((lines[1]:gsub('a', 'b')), fn.getline(1))
    eq((lines[800]:gsub('a', 'b')), fn.getline(800))
    eq((lines[1600]:gsub('a', 'b')), fn.getline(1600))

    stats = api.nvim__buf_stats(0)
    eq(true, stats.mmap_active)
    eq(true, stats.mmap_piece_tree)
    eq(0, stats.virt_blocks)
    ok(stats.mmap_piece_revision > 0)
    eq(literal_count + 1, stats.mmap_substitute_literal_count)
  end)

  it('skips nonmatching mmap lines for sparse literal substitute', function()
    local lines = {}
    local payload = string.rep('x', 900)
    for i = 1, 1600 do
      lines[i] = ('sparse row %05d %s'):format(i, payload)
    end
    lines[10] = 'sparse needle one ' .. payload
    lines[800] = 'sparse needle two ' .. payload
    lines[1599] = 'sparse needle three ' .. payload

    write_file('Xtest_mmap_readfile', table.concat(lines, '\n') .. '\n', false)

    clear({ args = { '-n', '-u', 'NONE', '-i', 'NONE' } })
    command('edit Xtest_mmap_readfile')
    local stats = api.nvim__buf_stats(0)
    eq(true, stats.mmap_active)
    eq(true, stats.mmap_piece_tree)
    eq(0, stats.virt_blocks)
    local literal_count = stats.mmap_substitute_literal_count
    local literal_line_count = stats.mmap_substitute_literal_line_count

    command([[silent! 1,9s/needle/pin/g]])
    eq('sparse needle one ' .. payload, fn.getline(10))
    stats = api.nvim__buf_stats(0)
    eq(literal_count + 1, stats.mmap_substitute_literal_count)
    eq(literal_line_count, stats.mmap_substitute_literal_line_count)

    command([[%s/needle/pin/g]])
    eq('sparse pin one ' .. payload, fn.getline(10))
    eq('sparse pin two ' .. payload, fn.getline(800))
    eq('sparse pin three ' .. payload, fn.getline(1599))
    eq(lines[1], fn.getline(1))
    eq(lines[1600], fn.getline(1600))

    stats = api.nvim__buf_stats(0)
    eq(true, stats.mmap_active)
    eq(true, stats.mmap_piece_tree)
    eq(0, stats.virt_blocks)
    eq(literal_count + 2, stats.mmap_substitute_literal_count)
    eq(literal_line_count + 3, stats.mmap_substitute_literal_line_count)
  end)

  it('keeps mmap piece tree active for :global mark execution', function()
    local lines = {}
    for i = 1, 42000 do
      lines[i] = ('global mmap row %05d plain ascii'):format(i)
    end
    lines[200] = 'global-change alpha'
    lines[202] = 'global-change beta'
    lines[300] = 'global-insert anchor'
    lines[1000] = 'global-delete one'
    lines[1001] = 'global-delete two'
    lines[39950] = 'global-regex-12345 target'
    lines[41000] = 'global-delete tail'

    write_file('Xtest_mmap_readfile', table.concat(lines, '\n') .. '\n', false)

    clear({ args = { '-n', '-u', 'NONE', '-i', 'NONE' } })
    command('edit Xtest_mmap_readfile')
    local stats = api.nvim__buf_stats(0)
    eq(true, stats.mmap_active)
    eq(true, stats.mmap_piece_tree)
    eq(0, stats.virt_blocks)

    command('g/global-change/s/global-change/global-changed/')
    eq('global-changed alpha', fn.getline(200))
    eq('global-changed beta', fn.getline(202))

    stats = api.nvim__buf_stats(0)
    local prefilter_count = stats.mmap_search_prefilter_count
    local prefilter_miss_count = stats.mmap_search_prefilter_miss_count
    command('set regexpengine=1')
    command([[silent! 1,100g/.*global-regex-\d\+/s/target/outside/]])
    command('set regexpengine&')
    eq('global-regex-12345 target', fn.getline(39950))

    stats = api.nvim__buf_stats(0)
    eq(true, stats.mmap_active)
    eq(true, stats.mmap_piece_tree)
    eq(0, stats.virt_blocks)
    eq(prefilter_count, stats.mmap_search_prefilter_count)
    eq(prefilter_miss_count + 1, stats.mmap_search_prefilter_miss_count)
    prefilter_miss_count = stats.mmap_search_prefilter_miss_count

    command('set regexpengine=1')
    command([[g/.*global-regex-\d\+/s/target/done/]])
    command('set regexpengine&')
    eq('global-regex-12345 done', fn.getline(39950))

    stats = api.nvim__buf_stats(0)
    eq(true, stats.mmap_active)
    eq(true, stats.mmap_piece_tree)
    eq(0, stats.virt_blocks)
    ok(stats.mmap_search_prefilter_count > prefilter_count)
    eq(prefilter_miss_count + 1, stats.mmap_search_prefilter_miss_count)

    command([[call setreg('a', 'inserted-by-global', 'l')]])
    command('g/global-insert/put a')
    eq('inserted-by-global', fn.getline(301))

    command('g/global-delete/d')
    eq(41998, fn.line('$'))
    command('normal! gg0')
    eq(0, fn.search('global-delete', 'nw'))

    stats = api.nvim__buf_stats(0)
    eq(true, stats.mmap_active)
    eq(true, stats.mmap_piece_tree)
    eq(0, stats.virt_blocks)
    ok(stats.mmap_piece_revision >= 6)
  end)

  it('keeps mmap piece tree active for same-file copy-backup writes', function()
    local lines = {}
    for i = 1, 40000 do
      lines[i] = ('copy-backup mmap line %05d'):format(i)
    end

    write_file('Xtest_mmap_readfile', table.concat(lines, '\n') .. '\n', false)

    clear({ args = { '-n', '-u', 'NONE', '-i', 'NONE' } })
    command('edit Xtest_mmap_readfile')
    local stats = api.nvim__buf_stats(0)
    eq(true, stats.mmap_active)
    eq(1, stats.mmap_storage_refs)
    eq(1, stats.mmap_line_index_refs)
    eq(true, stats.mmap_piece_tree)
    eq(true, stats.mmap_source_is_buffer_file)

    lines[2] = 'copy-backup mmap write'
    command("call setline(2, 'copy-backup mmap write')")
    command('set writebackup nobackup backupcopy=yes backupskip=')
    stats = api.nvim__buf_stats(0)
    command('write')
    local written_stats = api.nvim__buf_stats(0)
    eq(true, written_stats.mmap_active)
    eq(true, written_stats.mmap_piece_tree)
    eq(false, written_stats.mmap_source_is_buffer_file)
    eq(stats.mmap_piece_write_fast_count + 1, written_stats.mmap_piece_write_fast_count)
    local prefix = 'copy-backup mmap line 00001\ncopy-backup mmap write\n'
    eq(prefix, read_file('Xtest_mmap_readfile'):sub(1, #prefix))

    lines[3] = 'detached-source mmap write'
    command("call setline(3, 'detached-source mmap write')")
    stats = api.nvim__buf_stats(0)
    command('write')
    written_stats = api.nvim__buf_stats(0)
    eq(true, written_stats.mmap_active)
    eq(true, written_stats.mmap_piece_tree)
    eq(false, written_stats.mmap_source_is_buffer_file)
    eq(stats.mmap_piece_write_fast_count + 1, written_stats.mmap_piece_write_fast_count)
    prefix = 'copy-backup mmap line 00001\ncopy-backup mmap write\n'
      .. 'detached-source mmap write\n'
    eq(prefix, read_file('Xtest_mmap_readfile'):sub(1, #prefix))
  end)

  it('keeps mmap piece tree editable while swapfile is enabled', function()
    local lines = {}
    for i = 1, 40000 do
      lines[i] = ('line%d ascii text for mmap swap smoke'):format(i)
    end

    write_file('Xtest_mmap_readfile', table.concat(lines, '\n') .. '\n', false)

    clear({ args = { '--cmd', 'set nofsync directory=Xtest_startup_swapdir swapfile' } })
    command('edit Xtest_mmap_readfile')
    local stats = api.nvim__buf_stats(0)
    eq(true, stats.mmap_active)
    eq(true, stats.mmap_piece_tree)
    eq(40000, fn.line('$'))
    eq(lines[1], fn.getline(1))
    eq(lines[40000], fn.getline(40000))

    eq('', fn.swapname('%'))
    eq(true, stats.mmap_piece_journal_active)
    eq(false, stats.mmap_piece_journal_failed)
    eq(false, stats.mmap_piece_journal_dirty)
    eq(0, stats.mmap_piece_journal_record_count)
    ok(stats.mmap_piece_journal_bytes > 0)
    neq('', stats.mmap_piece_journal_path)
    neq(nil, uv.fs_stat(stats.mmap_piece_journal_path))
    local journal_path = stats.mmap_piece_journal_path
    local journal_bytes = stats.mmap_piece_journal_bytes

    command("call setline(2, 'changed with swap')")
    lines[2] = 'changed with swap'
    stats = api.nvim__buf_stats(0)
    eq(true, stats.mmap_active)
    eq(1, stats.mmap_storage_refs)
    eq(1, stats.mmap_line_index_refs)
    eq(true, stats.mmap_piece_tree)
    ok(stats.mmap_piece_revision >= 1)
    ok(stats.mmap_piece_nodes > 0)
    ok(stats.mmap_piece_add_len > 0)
    eq(true, stats.mmap_piece_journal_active)
    eq(false, stats.mmap_piece_journal_failed)
    eq(true, stats.mmap_piece_journal_dirty)
    eq(1, stats.mmap_piece_journal_record_count)
    ok(stats.mmap_piece_journal_bytes > journal_bytes)
    eq(journal_path, stats.mmap_piece_journal_path)
    eq('changed with swap', fn.getline(2))
    eq(lines[40000], fn.getline(40000))
    eq(40000, fn.line('$'))

    command('preserve')
    stats = api.nvim__buf_stats(0)
    eq(true, stats.mmap_active)
    eq(true, stats.mmap_piece_tree)
    eq(true, stats.mmap_piece_journal_active)
    eq(false, stats.mmap_piece_journal_failed)
    eq(false, stats.mmap_piece_journal_dirty)
    eq(1, stats.mmap_piece_journal_record_count)

    command("call append(2, 'inserted with swap')")
    stats = api.nvim__buf_stats(0)
    eq(true, stats.mmap_piece_journal_dirty)
    eq(2, stats.mmap_piece_journal_record_count)
    ok(stats.mmap_piece_journal_bytes > journal_bytes)
    eq('inserted with swap', fn.getline(3))

    command('3delete')
    stats = api.nvim__buf_stats(0)
    eq(true, stats.mmap_piece_journal_dirty)
    eq(3, stats.mmap_piece_journal_record_count)
    eq('changed with swap', fn.getline(2))
    eq(lines[3], fn.getline(3))

    command('write')
    stats = api.nvim__buf_stats(0)
    eq(true, stats.mmap_active)
    eq(true, stats.mmap_piece_tree)
    eq(true, stats.mmap_piece_journal_active)
    eq(false, stats.mmap_piece_journal_failed)
    eq(false, stats.mmap_piece_journal_dirty)
    eq(0, stats.mmap_piece_journal_record_count)
    journal_path = stats.mmap_piece_journal_path
    neq(nil, uv.fs_stat(journal_path))

    command("call setline(4, 'post-write swap')")
    stats = api.nvim__buf_stats(0)
    eq(true, stats.mmap_piece_journal_active)
    eq(false, stats.mmap_piece_journal_failed)
    eq(true, stats.mmap_piece_journal_dirty)
    eq(1, stats.mmap_piece_journal_record_count)

    local stopped_journal_path = stats.mmap_piece_journal_path
    command('set noswapfile')
    stats = api.nvim__buf_stats(0)
    eq(true, stats.mmap_active)
    eq(true, stats.mmap_piece_tree)
    eq(false, stats.mmap_piece_journal_active)
    eq(false, stats.mmap_piece_journal_failed)
    eq(false, stats.mmap_piece_journal_dirty)
    eq(0, stats.mmap_piece_journal_record_count)
    eq('', stats.mmap_piece_journal_path)
    eq(nil, uv.fs_stat(stopped_journal_path))

    command("call setline(5, 'edit without swap journal')")
    stats = api.nvim__buf_stats(0)
    eq(true, stats.mmap_active)
    eq(true, stats.mmap_piece_tree)
    eq(false, stats.mmap_piece_journal_active)
    eq(0, stats.mmap_piece_journal_record_count)
    eq('edit without swap journal', fn.getline(5))

    command('set swapfile')
    stats = api.nvim__buf_stats(0)
    eq(true, stats.mmap_active)
    eq(true, stats.mmap_piece_tree)
    eq(true, stats.mmap_piece_journal_active)
    eq(false, stats.mmap_piece_journal_failed)
    eq(false, stats.mmap_piece_journal_dirty)
    eq(0, stats.mmap_piece_journal_record_count)
    journal_path = stats.mmap_piece_journal_path
    neq('', journal_path)
    neq(nil, uv.fs_stat(journal_path))

    command("call setline(6, 'reopened swap journal edit')")
    stats = api.nvim__buf_stats(0)
    eq(true, stats.mmap_piece_journal_active)
    eq(false, stats.mmap_piece_journal_failed)
    eq(true, stats.mmap_piece_journal_dirty)
    eq(1, stats.mmap_piece_journal_record_count)
    eq('reopened swap journal edit', fn.getline(6))

    command('bwipe!')
    eq(nil, uv.fs_stat(journal_path))
  end)

  it('opens mmap piece journal when updatecount is enabled later', function()
    local lines = {}
    for i = 1, 40000 do
      lines[i] = ('line%d ascii text for delayed mmap swap'):format(i)
    end

    write_file('Xtest_mmap_readfile', table.concat(lines, '\n') .. '\n', false)

    clear({
      args = { '--cmd', 'set nofsync directory=Xtest_startup_swapdir// swapfile updatecount=0' },
    })
    command('edit Xtest_mmap_readfile')
    local stats = api.nvim__buf_stats(0)
    eq(true, stats.mmap_active)
    eq(true, stats.mmap_piece_tree)
    eq(false, stats.mmap_piece_journal_active)
    eq(false, stats.mmap_piece_journal_failed)
    eq('', fn.swapname('%'))

    command('set updatecount=100')
    stats = api.nvim__buf_stats(0)
    eq(true, stats.mmap_active)
    eq(true, stats.mmap_piece_tree)
    eq(true, stats.mmap_piece_journal_active)
    eq(false, stats.mmap_piece_journal_failed)
    eq(false, stats.mmap_piece_journal_dirty)
    eq(0, stats.mmap_piece_journal_record_count)
    eq('', fn.swapname('%'))
    local journal_path = stats.mmap_piece_journal_path
    neq('', journal_path)
    neq(nil, uv.fs_stat(journal_path))

    command("call setline(2, 'delayed swap journal edit')")
    stats = api.nvim__buf_stats(0)
    eq(true, stats.mmap_active)
    eq(true, stats.mmap_piece_tree)
    eq(true, stats.mmap_piece_journal_active)
    eq(false, stats.mmap_piece_journal_failed)
    eq(true, stats.mmap_piece_journal_dirty)
    eq(1, stats.mmap_piece_journal_record_count)
    eq(journal_path, stats.mmap_piece_journal_path)
    eq('delayed swap journal edit', fn.getline(2))

    command('bwipe!')
    eq(nil, uv.fs_stat(journal_path))
  end)

  it('recovers mmap piece-tree edits from a piece journal', function()
    local lines = {}
    for i = 1, 40000 do
      lines[i] = ('line%d ascii text for mmap recovery smoke'):format(i)
    end

    write_file('Xtest_mmap_readfile', table.concat(lines, '\n') .. '\n', false)

    clear({ args = { '--cmd', 'set nofsync directory=Xtest_startup_swapdir// swapfile' } })
    command('edit Xtest_mmap_readfile')
    command("call setline(2, 'recovered change')")
    command("call append(2, 'recovered inserted')")
    command('5delete')

    local stats = api.nvim__buf_stats(0)
    eq(true, stats.mmap_piece_journal_active)
    eq(3, stats.mmap_piece_journal_record_count)
    local journal_path = stats.mmap_piece_journal_path
    neq(nil, uv.fs_stat(journal_path))
    eq(true, uv.fs_copyfile(journal_path, 'Xtest_mmap_saved_journal'))

    command('bwipe!')
    eq(nil, uv.fs_stat(journal_path))
    eq(true, uv.fs_copyfile('Xtest_mmap_saved_journal', journal_path))

    command('edit Xtest_mmap_readfile')
    stats = api.nvim__buf_stats(0)
    eq(true, stats.mmap_active)
    eq(true, stats.mmap_piece_tree)
    eq(false, stats.mmap_piece_journal_active)
    eq(true, stats.mmap_piece_journal_failed)
    eq(journal_path, stats.mmap_piece_journal_path)

    local swaps = fn.swapfilelist()
    eq(1, #swaps)
    matches('Xtest_mmap_readfile%.swp%.pj$', swaps[1])
    local info = fn.swapinfo(swaps[1])
    eq(1, info.dirty)
    matches('Xtest_mmap_readfile$', info.fname)

    command('recover')
    stats = api.nvim__buf_stats(0)
    eq(true, stats.mmap_active)
    eq(true, stats.mmap_piece_tree)
    eq(true, stats.mmap_piece_journal_active)
    eq(false, stats.mmap_piece_journal_failed)
    eq(3, stats.mmap_piece_journal_record_count)
    eq('recovered change', fn.getline(2))
    eq('recovered inserted', fn.getline(3))
    eq(lines[3], fn.getline(4))
    eq(lines[5], fn.getline(5))
    eq(1, fn.getbufvar('%', '&modified'))

    command('bwipe!')
    eq(nil, uv.fs_stat(journal_path))
    eq(true, uv.fs_copyfile('Xtest_mmap_saved_journal', journal_path))

    command('enew')
    command('recover! ' .. fn.fnameescape(journal_path))
    stats = api.nvim__buf_stats(0)
    eq(true, stats.mmap_active)
    eq(true, stats.mmap_piece_tree)
    eq(3, stats.mmap_piece_journal_record_count)
    eq('recovered change', fn.getline(2))
    eq('recovered inserted', fn.getline(3))
    eq(lines[5], fn.getline(5))
    eq(1, fn.getbufvar('%', '&modified'))
  end)

  it('recovers committed mmap piece-journal records with a torn tail', function()
    local lines = {}
    for i = 1, 40000 do
      lines[i] = ('line%d ascii text for mmap torn journal'):format(i)
    end

    write_file('Xtest_mmap_readfile', table.concat(lines, '\n') .. '\n', false)

    clear({ args = { '--cmd', 'set nofsync directory=Xtest_startup_swapdir// swapfile' } })
    command('edit Xtest_mmap_readfile')
    command("call setline(2, 'committed before torn tail')")

    local stats = api.nvim__buf_stats(0)
    eq(true, stats.mmap_piece_journal_active)
    eq(1, stats.mmap_piece_journal_record_count)
    local journal_path = stats.mmap_piece_journal_path
    local committed_bytes = stats.mmap_piece_journal_bytes

    command("call setline(3, 'ignored torn tail')")
    stats = api.nvim__buf_stats(0)
    eq(2, stats.mmap_piece_journal_record_count)
    ok(stats.mmap_piece_journal_bytes > committed_bytes)
    local full_bytes = stats.mmap_piece_journal_bytes
    eq(true, uv.fs_copyfile(journal_path, 'Xtest_mmap_saved_journal'))

    local fd = assert(uv.fs_open('Xtest_mmap_saved_journal', 'r+', 384))
    assert(uv.fs_ftruncate(fd, committed_bytes + 8))
    assert(uv.fs_close(fd))
    local torn_stat = assert(uv.fs_stat('Xtest_mmap_saved_journal'))
    eq(committed_bytes + 8, torn_stat.size)
    ok(torn_stat.size < full_bytes)

    command('bwipe!')
    eq(nil, uv.fs_stat(journal_path))
    eq(true, uv.fs_copyfile('Xtest_mmap_saved_journal', journal_path))

    command('edit Xtest_mmap_readfile')
    stats = api.nvim__buf_stats(0)
    eq(true, stats.mmap_active)
    eq(true, stats.mmap_piece_tree)
    eq(false, stats.mmap_piece_journal_active)
    eq(true, stats.mmap_piece_journal_failed)

    command('recover')
    stats = api.nvim__buf_stats(0)
    eq(true, stats.mmap_active)
    eq(true, stats.mmap_piece_tree)
    eq(true, stats.mmap_piece_journal_active)
    eq(false, stats.mmap_piece_journal_failed)
    eq(false, stats.mmap_piece_journal_dirty)
    eq(1, stats.mmap_piece_journal_record_count)
    eq(committed_bytes, stats.mmap_piece_journal_bytes)
    eq(committed_bytes, assert(uv.fs_stat(journal_path)).size)
    eq('committed before torn tail', fn.getline(2))
    eq(lines[3], fn.getline(3))
    eq(1, fn.getbufvar('%', '&modified'))

    command("call setline(4, 'post-recovery journal append')")
    stats = api.nvim__buf_stats(0)
    eq(true, stats.mmap_piece_journal_active)
    eq(false, stats.mmap_piece_journal_failed)
    eq(true, stats.mmap_piece_journal_dirty)
    eq(2, stats.mmap_piece_journal_record_count)
  end)

  it('refuses mmap piece-journal recovery when the original file changed', function()
    local lines = {}
    for i = 1, 40000 do
      lines[i] = ('line%d ascii text for mmap recovery refusal'):format(i)
    end

    write_file('Xtest_mmap_readfile', table.concat(lines, '\n') .. '\n', false)

    clear({ args = { '--cmd', 'set nofsync directory=Xtest_startup_swapdir// swapfile' } })
    command('edit Xtest_mmap_readfile')
    command("call setline(2, 'unsafe recovered change')")

    local stats = api.nvim__buf_stats(0)
    local journal_path = stats.mmap_piece_journal_path
    eq(true, uv.fs_copyfile(journal_path, 'Xtest_mmap_saved_journal'))
    command('bwipe!')

    lines[#lines + 1] = 'original changed outside recovery'
    write_file('Xtest_mmap_readfile', table.concat(lines, '\n') .. '\n', false)
    eq(true, uv.fs_copyfile('Xtest_mmap_saved_journal', journal_path))

    command('edit Xtest_mmap_readfile')
    stats = api.nvim__buf_stats(0)
    eq(true, stats.mmap_active)
    eq(true, stats.mmap_piece_tree)
    eq(false, stats.mmap_piece_journal_active)
    eq(true, stats.mmap_piece_journal_failed)
    matches('E308: Original file changed;', pcall_err(command, 'recover'))
    eq(lines[2], fn.getline(2))
    eq(0, fn.getbufvar('%', '&modified'))
    os.remove(journal_path)
  end)

  it('defers stale legacy swap checks for mmap piece tree reads', function()
    local lines = {}
    for i = 1, 40000 do
      lines[i] = ('line%d ascii text for mmap stale swap smoke'):format(i)
    end

    write_file('Xtest_mmap_readfile', 'small file before mmap reopen\n', false)
    mkdir('Xtest_startup_swapdir')

    clear({ args = { '--cmd', 'set nofsync' } })
    local j = fn.jobstart({
      nvim_prog,
      '--clean',
      '--embed',
      '--cmd',
      'set nofsync directory=Xtest_startup_swapdir// swapfile fileformat=unix undolevels=-1',
    }, { rpc = true })
    fn.rpcrequest(
      j,
      'nvim_exec2',
      [[
      edit Xtest_mmap_readfile
      call setline(1, 'stale swap change')
      preserve
    ]],
      {}
    )
    local swapname = fn.rpcrequest(j, 'nvim_eval', "swapname('%')")
    neq('', swapname)
    neq(nil, uv.fs_stat(swapname))
    fn.jobstop(j)
    retry(10, nil, function()
      neq(nil, uv.fs_stat(swapname))
    end)

    write_file('Xtest_mmap_readfile', table.concat(lines, '\n') .. '\n', false)
    clear({
      args = {
        '--cmd',
        'set nofsync directory=Xtest_startup_swapdir// swapfile fileformat=unix undolevels=-1',
      },
    })
    command('messages clear')
    command('edit Xtest_mmap_readfile')

    local stats = api.nvim__buf_stats(0)
    eq(true, stats.mmap_active)
    eq(true, stats.mmap_piece_tree)
    eq('', fn.swapname('%'))
    eq(lines[2], fn.getline(2))
    eq(40000, fn.line('$'))

    local messages = exec_capture('messages')
    eq(nil, messages:find('E325', 1, true))
    eq(nil, messages:find('W325', 1, true))
  end)

  it("fsync() with 'nofsync' #8304", function()
    clear({ args = { '--cmd', 'set nofsync directory=Xtest_startup_swapdir' } })

    -- These cases ALWAYS force fsync (regardless of 'fsync' option):

    -- 1. Idle (CursorHold) with modified buffers (+ 'swapfile').
    command('write Xtest_startup_file1')
    feed('Afoo<esc>h')
    command('write')
    eq(0, request('nvim__stats').fsync)
    command('set swapfile')
    command('set updatetime=1')
    feed('Azub<esc>h') -- File is 'modified'.
    sleep(3) -- Allow 'updatetime' to expire.
    retry(3, nil, function()
      eq(1, request('nvim__stats').fsync)
    end)
    command('set updatetime=100000 updatecount=100000')

    -- 2. Explicit :preserve command.
    command('preserve')
    -- TODO: should be exactly 2; where is the extra fsync() is coming from? #26404
    ok(request('nvim__stats').fsync == 2 or request('nvim__stats').fsync == 3)

    -- 3. Enable 'fsync' option, write file.
    command('set fsync')
    feed('Abaz<esc>h')
    command('write')
    -- TODO: should be exactly 4; where is the extra fsync() is coming from? #26404
    ok(request('nvim__stats').fsync == 4 or request('nvim__stats').fsync == 5)
    eq('foozubbaz', trim(read_file('Xtest_startup_file1')))

    -- 4. Exit caused by deadly signal (+ 'swapfile').
    local j =
      fn.jobstart(vim.iter({ nvim_prog, args, '--embed' }):flatten():totable(), { rpc = true })
    fn.rpcrequest(
      j,
      'nvim_exec2',
      [[
      set nofsync directory=Xtest_startup_swapdir
      edit Xtest_startup_file2
      write
      put ='fsyncd text'
    ]],
      {}
    )
    eq('Xtest_startup_swapdir', fn.rpcrequest(j, 'nvim_eval', '&directory'))
    fn.jobstop(j) -- Send deadly signal.

    local screen = startup()
    feed(':recover Xtest_startup_file2<cr>')
    screen:expect({ any = [[Using swap file "Xtest_startup_swapdir[/\]Xtest_startup_file2%.swp"]] })
    feed('<cr>')
    screen:expect({ any = 'fsyncd text' })

    -- 5. SIGPWR signal.
    -- oldtest: Test_signal_PWR()
  end)

  it('backup #9709', function()
    clear({
      args = {
        '-i',
        'Xtest_startup_shada',
        '--cmd',
        'set directory=Xtest_startup_swapdir',
      },
    })

    command('write Xtest_startup_file1')
    feed('ifoo<esc>')
    command('set backup')
    command('set backupcopy=yes')
    command('write')
    feed('Abar<esc>')
    command('write')

    local foobar_contents = trim(read_file('Xtest_startup_file1'))
    local bar_contents = trim(read_file('Xtest_startup_file1~'))

    eq('foobar', foobar_contents)
    eq('foo', bar_contents)
  end)

  it('backup with full path #11214', function()
    clear()
    mkdir('Xtest_backupdir')
    command('set backup')
    command('set backupdir=Xtest_backupdir//')
    command('write Xtest_startup_file1')
    feed('ifoo<esc>')
    command('write')
    feed('Abar<esc>')
    command('write')

    -- Backup filename = fullpath, separators replaced with "%".
    local backup_file_name = string.gsub(
      currentdir() .. '/Xtest_startup_file1',
      is_os('win') and '[:/\\]' or '/',
      '%%'
    ) .. '~'
    local foo_contents = trim(read_file('Xtest_backupdir/' .. backup_file_name))
    local foobar_contents = trim(read_file('Xtest_startup_file1'))

    eq('foobar', foobar_contents)
    eq('foo', foo_contents)
  end)

  it('backup with full path with spaces', function()
    clear()
    mkdir('Xtest_backupdir with spaces')
    command('set backup')
    command('set backupdir=Xtest_backupdir\\ with\\ spaces//')
    command('write Xtest_startup_file1')
    feed('ifoo<esc>')
    command('write')
    feed('Abar<esc>')
    command('write')

    -- Backup filename = fullpath, separators replaced with "%".
    local backup_file_name = string.gsub(
      currentdir() .. '/Xtest_startup_file1',
      is_os('win') and '[:/\\]' or '/',
      '%%'
    ) .. '~'
    local foo_contents = trim(read_file('Xtest_backupdir with spaces/' .. backup_file_name))
    local foobar_contents = trim(read_file('Xtest_startup_file1'))

    eq('foobar', foobar_contents)
    eq('foo', foo_contents)
  end)

  it('backup symlinked files #11349', function()
    clear()

    local initial_content = 'foo'
    local link_file_name = 'Xtest_startup_file2'
    local backup_file_name = link_file_name .. '~'

    write_file('Xtest_startup_file1', initial_content, false)
    uv.fs_symlink('Xtest_startup_file1', link_file_name)
    command('set backup')
    command('set backupcopy=yes')
    command('edit ' .. link_file_name)
    feed('Abar<esc>')
    command('write')

    local backup_raw = read_file(backup_file_name)
    neq(nil, backup_raw, 'Expected backup file ' .. backup_file_name .. 'to exist but did not')
    eq(initial_content, trim(backup_raw), 'Expected backup to contain original contents')
  end)

  it('backup symlinked files in first available backupdir #11349', function()
    clear()

    local initial_content = 'foo'
    local backup_dir = 'Xtest_backupdir'
    local sep = n.get_pathsep()
    local link_file_name = 'Xtest_startup_file2'
    local backup_file_name = backup_dir .. sep .. link_file_name .. '~'

    write_file('Xtest_startup_file1', initial_content, false)
    uv.fs_symlink('Xtest_startup_file1', link_file_name)
    mkdir(backup_dir)
    command('set backup')
    command('set backupcopy=yes')
    command('set backupdir=.__this_does_not_exist__,' .. backup_dir)
    command('edit ' .. link_file_name)
    feed('Abar<esc>')
    command('write')

    local backup_raw = read_file(backup_file_name)
    neq(nil, backup_raw, 'Expected backup file ' .. backup_file_name .. ' to exist but did not')
    eq(initial_content, trim(backup_raw), 'Expected backup to contain original contents')
  end)

  it('readfile() on multibyte filename #10586', function()
    clear()
    local text = {
      'line1',
      '  ...line2...  ',
      '',
      'line3!',
      'тест yay тест.',
      '',
    }
    local fname = 'Xtest_тест.md'
    fn.writefile(text, fname, 's')
    table.insert(text, '')
    eq(text, fn.readfile(fname, 'b'))
  end)
  it("read invalid u8 over INT_MAX doesn't segfault", function()
    clear()
    command('call writefile(0zFFFFFFFF, "Xtest-u8-int-max")')
    -- This should not segfault
    command('edit ++enc=utf32 Xtest-u8-int-max')
    assert_alive()
  end)

  it(':w! does not show "file has been changed" warning', function()
    clear()
    write_file('Xtest-overwrite-forced', 'foobar')
    command('set nofixendofline')
    local screen = Screen.new(40, 4)
    command('set shortmess-=F')

    command('e Xtest-overwrite-forced')
    screen:expect([[
      ^foobar                                  |
      {1:~                                       }|*2
      "Xtest-overwrite-forced" [noeol] 1L, 6B |
    ]])

    -- Get current unix time.
    local cur_unix_time = os.time(os.date('!*t'))
    local future_time = cur_unix_time + 999999
    -- Set the file's access/update time to be
    -- greater than the time at which it was created.
    uv.fs_utime('Xtest-overwrite-forced', future_time, future_time)
    -- use async feed_command because nvim basically hangs on the prompt
    feed_command('w')
    screen:expect([[
      {9:WARNING: The file has been changed since}|
      {9: reading it!!!}                          |
      {6:Do you really want to write to it (y/n)?}|
      ^                                        |
    ]])

    feed('n')
    feed('<cr>')
    screen:expect([[
      ^foobar                                  |
      {1:~                                       }|*2
                                              |
    ]])
    -- Use a screen test because the warning does not set v:errmsg.
    command('w!')
    screen:expect([[
      ^foobar                                  |
      {1:~                                       }|*2
      <erwrite-forced" [noeol] 1L, 6B written |
    ]])
  end)
end)

describe('tmpdir', function()
  local tmproot_pat = [=[.*[/\\]nvim%.[^/\\]+]=]
  local testlog = 'Xtest_tmpdir_log'
  local os_tmpdir ---@type string

  before_each(function()
    -- Fake /tmp dir so that we can mess it up.
    os_tmpdir = assert(vim.uv.fs_mkdtemp(vim.fs.dirname(t.tmpname(false)) .. '/nvim_XXXXXXXXXX'))
  end)

  after_each(function()
    check_close()
    os.remove(testlog)
  end)

  local function get_tmproot()
    -- Tempfiles typically look like: "…/nvim.<user>/xxx/0".
    --  - "…/nvim.<user>/xxx/" is the per-process tmpdir, not shared with other Nvims.
    --  - "…/nvim.<user>/" is the tmpdir root, shared by all Nvims (normally).
    local tmproot = (fn.tempname()):match(tmproot_pat)
    ok(tmproot:len() > 4, 'tmproot like "nvim.foo"', tmproot)
    return tmproot
  end

  it('failure modes', function()
    clear({ env = { NVIM_LOG_FILE = testlog, TMPDIR = os_tmpdir } })
    assert_nolog('tempdir is not a directory', testlog)
    assert_nolog('tempdir has invalid permissions', testlog)

    local tmproot = get_tmproot()

    -- Test how Nvim handles invalid tmpdir root (by hostile users or accidents).
    --
    -- "…/nvim.<user>/" is not a directory:
    expect_exit(command, ':qall!')
    rmdir(tmproot)
    write_file(tmproot, '') -- Not a directory, vim_mktempdir() should skip it.
    clear({ env = { NVIM_LOG_FILE = testlog, TMPDIR = os_tmpdir } })
    matches(tmproot_pat, fn.stdpath('run')) -- Tickle vim_mktempdir().
    -- Assert that broken tmpdir root was handled.
    assert_log('tempdir root not a directory', testlog, 100)

    -- "…/nvim.<user>/" has wrong permissions:
    skip(is_os('win'), 'TODO(justinmk): need setfperm/getfperm on Windows. #8244')
    os.remove(testlog)
    os.remove(tmproot)
    mkdir(tmproot)
    fn.setfperm(tmproot, 'rwxr--r--') -- Invalid permissions, vim_mktempdir() should skip it.
    clear({ env = { NVIM_LOG_FILE = testlog, TMPDIR = os_tmpdir } })
    matches(tmproot_pat, fn.stdpath('run')) -- Tickle vim_mktempdir().
    -- Assert that broken tmpdir root was handled.
    assert_log('tempdir root has invalid permissions', testlog, 100)
  end)

  it('too long', function()
    local bigname = ('%s/%s'):format(os_tmpdir, ('x'):rep(666))
    mkdir(bigname)
    clear({ env = { NVIM_LOG_FILE = testlog, TMPDIR = bigname } })
    matches(tmproot_pat, fn.stdpath('run')) -- Tickle vim_mktempdir().
    local len = (fn.tempname()):len()
    ok(len > 4 and len < 256, '4 < len < 256', tostring(len))
  end)

  it('disappeared #1432', function()
    clear({ env = { NVIM_LOG_FILE = testlog, TMPDIR = os_tmpdir } })
    assert_nolog('tempdir disappeared', testlog)

    local function rm_tmpdir()
      local tmpname1 = fn.tempname()
      local tmpdir1 = fn.fnamemodify(tmpname1, ':h')
      eq(fn.stdpath('run'), tmpdir1)

      rmdir(tmpdir1)
      retry(nil, 1000, function()
        eq(0, fn.isdirectory(tmpdir1))
      end)
      local tmpname2 = fn.tempname()
      local tmpdir2 = fn.fnamemodify(tmpname2, ':h')
      neq(tmpdir1, tmpdir2)
    end

    -- Your antivirus hates you...
    rm_tmpdir()
    assert_log('tempdir disappeared', testlog, 100)
    fn.tempname()
    fn.tempname()
    fn.tempname()
    eq('', api.nvim_get_vvar('errmsg'))
    rm_tmpdir()
    fn.tempname()
    fn.tempname()
    fn.tempname()
    eq('E5431: tempdir disappeared (2 times)', api.nvim_get_vvar('errmsg'))
    rm_tmpdir()
    eq('E5431: tempdir disappeared (3 times)', api.nvim_get_vvar('errmsg'))
  end)
end)
