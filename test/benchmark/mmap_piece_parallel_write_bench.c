#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <limits.h>
#include <linux/fs.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

typedef enum {
  kJobOriginal = 0,
  kJobInsert = 1,
} JobKind;

typedef struct {
  JobKind kind;
  uint64_t src_off;
  uint64_t dst_off;
  uint64_t len;
  char *data;
} WriteJob;

typedef struct {
  uint64_t clone_jobs;
  uint64_t clone_bytes;
  uint64_t clone_fail_jobs;
  uint64_t clone_fail_einval;
  uint64_t clone_fail_eopnotsupp;
  uint64_t clone_fail_exdev;
  uint64_t clone_fail_other;
  int clone_first_errno;
  int clone_last_errno;

  uint64_t copy_jobs;
  uint64_t copy_bytes;
  uint64_t insert_jobs;
  uint64_t insert_bytes;
} BenchStats;

typedef struct {
  int src_fd;
  int dst_fd;
  WriteJob *jobs;
  size_t job_count;
  size_t next_job;
  uint64_t copy_chunk;
  bool raw_fallback;
  BenchStats stats;
  int error;
  pthread_mutex_t mutex;
} WorkQueue;

static double now_seconds(void)
{
  struct timespec ts;
  if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
    return 0.0;
  }
  return (double)ts.tv_sec + ((double)ts.tv_nsec / 1000000000.0);
}

static void usage(const char *argv0)
{
  fprintf(stderr,
          "usage: %s SRC DST THREADS INSERTS INSERT_LEN [raw|COPY_CHUNK_MIB]\n"
          "\n"
          "Builds a piece-table-style write workload:\n"
          "  original range, inserted bytes, original range, ...\n"
          "\n"
          "Original ranges use FICLONERANGE first, then copy_file_range fallback.\n"
          "Pass \"raw\" to use pread+pwrite fallback instead of copy_file_range.\n"
          "THREADS=1 models the current sequential writer; THREADS>1 tests a\n"
          "parallel output engine with explicit source/destination offsets.\n",
          argv0);
}

static bool parse_u64(const char *arg, uint64_t *value)
{
  char *end = NULL;
  errno = 0;
  unsigned long long parsed = strtoull(arg, &end, 10);
  if (errno != 0 || end == arg || *end != '\0') {
    return false;
  }
  *value = (uint64_t)parsed;
  return true;
}

static int full_pwrite(int fd, const char *data, uint64_t len, uint64_t off)
{
  while (len > 0) {
    const size_t todo = len > (uint64_t)SSIZE_MAX ? (size_t)SSIZE_MAX : (size_t)len;
    ssize_t written = pwrite(fd, data, todo, (off_t)off);
    if (written < 0) {
      if (errno == EINTR) {
        continue;
      }
      return errno;
    }
    if (written == 0) {
      return EIO;
    }
    data += written;
    off += (uint64_t)written;
    len -= (uint64_t)written;
  }
  return 0;
}

static int full_pread(int fd, char *data, uint64_t len, uint64_t off)
{
  while (len > 0) {
    const size_t todo = len > (uint64_t)SSIZE_MAX ? (size_t)SSIZE_MAX : (size_t)len;
    ssize_t nread = pread(fd, data, todo, (off_t)off);
    if (nread < 0) {
      if (errno == EINTR) {
        continue;
      }
      return errno;
    }
    if (nread == 0) {
      return EIO;
    }
    data += nread;
    off += (uint64_t)nread;
    len -= (uint64_t)nread;
  }
  return 0;
}

static int clone_range(int src_fd, int dst_fd, uint64_t src_off, uint64_t dst_off, uint64_t len)
{
#ifdef FICLONERANGE
  struct file_clone_range range = {
    .src_fd = src_fd,
    .src_offset = src_off,
    .src_length = len,
    .dest_offset = dst_off,
  };

  int ret;
  do {
    ret = ioctl(dst_fd, FICLONERANGE, &range);
  } while (ret < 0 && errno == EINTR);

  return ret == 0 ? 0 : errno;
#else
  (void)src_fd;
  (void)dst_fd;
  (void)src_off;
  (void)dst_off;
  (void)len;
  return ENOSYS;
#endif
}

static int copy_range(int src_fd, int dst_fd, uint64_t src_off, uint64_t dst_off, uint64_t len,
                      uint64_t copy_chunk)
{
#ifdef __linux__
  off_t source = (off_t)src_off;
  off_t dest = (off_t)dst_off;

  while (len > 0) {
    const size_t todo = (size_t)(len < copy_chunk ? len : copy_chunk);
    ssize_t copied = copy_file_range(src_fd, &source, dst_fd, &dest, todo, 0);
    if (copied < 0) {
      if (errno == EINTR) {
        continue;
      }
      return errno;
    }
    if (copied == 0) {
      return EIO;
    }
    len -= (uint64_t)copied;
  }
  return 0;
#else
  (void)src_fd;
  (void)dst_fd;
  (void)src_off;
  (void)dst_off;
  (void)len;
  (void)copy_chunk;
  return ENOSYS;
#endif
}

static int raw_copy_range(int src_fd, int dst_fd, uint64_t src_off, uint64_t dst_off,
                          uint64_t len, char *buf, uint64_t buf_len)
{
  while (len > 0) {
    const uint64_t todo = len < buf_len ? len : buf_len;
    int err = full_pread(src_fd, buf, todo, src_off);
    if (err != 0) {
      return err;
    }
    err = full_pwrite(dst_fd, buf, todo, dst_off);
    if (err != 0) {
      return err;
    }
    src_off += todo;
    dst_off += todo;
    len -= todo;
  }
  return 0;
}

static void record_clone_failure(BenchStats *stats, int err)
{
  stats->clone_fail_jobs++;
  stats->clone_last_errno = err;
  if (stats->clone_first_errno == 0) {
    stats->clone_first_errno = err;
  }

  switch (err) {
  case EINVAL:
    stats->clone_fail_einval++;
    break;
  case EOPNOTSUPP:
    stats->clone_fail_eopnotsupp++;
    break;
  case EXDEV:
    stats->clone_fail_exdev++;
    break;
  default:
    stats->clone_fail_other++;
    break;
  }
}

static bool next_job(WorkQueue *queue, WriteJob *job)
{
  bool found = false;
  pthread_mutex_lock(&queue->mutex);
  if (queue->error == 0 && queue->next_job < queue->job_count) {
    *job = queue->jobs[queue->next_job++];
    found = true;
  }
  pthread_mutex_unlock(&queue->mutex);
  return found;
}

static void merge_stats(WorkQueue *queue, const BenchStats *stats)
{
  pthread_mutex_lock(&queue->mutex);
  queue->stats.clone_jobs += stats->clone_jobs;
  queue->stats.clone_bytes += stats->clone_bytes;
  queue->stats.clone_fail_jobs += stats->clone_fail_jobs;
  queue->stats.clone_fail_einval += stats->clone_fail_einval;
  queue->stats.clone_fail_eopnotsupp += stats->clone_fail_eopnotsupp;
  queue->stats.clone_fail_exdev += stats->clone_fail_exdev;
  queue->stats.clone_fail_other += stats->clone_fail_other;
  if (queue->stats.clone_first_errno == 0) {
    queue->stats.clone_first_errno = stats->clone_first_errno;
  }
  if (stats->clone_last_errno != 0) {
    queue->stats.clone_last_errno = stats->clone_last_errno;
  }
  queue->stats.copy_jobs += stats->copy_jobs;
  queue->stats.copy_bytes += stats->copy_bytes;
  queue->stats.insert_jobs += stats->insert_jobs;
  queue->stats.insert_bytes += stats->insert_bytes;
  pthread_mutex_unlock(&queue->mutex);
}

static void set_error(WorkQueue *queue, int err)
{
  pthread_mutex_lock(&queue->mutex);
  if (queue->error == 0) {
    queue->error = err == 0 ? EIO : err;
  }
  pthread_mutex_unlock(&queue->mutex);
}

static void *worker_main(void *arg)
{
  WorkQueue *queue = arg;
  BenchStats stats = { 0 };
  WriteJob job;
  enum { kRawCopyChunk = 16 * 1024 * 1024 };
  char *raw_buf = queue->raw_fallback ? malloc(kRawCopyChunk) : NULL;
  if (queue->raw_fallback && raw_buf == NULL) {
    set_error(queue, ENOMEM);
    return NULL;
  }

  while (next_job(queue, &job)) {
    if (job.kind == kJobOriginal) {
      const int clone_err = clone_range(queue->src_fd, queue->dst_fd, job.src_off, job.dst_off,
                                        job.len);
      if (clone_err == 0) {
        stats.clone_jobs++;
        stats.clone_bytes += job.len;
        continue;
      }

      record_clone_failure(&stats, clone_err);
      const int copy_err = queue->raw_fallback
                           ? raw_copy_range(queue->src_fd, queue->dst_fd, job.src_off,
                                            job.dst_off, job.len, raw_buf, kRawCopyChunk)
                           : copy_range(queue->src_fd, queue->dst_fd, job.src_off, job.dst_off,
                                        job.len, queue->copy_chunk);
      if (copy_err != 0) {
        set_error(queue, copy_err);
        break;
      }
      stats.copy_jobs++;
      stats.copy_bytes += job.len;
    } else {
      const int err = full_pwrite(queue->dst_fd, job.data, job.len, job.dst_off);
      if (err != 0) {
        set_error(queue, err);
        break;
      }
      stats.insert_jobs++;
      stats.insert_bytes += job.len;
    }
  }

  merge_stats(queue, &stats);
  free(raw_buf);
  return NULL;
}

static bool add_job(WriteJob **jobs, size_t *count, size_t *capacity, WriteJob job)
{
  if (job.len == 0) {
    return true;
  }
  if (*count == *capacity) {
    size_t new_capacity = *capacity == 0 ? 16 : *capacity * 2;
    if (new_capacity < *capacity || new_capacity > SIZE_MAX / sizeof **jobs) {
      return false;
    }
    WriteJob *new_jobs = realloc(*jobs, new_capacity * sizeof **jobs);
    if (new_jobs == NULL) {
      return false;
    }
    *jobs = new_jobs;
    *capacity = new_capacity;
  }
  (*jobs)[(*count)++] = job;
  return true;
}

static bool build_jobs(uint64_t source_size, uint64_t insert_count, uint64_t insert_len,
                       WriteJob **jobsp, size_t *job_countp, uint64_t *output_sizep)
{
  if (insert_count > 1000000 || insert_len > (UINT64_MAX / (insert_count == 0 ? 1 : insert_count))
      || source_size > UINT64_MAX - (insert_count * insert_len)) {
    return false;
  }

  WriteJob *jobs = NULL;
  size_t job_count = 0;
  size_t capacity = 0;
  uint64_t prev_src = 0;
  uint64_t inserted = 0;

  for (uint64_t i = 0; i < insert_count; i++) {
    uint64_t pos = (source_size * (i + 1)) / (insert_count + 1);
    pos += ((i + 1) * 131) & 4095;
    if (pos > source_size) {
      pos = source_size;
    }
    if (pos < prev_src) {
      pos = prev_src;
    }

    if (!add_job(&jobs, &job_count, &capacity, (WriteJob){
          .kind = kJobOriginal,
          .src_off = prev_src,
          .dst_off = prev_src + inserted,
          .len = pos - prev_src,
        })) {
      free(jobs);
      return false;
    }

    char *insert = malloc(insert_len == 0 ? 1 : insert_len);
    if (insert == NULL) {
      free(jobs);
      return false;
    }
    for (uint64_t j = 0; j < insert_len; j++) {
      insert[j] = (char)('A' + ((i + j) % 26));
    }
    if (!add_job(&jobs, &job_count, &capacity, (WriteJob){
          .kind = kJobInsert,
          .dst_off = pos + inserted,
          .len = insert_len,
          .data = insert,
        })) {
      free(insert);
      for (size_t j = 0; j < job_count; j++) {
        if (jobs[j].kind == kJobInsert) {
          free(jobs[j].data);
        }
      }
      free(jobs);
      return false;
    }

    prev_src = pos;
    inserted += insert_len;
  }

  if (!add_job(&jobs, &job_count, &capacity, (WriteJob){
        .kind = kJobOriginal,
        .src_off = prev_src,
        .dst_off = prev_src + inserted,
        .len = source_size - prev_src,
      })) {
    for (size_t j = 0; j < job_count; j++) {
      if (jobs[j].kind == kJobInsert) {
        free(jobs[j].data);
      }
    }
    free(jobs);
    return false;
  }

  *jobsp = jobs;
  *job_countp = job_count;
  *output_sizep = source_size + inserted;
  return true;
}

int main(int argc, char **argv)
{
  if (argc < 6 || argc > 7) {
    usage(argv[0]);
    return 2;
  }

  uint64_t threads_u64 = 0;
  uint64_t insert_count = 0;
  uint64_t insert_len = 0;
  uint64_t copy_chunk_mib = 1024;
  bool raw_fallback = false;
  if (!parse_u64(argv[3], &threads_u64) || threads_u64 == 0 || threads_u64 > 256
      || !parse_u64(argv[4], &insert_count)
      || !parse_u64(argv[5], &insert_len)) {
    usage(argv[0]);
    return 2;
  }
  if (argc == 7) {
    if (strcmp(argv[6], "raw") == 0) {
      raw_fallback = true;
    } else if (!parse_u64(argv[6], &copy_chunk_mib)
               || copy_chunk_mib == 0 || copy_chunk_mib > 1024) {
      usage(argv[0]);
      return 2;
    }
  }

  int src_fd = open(argv[1], O_RDONLY | O_CLOEXEC);
  if (src_fd < 0) {
    perror("open source");
    return 1;
  }

  struct stat st;
  if (fstat(src_fd, &st) != 0 || st.st_size < 0) {
    perror("fstat source");
    close(src_fd);
    return 1;
  }
  const uint64_t source_size = (uint64_t)st.st_size;

  WriteJob *jobs = NULL;
  size_t job_count = 0;
  uint64_t output_size = 0;
  if (!build_jobs(source_size, insert_count, insert_len, &jobs, &job_count, &output_size)) {
    fprintf(stderr, "failed to build jobs\n");
    close(src_fd);
    return 1;
  }

  int dst_fd = open(argv[2], O_CREAT | O_TRUNC | O_RDWR | O_CLOEXEC, 0666);
  if (dst_fd < 0) {
    perror("open dest");
    close(src_fd);
    return 1;
  }
  if (ftruncate(dst_fd, (off_t)output_size) != 0) {
    perror("ftruncate dest");
    close(dst_fd);
    close(src_fd);
    return 1;
  }

  WorkQueue queue = {
    .src_fd = src_fd,
    .dst_fd = dst_fd,
    .jobs = jobs,
    .job_count = job_count,
    .copy_chunk = copy_chunk_mib * 1024 * 1024,
    .raw_fallback = raw_fallback,
  };
  pthread_mutex_init(&queue.mutex, NULL);

  const double start = now_seconds();
  pthread_t *threads = calloc((size_t)threads_u64, sizeof *threads);
  if (threads == NULL) {
    fprintf(stderr, "failed to allocate thread handles\n");
    close(dst_fd);
    close(src_fd);
    return 1;
  }

  for (uint64_t i = 0; i < threads_u64; i++) {
    if (pthread_create(&threads[i], NULL, worker_main, &queue) != 0) {
      perror("pthread_create");
      set_error(&queue, errno);
      threads_u64 = i;
      break;
    }
  }
  for (uint64_t i = 0; i < threads_u64; i++) {
    pthread_join(threads[i], NULL);
  }
  const double elapsed = now_seconds() - start;

  struct stat dst_st;
  const int stat_ok = fstat(dst_fd, &dst_st);
  close(dst_fd);
  close(src_fd);

  const double gib = (double)output_size / (1024.0 * 1024.0 * 1024.0);
  printf("source=%" PRIu64 " output=%" PRIu64 " jobs=%zu threads=%" PRIu64
         " inserts=%" PRIu64 " insert_len=%" PRIu64 "\n",
         source_size, output_size, job_count, threads_u64, insert_count, insert_len);
  printf("fallback=%s elapsed=%.6f throughput=%.3fGiB/s error=%d output_size_ok=%s\n",
         raw_fallback ? "pread+pwrite" : "copy_file_range",
         elapsed, elapsed > 0.0 ? gib / elapsed : 0.0, queue.error,
         stat_ok == 0 && (uint64_t)dst_st.st_size == output_size ? "true" : "false");
  printf("clone_jobs=%" PRIu64 " clone_bytes=%" PRIu64
         " clone_fail_jobs=%" PRIu64 " first_errno=%d(%s) last_errno=%d(%s)\n",
         queue.stats.clone_jobs, queue.stats.clone_bytes, queue.stats.clone_fail_jobs,
         queue.stats.clone_first_errno,
         queue.stats.clone_first_errno == 0 ? "OK" : strerror(queue.stats.clone_first_errno),
         queue.stats.clone_last_errno,
         queue.stats.clone_last_errno == 0 ? "OK" : strerror(queue.stats.clone_last_errno));
  printf("clone_fail_einval=%" PRIu64 " clone_fail_eopnotsupp=%" PRIu64
         " clone_fail_exdev=%" PRIu64 " clone_fail_other=%" PRIu64 "\n",
         queue.stats.clone_fail_einval, queue.stats.clone_fail_eopnotsupp,
         queue.stats.clone_fail_exdev, queue.stats.clone_fail_other);
  printf("copy_jobs=%" PRIu64 " copy_bytes=%" PRIu64
         " insert_jobs=%" PRIu64 " insert_bytes=%" PRIu64 "\n",
         queue.stats.copy_jobs, queue.stats.copy_bytes, queue.stats.insert_jobs,
         queue.stats.insert_bytes);

  free(threads);
  for (size_t i = 0; i < job_count; i++) {
    if (jobs[i].kind == kJobInsert) {
      free(jobs[i].data);
    }
  }
  free(jobs);
  pthread_mutex_destroy(&queue.mutex);

  return queue.error == 0 ? 0 : 1;
}
