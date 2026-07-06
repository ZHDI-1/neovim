local t = require('test.testutil')
local n = require('test.functional.testnvim')()
local Screen = require('test.functional.ui.screen')

local feed = n.feed
local eq = t.eq
local pcall_err = t.pcall_err
local clear = n.clear
local fn = n.fn
local command = n.command
local write_file = t.write_file
local api = n.api
local source = n.source

local file_base = 'Xtest-functional-ex_cmds-quickfix_commands'

before_each(clear)

for _, c in ipairs({ 'l', 'c' }) do
  local file = ('%s.%s'):format(file_base, c)
  local filecmd = c .. 'file'
  local getfcmd = c .. 'getfile'
  local addfcmd = c .. 'addfile'
  local getlist = (c == 'c') and fn.getqflist or function()
    return fn.getloclist(0)
  end

  describe((':%s*file commands'):format(c), function()
    before_each(function()
      write_file(
        file,
        ([[
        %s-1.res:700:10:Line 700
        %s-2.res:800:15:Line 800
      ]]):format(file, file)
      )
    end)
    after_each(function()
      os.remove(file)
    end)

    it('work', function()
      command(('%s %s'):format(filecmd, file))
      -- Second line of each entry (i.e. `nr=-1, …`) was obtained from actual
      -- results. First line (i.e. `{lnum=…`) was obtained from legacy test.
      local list = {
        {
          lnum = 700,
          end_lnum = 0,
          col = 10,
          end_col = 0,
          text = 'Line 700',
          module = '',
          nr = -1,
          bufnr = 2,
          valid = 1,
          pattern = '',
          vcol = 0,
          ['type'] = '',
        },
        {
          lnum = 800,
          end_lnum = 0,
          col = 15,
          end_col = 0,
          text = 'Line 800',
          module = '',
          nr = -1,
          bufnr = 3,
          valid = 1,
          pattern = '',
          vcol = 0,
          ['type'] = '',
        },
      }
      eq(list, getlist())
      eq(('%s-1.res'):format(file), fn.bufname(list[1].bufnr))
      eq(('%s-2.res'):format(file), fn.bufname(list[2].bufnr))

      -- Run cfile/lfile from a modified buffer
      command('set nohidden')
      command('enew!')
      api.nvim_buf_set_lines(0, 1, 1, true, { 'Quickfix' })
      eq(
        ('Vim(%s):E37: No write since last change (add ! to override)'):format(filecmd),
        pcall_err(command, ('%s %s'):format(filecmd, file))
      )

      write_file(
        file,
        ([[
        %s-3.res:900:30:Line 900
      ]]):format(file)
      )
      command(('%s %s'):format(addfcmd, file))
      list[#list + 1] = {
        lnum = 900,
        end_lnum = 0,
        col = 30,
        end_col = 0,
        text = 'Line 900',
        module = '',
        nr = -1,
        bufnr = 5,
        valid = 1,
        pattern = '',
        vcol = 0,
        ['type'] = '',
      }
      eq(list, getlist())
      eq(('%s-3.res'):format(file), fn.bufname(list[3].bufnr))

      write_file(
        file,
        ([[
        %s-1.res:222:77:Line 222
        %s-2.res:333:88:Line 333
      ]]):format(file, file)
      )
      command('enew!')
      command(('%s %s'):format(getfcmd, file))
      list = {
        {
          lnum = 222,
          end_lnum = 0,
          col = 77,
          end_col = 0,
          text = 'Line 222',
          module = '',
          nr = -1,
          bufnr = 2,
          valid = 1,
          pattern = '',
          vcol = 0,
          ['type'] = '',
        },
        {
          lnum = 333,
          end_lnum = 0,
          col = 88,
          end_col = 0,
          text = 'Line 333',
          module = '',
          nr = -1,
          bufnr = 3,
          valid = 1,
          pattern = '',
          vcol = 0,
          ['type'] = '',
        },
      }
      eq(list, getlist())
      eq(('%s-1.res'):format(file), fn.bufname(list[1].bufnr))
      eq(('%s-2.res'):format(file), fn.bufname(list[2].bufnr))
    end)
  end)
end

describe('quickfix', function()
  it('location-list update on buffer modification', function()
    source([[
        new
        setl bt=nofile
        let lines = ['Line 1', 'Line 2', 'Line 3', 'Line 4', 'Line 5']
        call append(0, lines)
        new
        setl bt=nofile
        call append(0, lines)
        let qf_item = {
          \ 'lnum': 4,
          \ 'text': "This is the error line.",
          \ }
        let qf_item['bufnr'] = bufnr('%')
        call setloclist(0, [qf_item])
        wincmd p
        let qf_item['bufnr'] = bufnr('%')
        call setloclist(0, [qf_item])
        1del _
        call append(0, ['New line 1', 'New line 2', 'New line 3'])
        silent ll
    ]])
    eq({ 0, 6, 1, 0, 1 }, fn.getcurpos())
  end)

  it('BufAdd does not cause E16 when reusing quickfix buffer #18135', function()
    local file = file_base .. '_reuse_qfbuf_BufAdd'
    write_file(file, ('\n'):rep(100) .. 'foo')
    finally(function()
      os.remove(file)
    end)
    source([[
      set grepprg=internal
      autocmd BufAdd * call and(0, 0)
      autocmd QuickFixCmdPost grep ++nested cclose | cwindow
    ]])
    command('grep foo ' .. file)
    command('grep foo ' .. file)
  end)

  it('jump message does not scroll with cmdheight=0 and shm+=O #29597', function()
    local screen = Screen.new(40, 6)
    command('set cmdheight=0')
    local file = file_base .. '_reuse_qfbuf_BufAdd'
    write_file(file, 'foobar')
    finally(function()
      os.remove(file)
    end)
    command('vimgrep /foo/gj ' .. file)
    feed(':cc<CR>')
    screen:expect([[
      ^foobar                                  |
      {1:~                                       }|*4
      (1 of 1): foobar                        |
    ]])
  end)
end)

it(':vimgrep keeps literal fast path separate from regex patterns', function()
  local file = file_base .. '_vimgrep_literal'
  write_file(file,
    'panic: path/to status=500\npanic path status 500\nf.o\nfao\nfoo\naa中🙂bb\nstatus Z: done\n')
  finally(function()
    os.remove(file)
  end)

  command('set noignorecase nosmartcase regexpengine=2')
  command('vimgrep /panic:/gj ' .. file)
  local list = fn.getqflist()
  eq(1, #list)
  eq({ 1, 1, 7 }, { list[1].lnum, list[1].col, list[1].end_col })

  command('vimgrep /path\\/to/gj ' .. file)
  list = fn.getqflist()
  eq(1, #list)
  eq({ 1, 8, 15 }, { list[1].lnum, list[1].col, list[1].end_col })

  command('vimgrep /f.o/gj ' .. file)
  list = fn.getqflist()
  eq(3, #list)
  eq({ 3, 4, 5 }, { list[1].lnum, list[2].lnum, list[3].lnum })

  command('vimgrep /中🙂/gj ' .. file)
  list = fn.getqflist()
  eq(1, #list)
  eq({ 6, 3, 10 }, { list[1].lnum, list[1].col, list[1].end_col })

  command('vimgrep /Z:/gj ' .. file)
  list = fn.getqflist()
  eq(1, #list)
  eq({ 7, 8, 10 }, { list[1].lnum, list[1].col, list[1].end_col })
end)

it(':vimgrep searches edited mmap buffers through the piece tree', function()
  local file = file_base .. '_vimgrep_mmap_piece_tree'
  local lines = {}
  for i = 1, 40000 do
    lines[i] = ('line%d ascii text for mmap quickfix'):format(i)
  end
  lines[1001] = 'after empty mmap line'

  write_file(file, table.concat(lines, '\n') .. '\n', false)
  finally(function()
    os.remove(file)
  end)

  clear({ args = { '-n', '-u', 'NONE', '-i', 'NONE' } })
  command('set noignorecase nosmartcase regexpengine=2')
  command('edit ' .. file)
  eq(40000, fn.line('$'))

  command("call setline(2, 'changed Zhanged')")
  command('call cursor(2, 1)')
  command('normal! rZ')
  eq('Zhanged Zhanged', fn.getline(2))

  command('vimgrep /Zhanged/j %')
  local list = fn.getqflist()
  eq(1, #list)
  eq({ 2, 1, 8 }, { list[1].lnum, list[1].col, list[1].end_col })

  command('vimgrep /Zhanged/gj %')
  list = fn.getqflist()
  eq(2, #list)
  eq({ 2, 1, 8 }, { list[1].lnum, list[1].col, list[1].end_col })
  eq({ 2, 9, 16 }, { list[2].lnum, list[2].col, list[2].end_col })

  command('1vimgrep /Zhanged/gj %')
  list = fn.getqflist()
  eq(1, #list)
  eq({ 2, 1, 8 }, { list[1].lnum, list[1].col, list[1].end_col })

  command('vimgrep /after empty mmap line/gj %')
  list = fn.getqflist()
  eq(1, #list)
  eq({ 1001, 1, 22 }, { list[1].lnum, list[1].col, list[1].end_col })

  eq('Vim(vimgrep):E480: No match: definitely-missing-piece-text',
    pcall_err(command, 'vimgrep /definitely-missing-piece-text/gj %'))

  api.nvim_buf_set_text(0, 1000, 6, 1000, 6, { 'piece-' })
  eq('after piece-empty mmap line', fn.getline(1001))
  command('vimgrep /piece-empty/gj %')
  list = fn.getqflist()
  eq(1, #list)
  eq({ 1001, 7, 18 }, { list[1].lnum, list[1].col, list[1].end_col })

  for i = 1, 100 do
    command(('call setline(%d, "fragmark avx %d")'):format(1500 + i * 100, i))
  end

  command('25vimgrep /fragmark/gj %')
  list = fn.getqflist()
  eq(25, #list)
  eq({ 1600, 1, 9 }, { list[1].lnum, list[1].col, list[1].end_col })
  eq({ 4000, 1, 9 }, { list[25].lnum, list[25].col, list[25].end_col })
end)

it(':vimgrep can specify Unicode pattern without delimiters', function()
  eq(
    'Vim(vimgrep):E480: No match: →',
    pcall_err(command, 'vimgrep → test/functional/fixtures/tty-test.c')
  )
  local screen = Screen.new(40, 6)
  screen:set_default_attr_ids({
    [0] = { bold = true, foreground = Screen.colors.Blue }, -- NonText
    [1] = { reverse = true }, -- IncSearch
  })
  feed('i→<Esc>:vimgrep →')
  screen:expect([[
    {1:→}                                       |
    {0:~                                       }|*4
    :vimgrep →^                              |
  ]])
end)
