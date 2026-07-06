#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef enum {
  kPieceTreeSourceOriginal = 0,
  kPieceTreeSourceAdd = 1,
} PieceTreeSource;

typedef struct piece_tree_node PieceTreeNode;
typedef struct piece_tree_node_block PieceTreeNodeBlock;
typedef struct piece_tree_add_chunk PieceTreeAddChunk;
#ifndef NVIM_PIECE_TREE_TYPEDEF
# define NVIM_PIECE_TREE_TYPEDEF
typedef struct piece_tree PieceTree;
#endif
typedef struct {
  const char *data;
  size_t len;
  size_t offset;
  PieceTreeSource source;
  size_t source_start;
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
typedef bool (*PieceTreeSpanCallback)(const char *data, size_t len, void *ctx);
typedef bool (*PieceTreeMatchCallback)(size_t offset, void *ctx);

struct piece_tree {
  const char *original;
  size_t original_len;
  const size_t *original_line_starts;
  size_t original_index_count;
  size_t original_index_stride;

  size_t add_len;
  size_t add_cap;
  PieceTreeAddChunk *add_chunks;
  PieceTreeAddChunk *add_tail;

  PieceTreeNode *root;
  PieceTreeNodeBlock *node_blocks;
  PieceTreeNode *free_nodes;
  PieceTreeNode *retired_nodes;
  size_t node_count;
  size_t node_capacity;
  size_t retired_node_count;
  size_t reader_count;
  size_t span_ref_count;
  uint64_t revision;
};

#include "piece_tree.h.generated.h"
