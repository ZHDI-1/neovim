#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "nvim/macros_defs.h"
#include "nvim/memory.h"
#include "nvim/piece_tree.h"

struct piece_tree_node {
  PieceTreeSource source;
  PieceTreeAddChunk *add_chunk;
  size_t start;
  size_t len;
  size_t lf_count;

  size_t subtree_bytes;
  size_t subtree_lfs;

  PieceTreeNode *left;
  PieceTreeNode *right;
  PieceTreeNode *parent;
  PieceTreeNode *next_free;
  bool red;
};

struct piece_tree_node_block {
  PieceTreeNodeBlock *next;
  size_t used;
  size_t capacity;
  PieceTreeNode nodes[];
};

struct piece_tree_add_chunk {
  PieceTreeAddChunk *next;
  size_t start;
  size_t len;
  size_t cap;
  char data[];
};

typedef struct {
  bool ok;
  int black_height;
  size_t node_count;
} PieceTreeCheckResult;

enum {
  PT_NODE_BLOCK_CAPACITY = 256,
  PT_ADD_CHUNK_MIN_CAPACITY = 4096,
  PT_ADD_CHUNK_MAX_CAPACITY = 1024 * 1024,
};

#include "piece_tree.c.generated.h"

static size_t pt_reader_count_load(const PieceTree *tree);
static size_t pt_span_ref_count_load(const PieceTree *tree);
static size_t pt_reclaim_retired_nodes(PieceTree *tree, size_t budget);

static size_t pt_count_lfs(const char *data, size_t len)
{
  if (len == 0) {
    return 0;
  }

  size_t count = 0;
  const char *p = data;
  const char *const end = data + len;

  while (p < end) {
    const char *nl = memchr(p, '\n', (size_t)(end - p));
    if (nl == NULL) {
      break;
    }
    count++;
    p = nl + 1;
  }
  return count;
}

static bool pt_find_nth_lf_in_data(const char *data, size_t len, size_t nth, size_t *posp)
{
  if (len == 0 || nth == 0) {
    return false;
  }

  const char *p = data;
  const char *const end = data + len;

  while (p < end) {
    const char *nl = memchr(p, '\n', (size_t)(end - p));
    if (nl == NULL) {
      return false;
    }
    nth--;
    if (nth == 0) {
      *posp = (size_t)(nl - data);
      return true;
    }
    p = nl + 1;
  }
  return false;
}

static bool pt_has_original_index(const PieceTree *tree)
{
  return tree->original_line_starts != NULL
         && tree->original_index_count > 0
         && tree->original_index_stride > 0;
}

static size_t pt_original_index_for_offset(const PieceTree *tree, size_t offset)
{
  size_t low = 0;
  size_t high = tree->original_index_count - 1;

  while (low < high) {
    const size_t mid = low + (high - low + 1) / 2;
    if (tree->original_line_starts[mid] <= offset) {
      low = mid;
    } else {
      high = mid - 1;
    }
  }
  return low;
}

static size_t pt_original_lfs_before_offset(const PieceTree *tree, size_t offset)
{
  if (offset > tree->original_len) {
    offset = tree->original_len;
  }
  if (offset == 0) {
    return 0;
  }
  if (!pt_has_original_index(tree)) {
    return pt_count_lfs(tree->original, offset);
  }

  size_t index = pt_original_index_for_offset(tree, offset);
  size_t scan_start = tree->original_line_starts[index];
  if (scan_start > offset) {
    index = 0;
    scan_start = 0;
  }

  return index * tree->original_index_stride
         + pt_count_lfs(tree->original + scan_start, offset - scan_start);
}

static bool pt_find_original_lf_by_rank(const PieceTree *tree, size_t rank, size_t *posp)
{
  if (rank == 0) {
    return false;
  }
  if (!pt_has_original_index(tree)) {
    return pt_find_nth_lf_in_data(tree->original, tree->original_len, rank, posp);
  }

  size_t index = (rank - 1) / tree->original_index_stride;
  if (index >= tree->original_index_count) {
    index = tree->original_index_count - 1;
  }

  size_t scan_start = tree->original_line_starts[index];
  size_t lfs_before = index * tree->original_index_stride;
  if (scan_start > tree->original_len || lfs_before >= rank) {
    scan_start = 0;
    lfs_before = 0;
  }

  size_t local_pos = 0;
  if (!pt_find_nth_lf_in_data(tree->original + scan_start, tree->original_len - scan_start,
                              rank - lfs_before, &local_pos)) {
    return false;
  }
  *posp = scan_start + local_pos;
  return true;
}

static const char *pt_add_chunk_data(const PieceTreeAddChunk *chunk, size_t start, size_t len)
{
  if (chunk == NULL || start < chunk->start) {
    return NULL;
  }
  const size_t chunk_offset = start - chunk->start;
  if (chunk_offset > chunk->len || len > chunk->len - chunk_offset) {
    return NULL;
  }
  return chunk->data + chunk_offset;
}

static bool pt_find_nth_lf_in_range(const PieceTree *tree, PieceTreeSource source,
                                    const PieceTreeAddChunk *add_chunk, size_t start,
                                    size_t len, size_t nth, size_t *posp)
{
  if (source != kPieceTreeSourceOriginal) {
    const char *data = pt_add_chunk_data(add_chunk, start, len);
    return data != NULL && pt_find_nth_lf_in_data(data, len, nth, posp);
  }
  if (!pt_has_original_index(tree)) {
    return pt_find_nth_lf_in_data(tree->original + start, len, nth, posp);
  }

  const size_t lfs_before = pt_original_lfs_before_offset(tree, start);
  size_t source_pos = 0;
  if (!pt_find_original_lf_by_rank(tree, lfs_before + nth, &source_pos)) {
    return false;
  }
  if (source_pos < start || source_pos - start >= len) {
    return false;
  }
  *posp = source_pos - start;
  return true;
}

static const char *pt_node_data(const PieceTree *tree, const PieceTreeNode *node)
{
  if (node->source == kPieceTreeSourceOriginal) {
    return tree->original + node->start;
  }
  return pt_add_chunk_data(node->add_chunk, node->start, node->len);
}

static size_t pt_range_lfs(const PieceTree *tree, PieceTreeSource source,
                           const PieceTreeAddChunk *add_chunk, size_t start, size_t len)
{
  if (source == kPieceTreeSourceOriginal && pt_has_original_index(tree)) {
    return pt_original_lfs_before_offset(tree, start + len)
           - pt_original_lfs_before_offset(tree, start);
  }

  const char *data = source == kPieceTreeSourceOriginal
                     ? tree->original + start
                     : pt_add_chunk_data(add_chunk, start, len);
  return data == NULL ? 0 : pt_count_lfs(data, len);
}

static size_t pt_bytes(const PieceTreeNode *node)
{
  return node == NULL ? 0 : node->subtree_bytes;
}

static size_t pt_lfs(const PieceTreeNode *node)
{
  return node == NULL ? 0 : node->subtree_lfs;
}

static void pt_update(PieceTreeNode *node)
{
  if (node == NULL) {
    return;
  }

  node->subtree_bytes = pt_bytes(node->left) + node->len + pt_bytes(node->right);
  node->subtree_lfs = pt_lfs(node->left) + node->lf_count + pt_lfs(node->right);
}

static void pt_update_upwards(PieceTreeNode *node)
{
  while (node != NULL) {
    pt_update(node);
    node = node->parent;
  }
}

static void pt_add_node_block(PieceTree *tree)
{
  assert(PT_NODE_BLOCK_CAPACITY <= (SIZE_MAX - sizeof(PieceTreeNodeBlock))
         / sizeof(PieceTreeNode));
  assert(tree->node_capacity <= SIZE_MAX - PT_NODE_BLOCK_CAPACITY);

  const size_t alloc_size = sizeof(PieceTreeNodeBlock)
                            + PT_NODE_BLOCK_CAPACITY * sizeof(PieceTreeNode);
  PieceTreeNodeBlock *block = xmalloc(alloc_size);
  block->next = tree->node_blocks;
  block->used = 0;
  block->capacity = PT_NODE_BLOCK_CAPACITY;
  tree->node_blocks = block;

  tree->node_capacity += PT_NODE_BLOCK_CAPACITY;
}

static PieceTreeNode *pt_alloc_node(PieceTree *tree)
{
  enum { kReclaimBudget = 64 };

  if (tree->free_nodes == NULL && tree->retired_nodes != NULL
      && pt_reader_count_load(tree) == 0) {
    (void)pt_reclaim_retired_nodes(tree, kReclaimBudget);
  }

  if (tree->free_nodes != NULL) {
    PieceTreeNode *node = tree->free_nodes;
    tree->free_nodes = node->next_free;
    return node;
  }

  if (tree->node_blocks == NULL || tree->node_blocks->used == tree->node_blocks->capacity) {
    pt_add_node_block(tree);
  }

  return &tree->node_blocks->nodes[tree->node_blocks->used++];
}

static size_t pt_reader_count_load(const PieceTree *tree)
{
  return __atomic_load_n(&tree->reader_count, __ATOMIC_ACQUIRE);
}

static void pt_reader_count_increment(PieceTree *tree)
{
  size_t old = pt_reader_count_load(tree);
  for (;;) {
    assert(old < SIZE_MAX);
    if (old == SIZE_MAX) {
      return;
    }
    const size_t new_count = old + 1;
    if (__atomic_compare_exchange_n(&tree->reader_count, &old, new_count, false,
                                    __ATOMIC_ACQUIRE, __ATOMIC_ACQUIRE)) {
      return;
    }
  }
}

static size_t pt_reader_count_decrement(PieceTree *tree)
{
  const size_t old = __atomic_load_n(&tree->reader_count, __ATOMIC_ACQUIRE);
  assert(old > 0);
  if (old == 0) {
    return 0;
  }

  const size_t remaining = __atomic_sub_fetch(&tree->reader_count, 1, __ATOMIC_RELEASE);
  if (remaining == 0) {
    __atomic_thread_fence(__ATOMIC_ACQUIRE);
  }
  return remaining;
}

static size_t pt_span_ref_count_load(const PieceTree *tree)
{
  return __atomic_load_n(&tree->span_ref_count, __ATOMIC_ACQUIRE);
}

static void pt_span_ref_count_increment(PieceTree *tree)
{
  size_t old = pt_span_ref_count_load(tree);
  for (;;) {
    assert(old < SIZE_MAX);
    if (old == SIZE_MAX) {
      return;
    }
    const size_t new_count = old + 1;
    if (__atomic_compare_exchange_n(&tree->span_ref_count, &old, new_count, false,
                                    __ATOMIC_ACQUIRE, __ATOMIC_ACQUIRE)) {
      return;
    }
  }
}

static void pt_span_ref_count_decrement(PieceTree *tree)
{
  const size_t old = __atomic_load_n(&tree->span_ref_count, __ATOMIC_ACQUIRE);
  assert(old > 0);
  if (old == 0) {
    return;
  }

  const size_t remaining = __atomic_sub_fetch(&tree->span_ref_count, 1, __ATOMIC_RELEASE);
  if (remaining == 0) {
    __atomic_thread_fence(__ATOMIC_ACQUIRE);
  }
}

static void pt_recycle_node(PieceTree *tree, PieceTreeNode *node)
{
  memset(node, 0, sizeof *node);
  node->next_free = tree->free_nodes;
  tree->free_nodes = node;
}

static size_t pt_reclaim_retired_nodes(PieceTree *tree, size_t budget)
{
  size_t reclaimed = 0;
  while (tree->retired_nodes != NULL && reclaimed < budget) {
    PieceTreeNode *node = tree->retired_nodes;
    tree->retired_nodes = node->next_free;
    assert(tree->retired_node_count > 0);
    tree->retired_node_count--;
    pt_recycle_node(tree, node);
    reclaimed++;
  }
  return reclaimed;
}

static void pt_retire_node(PieceTree *tree, PieceTreeNode *node)
{
  if (pt_reader_count_load(tree) == 0) {
    pt_recycle_node(tree, node);
    return;
  }

  node->next_free = tree->retired_nodes;
  tree->retired_nodes = node;
  tree->retired_node_count++;
}

static PieceTreeNode *pt_new_node(PieceTree *tree, PieceTreeSource source,
                                  PieceTreeAddChunk *add_chunk, size_t start, size_t len,
                                  size_t lf_count)
{
  PieceTreeNode *node = pt_alloc_node(tree);
  memset(node, 0, sizeof *node);
  node->source = source;
  node->add_chunk = add_chunk;
  node->start = start;
  node->len = len;
  node->lf_count = lf_count;
  node->subtree_bytes = len;
  node->subtree_lfs = lf_count;
  node->red = true;
  return node;
}

static PieceTreeNode *pt_minimum(PieceTreeNode *node)
{
  if (node == NULL) {
    return NULL;
  }
  while (node->left != NULL) {
    node = node->left;
  }
  return node;
}

static PieceTreeNode *pt_maximum(PieceTreeNode *node)
{
  if (node == NULL) {
    return NULL;
  }
  while (node->right != NULL) {
    node = node->right;
  }
  return node;
}

static PieceTreeNode *pt_successor(PieceTreeNode *node)
{
  if (node == NULL) {
    return NULL;
  }
  if (node->right != NULL) {
    return pt_minimum(node->right);
  }
  PieceTreeNode *parent = node->parent;
  while (parent != NULL && node == parent->right) {
    node = parent;
    parent = parent->parent;
  }
  return parent;
}

static PieceTreeNode *pt_predecessor(PieceTreeNode *node)
{
  if (node == NULL) {
    return NULL;
  }
  if (node->left != NULL) {
    return pt_maximum(node->left);
  }
  PieceTreeNode *parent = node->parent;
  while (parent != NULL && node == parent->left) {
    node = parent;
    parent = parent->parent;
  }
  return parent;
}

static bool pt_is_red(const PieceTreeNode *node)
{
  return node != NULL && node->red;
}

static void pt_rotate_left(PieceTree *tree, PieceTreeNode *node)
{
  PieceTreeNode *right = node->right;
  assert(right != NULL);

  node->right = right->left;
  if (right->left != NULL) {
    right->left->parent = node;
  }

  right->parent = node->parent;
  if (node->parent == NULL) {
    tree->root = right;
  } else if (node == node->parent->left) {
    node->parent->left = right;
  } else {
    node->parent->right = right;
  }

  right->left = node;
  node->parent = right;

  pt_update(node);
  pt_update(right);
  pt_update_upwards(right->parent);
}

static void pt_rotate_right(PieceTree *tree, PieceTreeNode *node)
{
  PieceTreeNode *left = node->left;
  assert(left != NULL);

  node->left = left->right;
  if (left->right != NULL) {
    left->right->parent = node;
  }

  left->parent = node->parent;
  if (node->parent == NULL) {
    tree->root = left;
  } else if (node == node->parent->right) {
    node->parent->right = left;
  } else {
    node->parent->left = left;
  }

  left->right = node;
  node->parent = left;

  pt_update(node);
  pt_update(left);
  pt_update_upwards(left->parent);
}

static void pt_insert_fixup(PieceTree *tree, PieceTreeNode *node)
{
  while (pt_is_red(node->parent)) {
    PieceTreeNode *parent = node->parent;
    PieceTreeNode *grandparent = parent->parent;
    if (parent == grandparent->left) {
      PieceTreeNode *uncle = grandparent->right;
      if (pt_is_red(uncle)) {
        parent->red = false;
        uncle->red = false;
        grandparent->red = true;
        node = grandparent;
      } else {
        if (node == parent->right) {
          node = parent;
          pt_rotate_left(tree, node);
          parent = node->parent;
          grandparent = parent->parent;
        }
        parent->red = false;
        grandparent->red = true;
        pt_rotate_right(tree, grandparent);
      }
    } else {
      PieceTreeNode *uncle = grandparent->left;
      if (pt_is_red(uncle)) {
        parent->red = false;
        uncle->red = false;
        grandparent->red = true;
        node = grandparent;
      } else {
        if (node == parent->left) {
          node = parent;
          pt_rotate_right(tree, node);
          parent = node->parent;
          grandparent = parent->parent;
        }
        parent->red = false;
        grandparent->red = true;
        pt_rotate_left(tree, grandparent);
      }
    }
  }
  tree->root->red = false;
}

static void pt_attach_child(PieceTree *tree, PieceTreeNode *parent, PieceTreeNode *node,
                            bool left)
{
  node->parent = parent;
  node->left = NULL;
  node->right = NULL;
  node->red = true;
  pt_update(node);

  if (parent == NULL) {
    tree->root = node;
  } else if (left) {
    assert(parent->left == NULL);
    parent->left = node;
  } else {
    assert(parent->right == NULL);
    parent->right = node;
  }

  tree->node_count++;
  pt_update_upwards(parent);
  pt_insert_fixup(tree, node);
}

static void pt_insert_before(PieceTree *tree, PieceTreeNode *pos, PieceTreeNode *node)
{
  if (tree->root == NULL) {
    pt_attach_child(tree, NULL, node, false);
  } else if (pos == NULL) {
    PieceTreeNode *parent = pt_maximum(tree->root);
    pt_attach_child(tree, parent, node, false);
  } else if (pos->left == NULL) {
    pt_attach_child(tree, pos, node, true);
  } else {
    PieceTreeNode *parent = pt_maximum(pos->left);
    pt_attach_child(tree, parent, node, false);
  }
}

static void pt_insert_after(PieceTree *tree, PieceTreeNode *pos, PieceTreeNode *node)
{
  if (tree->root == NULL) {
    pt_attach_child(tree, NULL, node, false);
  } else if (pos == NULL) {
    PieceTreeNode *parent = pt_minimum(tree->root);
    pt_attach_child(tree, parent, node, true);
  } else if (pos->right == NULL) {
    pt_attach_child(tree, pos, node, false);
  } else {
    PieceTreeNode *parent = pt_minimum(pos->right);
    pt_attach_child(tree, parent, node, true);
  }
}

static void pt_transplant(PieceTree *tree, PieceTreeNode *old, PieceTreeNode *new)
{
  if (old->parent == NULL) {
    tree->root = new;
  } else if (old == old->parent->left) {
    old->parent->left = new;
  } else {
    old->parent->right = new;
  }
  if (new != NULL) {
    new->parent = old->parent;
  }
  pt_update_upwards(old->parent);
}

static void pt_delete_fixup(PieceTree *tree, PieceTreeNode *node, PieceTreeNode *parent)
{
  while (node != tree->root && !pt_is_red(node)) {
    if (parent == NULL) {
      break;
    }
    if (node == parent->left) {
      PieceTreeNode *sibling = parent->right;
      if (sibling == NULL) {
        node = parent;
        parent = node->parent;
        continue;
      }
      if (pt_is_red(sibling)) {
        sibling->red = false;
        parent->red = true;
        pt_rotate_left(tree, parent);
        sibling = parent->right;
      }
      if (!pt_is_red(sibling->left) && !pt_is_red(sibling->right)) {
        sibling->red = true;
        node = parent;
        parent = node->parent;
      } else {
        if (!pt_is_red(sibling->right)) {
          if (sibling->left != NULL) {
            sibling->left->red = false;
          }
          sibling->red = true;
          pt_rotate_right(tree, sibling);
          sibling = parent->right;
        }
        sibling->red = parent->red;
        parent->red = false;
        if (sibling->right != NULL) {
          sibling->right->red = false;
        }
        pt_rotate_left(tree, parent);
        node = tree->root;
        parent = NULL;
      }
    } else {
      PieceTreeNode *sibling = parent->left;
      if (sibling == NULL) {
        node = parent;
        parent = node->parent;
        continue;
      }
      if (pt_is_red(sibling)) {
        sibling->red = false;
        parent->red = true;
        pt_rotate_right(tree, parent);
        sibling = parent->left;
      }
      if (!pt_is_red(sibling->right) && !pt_is_red(sibling->left)) {
        sibling->red = true;
        node = parent;
        parent = node->parent;
      } else {
        if (!pt_is_red(sibling->left)) {
          if (sibling->right != NULL) {
            sibling->right->red = false;
          }
          sibling->red = true;
          pt_rotate_left(tree, sibling);
          sibling = parent->left;
        }
        sibling->red = parent->red;
        parent->red = false;
        if (sibling->left != NULL) {
          sibling->left->red = false;
        }
        pt_rotate_right(tree, parent);
        node = tree->root;
        parent = NULL;
      }
    }
  }
  if (node != NULL) {
    node->red = false;
  }
}

static void pt_delete_node(PieceTree *tree, PieceTreeNode *node)
{
  PieceTreeNode *replacement = NULL;
  PieceTreeNode *replacement_parent = NULL;
  PieceTreeNode *moved = node;
  const bool moved_red_initial = moved->red;

  if (node->left == NULL) {
    replacement = node->right;
    replacement_parent = node->parent;
    pt_transplant(tree, node, node->right);
  } else if (node->right == NULL) {
    replacement = node->left;
    replacement_parent = node->parent;
    pt_transplant(tree, node, node->left);
  } else {
    moved = pt_minimum(node->right);
    const bool moved_red = moved->red;
    replacement = moved->right;

    if (moved->parent == node) {
      replacement_parent = moved;
      if (replacement != NULL) {
        replacement->parent = moved;
      }
    } else {
      replacement_parent = moved->parent;
      pt_transplant(tree, moved, moved->right);
      moved->right = node->right;
      moved->right->parent = moved;
    }

    pt_transplant(tree, node, moved);
    moved->left = node->left;
    moved->left->parent = moved;
    moved->red = node->red;
    pt_update(moved);
    pt_update_upwards(moved->parent);

    if (!moved_red) {
      pt_delete_fixup(tree, replacement, replacement_parent);
    }
    pt_retire_node(tree, node);
    tree->node_count--;
    return;
  }

  if (!moved_red_initial) {
    pt_delete_fixup(tree, replacement, replacement_parent);
  }
  pt_retire_node(tree, node);
  tree->node_count--;
}

static PieceTreeNode *pt_find_node(PieceTreeNode *node, size_t offset, size_t *localp)
{
  while (node != NULL) {
    const size_t left_bytes = pt_bytes(node->left);
    if (offset < left_bytes) {
      node = node->left;
    } else if (offset < left_bytes + node->len) {
      *localp = offset - left_bytes;
      return node;
    } else {
      offset -= left_bytes + node->len;
      node = node->right;
    }
  }
  return NULL;
}

static PieceTreeNode *pt_split_at(PieceTree *tree, size_t offset)
{
  const size_t total = piece_tree_byte_len(tree);
  if (offset == total) {
    return NULL;
  }

  size_t local = 0;
  PieceTreeNode *node = pt_find_node(tree->root, offset, &local);
  assert(node != NULL);

  if (local == 0) {
    return node;
  }
  if (local == node->len) {
    return pt_successor(node);
  }

  const size_t right_len = node->len - local;
  PieceTreeNode *right =
    pt_new_node(tree, node->source, node->add_chunk, node->start + local, right_len,
                pt_range_lfs(tree, node->source, node->add_chunk, node->start + local,
                             right_len));

  node->len = local;
  node->lf_count = pt_range_lfs(tree, node->source, node->add_chunk, node->start, node->len);
  pt_update_upwards(node);
  pt_insert_after(tree, node, right);
  return right;
}

static bool pt_can_merge(const PieceTreeNode *left, const PieceTreeNode *right)
{
  return left != NULL
         && right != NULL
         && left->source == right->source
         && left->add_chunk == right->add_chunk
         && left->start + left->len == right->start;
}

static PieceTreeNode *pt_coalesce_around(PieceTree *tree, PieceTreeNode *node)
{
  if (node == NULL) {
    return NULL;
  }

  PieceTreeNode *prev = pt_predecessor(node);
  if (pt_can_merge(prev, node)) {
    prev->len += node->len;
    prev->lf_count += node->lf_count;
    pt_update_upwards(prev);
    pt_delete_node(tree, node);
    node = prev;
  }

  PieceTreeNode *next = pt_successor(node);
  if (pt_can_merge(node, next)) {
    node->len += next->len;
    node->lf_count += next->lf_count;
    pt_update_upwards(node);
    pt_delete_node(tree, next);
  }

  return node;
}

static bool pt_can_extend_add_tail(const PieceTree *tree, const PieceTreeNode *node, size_t len)
{
  return node != NULL
         && node->source == kPieceTreeSourceAdd
         && node->add_chunk == tree->add_tail
         && node->start + node->len == tree->add_len
         && tree->add_tail != NULL
         && len <= tree->add_tail->cap - tree->add_tail->len;
}

static void pt_free_node_blocks(PieceTreeNodeBlock *block)
{
  while (block != NULL) {
    PieceTreeNodeBlock *next = block->next;
    xfree(block);
    block = next;
  }
}

static void pt_free_add_chunks(PieceTreeAddChunk *chunk)
{
  while (chunk != NULL) {
    PieceTreeAddChunk *next = chunk->next;
    xfree(chunk);
    chunk = next;
  }
}

static size_t pt_next_add_chunk_capacity(const PieceTree *tree, size_t min_cap)
{
  size_t cap = PT_ADD_CHUNK_MIN_CAPACITY;
  if (tree->add_tail != NULL) {
    const size_t tail_cap = tree->add_tail->cap;
    if (tail_cap >= PT_ADD_CHUNK_MAX_CAPACITY) {
      cap = PT_ADD_CHUNK_MAX_CAPACITY;
    } else if (tail_cap > PT_ADD_CHUNK_MAX_CAPACITY / 2) {
      cap = PT_ADD_CHUNK_MAX_CAPACITY;
    } else {
      cap = tail_cap * 2;
    }
  }
  return cap < min_cap ? min_cap : cap;
}

static PieceTreeAddChunk *pt_new_add_chunk(PieceTree *tree, size_t min_cap)
{
  size_t cap = pt_next_add_chunk_capacity(tree, min_cap);
  if (cap > SIZE_MAX - sizeof(PieceTreeAddChunk)
      || cap > SIZE_MAX - tree->add_cap) {
    return NULL;
  }

  PieceTreeAddChunk *chunk = xmalloc(sizeof(*chunk) + cap);
  chunk->next = NULL;
  chunk->start = tree->add_len;
  chunk->len = 0;
  chunk->cap = cap;

  if (tree->add_tail != NULL) {
    tree->add_tail->next = chunk;
  } else {
    tree->add_chunks = chunk;
  }
  tree->add_tail = chunk;
  tree->add_cap += cap;
  return chunk;
}

static bool pt_reserve_add(PieceTree *tree, size_t len)
{
  if (len > SIZE_MAX - tree->add_len) {
    return false;
  }
  if (len == 0) {
    return true;
  }

  if (tree->add_tail != NULL && len <= tree->add_tail->cap - tree->add_tail->len) {
    return true;
  }
  return pt_new_add_chunk(tree, len) != NULL;
}

static bool pt_append_add(PieceTree *tree, const char *text, size_t len, size_t *startp,
                          PieceTreeAddChunk **chunkp)
{
  if (!pt_reserve_add(tree, len)) {
    return false;
  }
  if (len == 0) {
    *startp = tree->add_len;
    *chunkp = tree->add_tail;
    return true;
  }

  PieceTreeAddChunk *chunk = tree->add_tail;
  assert(chunk != NULL);
  assert(len <= chunk->cap - chunk->len);
  assert(tree->add_len == chunk->start + chunk->len);

  *startp = tree->add_len;
  memcpy(chunk->data + chunk->len, text, len);
  chunk->len += len;
  tree->add_len += len;
  *chunkp = chunk;
  return true;
}

void piece_tree_init(PieceTree *tree, const char *original, size_t original_len)
{
  piece_tree_init_with_line_index(tree, original, original_len, NULL, 0, 0,
                                  pt_count_lfs(original, original_len));
}

void piece_tree_init_with_line_index(PieceTree *tree, const char *original, size_t original_len,
                                     const size_t *line_starts, size_t index_count,
                                     size_t index_stride, size_t newline_count)
{
  memset(tree, 0, sizeof *tree);
  tree->original = original;
  tree->original_len = original_len;
  tree->original_line_starts = line_starts;
  tree->original_index_count = index_count;
  tree->original_index_stride = index_stride;
  if (original_len > 0) {
    PieceTreeNode *node = pt_new_node(tree, kPieceTreeSourceOriginal, NULL, 0, original_len,
                                      newline_count);
    pt_insert_before(tree, NULL, node);
    tree->root->red = false;
  }
}

void piece_tree_clear(PieceTree *tree)
{
  assert(pt_reader_count_load(tree) == 0);
  assert(pt_span_ref_count_load(tree) == 0);
  pt_free_node_blocks(tree->node_blocks);
  pt_free_add_chunks(tree->add_chunks);
  memset(tree, 0, sizeof *tree);
}

bool piece_tree_dispose_budget(PieceTree *tree, size_t *budgetp)
{
  if (tree == NULL || budgetp == NULL) {
    return true;
  }
  if (pt_reader_count_load(tree) != 0 || pt_span_ref_count_load(tree) != 0) {
    return false;
  }
  if (*budgetp == 0) {
    return tree->node_blocks == NULL && tree->add_chunks == NULL;
  }

  tree->original = NULL;
  tree->original_len = 0;
  tree->original_line_starts = NULL;
  tree->original_index_count = 0;
  tree->original_index_stride = 0;
  tree->add_tail = NULL;
  tree->root = NULL;
  tree->free_nodes = NULL;
  tree->retired_nodes = NULL;
  tree->add_len = 0;
  tree->add_cap = 0;
  tree->node_count = 0;
  tree->node_capacity = 0;
  tree->retired_node_count = 0;
  tree->revision = 0;

  while (*budgetp > 0 && tree->node_blocks != NULL) {
    PieceTreeNodeBlock *next = tree->node_blocks->next;
    xfree(tree->node_blocks);
    tree->node_blocks = next;
    (*budgetp)--;
  }
  while (*budgetp > 0 && tree->add_chunks != NULL) {
    PieceTreeAddChunk *next = tree->add_chunks->next;
    xfree(tree->add_chunks);
    tree->add_chunks = next;
    (*budgetp)--;
  }

  const bool done = tree->node_blocks == NULL && tree->add_chunks == NULL;
  if (done) {
    memset(tree, 0, sizeof *tree);
  }
  return done;
}

bool piece_tree_rebase_original(PieceTree *tree, const char *original, size_t original_len)
{
  if (tree == NULL || original_len != tree->original_len
      || (original == NULL && original_len != 0)
      || pt_reader_count_load(tree) != 0
      || pt_span_ref_count_load(tree) != 0) {
    return false;
  }

  tree->original = original;
  return true;
}

static bool pt_clone_append_original(PieceTree *dst, const PieceTreeNode *src_node)
{
  PieceTreeNode *last = pt_maximum(dst->root);
  if (last != NULL
      && last->source == kPieceTreeSourceOriginal
      && last->start + last->len == src_node->start) {
    last->len += src_node->len;
    last->lf_count += src_node->lf_count;
    pt_update_upwards(last);
    return true;
  }

  PieceTreeNode *node = pt_new_node(dst, kPieceTreeSourceOriginal, NULL, src_node->start,
                                    src_node->len, src_node->lf_count);
  pt_insert_before(dst, NULL, node);
  return true;
}

static bool pt_clone_append_add(PieceTree *dst, const PieceTree *src,
                                const PieceTreeNode *src_node)
{
  size_t add_start = 0;
  PieceTreeAddChunk *add_chunk = NULL;
  if (!pt_append_add(dst, pt_node_data(src, src_node), src_node->len, &add_start, &add_chunk)) {
    return false;
  }

  PieceTreeNode *last = pt_maximum(dst->root);
  if (last != NULL
      && last->source == kPieceTreeSourceAdd
      && last->add_chunk == add_chunk
      && last->start + last->len == add_start) {
    last->len += src_node->len;
    last->lf_count += src_node->lf_count;
    pt_update_upwards(last);
    return true;
  }

  PieceTreeNode *node = pt_new_node(dst, kPieceTreeSourceAdd, add_chunk, add_start,
                                    src_node->len, src_node->lf_count);
  pt_insert_before(dst, NULL, node);
  return true;
}

bool piece_tree_clone_compact(PieceTree *dst, PieceTree *src)
{
  if (dst == NULL || src == NULL || dst == src) {
    return false;
  }

  memset(dst, 0, sizeof *dst);
  dst->original = src->original;
  dst->original_len = src->original_len;
  dst->original_line_starts = src->original_line_starts;
  dst->original_index_count = src->original_index_count;
  dst->original_index_stride = src->original_index_stride;

  piece_tree_reader_enter(src);
  const uint64_t revision = src->revision;
  bool ok = true;
  for (const PieceTreeNode *node = pt_minimum(src->root);
       node != NULL;
       node = pt_successor((PieceTreeNode *)node)) {
    if (node->source == kPieceTreeSourceOriginal) {
      ok = pt_clone_append_original(dst, node);
    } else {
      ok = pt_clone_append_add(dst, src, node);
    }
    if (!ok) {
      break;
    }
  }
  ok = ok && src->revision == revision;
  piece_tree_reader_leave(src);

  if (!ok) {
    piece_tree_clear(dst);
    return false;
  }
  dst->revision = revision;
  return true;
}

size_t piece_tree_byte_len(const PieceTree *tree)
{
  return pt_bytes(tree->root);
}

size_t piece_tree_newline_count(const PieceTree *tree)
{
  return pt_lfs(tree->root);
}

size_t piece_tree_node_count(const PieceTree *tree)
{
  return tree->node_count;
}

size_t piece_tree_node_capacity(const PieceTree *tree)
{
  return tree->node_capacity;
}

size_t piece_tree_free_node_count(const PieceTree *tree)
{
  size_t count = 0;
  for (const PieceTreeNode *node = tree->free_nodes; node != NULL; node = node->next_free) {
    count++;
  }
  return count;
}

static size_t pt_add_live_len(const PieceTreeNode *node)
{
  if (node == NULL) {
    return 0;
  }
  size_t len = node->source == kPieceTreeSourceAdd ? node->len : 0;
  len += pt_add_live_len(node->left);
  len += pt_add_live_len(node->right);
  return len;
}

size_t piece_tree_add_live_len(PieceTree *tree)
{
  if (tree == NULL) {
    return 0;
  }

  piece_tree_reader_enter(tree);
  const size_t len = pt_add_live_len(tree->root);
  piece_tree_reader_leave(tree);
  return len;
}

size_t piece_tree_retired_node_count(const PieceTree *tree)
{
  return tree->retired_node_count;
}

size_t piece_tree_storage_ref_count(const PieceTree *tree)
{
  if (tree == NULL) {
    return 0;
  }
  return pt_reader_count_load(tree) + pt_span_ref_count_load(tree);
}

void piece_tree_reader_enter(PieceTree *tree)
{
  pt_reader_count_increment(tree);
}

void piece_tree_reader_leave(PieceTree *tree)
{
  (void)pt_reader_count_decrement(tree);
}

bool piece_tree_reclaim_retired(PieceTree *tree)
{
  if (pt_reader_count_load(tree) != 0) {
    return false;
  }

  while (tree->retired_nodes != NULL) {
    (void)pt_reclaim_retired_nodes(tree, SIZE_MAX);
  }
  return true;
}

size_t piece_tree_reclaim_retired_budget(PieceTree *tree, size_t budget)
{
  if (tree == NULL || budget == 0 || pt_reader_count_load(tree) != 0) {
    return 0;
  }

  return pt_reclaim_retired_nodes(tree, budget);
}

static bool pt_byte_at(const PieceTree *tree, size_t offset, char *chp)
{
  if (chp == NULL || offset >= piece_tree_byte_len(tree)) {
    return false;
  }

  size_t local = 0;
  PieceTreeNode *node = pt_find_node(tree->root, offset, &local);
  if (node == NULL) {
    return false;
  }

  *chp = pt_node_data(tree, node)[local];
  return true;
}

bool piece_tree_byte_at(PieceTree *tree, size_t offset, char *chp)
{
  piece_tree_reader_enter(tree);
  const bool ok = pt_byte_at(tree, offset, chp);
  piece_tree_reader_leave(tree);
  return ok;
}

static size_t pt_line_count(const PieceTree *tree)
{
  const size_t len = piece_tree_byte_len(tree);
  if (len == 0) {
    return 1;
  }

  char last = '\0';
  if (pt_byte_at(tree, len - 1, &last) && last == '\n') {
    return piece_tree_newline_count(tree);
  }
  return piece_tree_newline_count(tree) + 1;
}

size_t piece_tree_line_count(PieceTree *tree)
{
  piece_tree_reader_enter(tree);
  const size_t count = pt_line_count(tree);
  piece_tree_reader_leave(tree);
  return count;
}

bool piece_tree_snapshot(PieceTree *tree, PieceTreeSnapshot *snapshot)
{
  if (snapshot == NULL) {
    return false;
  }

  piece_tree_reader_enter(tree);
  *snapshot = (PieceTreeSnapshot){
    .byte_len = piece_tree_byte_len(tree),
    .newline_count = piece_tree_newline_count(tree),
    .line_count = pt_line_count(tree),
    .revision = tree->revision,
  };
  piece_tree_reader_leave(tree);
  return true;
}

static bool pt_line_start(const PieceTree *tree, size_t lnum, size_t *offsetp)
{
  if (offsetp == NULL || lnum < 1 || lnum > pt_line_count(tree)) {
    return false;
  }
  if (lnum == 1) {
    *offsetp = 0;
    return true;
  }

  size_t nth = lnum - 1;
  size_t base = 0;
  PieceTreeNode *node = tree->root;
  while (node != NULL) {
    const size_t left_lfs = pt_lfs(node->left);
    if (nth <= left_lfs) {
      node = node->left;
      continue;
    }

    base += pt_bytes(node->left);
    nth -= left_lfs;
    if (nth <= node->lf_count) {
      size_t local_pos = 0;
      if (!pt_find_nth_lf_in_range(tree, node->source, node->add_chunk, node->start,
                                   node->len, nth, &local_pos)) {
        return false;
      }
      *offsetp = base + local_pos + 1;
      return *offsetp <= piece_tree_byte_len(tree);
    }

    base += node->len;
    nth -= node->lf_count;
    node = node->right;
  }

  return false;
}

bool piece_tree_line_start(PieceTree *tree, size_t lnum, size_t *offsetp)
{
  piece_tree_reader_enter(tree);
  const bool ok = pt_line_start(tree, lnum, offsetp);
  piece_tree_reader_leave(tree);
  return ok;
}

bool piece_tree_line_start_at_revision(PieceTree *tree, size_t lnum, uint64_t revision,
                                       size_t *offsetp)
{
  if (offsetp == NULL) {
    return false;
  }

  piece_tree_reader_enter(tree);
  const bool ok = tree->revision == revision && pt_line_start(tree, lnum, offsetp)
                  && tree->revision == revision;
  piece_tree_reader_leave(tree);
  return ok;
}

static bool pt_lnum_for_offset(const PieceTree *tree, size_t offset, size_t *lnump,
                               size_t *line_startp)
{
  const size_t total = piece_tree_byte_len(tree);
  if (lnump == NULL || line_startp == NULL || offset > total) {
    return false;
  }
  if (total == 0) {
    *lnump = 1;
    *line_startp = 0;
    return offset == 0;
  }

  if (offset == total) {
    char last = '\0';
    if (!pt_byte_at(tree, total - 1, &last)) {
      return false;
    }
    *lnump = last == '\n' ? pt_line_count(tree) : piece_tree_newline_count(tree) + 1;
    return pt_line_start(tree, *lnump, line_startp);
  }

  size_t local = 0;
  size_t newlines_before = 0;
  PieceTreeNode *node = tree->root;
  while (node != NULL) {
    const size_t left_bytes = pt_bytes(node->left);
    if (offset < left_bytes) {
      node = node->left;
    } else if (offset < left_bytes + node->len) {
      local = offset - left_bytes;
      newlines_before += pt_lfs(node->left);
      newlines_before += pt_range_lfs(tree, node->source, node->add_chunk, node->start,
                                      local);
      *lnump = newlines_before + 1;
      return pt_line_start(tree, *lnump, line_startp);
    } else {
      offset -= left_bytes + node->len;
      newlines_before += pt_lfs(node->left) + node->lf_count;
      node = node->right;
    }
  }

  return false;
}

bool piece_tree_lnum_for_offset(PieceTree *tree, size_t offset, size_t *lnump,
                                size_t *line_startp)
{
  piece_tree_reader_enter(tree);
  const bool ok = pt_lnum_for_offset(tree, offset, lnump, line_startp);
  piece_tree_reader_leave(tree);
  return ok;
}

static bool pt_line_bounds(const PieceTree *tree, size_t lnum, size_t *startp, size_t *endp)
{
  if (startp == NULL || endp == NULL || !pt_line_start(tree, lnum, startp)) {
    return false;
  }

  const size_t line_count = pt_line_count(tree);
  if (lnum < line_count) {
    size_t next_start = 0;
    if (!pt_line_start(tree, lnum + 1, &next_start) || next_start == 0) {
      return false;
    }
    *endp = next_start - 1;
    return true;
  }

  const size_t total = piece_tree_byte_len(tree);
  if (total == 0) {
    *endp = 0;
    return true;
  }

  char last = '\0';
  if (!pt_byte_at(tree, total - 1, &last)) {
    return false;
  }
  *endp = last == '\n' ? total - 1 : total;
  return *startp <= *endp;
}

bool piece_tree_line_bounds(PieceTree *tree, size_t lnum, size_t *startp, size_t *endp)
{
  piece_tree_reader_enter(tree);
  const bool ok = pt_line_bounds(tree, lnum, startp, endp);
  piece_tree_reader_leave(tree);
  return ok;
}

static bool pt_for_each_span(const PieceTree *tree, size_t offset, size_t len,
                             PieceTreeSpanCallback callback, void *ctx)
{
  if (callback == NULL) {
    return false;
  }

  const size_t total = piece_tree_byte_len(tree);
  if (offset > total || len > total - offset) {
    return false;
  }
  if (len == 0) {
    return true;
  }

  size_t local = 0;
  PieceTreeNode *node = pt_find_node(tree->root, offset, &local);
  size_t done = 0;
  while (node != NULL && done < len) {
    const size_t todo = MIN(node->len - local, len - done);
    if (todo > 0 && !callback(pt_node_data(tree, node) + local, todo, ctx)) {
      return false;
    }
    done += todo;
    node = pt_successor(node);
    local = 0;
  }
  return done == len;
}

static bool pt_for_each_span_guarded(PieceTree *tree, size_t offset, size_t len,
                                     PieceTreeSpanCallback callback, void *ctx)
{
  piece_tree_reader_enter(tree);
  const bool ok = pt_for_each_span(tree, offset, len, callback, ctx);
  piece_tree_reader_leave(tree);
  return ok;
}

bool piece_tree_for_each_span(PieceTree *tree, size_t offset, size_t len,
                              PieceTreeSpanCallback callback, void *ctx)
{
  if (callback == NULL) {
    return false;
  }

  return pt_for_each_span_guarded(tree, offset, len, callback, ctx);
}

typedef struct {
  PieceTreeSpan *spans;
  size_t count;
  size_t capacity;
  size_t logical_offset;
} PieceTreeSpanCollectCtx;

static bool pt_collect_span(const char *data, size_t len, void *ctx)
{
  PieceTreeSpanCollectCtx *collect_ctx = ctx;
  if (collect_ctx->count == collect_ctx->capacity) {
    size_t capacity = collect_ctx->capacity == 0 ? 8 : collect_ctx->capacity * 2;
    if (capacity < collect_ctx->capacity
        || capacity > SIZE_MAX / sizeof(*collect_ctx->spans)) {
      return false;
    }
    collect_ctx->spans = xrealloc(collect_ctx->spans,
                                  capacity * sizeof(*collect_ctx->spans));
    collect_ctx->capacity = capacity;
  }

  collect_ctx->spans[collect_ctx->count++] = (PieceTreeSpan){
    .data = data,
    .len = len,
    .offset = collect_ctx->logical_offset,
  };
  collect_ctx->logical_offset += len;
  return true;
}

static bool pt_collect_span_vec(PieceTree *tree, size_t offset, size_t len,
                                uint64_t revision, bool check_revision,
                                bool lease_storage, PieceTreeSpanVec *vec)
{
  if (vec == NULL) {
    return false;
  }
  *vec = (PieceTreeSpanVec){ 0 };

  PieceTreeSpanCollectCtx ctx = { .logical_offset = offset };
  piece_tree_reader_enter(tree);
  const uint64_t actual_revision = tree->revision;
  const bool ok = (!check_revision || actual_revision == revision)
                  && pt_for_each_span(tree, offset, len, pt_collect_span, &ctx)
                  && (!check_revision || tree->revision == revision);
  if (ok && lease_storage) {
    pt_span_ref_count_increment(tree);
  }
  piece_tree_reader_leave(tree);
  if (!ok) {
    xfree(ctx.spans);
    return false;
  }

  *vec = (PieceTreeSpanVec){
    .owner = lease_storage ? tree : NULL,
    .items = ctx.spans,
    .count = ctx.count,
    .logical_start = offset,
    .byte_len = len,
    .revision = actual_revision,
  };
  return true;
}

bool piece_tree_collect_span_vec(PieceTree *tree, size_t offset, size_t len,
                                 PieceTreeSpanVec *vec)
{
  return pt_collect_span_vec(tree, offset, len, 0, false, true, vec);
}

bool piece_tree_collect_span_vec_at_revision(PieceTree *tree, size_t offset, size_t len,
                                             uint64_t revision, PieceTreeSpanVec *vec)
{
  return pt_collect_span_vec(tree, offset, len, revision, true, true, vec);
}

void piece_tree_span_vec_clear(PieceTreeSpanVec *vec)
{
  if (vec == NULL) {
    return;
  }

  if (vec->owner != NULL) {
    pt_span_ref_count_decrement(vec->owner);
  }
  xfree(vec->items);
  *vec = (PieceTreeSpanVec){ 0 };
}

bool piece_tree_collect_spans(PieceTree *tree, size_t offset, size_t len,
                              PieceTreeSpan **spansp, size_t *countp)
{
  if (spansp == NULL || countp == NULL) {
    return false;
  }
  *spansp = NULL;
  *countp = 0;

  PieceTreeSpanVec vec = { 0 };
  if (!pt_collect_span_vec(tree, offset, len, 0, false, false, &vec)) {
    return false;
  }

  *spansp = vec.items;
  *countp = vec.count;
  return true;
}

void piece_tree_free_spans(PieceTreeSpan *spans)
{
  xfree(spans);
}

typedef struct {
  char *dst;
  size_t copied;
} PieceTreeReadCtx;

static bool pt_read_span(const char *data, size_t len, void *ctx)
{
  PieceTreeReadCtx *read_ctx = ctx;
  memcpy(read_ctx->dst + read_ctx->copied, data, len);
  read_ctx->copied += len;
  return true;
}

size_t piece_tree_read(PieceTree *tree, size_t offset, char *dst, size_t len)
{
  if (len == 0) {
    return 0;
  }

  PieceTreeReadCtx ctx = { .dst = dst };
  piece_tree_reader_enter(tree);
  const size_t total = piece_tree_byte_len(tree);
  bool ok = true;
  if (offset < total) {
    len = MIN(len, total - offset);
    ok = pt_for_each_span(tree, offset, len, pt_read_span, &ctx);
  }
  piece_tree_reader_leave(tree);
  if (!ok) {
    return 0;
  }
  return ctx.copied;
}

typedef struct {
  const char *pat;
  size_t logical_offset;
  size_t found_offset;
  bool found;
} PieceTreeByteFindCtx;

static bool pt_find_byte_span(const char *data, size_t len, void *ctx)
{
  PieceTreeByteFindCtx *find_ctx = ctx;
  const char *match = memchr(data, (uint8_t)find_ctx->pat[0], len);
  if (match != NULL) {
    find_ctx->found_offset = find_ctx->logical_offset + (size_t)(match - data);
    find_ctx->found = true;
    return false;
  }
  find_ctx->logical_offset += len;
  return true;
}

typedef struct {
  const char *pat;
  const size_t *prefix;
  size_t pat_len;
  size_t matched;
  size_t logical_offset;
  size_t found_offset;
  bool found;
} PieceTreeLiteralFindCtx;

typedef struct {
  const char *pat;
  const size_t *prefix;
  size_t pat_len;
  size_t matched;
  size_t logical_offset;
  PieceTreeMatchCallback callback;
  void *callback_ctx;
} PieceTreeLiteralFindAllCtx;

static bool pt_find_literal_span(const char *data, size_t len, void *ctx)
{
  PieceTreeLiteralFindCtx *find_ctx = ctx;
  for (size_t i = 0; i < len; i++) {
    while (find_ctx->matched > 0 && data[i] != find_ctx->pat[find_ctx->matched]) {
      find_ctx->matched = find_ctx->prefix[find_ctx->matched - 1];
    }
    if (data[i] == find_ctx->pat[find_ctx->matched]) {
      find_ctx->matched++;
    }
    if (find_ctx->matched == find_ctx->pat_len) {
      find_ctx->found_offset = find_ctx->logical_offset + i + 1 - find_ctx->pat_len;
      find_ctx->found = true;
      return false;
    }
  }
  find_ctx->logical_offset += len;
  return true;
}

static bool pt_find_byte_matches_span(const char *data, size_t len, void *ctx)
{
  PieceTreeLiteralFindAllCtx *find_ctx = ctx;
  const char *p = data;
  const char *const end = data + len;

  while (p < end) {
    const char *match = memchr(p, (uint8_t)find_ctx->pat[0], (size_t)(end - p));
    if (match == NULL) {
      break;
    }
    if (!find_ctx->callback(find_ctx->logical_offset + (size_t)(match - data),
                            find_ctx->callback_ctx)) {
      return false;
    }
    p = match + 1;
  }

  find_ctx->logical_offset += len;
  return true;
}

static bool pt_find_literal_matches_span(const char *data, size_t len, void *ctx)
{
  PieceTreeLiteralFindAllCtx *find_ctx = ctx;
  for (size_t i = 0; i < len; i++) {
    while (find_ctx->matched > 0 && data[i] != find_ctx->pat[find_ctx->matched]) {
      find_ctx->matched = find_ctx->prefix[find_ctx->matched - 1];
    }
    if (data[i] == find_ctx->pat[find_ctx->matched]) {
      find_ctx->matched++;
    }
    if (find_ctx->matched == find_ctx->pat_len) {
      const size_t match_offset = find_ctx->logical_offset + i + 1 - find_ctx->pat_len;
      if (!find_ctx->callback(match_offset, find_ctx->callback_ctx)) {
        return false;
      }
      // Match Vim's literal global search behavior: after a match, resume
      // after the matched text rather than reporting overlapping matches.
      find_ctx->matched = 0;
    }
  }
  find_ctx->logical_offset += len;
  return true;
}

static size_t *pt_build_prefix_table(const char *pat, size_t pat_len)
{
  if (pat_len > SIZE_MAX / sizeof(size_t)) {
    return NULL;
  }

  size_t *prefix = xmalloc(sizeof(*prefix) * pat_len);
  prefix[0] = 0;
  for (size_t i = 1, matched = 0; i < pat_len; i++) {
    while (matched > 0 && pat[i] != pat[matched]) {
      matched = prefix[matched - 1];
    }
    if (pat[i] == pat[matched]) {
      matched++;
    }
    prefix[i] = matched;
  }
  return prefix;
}

bool piece_tree_find_literal(PieceTree *tree, size_t offset, size_t len,
                             const char *pat, size_t pat_len, size_t *match_offsetp)
{
  if (pat == NULL || match_offsetp == NULL || pat_len == 0
      || pat_len > len) {
    return false;
  }

  if (pat_len == 1) {
    PieceTreeByteFindCtx ctx = {
      .pat = pat,
      .logical_offset = offset,
    };
    (void)pt_for_each_span_guarded(tree, offset, len, pt_find_byte_span, &ctx);
    if (!ctx.found) {
      return false;
    }
    *match_offsetp = ctx.found_offset;
    return true;
  }

  size_t *prefix = pt_build_prefix_table(pat, pat_len);
  if (prefix == NULL) {
    return false;
  }

  PieceTreeLiteralFindCtx ctx = {
    .pat = pat,
    .prefix = prefix,
    .pat_len = pat_len,
    .logical_offset = offset,
  };
  (void)pt_for_each_span_guarded(tree, offset, len, pt_find_literal_span, &ctx);
  xfree(prefix);
  if (!ctx.found) {
    return false;
  }
  *match_offsetp = ctx.found_offset;
  return true;
}

bool piece_tree_find_literals(PieceTree *tree, size_t offset, size_t len,
                              const char *pat, size_t pat_len, PieceTreeMatchCallback callback,
                              void *ctx)
{
  if (pat == NULL || callback == NULL || pat_len == 0
      || pat_len > len) {
    return false;
  }

  if (pat_len == 1) {
    PieceTreeLiteralFindAllCtx find_ctx = {
      .pat = pat,
      .pat_len = pat_len,
      .logical_offset = offset,
      .callback = callback,
      .callback_ctx = ctx,
    };
    const bool ok = pt_for_each_span_guarded(tree, offset, len, pt_find_byte_matches_span,
                                             &find_ctx);
    return ok;
  }

  size_t *prefix = pt_build_prefix_table(pat, pat_len);
  if (prefix == NULL) {
    return false;
  }

  PieceTreeLiteralFindAllCtx find_ctx = {
    .pat = pat,
    .prefix = prefix,
    .pat_len = pat_len,
    .logical_offset = offset,
    .callback = callback,
    .callback_ctx = ctx,
  };
  const bool ok = pt_for_each_span_guarded(tree, offset, len, pt_find_literal_matches_span,
                                           &find_ctx);
  xfree(prefix);
  return ok;
}

char *piece_tree_to_string(PieceTree *tree, size_t *lenp)
{
  piece_tree_reader_enter(tree);
  const size_t len = piece_tree_byte_len(tree);
  char *ret = xmalloc(len + 1);
  PieceTreeReadCtx ctx = { .dst = ret };
  const bool ok = len == 0 || pt_for_each_span(tree, 0, len, pt_read_span, &ctx);
  const size_t copied = ok ? ctx.copied : 0;
  piece_tree_reader_leave(tree);
  ret[copied] = '\0';
  if (lenp != NULL) {
    *lenp = copied;
  }
  return ret;
}

static bool pt_insert(PieceTree *tree, size_t offset, const char *text, size_t len,
                      bool bump_revision)
{
  if (offset > piece_tree_byte_len(tree)) {
    return false;
  }
  if (len == 0) {
    return true;
  }

  if (!pt_reserve_add(tree, len)) {
    return false;
  }

  PieceTreeNode *pos = pt_split_at(tree, offset);
  PieceTreeNode *prev = pos == NULL ? pt_maximum(tree->root) : pt_predecessor(pos);
  if (pt_can_extend_add_tail(tree, prev, len)) {
    size_t add_start = 0;
    PieceTreeAddChunk *add_chunk = NULL;
    if (!pt_append_add(tree, text, len, &add_start, &add_chunk)) {
      return false;
    }
    assert(add_chunk == prev->add_chunk);
    assert(add_start == prev->start + prev->len);
    prev->len += len;
    prev->lf_count += pt_count_lfs(text, len);
    pt_update_upwards(prev);
    if (bump_revision) {
      tree->revision++;
    }
    return true;
  }

  size_t add_start = 0;
  PieceTreeAddChunk *add_chunk = NULL;
  if (!pt_append_add(tree, text, len, &add_start, &add_chunk)) {
    return false;
  }

  PieceTreeNode *node = pt_new_node(tree, kPieceTreeSourceAdd, add_chunk, add_start, len,
                                    pt_count_lfs(text, len));
  pt_insert_before(tree, pos, node);
  pt_coalesce_around(tree, node);
  if (bump_revision) {
    tree->revision++;
  }
  return true;
}

bool piece_tree_insert(PieceTree *tree, size_t offset, const char *text, size_t len)
{
  if (len > 0 && pt_reader_count_load(tree) != 0) {
    return false;
  }
  return pt_insert(tree, offset, text, len, true);
}

static bool pt_delete(PieceTree *tree, size_t offset, size_t len, bool bump_revision)
{
  const size_t total = piece_tree_byte_len(tree);
  if (offset > total || len > total - offset) {
    return false;
  }
  if (len == 0) {
    return true;
  }

  PieceTreeNode *end = pt_split_at(tree, offset + len);
  PieceTreeNode *node = pt_split_at(tree, offset);
  while (node != NULL && node != end) {
    PieceTreeNode *next = pt_successor(node);
    pt_delete_node(tree, node);
    node = next;
  }

  if (end != NULL) {
    pt_coalesce_around(tree, end);
  } else {
    pt_coalesce_around(tree, pt_maximum(tree->root));
  }
  if (bump_revision) {
    tree->revision++;
  }
  return true;
}

bool piece_tree_delete(PieceTree *tree, size_t offset, size_t len)
{
  if (len > 0 && pt_reader_count_load(tree) != 0) {
    return false;
  }
  return pt_delete(tree, offset, len, true);
}

bool piece_tree_replace(PieceTree *tree, size_t offset, size_t len, const char *text,
                        size_t text_len)
{
  const size_t total = piece_tree_byte_len(tree);
  if (offset > total || len > total - offset) {
    return false;
  }
  if (len == 0 && text_len == 0) {
    return true;
  }
  if (pt_reader_count_load(tree) != 0) {
    return false;
  }
  if (text_len > 0 && !pt_reserve_add(tree, text_len)) {
    return false;
  }

  if (!pt_delete(tree, offset, len, false)
      || !pt_insert(tree, offset, text, text_len, false)) {
    return false;
  }
  tree->revision++;
  return true;
}

static bool pt_arena_used_count(const PieceTree *tree, size_t *countp)
{
  size_t count = 0;
  for (const PieceTreeNodeBlock *block = tree->node_blocks; block != NULL; block = block->next) {
    if (block->used > block->capacity || count > SIZE_MAX - block->used) {
      return false;
    }
    count += block->used;
  }
  *countp = count;
  return true;
}

static bool pt_arena_index(const PieceTree *tree, const PieceTreeNode *node, size_t *indexp)
{
  if (node == NULL) {
    return false;
  }

  size_t base = 0;
  const uintptr_t ptr = (uintptr_t)node;
  for (const PieceTreeNodeBlock *block = tree->node_blocks; block != NULL; block = block->next) {
    const uintptr_t start = (uintptr_t)block->nodes;
    const uintptr_t end = start + block->used * sizeof(*block->nodes);
    if (ptr >= start && ptr < end) {
      const uintptr_t offset = ptr - start;
      if (offset % sizeof(*block->nodes) != 0) {
        return false;
      }
      *indexp = base + offset / sizeof(*block->nodes);
      return true;
    }
    base += block->used;
  }
  return false;
}

static bool pt_mark_arena_node(const PieceTree *tree, const PieceTreeNode *node, bool *seen,
                               size_t seen_count)
{
  size_t index = 0;
  if (!pt_arena_index(tree, node, &index) || index >= seen_count || seen[index]) {
    return false;
  }
  seen[index] = true;
  return true;
}

static bool pt_check_node_list(const PieceTree *tree, const PieceTreeNode *node,
                               size_t expected_count, bool check_expected_count,
                               bool *seen, size_t seen_count, size_t *countp)
{
  size_t count = 0;
  while (node != NULL) {
    if (count == seen_count || !pt_mark_arena_node(tree, node, seen, seen_count)) {
      return false;
    }
    count++;
    node = node->next_free;
  }

  if (check_expected_count && count != expected_count) {
    return false;
  }
  *countp = count;
  return true;
}

static PieceTreeCheckResult pt_check_node(const PieceTree *tree, const PieceTreeNode *node,
                                          const PieceTreeNode *parent, bool *seen,
                                          size_t seen_count)
{
  if (node == NULL) {
    return (PieceTreeCheckResult){ .ok = true, .black_height = 1, .node_count = 0 };
  }

  if (!pt_mark_arena_node(tree, node, seen, seen_count)) {
    return (PieceTreeCheckResult){ .ok = false };
  }

  const bool original_node = node->source == kPieceTreeSourceOriginal;
  const size_t source_len = original_node ? tree->original_len : tree->add_len;
  if (node->parent != parent
      || node->len == 0
      || node->start > source_len
      || node->len > source_len - node->start) {
    return (PieceTreeCheckResult){ .ok = false };
  }

  const char *data = original_node
                     ? (node->add_chunk == NULL && tree->original != NULL
                        ? tree->original + node->start
                        : NULL)
                     : pt_add_chunk_data(node->add_chunk, node->start, node->len);
  if (data == NULL
      || node->lf_count != pt_range_lfs(tree, node->source, node->add_chunk, node->start,
                                        node->len)) {
    return (PieceTreeCheckResult){ .ok = false };
  }

  if (node->red && (pt_is_red(node->left) || pt_is_red(node->right))) {
    return (PieceTreeCheckResult){ .ok = false };
  }

  PieceTreeCheckResult left = pt_check_node(tree, node->left, node, seen, seen_count);
  PieceTreeCheckResult right = pt_check_node(tree, node->right, node, seen, seen_count);
  if (!left.ok || !right.ok || left.black_height != right.black_height) {
    return (PieceTreeCheckResult){ .ok = false };
  }

  const size_t bytes = pt_bytes(node->left) + node->len + pt_bytes(node->right);
  const size_t lfs = pt_lfs(node->left) + node->lf_count + pt_lfs(node->right);
  if (node->subtree_bytes != bytes || node->subtree_lfs != lfs) {
    return (PieceTreeCheckResult){ .ok = false };
  }

  return (PieceTreeCheckResult){
    .ok = true,
    .black_height = left.black_height + (node->red ? 0 : 1),
    .node_count = left.node_count + 1 + right.node_count,
  };
}

bool piece_tree_check(const PieceTree *tree)
{
  size_t arena_count = 0;
  if (!pt_arena_used_count(tree, &arena_count)) {
    return false;
  }

  bool *seen = arena_count == 0 ? NULL : xcalloc(arena_count, sizeof(*seen));
  bool ok = true;
  size_t active_count = 0;
  if (tree->root == NULL) {
    ok = tree->node_count == 0 && piece_tree_byte_len(tree) == 0;
  } else if (tree->root->red || tree->root->parent != NULL) {
    ok = false;
  } else {
    PieceTreeCheckResult result = pt_check_node(tree, tree->root, NULL, seen, arena_count);
    active_count = result.node_count;
    ok = result.ok && active_count == tree->node_count;
  }

  size_t free_count = 0;
  if (ok) {
    ok = pt_check_node_list(tree, tree->free_nodes, 0, false, seen, arena_count, &free_count);
  }

  size_t retired_count = 0;
  if (ok) {
    ok = pt_check_node_list(tree, tree->retired_nodes, tree->retired_node_count, true, seen,
                            arena_count, &retired_count);
  }
  if (ok && active_count + free_count + retired_count != arena_count) {
    ok = false;
  }

  xfree(seen);
  return ok;
}
