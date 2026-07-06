#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef enum {
  kPieceJournalDecodeOK = 0,
  kPieceJournalDecodeIncomplete = 1,
  kPieceJournalDecodeCorrupt = 2,
} PieceJournalDecodeResult;

typedef enum {
  kPieceJournalOpInsert = 1,
  kPieceJournalOpDelete = 2,
  kPieceJournalOpReplace = 3,
} PieceJournalOp;

enum {
  PIECE_JOURNAL_VERSION = 1,
  PIECE_JOURNAL_FLAG_NOEOL = 1,
};

typedef struct {
  const char *path;
  size_t path_len;
  uint64_t original_dev;
  uint64_t original_ino;
  uint64_t original_size;
  uint64_t original_mtime_sec;
  uint64_t original_mtime_nsec;
  uint64_t text_size;
  uint64_t line_count;
  uint32_t flags;
} PieceJournalHeader;

typedef struct {
  PieceJournalOp op;
  uint64_t revision;
  uint64_t offset;
  uint64_t delete_len;
  uint64_t insert_len;
  uint64_t text_size_after;
  uint64_t line_count_after;
  uint32_t flags_after;
  const char *insert_text;
} PieceJournalRecord;

#include "piece_journal.h.generated.h"
