# mmap-backed large UTF-8 file work

This document describes the large-file open and search work on the
`mmap-open` branch. It is an internal design note for developers working on
the code, not a user-facing help document.

The implementation was inspired by the standalone `../logview` experiment:
map the file, count newlines with SIMD, split the scan across worker threads,
and avoid constructing a full in-memory line tree before the user actually
edits the file. The goal is to make opening and searching very large UTF-8 log
files much closer to the logviewer cost profile while preserving Neovim's
normal behavior when the fast path is not obviously safe.

## Goals

- Speed up opening very large UTF-8 files.
- Speed up common literal `:vimgrep` searches over mmap-backed large files.
- Keep the existing reader, memline tree, swapfile behavior, quickfix behavior,
  and regexp behavior as the fallback.
- Avoid changing behavior for binary files, CRLF/Mac files, invalid UTF-8,
  small files, or cases where Neovim needs the normal mutable memline tree.
- Keep the first checkpoint easy to revert: mmap/open/search changes are
  isolated to a small set of files.

## Non-goals for this checkpoint

- Full support for arbitrary encodings. The mmap path is for UTF-8-compatible
  file contents.
- Full support for CRLF or old-Mac line endings in the mmap representation.
- Skipping validation to match logviewer's fastest newline-only index time.
- Replacing the normal memline tree. The mmap layer is a lazy read-only
  representation that materializes into normal memline on mutation.
- Making all regexp searches parallel. The optimized quickfix path is for
  simple literal UTF-8 patterns.

## Files changed

- `src/nvim/fileio.c`
  - Chooses the mmap fast path while reading a file.
  - Implements AVX2/AVX512 CPU detection.
  - Implements scalar, AVX2, AVX512, and parallel mmap line scanning.
  - Builds the sparse mmap line-start index.

- `src/nvim/memline_defs.h`
  - Adds mmap fields to `memline_T`.
  - Adds `mmap_literal_match_T`, the compact match record used by mmap search.

- `src/nvim/memline.h`
  - Defines `ML_MMAP_INDEX_STRIDE`, the sparse line-index granularity.
  - Exposes mmap helper APIs used by file I/O and quickfix.

- `src/nvim/memline.c`
  - Owns the mmap-backed memline representation.
  - Implements lazy line access, byte/line conversion, materialization, and
    cleanup.
  - Implements AVX2/AVX512 literal search and newline counting helpers.
  - Implements parallel mmap literal match collection.

- `src/nvim/quickfix.c`
  - Detects simple literal UTF-8 `:vimgrep` patterns.
  - Calls mmap literal search helpers when the target buffer is mmap-backed.
  - Adds an internal quickfix insertion mode that can take ownership of an
    already-allocated line string and avoid an extra copy.

- `src/nvim/regexp.c`
  - Improves the existing NFA "plain literal text" path by preserving the full
    literal text and using it directly for case-sensitive matching.

- `test/functional/core/fileio_spec.lua`
  - Adds mmap read/materialize coverage.
  - Adds mmap read coverage with swapfile enabled.

- `test/functional/ex_cmds/quickfix_commands_spec.lua`
  - Adds literal `:vimgrep` fast-path coverage.
  - Adds coverage for a Unicode literal pattern without delimiters.

## High-level architecture

The new path has three layers:

1. File read selection in `fileio.c`.
   The reader maps candidate files, scans and validates their contents, builds
   lightweight line metadata, and installs mmap-backed memline state.

2. Lazy mmap memline in `memline.c`.
   The buffer appears to Neovim as a normal line-based buffer, but line text is
   copied from the mapped file on demand. The normal memline tree remains the
   fallback and the edit-time representation.

3. mmap-aware search in `quickfix.c` and `memline.c`.
   Literal `:vimgrep` over an mmap-backed buffer can scan the mapped bytes
   directly, collect matches in worker threads, and then build the quickfix
   list on the main thread.

Every layer is designed to fall back to the old implementation when the input
or command is outside the narrow safe fast path.

## File open fast path

The top-level entry point is `readfile_try_mmap_utf8()` in `src/nvim/fileio.c`.
It is attempted only for Unix builds and only when the file is large enough:

- `READFILE_MMAP_MIN_SIZE = 1 MiB`
- file size must be positive
- file size must fit `size_t` and `ptrdiff_t`

The file is mapped with:

```c
mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0)
```

The mapping is read-only from Neovim's point of view. Mutations happen only
after materializing into the normal memline tree.

The current reader also applies `MADV_SEQUENTIAL` when available. The
standalone logviewer used stronger page hints such as `MADV_WILLNEED` and
`MADV_HUGEPAGE`; those are not part of the current committed checkpoint.

### SIMD CPU dispatch

The file I/O code uses runtime CPU checks:

- `readfile_can_use_avx512bw()`
- `readfile_can_use_avx2()`

The AVX functions are compiled with target attributes, so the binary can still
run on machines without those instruction sets. Dispatch prefers AVX512BW,
then AVX2, then scalar validation/counting.

### ASCII vector fast path

The fastest path is intentionally strict. It accepts ASCII text with:

- no high-bit bytes
- no NUL bytes
- no carriage returns
- newline-delimited lines
- line count within `MAXLNUM - 1`
- each line length within `MAXCOL - 1`

If a high-bit byte is found, the vector ASCII path returns fallback rather than
rejecting the file. The fallback validates UTF-8 with Neovim's existing UTF-8
helpers and counts lines with scalar logic.

If NUL or carriage return is found, the mmap path rejects the file and the old
reader handles it. This avoids changing binary-file behavior and avoids taking
over CRLF/Mac line-ending semantics in this checkpoint.

### Parallel scan

For files at or above:

```c
READFILE_MMAP_PARALLEL_MIN_SIZE = 128 MiB
```

the reader uses worker threads. The input is split into fixed byte blocks:

```c
READFILE_MMAP_PARALLEL_BLOCK_SIZE = 4096
READFILE_MMAP_PARALLEL_MAX_THREADS = 32
```

Each block is independent. A worker scans its assigned block range and writes a
`ReadfileMmapBlockScan` record for each block:

```c
typedef struct {
  uint16_t nl_count;
  uint16_t prefix_len;
  uint16_t suffix_len;
} ReadfileMmapBlockScan;
```

The three fields are enough for the main thread to validate line lengths across
block boundaries:

- `nl_count`: number of newlines in the block.
- `prefix_len`: bytes before the first newline, or the whole block if there is
  no newline.
- `suffix_len`: bytes after the last newline, or the whole block if there is
  no newline.

Workers do not allocate per-line data and do not touch Neovim buffer state.
They only read mmap bytes and fill their block metadata. This keeps the
threaded section isolated and easy to reason about.

After joining workers, the main thread:

1. Checks worker results for reject/fallback.
2. Walks block metadata in order.
3. Accumulates total newline count.
4. Validates line lengths across block boundaries.
5. Computes whether the file has no final EOL.
6. Converts newline count to Neovim line count.
7. Builds the sparse line-start index.

### Sparse line-start index

The mmap memline does not store every line offset. It stores one byte offset
per `ML_MMAP_INDEX_STRIDE` lines:

```c
ML_MMAP_INDEX_STRIDE = 4096
```

The first entry is always byte offset 0. For line lookup, the mmap memline
starts from the nearest sparse checkpoint and scans forward with `memchr()` to
the requested line.

The sparse index has two important properties:

- Open cost stays low. On a 284M-line file, storing every line offset would be
  several GiB. The sparse index is tens of thousands of entries.
- Random line lookup remains bounded. Worst case is scanning at most 4095
  newlines after the sparse checkpoint.

During parallel open, the main thread uses block newline counts to locate only
the blocks that contain sparse-index target lines. It does not rescan the whole
file to build the sparse index.

## mmap-backed memline

Normal memline stores mutable line data in a memfile-backed tree. The mmap path
adds a temporary read-only representation:

```c
char *ml_mmap_base;
size_t ml_mmap_size;
size_t *ml_mmap_line_starts;
size_t ml_mmap_index_count;
bool ml_mmap_noeol;
PieceTree *ml_piece_tree;
```

These fields live in `memline_T`. When `ml_mmap_base != NULL`, the buffer is
mmap-backed.

### Installing mmap lines

`ml_set_mmap_lines()` installs the representation. Ownership of the mapping and
line-start index transfers to memline on success.

The normal memline tree is expected to still be in the initial empty-buffer
state created by `ml_open()`. The mmap representation then becomes the logical
contents of the buffer.

Important invariants:

- `ml_line_count` is set to the mmap line count.
- `ML_EMPTY` is cleared.
- a piece tree is initialized over the mapped bytes so common no-swap edits can
  update logical buffer content without copying the whole file.
- if installation fails, `fileio.c` unmaps and frees the temporary metadata.

### Reading lines

`ml_get_buf_impl()` has an mmap branch. For a read-only access:

1. Compute line bounds using `ml_mmap_line_bounds()`.
2. Copy that line from `ml_mmap_base` with `xmemdupz()`.
3. Store it in the existing memline line cache.
4. Mark the cached line as `ML_ALLOCATED`.

This preserves the existing expectation that callers receive a NUL-terminated
line string. The cache is invalidated through the normal `ml_flush_line()`
machinery.

### Editing and materialization

The original mmap bytes remain immutable, but the buffer can become logically
mutable through the piece tree. Common line-oriented operations replace, append,
and delete piece-tree ranges directly when swapfile editing is not active and
the payload can be represented as line text.

Operations that are not yet represented safely, or edits while a swapfile is
active, still use `ml_mmap_materialize()` to convert the mapped file into normal
memline blocks:

1. Save the mmap base, size, sparse index, and line count.
2. Clear mmap fields from the buffer.
3. Reset normal memline state to the initial empty line.
4. Append/replace each line into the normal memline tree.
5. Unmap the file and free the sparse index.

After materialization, all existing edit paths operate on normal Neovim data
structures. This remains the main safety valve for compatibility.

### Writing edited mmap buffers

`:write` has a guarded piece-span fast path for contiguous line ranges.
`buf_write()` still owns the normal Neovim write setup: backup handling, file
opening, permissions, fsync, timestamp updates, messages, and autocmd sequencing.
The optimized branch only replaces the inner byte-production loop when the
output can be written as raw logical bytes from the piece tree.

The fast path currently requires:

- mmap piece tree is still active
- line-range write, not append and not filtering
- Unix fileformat
- no binary write mode and no trailing CTRL-Z behavior
- no encoding conversion, BOM conversion, or iconv path
- no persistent-undo hash pass
- the output path must not truncate the mapped source in place; same-file writes
  need a rename-style backup, while new files, different files, and devices are
  safe

Before collecting spans it flushes the mmap memline cache, so a dirty current
line is either committed to the piece tree or the path declines. It then collects
a stable `PieceTreeSpanVec` at one tree revision and writes each physical span
directly. Final newline behavior follows the legacy `fixeol`/`endofline` rule:
if the logical bytes do not end in `\n`, the writer appends one only when the
normal line loop would have done so.

Unsupported write shapes still use the existing line-oriented writer. This keeps
correctness for DOS/Mac fileformats, conversion, partial ranges, filters,
append writes, and persistent undo while giving the common `nvim -n hugefile`
case an allocation-light save path.

### Closing

`ml_mmap_close()` unmaps `ml_mmap_base`, frees `ml_mmap_line_starts`, clears
mmap metadata, and clears cached line state.

### Byte/line conversion

`ml_find_line_or_offset()` has an mmap branch for both directions:

- `line2byte()` uses the sparse index plus forward newline scan.
- `byte2line()` finds the nearest sparse checkpoint by byte offset, then scans
  forward until it finds the line containing the byte.

For DOS fileformat accounting, the mmap branch adds the logical extra CR byte
count when needed, matching the existing `line2byte()` contract as closely as
possible for the supported mmap representation.

## mmap literal search

The quickfix work targets `:vimgrep` over mmap-backed buffers when the pattern
is a simple literal UTF-8 string.

### Literal pattern detection

`vgr_is_literal_utf8()` in `quickfix.c` accepts a pattern only if:

- it is valid UTF-8
- it is non-empty
- it is not fuzzy search
- ignorecase is not active
- it does not contain obvious regexp metacharacters handled by this path:
  backslash, `.`, `[`, `~`, `^`, `$`, `*`, or control characters

Patterns outside this definition use the existing regexp/fuzzy path.

### Direct mmap match records

The mmap search layer returns compact match metadata:

```c
typedef struct {
  linenr_T lnum;
  colnr_T col;
  size_t line_start;
  size_t line_len;
} mmap_literal_match_T;
```

The match record avoids copying line text during the worker scan. Quickfix
copies only the matched line text when it is actually adding an entry.

### Vector literal finder

`memline.c` has AVX512BW and AVX2 implementations for finding a literal inside
a byte range:

- find candidate bytes matching the first pattern byte with SIMD
- verify candidates with byte comparison
- fall back to scalar/memmem-like behavior when SIMD is unavailable or the
  pattern shape is not worth vectorizing

This replaced a hot `memmem()` profile point seen during mmap literal search.

### Parallel bounded match collection

`ml_get_buf_mmap_literal_matches()` is the batch API used by quickfix.

For pristine mmap buffers, it scans the mapped file directly. For edited mmap
buffers backed by the piece tree, it collects stable `PieceTreeSpanVec` objects
for line-range partitions and workers scan those span vectors instead of
traversing the tree. Each vector carries physical spans plus the logical start,
byte length, and piece-tree revision observed during collection. Partition setup
captures a piece-tree snapshot and requires every partition boundary and span
vector to match that revision; if not, the batch path falls back.

The edited piece-span scanner has two tiers:

- A proven-empty prefilter scans physical spans with the same literal finder
  used by raw mmap search, plus a small boundary window between adjacent spans.
  If no in-span or cross-span literal is possible, the search returns zero
  matches without walking every byte for line state.
- If matches exist and no cross-span match is possible, each worker uses the
  vector literal finder inside each span and advances line state with bulk
  newline counting between matches. The older byte-by-byte streaming matcher is
  kept for patterns that may cross piece boundaries.
- For bounded searches, reaching the requested match count is a successful
  stop, not an overflow. Workers can therefore stop after enough ordered
  candidates have been collected instead of forcing the slow fallback path.

The production path runs only when the workload is large enough and bounded
enough:

- mmap buffer is active
- logical text size is at least 128 MiB
- buffer has at least two lines
- pattern length is at least 3 bytes
- requested max matches is at least 4096
- collected matches are capped by `ML_MMAP_PARALLEL_MATCH_LIMIT`

The cap is important. An unbounded frequent search over a 20 GiB log can produce
an enormous quickfix list. The current fast path is meant to speed practical
bounded searches without building huge temporary arrays.

Thread partitioning is by line range, not raw byte range. Each worker receives:

- start byte offset
- end byte offset
- starting line number
- pattern bytes
- global/non-global mode
- either a contiguous mmap byte range and newline-counting implementation, or a
  stable `PieceTreeSpanVec`

Workers scan their range and append only match metadata to a private vector.
They do not chase piece-tree parent/child links, and no quickfix state is
touched from workers.

After joining workers, the main thread merges match arrays in worker order,
then `quickfix.c` creates quickfix entries.

When running under the Neovim test harness (`NVIM_TEST`), these thresholds are
lowered so focused functional tests can exercise the worker setup without
creating a 128 MiB fixture. Normal builds keep the production thresholds above.

### Serial mmap fallback

`ml_get_buf_mmap_literal_match_at()` is the serial fallback. It searches from a
byte offset, computes the line number by counting newlines from the previous
known point, copies the matched line text, and returns one match. It is used
when the batch path declines the workload.

### Quickfix ownership change

`qf_add_entry_impl()` gained a `take_mesg` boolean. Existing callers keep the
old wrapper behavior. The mmap path can pass an allocated line string and let
quickfix take ownership, avoiding one extra line copy for each quickfix entry.

## Regexp literal optimization

The NFA regexp engine already had a path for patterns that are just literal
text. This checkpoint improves that path:

- `nfa_get_match_text()` now preserves both:
  - `match_text`: text after the first character, used by the older path
  - `match_text_full`: the whole literal text
- case-sensitive literal regexp execution can use `strstr()` on
  `match_text_full` directly instead of first scanning for the first character
  and then checking the rest.
- case-insensitive matching keeps the older skip/check logic.

This is separate from the mmap quickfix path. It helps regular regexp
execution when the compiled NFA is a simple literal.

## Fallback strategy

The implementation is deliberately conservative. The mmap path should give up
and let old Neovim code handle the file or command whenever safety is unclear.

Examples that fall back:

- file smaller than 1 MiB
- non-Unix build
- mmap failure
- file size does not fit local pointer types
- BOM at the start of the file
- NUL byte
- carriage return byte
- invalid UTF-8
- too many lines for `MAXLNUM`
- line too long for `MAXCOL`
- unsupported search pattern
- ignorecase literal search
- fuzzy search
- dense/unbounded mmap match collection that would exceed collection limits
- worker creation failure

This is why the change is relatively large but behaviorally narrow.

## Benchmarks recorded during development

Benchmarks were run on:

- CPU: Intel Core i9-7960X, 16 cores / 32 hardware threads
- File: `../logview/paniclog.txt`
- Size: 21,475,073,550 bytes, about 20 GiB
- Lines: 284,435,256
- Neovim command shape:
  `build/bin/nvim -n -u NONE -i NONE --noplugin --headless`

Median timings from warmed-cache runs:

| Case | Median |
| --- | ---: |
| Neovim mmap open/index internal timer | 0.631 s |
| Neovim process open/quit wall time | about 1.10 s |
| `:vimgrep /zzzzzz/ %` no match | 1.148 s |
| `5000vimgrep /avx/ %` bounded frequent match | 0.843 s |
| standalone `logviewer` index, 32 threads | 0.553 s |

After adding the mmap piece-tree search path, another warmed-cache comparison
was run against `../panic.txt`, a symlink to the same 20 GiB log file:

| Case | Open/index | Edit | Search |
| --- | ---: | ---: | ---: |
| pristine raw mmap `:vimgrep /zzzzzz/ %` no match | 0.414-0.421 s | n/a | 0.329-0.335 s |
| edited piece tree `:vimgrep /zzzzzz/ %` no match | 0.402-0.435 s | ~0.00002 s | 0.326-0.330 s |
| pristine raw mmap `5000vimgrep /avx/ %` | 0.409-0.412 s | n/a | 0.117-0.120 s |
| edited piece tree `5000vimgrep /avx/ %` | 0.412-0.419 s | ~0.00002 s | 0.118-0.119 s |
| edited piece tree after 10,000 distributed line replacements, `5000vimgrep /avx/ %` | 0.421 s | 3.390 s | 0.124 s |
| edited piece tree after 10,000 distributed line replacements, `:vimgrep /zzzzzz/ %` no match | 0.419 s | 3.416 s | 0.336 s |

Before the piece-span no-match prefilter, the edited no-match search took about
3.76 s on the same warmed file because it used the streaming matcher over every
byte. The prefilter brings the no-match case back into the raw mmap range.
The vector within-span scanner plus successful bounded-stop handling reduced
the bounded frequent edited search from about 1.73 s to about 0.12 s, matching
the raw mmap range in this benchmark.
The fragmented runs created about 20,001 active piece nodes. Search stayed in
the same range as the lightly edited case; the cost was the edit workload that
created the fragmentation.

After adding the guarded piece-span writer, a 20 GiB edited-buffer smoke wrote
to `/dev/null` in about 0.72 s:

```text
nvim -n -u NONE -i NONE --noplugin --headless ../panic.txt
:call append("$", "mmap write smoke")
:write! /dev/null
```

The buffer still reported `mmap_active=true`, `mmap_piece_tree=true`,
`mmap_piece_revision=1`, `mmap_piece_add_len=17`, and
`mmap_piece_write_fast_count=1` after the write. This validates the fast span
path and avoids a 20 GiB output allocation, but it is not a real
storage-throughput benchmark because `/dev/null` discards the stream.

The internal open timer measures the mmap read/index path. Process wall time
also includes Neovim startup, command execution, teardown, and unmapping.

`perf` showed the open path dominated by:

```text
readfile_mmap_scan_block_ascii_avx512bw
```

That is expected. The remaining gap to logviewer is mostly that Neovim is doing
more validation work: ASCII high-bit detection, NUL rejection, CR rejection,
line length checking, line count limits, sparse-index construction, and
integration with memline.

## Experiments not included

### 256-byte AVX512 unroll

The logviewer kernel processes four AVX512 vectors per loop. We tried a similar
256-byte unroll in Neovim's 4 KiB block scanner while preserving the extra
validation checks.

Result on the 20 GiB file:

- previous open median: about 0.631 s
- unrolled scanner median: about 0.635 s

It was noise-to-slightly-worse on this CPU, so it was reverted.

### Persistent per-4KiB cumulative block index

We also tried storing logviewer-style block metadata in memline: newline counts
per 4 KiB block plus sparse cumulative checkpoints. This helped a sparse
last-line literal search slightly:

| Case | Median |
| --- | ---: |
| existing sparse line-start index | 1.220 s |
| added block index | 1.195 s |

But it regressed open time:

| Case | Median |
| --- | ---: |
| existing sparse line-start index | about 0.631 s |
| added block index | about 0.669 s |

The reason is straightforward: the block index adds persistent memory writes
for every 4 KiB block. On the measured workload that cost more during open than
it saved during sparse search. It is not in the checkpoint.

A better future version might build a block index lazily after open, only after
the user starts sparse navigation/search workflows where it pays for itself.

## Current limitations

- The fast parallel scanner is ASCII-only. Non-ASCII UTF-8 falls back to scalar
  UTF-8 validation/counting before installing mmap lines.
- Files containing CR bytes are rejected by the mmap path and handled by the old
  reader. This avoids changing CRLF/Mac behavior.
- Files containing NUL bytes are rejected by the mmap path.
- BOM-prefixed files are rejected by the mmap path.
- Common no-swap line edits stay mmap-backed through the piece tree. Unsupported
  edit shapes and swap-enabled edits still materialize the whole file into
  normal memline, which can be expensive for a very large file.
- `:vimgrep` acceleration applies only to simple case-sensitive literal UTF-8
  patterns.
- Dense unbounded searches intentionally fall back rather than building very
  large temporary match arrays.
- The sparse line-start index means byte-to-line and line-to-byte conversions
  may scan forward within a 4096-line window.
- mmap is Unix-only in this checkpoint.
- The implementation has focused tests and targeted large-file benchmarks, not
  a full proof across every Neovim workflow.

## Verification run during the checkpoint

The following checks passed before the checkpoint commit:

```sh
cmake --build build
git diff --check
TEST_FILE=test/functional/core/fileio_spec.lua cmake --build build --target functionaltest
TEST_FILE=test/functional/ex_cmds/quickfix_commands_spec.lua cmake --build build --target functionaltest
```

Additional focused checks also passed during development:

```sh
TEST_FILE=test/functional/ex_cmds/grep_spec.lua cmake --build build --target functionaltest
TEST_FILE=test/functional/api/buffer_spec.lua cmake --build build --target functionaltest
```

Functional tests should be run sequentially from this build tree. Running
multiple functional test targets in parallel caused shared `build/Xtest_*`
directory interference and produced bogus failures.

## Benchmark commands

Open/index:

```sh
build/bin/nvim -n -u NONE -i NONE --noplugin --headless \
  --cmd 'let g:start = reltime()' ../logview/paniclog.txt \
  -c "echo line('$') reltimefloat(reltime(g:start))" \
  -c 'qa!'
```

No-match literal search:

```sh
build/bin/nvim -n -u NONE -i NONE --noplugin --headless \
  --cmd 'let g:start = reltime()' ../logview/paniclog.txt \
  -c 'silent! vimgrep /zzzzzz/ %' \
  -c "echo len(getqflist()) reltimefloat(reltime(g:start))" \
  -c 'qa!'
```

Bounded frequent literal search:

```sh
build/bin/nvim -n -u NONE -i NONE --noplugin --headless \
  --cmd 'let g:start = reltime()' ../logview/paniclog.txt \
  -c 'silent! 5000vimgrep /avx/ %' \
  -c "echo len(getqflist()) reltimefloat(reltime(g:start))" \
  -c 'qa!'
```

Standalone logviewer comparison:

```sh
timeout 8s bash -c \
  'stdbuf -oL ../logview/logviewer ../logview/paniclog.txt 32 < <(sleep 30)'
```

## Future work

- Explore a lazy optional 4 KiB block line index for sparse navigation/search
  after open, instead of building it unconditionally during open.
- Explore a trusted newline-only mode if the UX/API can make the weaker
  validation contract explicit.
- Improve non-ASCII UTF-8 scanning with parallel validation instead of scalar
  fallback.
- Investigate page hints such as `MADV_WILLNEED` and `MADV_HUGEPAGE` with
  careful before/after measurements.
- Add more tests for edge cases: invalid UTF-8, BOM, CRLF, huge no-final-EOL
  files, materialization failure paths, and quickfix interruption.
- Consider broader quickfix/search integration for other literal-like patterns
  after the current path is stable.
- Revisit dense match handling with streaming quickfix insertion if quickfix can
  safely consume results incrementally without large temporary arrays.
