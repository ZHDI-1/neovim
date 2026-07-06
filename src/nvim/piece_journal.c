#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "nvim/piece_journal.h"

#include "piece_journal.c.generated.h"

enum {
  kPieceJournalHeaderSize = 88,
  kPieceJournalRecordSize = 80,
  kPieceJournalChecksumOffset = 72,
  kPieceJournalCommitSize = 8,
};

static const char kPieceJournalHeaderMagic[8] = { 'N', 'V', 'M', 'P', 'J', 'H', '1', '\0' };
static const char kPieceJournalRecordMagic[8] = { 'N', 'V', 'M', 'P', 'J', 'R', '1', '\0' };
static const char kPieceJournalCommitMagic[8] = { 'N', 'V', 'M', 'P', 'J', 'C', '1', '\0' };

static void pj_put_u32(char *dst, uint32_t value)
{
  dst[0] = (char)value;
  dst[1] = (char)(value >> 8);
  dst[2] = (char)(value >> 16);
  dst[3] = (char)(value >> 24);
}

static uint32_t pj_get_u32(const char *src)
{
  const uint8_t *p = (const uint8_t *)src;
  return (uint32_t)p[0]
         | ((uint32_t)p[1] << 8)
         | ((uint32_t)p[2] << 16)
         | ((uint32_t)p[3] << 24);
}

static void pj_put_u64(char *dst, uint64_t value)
{
  for (size_t i = 0; i < 8; i++) {
    dst[i] = (char)(value >> (i * 8));
  }
}

static uint64_t pj_get_u64(const char *src)
{
  const uint8_t *p = (const uint8_t *)src;
  uint64_t value = 0;
  for (size_t i = 0; i < 8; i++) {
    value |= (uint64_t)p[i] << (i * 8);
  }
  return value;
}

static uint64_t pj_checksum_update(uint64_t hash, const char *data, size_t len)
{
  const uint8_t *p = (const uint8_t *)data;
  for (size_t i = 0; i < len; i++) {
    hash ^= (uint64_t)p[i];
    hash *= UINT64_C(1099511628211);
  }
  return hash;
}

static uint64_t pj_checksum_with_zero_field(const char *header, size_t header_len,
                                            const char *payload, size_t payload_len)
{
  uint64_t hash = UINT64_C(1469598103934665603);
  hash = pj_checksum_update(hash, header, kPieceJournalChecksumOffset);
  static const char zero_checksum[8] = { 0 };
  hash = pj_checksum_update(hash, zero_checksum, sizeof zero_checksum);
  hash = pj_checksum_update(hash, header + kPieceJournalChecksumOffset + 8,
                            header_len - kPieceJournalChecksumOffset - 8);
  hash = pj_checksum_update(hash, payload, payload_len);
  hash = pj_checksum_update(hash, kPieceJournalCommitMagic, sizeof kPieceJournalCommitMagic);
  return hash;
}

static bool pj_checked_total_size(size_t fixed_len, size_t payload_len, size_t *sizep)
{
  if (payload_len > SIZE_MAX - fixed_len
      || payload_len + fixed_len > SIZE_MAX - kPieceJournalCommitSize) {
    return false;
  }
  *sizep = fixed_len + payload_len + kPieceJournalCommitSize;
  return true;
}

static bool pj_header_valid(const PieceJournalHeader *header)
{
  return header != NULL
         && (header->path_len == 0 || header->path != NULL)
         && header->path_len <= UINT32_MAX
         && header->line_count > 0;
}

size_t piece_journal_header_encoded_size(const PieceJournalHeader *header)
{
  if (!pj_header_valid(header)) {
    return 0;
  }

  size_t size = 0;
  return pj_checked_total_size(kPieceJournalHeaderSize, header->path_len, &size) ? size : 0;
}

bool piece_journal_header_encode(const PieceJournalHeader *header, char *dst, size_t dst_len,
                                 size_t *writtenp)
{
  const size_t size = piece_journal_header_encoded_size(header);
  if (size == 0 || dst == NULL || dst_len < size) {
    return false;
  }

  memset(dst, 0, size);
  memcpy(dst, kPieceJournalHeaderMagic, sizeof kPieceJournalHeaderMagic);
  pj_put_u32(dst + 8, PIECE_JOURNAL_VERSION);
  pj_put_u32(dst + 12, kPieceJournalHeaderSize);
  pj_put_u32(dst + 16, header->flags);
  pj_put_u32(dst + 20, (uint32_t)header->path_len);
  pj_put_u64(dst + 24, header->original_dev);
  pj_put_u64(dst + 32, header->original_ino);
  pj_put_u64(dst + 40, header->original_size);
  pj_put_u64(dst + 48, header->original_mtime_sec);
  pj_put_u64(dst + 56, header->original_mtime_nsec);
  pj_put_u64(dst + 64, header->text_size);
  pj_put_u64(dst + 80, header->line_count);

  if (header->path_len > 0) {
    memcpy(dst + kPieceJournalHeaderSize, header->path, header->path_len);
  }
  memcpy(dst + kPieceJournalHeaderSize + header->path_len, kPieceJournalCommitMagic,
         sizeof kPieceJournalCommitMagic);
  const uint64_t checksum = pj_checksum_with_zero_field(dst, kPieceJournalHeaderSize,
                                                        dst + kPieceJournalHeaderSize,
                                                        header->path_len);
  pj_put_u64(dst + kPieceJournalChecksumOffset, checksum);

  if (writtenp != NULL) {
    *writtenp = size;
  }
  return true;
}

PieceJournalDecodeResult piece_journal_header_decode(const char *src, size_t src_len,
                                                     PieceJournalHeader *headerp,
                                                     size_t *consumedp)
{
  if (src_len < kPieceJournalHeaderSize) {
    return kPieceJournalDecodeIncomplete;
  }
  if (src == NULL
      || memcmp(src, kPieceJournalHeaderMagic, sizeof kPieceJournalHeaderMagic) != 0
      || pj_get_u32(src + 8) != PIECE_JOURNAL_VERSION
      || pj_get_u32(src + 12) != kPieceJournalHeaderSize) {
    return kPieceJournalDecodeCorrupt;
  }

  const uint32_t path_len32 = pj_get_u32(src + 20);
  size_t size = 0;
  if (!pj_checked_total_size(kPieceJournalHeaderSize, (size_t)path_len32, &size)) {
    return kPieceJournalDecodeCorrupt;
  }
  if (src_len < size) {
    return kPieceJournalDecodeIncomplete;
  }
  if (memcmp(src + kPieceJournalHeaderSize + path_len32, kPieceJournalCommitMagic,
             sizeof kPieceJournalCommitMagic) != 0) {
    return kPieceJournalDecodeCorrupt;
  }

  const uint64_t checksum = pj_get_u64(src + kPieceJournalChecksumOffset);
  const uint64_t expected = pj_checksum_with_zero_field(src, kPieceJournalHeaderSize,
                                                        src + kPieceJournalHeaderSize,
                                                        path_len32);
  if (checksum != expected) {
    return kPieceJournalDecodeCorrupt;
  }

  if (headerp != NULL) {
    *headerp = (PieceJournalHeader){
      .path = src + kPieceJournalHeaderSize,
      .path_len = path_len32,
      .original_dev = pj_get_u64(src + 24),
      .original_ino = pj_get_u64(src + 32),
      .original_size = pj_get_u64(src + 40),
      .original_mtime_sec = pj_get_u64(src + 48),
      .original_mtime_nsec = pj_get_u64(src + 56),
      .text_size = pj_get_u64(src + 64),
      .line_count = pj_get_u64(src + 80),
      .flags = pj_get_u32(src + 16),
    };
  }
  if (consumedp != NULL) {
    *consumedp = size;
  }
  return kPieceJournalDecodeOK;
}

static bool pj_record_valid(const PieceJournalRecord *record)
{
  if (record == NULL || record->revision == 0 || record->line_count_after == 0
      || record->insert_len > SIZE_MAX
      || (record->insert_len > 0 && record->insert_text == NULL)) {
    return false;
  }

  switch (record->op) {
  case kPieceJournalOpInsert:
    return record->delete_len == 0 && record->insert_len > 0;
  case kPieceJournalOpDelete:
    return record->delete_len > 0 && record->insert_len == 0;
  case kPieceJournalOpReplace:
    return record->delete_len > 0;
  }
  return false;
}

size_t piece_journal_record_encoded_size(const PieceJournalRecord *record)
{
  if (!pj_record_valid(record)) {
    return 0;
  }

  size_t size = 0;
  return pj_checked_total_size(kPieceJournalRecordSize, (size_t)record->insert_len, &size)
         ? size : 0;
}

bool piece_journal_record_encode(const PieceJournalRecord *record, char *dst, size_t dst_len,
                                 size_t *writtenp)
{
  const size_t size = piece_journal_record_encoded_size(record);
  if (size == 0 || dst == NULL || dst_len < size) {
    return false;
  }

  memset(dst, 0, size);
  memcpy(dst, kPieceJournalRecordMagic, sizeof kPieceJournalRecordMagic);
  pj_put_u32(dst + 8, PIECE_JOURNAL_VERSION);
  pj_put_u32(dst + 12, kPieceJournalRecordSize);
  pj_put_u32(dst + 16, (uint32_t)record->op);
  pj_put_u32(dst + 20, record->flags_after);
  pj_put_u64(dst + 24, record->revision);
  pj_put_u64(dst + 32, record->offset);
  pj_put_u64(dst + 40, record->delete_len);
  pj_put_u64(dst + 48, record->insert_len);
  pj_put_u64(dst + 56, record->text_size_after);
  pj_put_u64(dst + 64, record->line_count_after);

  if (record->insert_len > 0) {
    memcpy(dst + kPieceJournalRecordSize, record->insert_text, (size_t)record->insert_len);
  }
  memcpy(dst + kPieceJournalRecordSize + record->insert_len, kPieceJournalCommitMagic,
         sizeof kPieceJournalCommitMagic);
  const uint64_t checksum = pj_checksum_with_zero_field(dst, kPieceJournalRecordSize,
                                                        dst + kPieceJournalRecordSize,
                                                        (size_t)record->insert_len);
  pj_put_u64(dst + kPieceJournalChecksumOffset, checksum);

  if (writtenp != NULL) {
    *writtenp = size;
  }
  return true;
}

PieceJournalDecodeResult piece_journal_record_decode(const char *src, size_t src_len,
                                                     PieceJournalRecord *recordp,
                                                     size_t *consumedp)
{
  if (src_len < kPieceJournalRecordSize) {
    return kPieceJournalDecodeIncomplete;
  }
  if (src == NULL
      || memcmp(src, kPieceJournalRecordMagic, sizeof kPieceJournalRecordMagic) != 0
      || pj_get_u32(src + 8) != PIECE_JOURNAL_VERSION
      || pj_get_u32(src + 12) != kPieceJournalRecordSize) {
    return kPieceJournalDecodeCorrupt;
  }

  const uint64_t insert_len = pj_get_u64(src + 48);
  if (insert_len > SIZE_MAX) {
    return kPieceJournalDecodeCorrupt;
  }
  size_t size = 0;
  if (!pj_checked_total_size(kPieceJournalRecordSize, (size_t)insert_len, &size)) {
    return kPieceJournalDecodeCorrupt;
  }
  if (src_len < size) {
    return kPieceJournalDecodeIncomplete;
  }
  if (memcmp(src + kPieceJournalRecordSize + insert_len, kPieceJournalCommitMagic,
             sizeof kPieceJournalCommitMagic) != 0) {
    return kPieceJournalDecodeCorrupt;
  }

  const uint64_t checksum = pj_get_u64(src + kPieceJournalChecksumOffset);
  const uint64_t expected = pj_checksum_with_zero_field(src, kPieceJournalRecordSize,
                                                        src + kPieceJournalRecordSize,
                                                        (size_t)insert_len);
  if (checksum != expected) {
    return kPieceJournalDecodeCorrupt;
  }

  PieceJournalRecord record = {
    .op = (PieceJournalOp)pj_get_u32(src + 16),
    .revision = pj_get_u64(src + 24),
    .offset = pj_get_u64(src + 32),
    .delete_len = pj_get_u64(src + 40),
    .insert_len = insert_len,
    .text_size_after = pj_get_u64(src + 56),
    .line_count_after = pj_get_u64(src + 64),
    .flags_after = pj_get_u32(src + 20),
    .insert_text = insert_len == 0 ? NULL : src + kPieceJournalRecordSize,
  };
  if (!pj_record_valid(&record)) {
    return kPieceJournalDecodeCorrupt;
  }

  if (recordp != NULL) {
    *recordp = record;
  }
  if (consumedp != NULL) {
    *consumedp = size;
  }
  return kPieceJournalDecodeOK;
}
