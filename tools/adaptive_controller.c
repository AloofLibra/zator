#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <limits.h>
#include <stdbool.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <signal.h>
#include <stddef.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/time.h>
#include <unistd.h>

/*
 * Small, dependency-free adaptive controller.
 * Reads C-owned nfqws2 TSV v2/v3 from stdin and never changes production policy.
 */
#define MAX_LINE 2048
#define MAX_FIELDS 32
#define MAX_OPEN_FLOWS 256
#define MAX_CONTEXTS 128
#define MAX_CANDIDATES 384
#define PROBE_GRACE_MS 90000ULL
#define HOST_CAP 256
#define SCOPE_CAP 64
#define COHORT_WINDOW_MS 10000ULL
#define STATE_TTL_MS (7ULL * 24ULL * 60ULL * 60ULL * 1000ULL)

struct flow_state {
	bool used, started, assigned, strategy_conflict, identity_conflict;
	bool network_context_usable;
	uint64_t id, tuple_hash, generation, network_epoch;
	uint32_t profile, strategy, source_port;
	uint8_t health_state, health_reason;
	char host[HOST_CAP], scope[SCOPE_CAP], transport[8], family[8];
};

struct context_state {
	bool used;
	uint64_t key, last_seen_ms, network_epoch;
	uint32_t profile, champion;
	char host[HOST_CAP], scope[SCOPE_CAP], transport[8], family[8];
};

struct candidate_state {
	bool used;
	unsigned context_index;
	uint32_t strategy;
	uint64_t successes, active_successes, unknown, last_success_ms, last_seen_ms;
	bool has_last_success;
};

/* One bounded active probe lease. It only joins C telemetry and the caller's
 * HTTP result; it does not schedule candidates or promote policy. */
struct probe_state {
	bool active, result_seen, flow_seen, flow_ambiguous;
	uint64_t id, started_ms, deadline_ms, join_ready_ms, flow_id, candidate_flow_id;
	uint64_t network_epoch;
	uint32_t source_port, profile, strategy, curl_rc, http_status;
	uint64_t generation, elapsed_ms;
	uint8_t health_state;
	bool network_context_usable;
	char host[HOST_CAP];
	char transport[8], family[8];
};

struct probe_tombstone {
	bool used;
	uint32_t source_port;
	uint64_t expires_ms;
};

static struct flow_state flows[MAX_OPEN_FLOWS];
static struct context_state contexts[MAX_CONTEXTS];
static struct candidate_state candidates[MAX_CANDIDATES];
static struct probe_state active_probe;
static uint64_t next_probe_id;
static uint64_t completed_probe_flows[16];
static unsigned completed_probe_flow_next;
static struct probe_tombstone probe_tombstones[16];
static unsigned probe_tombstone_next;

#define MAX_OUTPUT_BYTES (256U * 1024U)
#define MAX_STATE_BYTES (128U * 1024U)
#define STATE_SAVE_INTERVAL_MS (5ULL * 60ULL * 1000ULL)
#define NETWORK_SAMPLE_INTERVAL_MS (30ULL * 1000ULL)
#define MAX_NETWORK_SNAPSHOT_BYTES (64U * 1024U)
enum network_health_state { NETWORK_HEALTH_UNKNOWN, NETWORK_HEALTH_DEGRADED };
enum network_health_reason {
	NETWORK_REASON_SNAPSHOT_UNAVAILABLE,
	NETWORK_REASON_NO_DEFAULT_ROUTE,
	NETWORK_REASON_NO_RESOLVER,
	NETWORK_REASON_CONFIG_UNCONFIRMED,
	NETWORK_REASON_CANARY_REQUIRED
};
static FILE *controller_output;
static bool controller_output_limited;
static const char *controller_state_path;
static uint64_t network_epoch, network_fingerprint, network_last_sample_ms;
static bool network_context_known, network_sampling_enabled;
static bool network_default_route, network_dns_configured;
static uint8_t network_degraded_reason;
static unsigned network_degraded_streak;

static uint64_t hash_fields(const char *const *fields, size_t count);
static bool parse_u64(const char *s, uint64_t *out);
static bool copy_field(char *dst, size_t cap, const char *src);
static size_t split_tsv(char *line, char **fields, size_t cap);
static uint64_t monotonic_ms(void);
static void expire_state(uint64_t now);
static bool network_snapshot_fingerprint(uint64_t *fingerprint,
		bool *default_route, bool *dns_configured);
static void network_context_refresh(uint64_t now);
static void network_context_maybe_refresh(uint64_t now);

static bool secure_parent_dir(const char *path)
{
	char parent[PATH_MAX];
	const char *slash;
	size_t len;
	struct stat st;
	if (!path || path[0] != '/') return false;
	slash = strrchr(path, '/');
	if (!slash) return false;
	len = slash == path ? 1 : (size_t)(slash - path);
	if (len >= sizeof(parent)) return false;
	memcpy(parent, path, len);
	parent[len] = '\0';
	if (lstat(parent, &st) != 0 || !S_ISDIR(st.st_mode) ||
		st.st_uid != geteuid() || (st.st_mode & 077) != 0)
		return false;
	return true;
}

static void controller_printf(const char *format, ...)
{
	char line[4096];
	va_list args;
	int n;
	struct stat st;
	int fd;
	const char marker[] = "# OUTPUT_LIMIT\tmax_bytes=262144\n";
	if (controller_output_limited) return;
	if (!controller_output) controller_output = stdout;
	va_start(args, format);
	n = vsnprintf(line, sizeof(line), format, args);
	va_end(args);
	if (n < 0 || (size_t)n >= sizeof(line)) return;
	fd = fileno(controller_output);
	if (fd >= 0 && controller_output != stdout) {
		if (fflush(controller_output) != 0 || fstat(fd, &st) != 0 ||
			st.st_size < 0 || (uint64_t)st.st_size + (size_t)n > MAX_OUTPUT_BYTES) {
			if (fstat(fd, &st) == 0 && st.st_size >= 0 &&
				(uint64_t)st.st_size + sizeof(marker) - 1 <= MAX_OUTPUT_BYTES) {
				(void)fwrite(marker, 1, sizeof(marker) - 1, controller_output);
				(void)fflush(controller_output);
			}
			controller_output_limited = true;
			return;
		}
	}
	(void)fwrite(line, 1, (size_t)n, controller_output);
}

static void controller_puts(const char *line)
{
	controller_printf("%s\n", line);
}

#define printf controller_printf
#define puts controller_puts

static bool controller_output_open(const char *path)
{
	int flags = O_WRONLY | O_CREAT | O_APPEND;
	int fd;
	struct stat st;
	if (!secure_parent_dir(path)) return false;
#ifdef O_NOFOLLOW
	flags |= O_NOFOLLOW;
#endif
	fd = open(path, flags, 0600);
	if (fd < 0) return false;
	if (fchmod(fd, 0600) != 0 || fstat(fd, &st) != 0 ||
		!S_ISREG(st.st_mode) || st.st_uid != geteuid() ||
		st.st_size < 0) {
		close(fd);
		return false;
	}
	controller_output_limited = (uint64_t)st.st_size >= MAX_OUTPUT_BYTES;
	controller_output = fdopen(fd, "a");
	if (!controller_output) {
		close(fd);
		return false;
	}
	return true;
}

static void clear_aggregate_state(void)
{
	memset(contexts, 0, sizeof(contexts));
	memset(candidates, 0, sizeof(candidates));
}

static bool checkpoint_state(uint64_t now)
{
	char tmp[PATH_MAX];
	FILE *fp;
	int fd, n;
	size_t i;
	struct stat st;
	bool ok = true;
	if (!controller_state_path) return true;
	if (!secure_parent_dir(controller_state_path)) return false;
	n = snprintf(tmp, sizeof(tmp), "%s.tmp.%ld", controller_state_path, (long)getpid());
	if (n <= 0 || (size_t)n >= sizeof(tmp)) return false;
#ifdef O_NOFOLLOW
	fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
#else
	fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL, 0600);
#endif
	if (fd < 0) return false;
	fp = fdopen(fd, "w");
	if (!fp) { close(fd); unlink(tmp); return false; }
	if (fprintf(fp, "ADAPTIVE_STATE\t3\t%" PRIu64 "\t%" PRIu64
		"\t%" PRIu64 "\t%u\n", now, network_epoch,
		network_fingerprint, network_context_known ? 1U : 0U) < 0) ok = false;
	for (i = 0; ok && i < MAX_CONTEXTS; i++) {
		const struct context_state *ctx = &contexts[i];
		if (!ctx->used) continue;
		if (fprintf(fp, "C\t%lu\t%u\t%" PRIu64 "\t%" PRIu64
			"\t%" PRIu64 "\t%u\t%s\t%s\t%s\t%s\n", (unsigned long)i,
			ctx->profile, ctx->network_epoch, ctx->key, ctx->last_seen_ms,
			ctx->champion, ctx->host, ctx->scope, ctx->transport, ctx->family) < 0) ok = false;
	}
	for (i = 0; ok && i < MAX_CANDIDATES; i++) {
		const struct candidate_state *cand = &candidates[i];
		if (!cand->used) continue;
		if (fprintf(fp, "S\t%u\t%u\t%" PRIu64 "\t%" PRIu64 "\t%" PRIu64
			"\t%" PRIu64 "\t%" PRIu64 "\t%u\n", cand->context_index,
			cand->strategy, cand->successes, cand->active_successes, cand->unknown,
			cand->last_success_ms, cand->last_seen_ms,
			cand->has_last_success ? 1U : 0U) < 0) ok = false;
	}
	if (fflush(fp) != 0 || fsync(fileno(fp)) != 0 || fstat(fileno(fp), &st) != 0 ||
		st.st_size < 0 || (uint64_t)st.st_size > MAX_STATE_BYTES) ok = false;
	if (fclose(fp) != 0) ok = false;
	if (ok && rename(tmp, controller_state_path) == 0) return true;
	(void)unlink(tmp);
	return false;
}

static bool state_number(const char *text, uint64_t *value)
{
	return parse_u64(text, value);
}

static bool restore_state(const char *path)
{
	int fd;
	FILE *fp;
	struct stat st;
	char line[MAX_LINE];
	char *c[MAX_FIELDS];
	unsigned long line_no = 0;
	uint64_t saved_at = 0, saved_epoch = 0, saved_fingerprint = 0, now = monotonic_ms();
	uint64_t saved_version = 0;
	bool saved_network_known = false, header_seen = false, valid = true;
	if (!path) return true;
	if (!secure_parent_dir(path)) return false;
#ifdef O_NOFOLLOW
	fd = open(path, O_RDONLY | O_NOFOLLOW);
#else
	fd = open(path, O_RDONLY);
#endif
	if (fd < 0) return errno == ENOENT;
	if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) ||
		st.st_uid != geteuid() || (st.st_mode & 077) != 0 ||
		st.st_size < 0 || (uint64_t)st.st_size > MAX_STATE_BYTES) {
		close(fd);
		return false;
	}
	fp = fdopen(fd, "r");
	if (!fp) { close(fd); return false; }
	clear_aggregate_state();
	while (valid && fgets(line, sizeof(line), fp)) {
		size_t count;
		uint64_t v[8];
		line_no++;
		if (!strchr(line, '\n') && !feof(fp)) { valid = false; break; }
		count = split_tsv(line, c, MAX_FIELDS);
		if (!header_seen) {
			if (count != 6 || strcmp(c[0], "ADAPTIVE_STATE") ||
				!state_number(c[1], &saved_version) || (saved_version != 2 && saved_version != 3) ||
				!state_number(c[2], &saved_at) ||
				!state_number(c[3], &saved_epoch) ||
				!state_number(c[4], &saved_fingerprint) ||
				!state_number(c[5], &v[7]) || v[7] > 1 || now < saved_at) valid = false;
			else { saved_network_known = v[7] != 0; header_seen = true; }
			continue;
		}
		if (count == 11 && !strcmp(c[0], "C")) {
			struct context_state *ctx;
			uint64_t key;
			size_t i;
			char *key_fields[6];
			if (!state_number(c[1], &v[0]) || v[0] >= MAX_CONTEXTS ||
				!state_number(c[2], &v[1]) || v[1] == 0 || v[1] > UINT32_MAX ||
				!state_number(c[3], &v[2]) || v[2] > saved_epoch ||
				!state_number(c[4], &v[3]) || !state_number(c[5], &v[4]) ||
				v[4] > now ||
				!state_number(c[6], &v[5]) || v[5] > UINT32_MAX ||
				contexts[v[0]].used) { valid = false; continue; }
			for (i = 0; i < MAX_CONTEXTS; i++) {
				if (!contexts[i].used) continue;
				if (contexts[i].profile == (uint32_t)v[1] &&
					contexts[i].network_epoch == v[2] && contexts[i].key == v[3] &&
					!strcmp(contexts[i].host, c[7]) && !strcmp(contexts[i].scope, c[8]) &&
					!strcmp(contexts[i].transport, c[9]) && !strcmp(contexts[i].family, c[10])) {
					valid = false;
					break;
				}
			}
			if (!valid) continue;
			ctx = &contexts[v[0]];
			ctx->used = true;
			ctx->profile = (uint32_t)v[1];
			ctx->network_epoch = v[2];
			ctx->key = v[3];
			ctx->last_seen_ms = v[4];
			ctx->champion = (uint32_t)v[5];
			if (!copy_field(ctx->host, sizeof(ctx->host), c[7]) ||
				!copy_field(ctx->scope, sizeof(ctx->scope), c[8]) ||
				!copy_field(ctx->transport, sizeof(ctx->transport), c[9]) ||
				!copy_field(ctx->family, sizeof(ctx->family), c[10])) {
				valid = false;
				continue;
			}
			{
				char profile_text[16];
				char epoch_text[32];
				snprintf(profile_text, sizeof(profile_text), "%u", ctx->profile);
				snprintf(epoch_text, sizeof(epoch_text), "%" PRIu64, ctx->network_epoch);
				key_fields[0] = profile_text; key_fields[1] = ctx->host;
				key_fields[2] = ctx->scope; key_fields[3] = ctx->transport;
				key_fields[4] = ctx->family; key_fields[5] = epoch_text;
				key = hash_fields((const char *const *)key_fields, 6);
			}
			if (key != ctx->key) valid = false;
		} else if ((count == 8 || count == 9) && !strcmp(c[0], "S")) {
			struct candidate_state *cand = NULL;
			size_t i;
			if (!state_number(c[1], &v[0]) || v[0] >= MAX_CONTEXTS ||
				!state_number(c[2], &v[1]) || v[1] == 0 || v[1] > UINT32_MAX ||
				!state_number(c[3], &v[2]) ||
				(count == 9 && !state_number(c[4], &v[7])) ||
				!state_number(c[count == 9 ? 5 : 4], &v[3]) ||
				!state_number(c[count == 9 ? 6 : 5], &v[4]) ||
				!state_number(c[count == 9 ? 7 : 6], &v[5]) ||
				!state_number(c[count == 9 ? 8 : 7], &v[6]) || v[6] > 1 ||
				!contexts[v[0]].used || v[5] > now) { valid = false; continue; }
			for (i = 0; i < MAX_CANDIDATES; i++) {
				if (!candidates[i].used) { cand = &candidates[i]; break; }
				if (candidates[i].context_index == v[0] &&
					candidates[i].strategy == v[1]) { valid = false; break; }
			}
			if (!valid) continue;
			if (!cand) { valid = false; continue; }
			cand->used = true;
			cand->context_index = (unsigned)v[0];
			cand->strategy = (uint32_t)v[1];
			cand->successes = v[2];
			cand->active_successes = count == 9 ? v[7] : 0;
			cand->unknown = v[3];
			cand->last_success_ms = v[4];
			cand->last_seen_ms = v[5];
			cand->has_last_success = v[6] != 0;
			if (cand->active_successes > cand->successes ||
				(!cand->has_last_success && cand->last_success_ms != 0) ||
				(cand->has_last_success && cand->successes == 0)) valid = false;
		} else valid = false;
	}
	if (ferror(fp) || !header_seen) valid = false;
	if (fclose(fp) != 0) valid = false;
	if (!valid) {
		clear_aggregate_state();
		fprintf(stderr, "adaptive_controller: ignoring invalid state checkpoint (line %lu)\n", line_no);
		return false;
	}
	{
		bool current_network_known = network_context_known;
		uint64_t current_fingerprint = network_fingerprint;
		network_epoch = saved_epoch;
		network_fingerprint = saved_fingerprint;
		network_context_known = saved_network_known && current_network_known;
		if (!saved_network_known && current_network_known) {
			network_fingerprint = current_fingerprint;
			network_epoch = saved_epoch < UINT64_MAX ? saved_epoch + 1 : 0;
			network_context_known = network_epoch != 0;
		} else if (saved_network_known && current_network_known) {
			if (current_fingerprint != saved_fingerprint) {
				network_epoch = saved_epoch < UINT64_MAX ? saved_epoch + 1 : 0;
				network_context_known = network_epoch != 0;
			}
			network_fingerprint = current_fingerprint;
		}
	}
	expire_state(now);
	return true;
}

static uint64_t fnv1a(const char *s, uint64_t hash)
{
	while (*s) {
		hash ^= (unsigned char)*s++;
		hash *= 1099511628211ULL;
	}
	return hash;
}

static uint64_t hash_fields(const char *const *fields, size_t count)
{
	uint64_t hash = 1469598103934665603ULL;
	size_t i;
	for (i = 0; i < count; i++) {
		hash = fnv1a(fields[i], hash);
		hash ^= 0xff;
		hash *= 1099511628211ULL;
	}
	return hash ? hash : 1;
}

static bool hex_zero(const char *text, size_t expected)
{
	size_t i;
	if (strlen(text) != expected) return false;
	for (i = 0; i < expected; i++) if (text[i] != '0') return false;
	return true;
}

static bool ascii_space(char c)
{
	return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\f' || c == '\v';
}

static size_t split_ws(char *line, char **fields, size_t cap)
{
	size_t count = 0;
	char *p = line;
	while (*p) {
		while (*p && ascii_space(*p)) *p++ = '\0';
		if (!*p) break;
		if (count == cap) return cap + 1;
		fields[count++] = p;
		while (*p && !ascii_space(*p)) p++;
	}
	return count;
}

static bool parse_hex(const char *text, unsigned long *value)
{
	unsigned long result = 0;
	const char *p;
	if (!text || !*text) return false;
	for (p = text; *p; p++) {
		unsigned digit;
		if (*p >= '0' && *p <= '9') digit = (unsigned)(*p - '0');
		else if (*p >= 'a' && *p <= 'f') digit = (unsigned)(*p - 'a') + 10U;
		else if (*p >= 'A' && *p <= 'F') digit = (unsigned)(*p - 'A') + 10U;
		else return false;
		if (result > (ULONG_MAX - digit) / 16UL) return false;
		result = result * 16UL + digit;
	}
	*value = result;
	return true;
}

static void inspect_network_line(const char *path, const char *line,
		bool *default_route, bool *dns_configured)
{
	if (!strcmp(path, "/proc/net/route")) {
		char copy[1024], *fields[12];
		size_t count;
		unsigned long flag_value;
		if (!copy_field(copy, sizeof(copy), line)) return;
		count = split_ws(copy, fields, 12);
		if (count >= 8 && hex_zero(fields[1], 8) && hex_zero(fields[7], 8) &&
			parse_hex(fields[3], &flag_value) && (flag_value & 1UL))
			*default_route = true;
	} else if (!strcmp(path, "/proc/net/ipv6_route")) {
		char copy[1024], *fields[12];
		size_t count;
		unsigned long prefix_value, flag_value;
		if (!copy_field(copy, sizeof(copy), line)) return;
		count = split_ws(copy, fields, 12);
		if (count >= 10 && hex_zero(fields[0], 32) &&
			parse_hex(fields[1], &prefix_value) && prefix_value == 0 &&
			parse_hex(fields[8], &flag_value) && (flag_value & 1UL))
			*default_route = true;
	} else if (!strcmp(path, "/etc/resolv.conf")) {
		char copy[1024], *fields[4];
		size_t count;
		if (!copy_field(copy, sizeof(copy), line)) return;
		count = split_ws(copy, fields, 4);
		if (count >= 2 && !strcmp(fields[0], "nameserver") && fields[1][0] != '#')
			*dns_configured = true;
	}
}

static bool hash_network_file(const char *path, uint64_t *hash, size_t *total,
		bool *found, bool *default_route, bool *dns_configured)
{
	char line[1024];
	FILE *fp = fopen(path, "r");
	if (!fp) return errno == ENOENT;
	*found = true;
	*hash = fnv1a(path, *hash);
	*hash = fnv1a("\xff", *hash);
	while (fgets(line, sizeof(line), fp)) {
		size_t len = strlen(line);
		if (*total > MAX_NETWORK_SNAPSHOT_BYTES - len) {
			fclose(fp);
			return false;
		}
		*total += len;
		*hash = fnv1a(line, *hash);
		inspect_network_line(path, line, default_route, dns_configured);
	}
	if (ferror(fp)) {
		fclose(fp);
		return false;
	}
	return fclose(fp) == 0;
}

static bool network_snapshot_fingerprint(uint64_t *fingerprint,
		bool *default_route, bool *dns_configured)
{
	uint64_t hash = 1469598103934665603ULL;
	size_t total = 0;
	bool route4 = false, route6 = false, resolv = false;
	*default_route = false;
	*dns_configured = false;
	if (!hash_network_file("/proc/net/route", &hash, &total, &route4,
		default_route, dns_configured) ||
		!hash_network_file("/proc/net/ipv6_route", &hash, &total, &route6,
		default_route, dns_configured) ||
		!hash_network_file("/etc/resolv.conf", &hash, &total, &resolv,
		default_route, dns_configured)) return false;
	if (!route4 && !route6) return false;
	(void)resolv;
	*fingerprint = hash ? hash : 1;
	return true;
}

static void network_context_refresh(uint64_t now)
{
	uint64_t fingerprint;
	bool default_route, dns_configured;
	uint8_t degraded_reason = NETWORK_REASON_CANARY_REQUIRED;
	network_last_sample_ms = now;
	if (!network_snapshot_fingerprint(&fingerprint, &default_route, &dns_configured)) {
		network_context_known = false;
		network_degraded_reason = NETWORK_REASON_SNAPSHOT_UNAVAILABLE;
		network_degraded_streak = 0;
		return;
	}
	if (!network_epoch) network_epoch = 1;
	else if (network_fingerprint && fingerprint != network_fingerprint) {
		if (network_epoch == UINT64_MAX) network_epoch = 0;
		else network_epoch++;
	}
	network_fingerprint = fingerprint;
	network_context_known = network_epoch != 0;
	network_default_route = default_route;
	network_dns_configured = dns_configured;
	if (!default_route) degraded_reason = NETWORK_REASON_NO_DEFAULT_ROUTE;
	else if (!dns_configured) degraded_reason = NETWORK_REASON_NO_RESOLVER;
	if (degraded_reason == NETWORK_REASON_CANARY_REQUIRED) {
		network_degraded_reason = degraded_reason;
		network_degraded_streak = 0;
	} else if (network_degraded_reason == degraded_reason) {
		if (network_degraded_streak < 2) network_degraded_streak++;
	} else {
		network_degraded_reason = degraded_reason;
		network_degraded_streak = 1;
	}
}

static void network_context_maybe_refresh(uint64_t now)
{
	if (!network_last_sample_ms || now < network_last_sample_ms ||
		now - network_last_sample_ms >= NETWORK_SAMPLE_INTERVAL_MS)
		network_context_refresh(now);
}

static bool parse_u64(const char *s, uint64_t *out)
{
	char *end;
	unsigned long long value;
	if (!s || !*s || *s == '-') return false;
	errno = 0;
	value = strtoull(s, &end, 10);
	if (errno || *end) return false;
	*out = (uint64_t)value;
	return true;
}

static bool copy_field(char *dst, size_t cap, const char *src)
{
	size_t len = strlen(src);
	if (len >= cap) return false;
	memcpy(dst, src, len + 1);
	return true;
}

static size_t split_tsv(char *line, char **fields, size_t cap)
{
	size_t count = 0;
	char *p = line;
	if (!cap) return 0;
	fields[count++] = p;
	while (*p) {
		if (*p == '\t') {
			*p = '\0';
			if (count == cap) return cap + 1;
			fields[count++] = p + 1;
		} else if (*p == '\n' || *p == '\r') {
			*p = '\0';
		}
		p++;
	}
	return count;
}

static uint64_t monotonic_ms(void)
{
	struct timespec ts;
	if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
	return (uint64_t)ts.tv_sec * 1000ULL + (uint64_t)ts.tv_nsec / 1000000ULL;
}

static void expire_state(uint64_t now)
{
	size_t i;
	for (i = 0; i < MAX_CANDIDATES; i++) {
		if (candidates[i].used && now >= candidates[i].last_seen_ms &&
			now - candidates[i].last_seen_ms > STATE_TTL_MS)
			memset(&candidates[i], 0, sizeof(candidates[i]));
	}
	for (i = 0; i < MAX_CONTEXTS; i++) {
		if (contexts[i].used && now >= contexts[i].last_seen_ms &&
			now - contexts[i].last_seen_ms > STATE_TTL_MS) {
			memset(&contexts[i], 0, sizeof(contexts[i]));
		}
	}
}

static int find_or_create_flow(uint64_t id)
{
	int free_slot = -1;
	size_t i;
	for (i = 0; i < MAX_OPEN_FLOWS; i++) {
		if (flows[i].used && flows[i].id == id) return (int)i;
		if (!flows[i].used && free_slot < 0) free_slot = (int)i;
	}
	if (free_slot >= 0) {
		memset(&flows[free_slot], 0, sizeof(flows[free_slot]));
		flows[free_slot].used = true;
		flows[free_slot].id = id;
	}
	return free_slot;
}

static int find_context(uint32_t profile, const char *host, const char *scope,
		const char *transport, const char *family, uint64_t epoch, uint64_t key)
{
	size_t i;
	int free_slot = -1;
	for (i = 0; i < MAX_CONTEXTS; i++) {
		struct context_state *ctx = &contexts[i];
		if (!ctx->used) {
			if (free_slot < 0) free_slot = (int)i;
			continue;
		}
		if (ctx->key == key && ctx->profile == profile && ctx->network_epoch == epoch &&
			!strcmp(ctx->host, host) && !strcmp(ctx->scope, scope) &&
			!strcmp(ctx->transport, transport) && !strcmp(ctx->family, family))
			return (int)i;
	}
	if (free_slot < 0) return -1;
	{
		struct context_state *ctx = &contexts[free_slot];
		memset(ctx, 0, sizeof(*ctx));
		ctx->used = true;
		ctx->key = key;
		ctx->profile = profile;
		ctx->network_epoch = epoch;
		if (!copy_field(ctx->host, sizeof(ctx->host), host) ||
			!copy_field(ctx->scope, sizeof(ctx->scope), scope) ||
			!copy_field(ctx->transport, sizeof(ctx->transport), transport) ||
			!copy_field(ctx->family, sizeof(ctx->family), family)) {
			memset(ctx, 0, sizeof(*ctx));
			return -1;
		}
	}
	return free_slot;
}

static int find_or_create_candidate(unsigned context_index, uint32_t strategy,
		uint64_t now)
{
	int free_slot = -1;
	size_t i;
	for (i = 0; i < MAX_CANDIDATES; i++) {
		if (candidates[i].used && candidates[i].context_index == context_index &&
			candidates[i].strategy == strategy) return (int)i;
		if (!candidates[i].used && free_slot < 0) free_slot = (int)i;
	}
	if (free_slot < 0) return -1;
	memset(&candidates[free_slot], 0, sizeof(candidates[free_slot]));
	candidates[free_slot].used = true;
	candidates[free_slot].context_index = context_index;
	candidates[free_slot].strategy = strategy;
	candidates[free_slot].last_seen_ms = now;
	return free_slot;
}

static bool probe_host_valid(const char *host)
{
	size_t i, n = strlen(host);
	if (!n || n >= HOST_CAP || host[0] == '.' || host[n - 1] == '.') return false;
	for (i = 0; i < n; i++) {
		unsigned char c = (unsigned char)host[i];
		if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
			(c >= '0' && c <= '9') || c == '.' || c == '-')) return false;
	}
	return true;
}

static bool probe_flow_id_completed(uint64_t flow_id)
{
	size_t i;
	for (i = 0; i < sizeof(completed_probe_flows) / sizeof(completed_probe_flows[0]); i++)
		if (completed_probe_flows[i] == flow_id) return true;
	return false;
}

static void probe_emit_outcome(const char *outcome, const char *reason)
{
	struct probe_state *p = &active_probe;
	printf("PROBE_OUTCOME\t%" PRIu64 "\t%s\t%s\t%u\t%u\t%" PRIu64
		"\t%s\t%u\t%u\t%u\t%" PRIu64 "\t%" PRIu64 "\n",
		p->id, outcome, reason, p->profile, p->strategy, p->generation, p->host,
		p->source_port, p->curl_rc, p->http_status, p->elapsed_ms, p->flow_id);
}

static void probe_remember_port(uint64_t now, uint32_t source_port)
{
	struct probe_tombstone *t = &probe_tombstones[probe_tombstone_next++ %
		(sizeof(probe_tombstones) / sizeof(probe_tombstones[0]))];
	t->used = true;
	t->source_port = source_port;
	t->expires_ms = now + PROBE_GRACE_MS;
}

static bool probe_port_recent(uint64_t now, uint32_t source_port)
{
	size_t i;
	for (i = 0; i < sizeof(probe_tombstones) / sizeof(probe_tombstones[0]); i++) {
		if (probe_tombstones[i].used && now >= probe_tombstones[i].expires_ms)
			memset(&probe_tombstones[i], 0, sizeof(probe_tombstones[i]));
		if (probe_tombstones[i].used && probe_tombstones[i].source_port == source_port)
			return true;
	}
	return false;
}

static void probe_record_active_success(uint64_t now)
{
	struct probe_state *p = &active_probe;
	char profile_text[16], epoch_text[32];
	char *key_fields[6];
	uint64_t key;
	int ci, candidate_index;
	struct candidate_state *cand;
	if (p->health_state == NETWORK_HEALTH_DEGRADED || !p->network_context_usable) return;
	snprintf(profile_text, sizeof(profile_text), "%u", p->profile);
	snprintf(epoch_text, sizeof(epoch_text), "%" PRIu64, p->network_epoch);
	key_fields[0] = profile_text; key_fields[1] = p->host;
	key_fields[2] = (char *)"learning"; key_fields[3] = p->transport;
	key_fields[4] = p->family; key_fields[5] = epoch_text;
	key = hash_fields((const char *const *)key_fields, 6);
	ci = find_context(p->profile, p->host, "learning", p->transport, p->family,
		p->network_epoch, key);
	if (ci < 0) return;
	candidate_index = find_or_create_candidate((unsigned)ci, p->strategy, now);
	if (candidate_index < 0) return;
	cand = &candidates[candidate_index];
	cand->last_seen_ms = now;
	if (!cand->has_last_success ||
		(now >= cand->last_success_ms && now - cand->last_success_ms >= COHORT_WINDOW_MS)) {
		cand->successes++;
		cand->active_successes++;
		cand->last_success_ms = now;
		cand->has_last_success = true;
	}
}

static void probe_maybe_finalize(uint64_t now, bool expired)
{
	struct probe_state *p = &active_probe;
	bool valid, success;
	if (!p->active) return;
	if (!expired && !(p->result_seen && p->flow_seen && now >= p->join_ready_ms)) return;
	valid = p->result_seen && p->flow_seen && !p->flow_ambiguous;
	success = valid && p->curl_rc == 0 && p->http_status >= 100 && p->http_status <= 599;
	if (success) {
		probe_record_active_success(now);
		probe_emit_outcome("STRONG_SUCCESS", "HTTP_RESPONSE_AND_C_FLOW");
	} else {
		probe_emit_outcome("UNKNOWN", p->flow_ambiguous ? "AMBIGUOUS_FLOW" :
			(expired ? "JOIN_TIMEOUT" : "NO_CONFIRMED_HTTP_RESPONSE"));
	}
	if (p->flow_seen && p->flow_id)
		completed_probe_flows[completed_probe_flow_next++ %
			(sizeof(completed_probe_flows) / sizeof(completed_probe_flows[0]))] = p->flow_id;
	probe_remember_port(now, p->source_port);
	p->active = false;
}

static bool probe_event_matches(char **c, uint32_t source_port)
{
	const struct probe_state *p = &active_probe;
	uint64_t profile, strategy, generation;
	if (!p->active || source_port != p->source_port || strcmp(c[2], "FLOW_END")) return false;
	if (!parse_u64(c[4], &profile) || !parse_u64(c[5], &strategy) ||
		!parse_u64(c[6], &generation)) return false;
	return profile == p->profile && strategy == p->strategy && generation == p->generation &&
		!strcmp(c[7], "learning") && !strcmp(c[8], p->host) &&
		!strcmp(c[9], "tcp") && !strcmp(c[12], "443");
}

static unsigned rank_candidate(unsigned context_index, uint32_t strategy,
		uint64_t successes, unsigned *candidate_count, uint32_t *top_strategy)
{
	unsigned rank = successes ? 1 : 0, count = 0;
	uint64_t top_successes = 0;
	size_t i;
	*top_strategy = 0;
	for (i = 0; i < MAX_CANDIDATES; i++) {
		const struct candidate_state *other = &candidates[i];
		if (!other->used || other->context_index != context_index) continue;
		count++;
		if (!other->successes) continue;
		if (!*top_strategy || other->successes > top_successes ||
			(other->successes == top_successes && other->strategy < *top_strategy)) {
			top_successes = other->successes;
			*top_strategy = other->strategy;
		}
		if (other->successes > successes ||
			(other->successes == successes && other->strategy < strategy)) rank++;
	}
	*candidate_count = count;
	return rank;
}

static uint32_t confidence_lcb95_milli(uint64_t successes)
{
	/* Conservative integer approximation to the Wilson lower bound, z ~= 1.96. */
	uint64_t denominator, penalty;
	if (!successes) return 0;
	if (successes > UINT64_MAX - 4) return 100000;
	denominator = successes + 4;
	penalty = 400000ULL / denominator + (400000ULL % denominator != 0);
	return penalty > 100000ULL ? 0 : (uint32_t)(100000ULL - penalty);
}

static bool same_assignment(const struct flow_state *f, uint32_t profile,
		uint32_t strategy, uint64_t generation)
{
	return f->profile == profile && f->strategy == strategy &&
		f->generation == generation;
}

static void network_health_current(uint8_t *state, uint8_t *reason)
{
	if (!network_context_known) {
		*state = NETWORK_HEALTH_UNKNOWN;
		*reason = NETWORK_REASON_SNAPSHOT_UNAVAILABLE;
	} else if (network_degraded_streak >= 2 &&
		network_degraded_reason == NETWORK_REASON_NO_DEFAULT_ROUTE) {
		*state = NETWORK_HEALTH_DEGRADED;
		*reason = NETWORK_REASON_NO_DEFAULT_ROUTE;
	} else if (network_degraded_streak >= 2 &&
		network_degraded_reason == NETWORK_REASON_NO_RESOLVER) {
		*state = NETWORK_HEALTH_DEGRADED;
		*reason = NETWORK_REASON_NO_RESOLVER;
	} else if (!network_default_route || !network_dns_configured) {
		*state = NETWORK_HEALTH_UNKNOWN;
		*reason = NETWORK_REASON_CONFIG_UNCONFIRMED;
	} else {
		*state = NETWORK_HEALTH_UNKNOWN;
		*reason = NETWORK_REASON_CANARY_REQUIRED;
	}
}

static const char *network_health_name(uint8_t state)
{
	return state == NETWORK_HEALTH_DEGRADED ? "DEGRADED" : "UNKNOWN";
}

static const char *network_health_reason_name(uint8_t reason)
{
	switch (reason) {
	case NETWORK_REASON_NO_DEFAULT_ROUTE: return "NO_MAIN_DEFAULT_ROUTE";
	case NETWORK_REASON_NO_RESOLVER: return "NO_RESOLVER_CONFIG";
	case NETWORK_REASON_CONFIG_UNCONFIRMED: return "CONFIG_DEGRADATION_UNCONFIRMED";
	case NETWORK_REASON_CANARY_REQUIRED: return "CANARY_REQUIRED";
	default: return "SNAPSHOT_UNAVAILABLE";
	}
}

static void process_event(char **c, uint64_t now, uint32_t source_port)
{
	uint64_t event_ms, flow_id, generation, tuple_hash;
	uint64_t telemetry[14];
	uint64_t profile64, strategy64, port64;
	uint32_t profile, strategy;
	size_t i;
	int fi;
	struct flow_state *flow;
	char source_port_text[8];
	char *tuple_fields[5];
	bool valid_ids, leased_flow;

	if (network_sampling_enabled) network_context_maybe_refresh(now);
	if (strcmp(c[0], "v2")) return;
	valid_ids = parse_u64(c[1], &event_ms) && parse_u64(c[3], &flow_id) &&
		parse_u64(c[4], &profile64) && parse_u64(c[5], &strategy64) &&
		parse_u64(c[6], &generation) && parse_u64(c[12], &port64);
	if (!valid_ids || profile64 > UINT32_MAX || strategy64 > UINT32_MAX ||
		port64 > 65535 || flow_id == 0) return;
	for (i = 0; i < 14; i++) if (!parse_u64(c[13 + i], &telemetry[i])) return;
	if (telemetry[4] > 1 || telemetry[5] > 1 || telemetry[6] > 1 ||
		telemetry[7] > 1 || telemetry[8] > 1 || telemetry[9] > 1) return;
	profile = (uint32_t)profile64;
	strategy = (uint32_t)strategy64;
	if (!strcmp(c[2], "FLOW_END") && probe_flow_id_completed(flow_id)) return;
	if (!strcmp(c[2], "FLOW_END") && source_port &&
		!(active_probe.active && source_port == active_probe.source_port) &&
		probe_port_recent(now, source_port)) return;
	if (active_probe.active && source_port == active_probe.source_port &&
		!strcmp(c[2], "FLOW_START")) {
		if (active_probe.candidate_flow_id && active_probe.candidate_flow_id != flow_id)
			active_probe.flow_ambiguous = true;
		else active_probe.candidate_flow_id = flow_id;
		if ((c[7][0] && strcmp(c[7], "learning")) ||
			(c[8][0] && strcmp(c[8], active_probe.host))) active_probe.flow_ambiguous = true;
	}
	snprintf(source_port_text, sizeof(source_port_text), "%u", source_port);
	tuple_fields[0] = c[9]; tuple_fields[1] = c[10];
	tuple_fields[2] = c[11]; tuple_fields[3] = c[12]; tuple_fields[4] = source_port_text;
	tuple_hash = hash_fields((const char *const *)tuple_fields, 5);

	if (!strcmp(c[2], "TRACE_LIMIT")) {
		puts("TRACE_INCOMPLETE\tmax_bytes");
		return;
	}
	if (strcmp(c[2], "FLOW_START") && strcmp(c[2], "STRATEGY_APPLIED") &&
		strcmp(c[2], "STRATEGY_CONFLICT") && strcmp(c[2], "FLOW_END")) return;
	fi = find_or_create_flow(flow_id);
	if (fi < 0) {
		puts("CONTROLLER_OVERFLOW\topen_flow_capacity");
		return;
	}
	flow = &flows[fi];
	if (!flow->tuple_hash) flow->tuple_hash = tuple_hash;
	else if (flow->tuple_hash != tuple_hash) flow->identity_conflict = true;
	if (flow->source_port && source_port && flow->source_port != source_port)
		flow->identity_conflict = true;
	if (!flow->source_port) flow->source_port = source_port;
	if (strcmp(flow->transport, "") && strcmp(flow->transport, c[9]))
		flow->identity_conflict = true;
	if (!flow->transport[0]) copy_field(flow->transport, sizeof(flow->transport), c[9]);
	if (strcmp(flow->family, "") && strcmp(flow->family, c[10]))
		flow->identity_conflict = true;
	if (!flow->family[0]) copy_field(flow->family, sizeof(flow->family), c[10]);
	if (!strcmp(c[2], "FLOW_START")) {
		if (flow->started) {
			if (flow->network_epoch != (network_context_known ? network_epoch : 0))
				flow->identity_conflict = true;
		} else {
			flow->started = true;
			flow->network_epoch = network_context_known ? network_epoch : 0;
			flow->network_context_usable = !network_sampling_enabled || network_context_known;
			network_health_current(&flow->health_state, &flow->health_reason);
		}
		return;
	}

	if (!strcmp(c[2], "STRATEGY_APPLIED")) {
		if (flow->assigned && !same_assignment(flow, profile, strategy, generation))
			flow->strategy_conflict = true;
		else {
			if ((flow->scope[0] && strcmp(flow->scope, c[7])) ||
				(flow->host[0] && c[8][0] && strcmp(flow->host, c[8])))
				flow->strategy_conflict = true;
			flow->assigned = true;
			flow->profile = profile;
			flow->strategy = strategy;
			flow->generation = generation;
			if (!flow->host[0] && !copy_field(flow->host, sizeof(flow->host), c[8]))
				flow->strategy_conflict = true;
			if (!flow->scope[0] && !copy_field(flow->scope, sizeof(flow->scope), c[7]))
				flow->strategy_conflict = true;
		}
		return;
	}
	if (!strcmp(c[2], "STRATEGY_CONFLICT")) {
		flow->strategy_conflict = true;
		return;
	}
	if (strcmp(c[2], "FLOW_END")) return;
	if (flow->assigned && !same_assignment(flow, profile, strategy, generation))
		flow->strategy_conflict = true;
	if (!flow->host[0] && c[8][0]) {
		if (!copy_field(flow->host, sizeof(flow->host), c[8])) flow->identity_conflict = true;
	} else if (flow->host[0] && c[8][0] && strcmp(flow->host, c[8]))
		flow->identity_conflict = true;
	if (!flow->scope[0]) {
		if (!copy_field(flow->scope, sizeof(flow->scope), c[7])) flow->strategy_conflict = true;
	} else if (strcmp(flow->scope, c[7])) flow->strategy_conflict = true;
	leased_flow = active_probe.active && flow->source_port == active_probe.source_port;
	if (leased_flow) {
		if (!probe_event_matches(c, flow->source_port) ||
			!flow->started || !flow->assigned || flow->identity_conflict ||
			flow->strategy_conflict || !flow->network_context_usable ||
			flow->health_state == NETWORK_HEALTH_DEGRADED ||
			active_probe.candidate_flow_id != flow_id ||
			(active_probe.flow_seen && active_probe.flow_id != flow_id)) {
			active_probe.flow_ambiguous = true;
		} else {
			active_probe.flow_seen = true;
			active_probe.flow_id = flow_id;
			active_probe.join_ready_ms = now + 1000ULL;
			active_probe.network_epoch = flow->network_epoch;
			active_probe.health_state = flow->health_state;
			active_probe.network_context_usable = flow->network_context_usable;
			copy_field(active_probe.transport, sizeof(active_probe.transport), flow->transport);
			copy_field(active_probe.family, sizeof(active_probe.family), flow->family);
		}
		probe_maybe_finalize(now, false);
		memset(flow, 0, sizeof(*flow));
		return;
	}
	{
		bool usable = flow->started && flow->assigned && flow->profile > 0 && flow->strategy > 0 &&
			flow->generation > 0 && !flow->strategy_conflict && !flow->identity_conflict &&
			flow->scope[0] && flow->host[0] && flow->network_context_usable;
		bool freeze_learning = usable && flow->health_state == NETWORK_HEALTH_DEGRADED;
		bool success = telemetry[5] != 0;
		const char *evidence = success ? "WEAK_SUCCESS" : "UNKNOWN";
		const char *action = freeze_learning ? "NETWORK_GATE_FROZEN" : "UNATTRIBUTED";
		uint32_t champion = 0, challenger = 0, top_strategy = 0;
		uint32_t confidence = 0;
		unsigned rank = 0, candidate_count = 0;
		bool independent = false;
		int ci = -1, candidate_index = -1;
		uint64_t context_key = 0;
		char epoch_output[32];
		const char *health_output = network_health_name(flow->health_state);
		const char *health_reason_output = network_health_reason_name(flow->health_reason);
		if (usable && !freeze_learning) {
			const char *ctx_fields[6];
			char epoch_text[32];
			int context_index;
			snprintf(epoch_text, sizeof(epoch_text), "%" PRIu64, flow->network_epoch);
			ctx_fields[0] = c[4]; ctx_fields[1] = flow->host;
			ctx_fields[2] = flow->scope; ctx_fields[3] = flow->transport;
			ctx_fields[4] = flow->family; ctx_fields[5] = epoch_text;
			context_key = hash_fields(ctx_fields, 6);
			context_index = find_context(flow->profile, flow->host, flow->scope,
				flow->transport, flow->family, flow->network_epoch, context_key);
			if (context_index >= 0) {
				struct context_state *ctx = &contexts[context_index];
				ctx->last_seen_ms = now;
				champion = ctx->champion;
				candidate_index = find_or_create_candidate((unsigned)context_index,
					flow->strategy, now);
				if (candidate_index >= 0) {
					struct candidate_state *cand = &candidates[candidate_index];
					cand->last_seen_ms = now;
					if (success) {
						independent = !cand->has_last_success ||
							(event_ms >= cand->last_success_ms &&
							 event_ms - cand->last_success_ms >= COHORT_WINDOW_MS);
						if (independent) {
							cand->successes++;
							cand->last_success_ms = event_ms;
							cand->has_last_success = true;
						}
					} else cand->unknown++;
					if (!champion && candidates[candidate_index].successes >= 2) {
						ctx->champion = flow->strategy;
						champion = flow->strategy;
						action = "SHADOW_INITIAL_CHAMPION";
					} else if (!champion)
						action = success ? "CANDIDATE_OBSERVED" : "UNKNOWN_NO_UPDATE";
					else if (champion == flow->strategy)
						action = success ? "KEEP_CHAMPION" : "UNKNOWN_NO_UPDATE";
					else {
						challenger = flow->strategy;
						action = candidates[candidate_index].successes >= 2 ?
							"CHALLENGER_READY" : "CHALLENGER_OBSERVED";
					}
					confidence = confidence_lcb95_milli(cand->successes);
					rank = rank_candidate((unsigned)context_index, flow->strategy,
						cand->successes, &candidate_count, &top_strategy);
					ci = context_index;
				} else usable = false;
			} else usable = false;
		}
		if (flow->network_epoch)
			snprintf(epoch_output, sizeof(epoch_output), "%" PRIu64, flow->network_epoch);
		else strcpy(epoch_output, "unknown");
		printf("FLOW_OUTCOME\t%" PRIu64 "\t%u\t%u\t%" PRIu64
			"\t%s\t%s\t%u\t%u\t%s\t%d\t%u\t%u\t%u\t%u\tNONE\t%s"
			"\t%s\t%s\t%s\t%s\t%s\t%s"
			"\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s"
			"\t%s\t%s\t%s\t%s\t%s\t%u\n",
		flow_id, flow->profile, flow->strategy, flow->generation, evidence,
			usable ? (ci >= 0 ? contexts[ci].host : flow->host) : "", champion,
			challenger, action, independent ? 1 : 0, confidence, rank,
			candidate_count, top_strategy,
			freeze_learning ? "NETWORK_FROZEN" : (usable ? "SHADOW_ONLY" : "UNATTRIBUTED"),
			flow->scope, flow->transport, flow->family, epoch_output,
			health_output, health_reason_output,
			c[13], c[14], c[15], c[16], c[17], c[18], c[19], c[20], c[21], c[22],
			c[23], c[24], c[25], c[26], c[27], flow->source_port);
		(void)candidate_index; (void)context_key;
	}
	memset(flow, 0, sizeof(*flow));
}

static volatile sig_atomic_t controller_stopping;

static void on_stop(int sig)
{
	(void)sig;
	controller_stopping = 1;
}

static size_t clear_open_flows(void)
{
	size_t i, count = 0;
	for (i = 0; i < MAX_OPEN_FLOWS; i++) {
		if (flows[i].used) {
			count++;
			memset(&flows[i], 0, sizeof(flows[i]));
		}
	}
	return count;
}

static void process_line(char *line, unsigned long line_no)
{
	char *fields[MAX_FIELDS];
	char *normalized[MAX_FIELDS];
	size_t count, i;
	uint32_t source_port = 0;
	if (!strncmp(line, "# TRACE_LIMIT", 13)) {
		puts("TRACE_INCOMPLETE\tmax_bytes");
		if (active_probe.active) {
			active_probe.flow_ambiguous = true;
			probe_maybe_finalize(monotonic_ms(), true);
		}
		return;
	}
	if (!strncmp(line, "# EVENT_GAP\t", 12)) {
		char *end;
		unsigned long long dropped = strtoull(line + 12, &end, 10);
		size_t invalidated = clear_open_flows();
		if (end == line + 12 || (*end && *end != '\n' && *end != '\r')) dropped = 0;
		printf("TRACE_INCOMPLETE\tevent_gap\tdropped=%llu\topen_flows_discarded=%lu\n",
			 dropped, (unsigned long)invalidated);
		if (active_probe.active) {
			active_probe.flow_ambiguous = true;
			probe_maybe_finalize(monotonic_ms(), true);
		}
		return;
	}
	if (!line[0] || line[0] == '#') return;
	count = split_tsv(line, fields, MAX_FIELDS);
	if (count == 29 && !strcmp(fields[0], "v3")) {
		uint64_t source_port64;
		if (!parse_u64(fields[13], &source_port64) || source_port64 > 65535) {
			printf("INPUT_REJECTED\t%lu\tbad_v3_source_port\n", line_no);
			return;
		}
		source_port = (uint32_t)source_port64;
		for (i = 0; i < 13; i++) normalized[i] = fields[i];
		for (i = 13; i < 28; i++) normalized[i] = fields[i + 1];
		normalized[0] = "v2";
		fields[0] = normalized[0];
		expire_state(monotonic_ms());
		process_event(normalized, monotonic_ms(), source_port);
		return;
	}
	if (count != 28 || strcmp(fields[0], "v2")) {
		printf("INPUT_REJECTED\t%lu\tbad_v2_v3_record\n", line_no);
		return;
	}
	expire_state(monotonic_ms());
	process_event(fields, monotonic_ms(), source_port);
}

static void report_open_flows(void)
{
	size_t i, open_flows = 0;
	for (i = 0; i < MAX_OPEN_FLOWS; i++) if (flows[i].used) open_flows++;
	if (open_flows) printf("TRACE_INCOMPLETE\topen_flows=%lu\n", (unsigned long)open_flows);
}

/* Send one acknowledged candidate update to an isolated nfqws2 learning worker. */
static int set_worker_candidate(const char *worker_path, uint32_t profile, uint32_t strategy)
{
	int fd = -1, result = 1;
	struct sockaddr_un local, remote;
	struct stat before, current;
	struct timeval timeout = { 2, 0 };
	char local_path[sizeof(local.sun_path)], request[96], reply[192];
	int n;
	ssize_t received;
	if (!worker_path || worker_path[0] != '/' || strlen(worker_path) >= sizeof(remote.sun_path) ||
		!profile || !strategy) return 2;
	if (snprintf(local_path, sizeof(local_path), "/tmp/zator-adaptive/set-%ld.sock", (long)getpid()) >= (int)sizeof(local_path)) return 2;
	if (lstat(local_path, &before) == 0 || errno != ENOENT) {
		fputs("adaptive_controller: local control socket path is unavailable\n", stderr);
		return 1;
	}
	fd = socket(AF_UNIX, SOCK_DGRAM, 0);
	if (fd < 0) { perror("adaptive_controller: control socket"); goto done; }
	memset(&local, 0, sizeof(local));
	local.sun_family = AF_UNIX;
	memcpy(local.sun_path, local_path, strlen(local_path) + 1);
	if (bind(fd, (struct sockaddr *)&local, sizeof(local)) != 0 || chmod(local_path, 0600) != 0) {
		perror("adaptive_controller: bind control socket"); goto done;
	}
	if (setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) != 0) {
		perror("adaptive_controller: control timeout"); goto done;
	}
	memset(&remote, 0, sizeof(remote));
	remote.sun_family = AF_UNIX;
	memcpy(remote.sun_path, worker_path, strlen(worker_path) + 1);
	n = snprintf(request, sizeof(request), "SET_CANDIDATE\t1\t%u\t%u\n", profile, strategy);
	if (n < 0 || (size_t)n >= sizeof(request) ||
		sendto(fd, request, (size_t)n, 0, (struct sockaddr *)&remote, sizeof(remote)) != n) {
		perror("adaptive_controller: send candidate"); goto done;
	}
	received = recv(fd, reply, sizeof(reply) - 1, 0);
	if (received < 0) { perror("adaptive_controller: candidate acknowledgement"); goto done; }
	reply[received] = '\0';
	{
		unsigned ack_profile = 0, ack_strategy = 0;
		unsigned long long generation = 0;
		char tail = 0;
		if (sscanf(reply, "ACK\t1\tOK\t%u\t%u\t%llu\n%c", &ack_profile,
			&ack_strategy, &generation, &tail) != 3 || ack_profile != profile ||
			ack_strategy != strategy || !generation) {
			fprintf(stderr, "adaptive_controller: worker rejected candidate: %s", reply);
			goto done;
		}
		printf("candidate_applied\tprofile=%u\tstrategy=%u\tgeneration=%llu\n",
			profile, strategy, generation);
	}
	result = 0;
done:
	if (fd >= 0) close(fd);
	if (lstat(local_path, &current) == 0 && S_ISSOCK(current.st_mode) && current.st_uid == geteuid())
		(void)unlink(local_path);
	return result;
}

static int get_worker_candidate(const char *worker_path)
{
	int fd = -1, result = 1, n;
	struct sockaddr_un local, remote;
	struct stat before, current;
	struct timeval timeout = { 2, 0 };
	char local_path[sizeof(local.sun_path)], reply[192];
	ssize_t received;
	if (!worker_path || worker_path[0] != '/' || strlen(worker_path) >= sizeof(remote.sun_path)) return 2;
	if (snprintf(local_path, sizeof(local_path), "/tmp/zator-adaptive/get-%ld.sock", (long)getpid()) >= (int)sizeof(local_path)) return 2;
	if (lstat(local_path, &before) == 0 || errno != ENOENT) {
		fputs("adaptive_controller: local control socket path is unavailable\n", stderr);
		return 1;
	}
	fd = socket(AF_UNIX, SOCK_DGRAM, 0);
	if (fd < 0) { perror("adaptive_controller: control socket"); goto done; }
	memset(&local, 0, sizeof(local));
	local.sun_family = AF_UNIX;
	memcpy(local.sun_path, local_path, strlen(local_path) + 1);
	if (bind(fd, (struct sockaddr *)&local, sizeof(local)) != 0 || chmod(local_path, 0600) != 0) {
		perror("adaptive_controller: bind control socket"); goto done;
	}
	if (setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) != 0) {
		perror("adaptive_controller: control timeout"); goto done;
	}
	memset(&remote, 0, sizeof(remote));
	remote.sun_family = AF_UNIX;
	memcpy(remote.sun_path, worker_path, strlen(worker_path) + 1);
	n = (int)sizeof("GET_CANDIDATE\t1\n") - 1;
	if (sendto(fd, "GET_CANDIDATE\t1\n", (size_t)n, 0,
		(struct sockaddr *)&remote, sizeof(remote)) != n) {
		perror("adaptive_controller: query candidate"); goto done;
	}
	received = recv(fd, reply, sizeof(reply) - 1, 0);
	if (received < 0) { perror("adaptive_controller: candidate response"); goto done; }
	reply[received] = '\0';
	if (!strcmp(reply, "ACK\t1\tERR\tno_candidate\n")) {
		fputs("adaptive_controller: worker has no candidate\n", stderr);
		goto done;
	}
	{
		unsigned profile = 0, strategy = 0;
		unsigned long long generation = 0;
		char tail = 0;
		if (sscanf(reply, "ACK\t1\tOK\t%u\t%u\t%llu\n%c", &profile,
			&strategy, &generation, &tail) != 3 || !profile || !strategy || !generation) {
			fputs("adaptive_controller: invalid worker response\n", stderr);
			goto done;
		}
		printf("candidate_current\tprofile=%u\tstrategy=%u\tgeneration=%llu\n",
			profile, strategy, generation);
	}
	result = 0;
done:
	if (fd >= 0) close(fd);
	if (lstat(local_path, &current) == 0 && S_ISSOCK(current.st_mode) && current.st_uid == geteuid())
		(void)unlink(local_path);
	return result;
}

static void controller_reply(int fd, const struct sockaddr_un *peer, socklen_t peer_len,
		const char *reply)
{
	if (peer_len > offsetof(struct sockaddr_un, sun_path) && peer->sun_path[0])
		(void)sendto(fd, reply, strlen(reply), 0,
			(const struct sockaddr *)peer, peer_len);
}

/* Process bounded probe lease messages on the same private socket as C events. */
static bool handle_probe_command(char *line, int fd, const struct sockaddr_un *peer,
		socklen_t peer_len, uint64_t now)
{
	char *f[MAX_FIELDS];
	size_t n;
	char reply[160];
	uint64_t a, b, c, d;
	if (strncmp(line, "PROBE_", 6)) return false;
	n = split_tsv(line, f, MAX_FIELDS);
	if (n == 7 && !strcmp(f[0], "PROBE_BEGIN") && !strcmp(f[1], "v1")) {
		if (!probe_host_valid(f[2]) || !parse_u64(f[3], &a) || a < 62000 || a > 62015 ||
			!parse_u64(f[4], &b) || b != 1 || !parse_u64(f[5], &c) || !c || c > UINT32_MAX ||
			!parse_u64(f[6], &d) || !d) {
			controller_reply(fd, peer, peer_len, "ACK\tPROBE_BEGIN\tERR\tinvalid\n");
			return true;
		}
		if (active_probe.active) {
			controller_reply(fd, peer, peer_len, "ACK\tPROBE_BEGIN\tERR\tbusy\n");
			return true;
		}
		memset(&active_probe, 0, sizeof(active_probe));
		active_probe.active = true;
		active_probe.source_port = (uint32_t)a;
		active_probe.profile = (uint32_t)b;
		active_probe.strategy = (uint32_t)c;
		active_probe.generation = d;
		active_probe.started_ms = now;
		active_probe.deadline_ms = now + PROBE_GRACE_MS;
		if (!copy_field(active_probe.host, sizeof(active_probe.host), f[2])) {
			memset(&active_probe, 0, sizeof(active_probe));
			controller_reply(fd, peer, peer_len, "ACK\tPROBE_BEGIN\tERR\tinvalid\n");
			return true;
		}
		next_probe_id++;
		if (!next_probe_id) next_probe_id++;
		active_probe.id = next_probe_id;
		snprintf(reply, sizeof(reply), "ACK\tPROBE_BEGIN\tOK\t%" PRIu64 "\n", active_probe.id);
		controller_reply(fd, peer, peer_len, reply);
		printf("PROBE_BEGIN\t%" PRIu64 "\t%s\t%u\t%u\t%u\t%" PRIu64 "\n",
			active_probe.id, active_probe.host, active_probe.source_port,
			active_probe.profile, active_probe.strategy, active_probe.generation);
		return true;
	}
	if (n == 6 && !strcmp(f[0], "PROBE_RESULT") && !strcmp(f[1], "v1")) {
		if (!parse_u64(f[2], &a) || !a || !parse_u64(f[3], &b) || b > 255 ||
			!parse_u64(f[4], &c) || c > 599 || !parse_u64(f[5], &d)) {
			controller_reply(fd, peer, peer_len, "ACK\tPROBE_RESULT\tERR\tinvalid\n");
			return true;
		}
		if (active_probe.id != a || (!active_probe.active && !active_probe.result_seen)) {
			controller_reply(fd, peer, peer_len, "ACK\tPROBE_RESULT\tERR\tstale\n");
			return true;
		}
		if (active_probe.result_seen) {
			if (active_probe.curl_rc != b || active_probe.http_status != c || active_probe.elapsed_ms != d)
				controller_reply(fd, peer, peer_len, "ACK\tPROBE_RESULT\tERR\tconflict\n");
			else controller_reply(fd, peer, peer_len, "ACK\tPROBE_RESULT\tOK\tduplicate\n");
			return true;
		}
		active_probe.result_seen = true;
		active_probe.curl_rc = (uint32_t)b;
		active_probe.http_status = (uint32_t)c;
		active_probe.elapsed_ms = d;
		controller_reply(fd, peer, peer_len, "ACK\tPROBE_RESULT\tOK\n");
		probe_maybe_finalize(now, false);
		return true;
	}
	controller_reply(fd, peer, peer_len, "ACK\tPROBE\tERR\tbad_request\n");
	return true;
}

static int controller_probe_request(const char *path, const char *request, char *reply, size_t reply_cap)
{
	int fd = -1, result = 1;
	struct sockaddr_un local, remote;
	struct stat before, current;
	struct timeval timeout = { 3, 0 };
	char local_path[sizeof(local.sun_path)];
	ssize_t received;
	if (!path || path[0] != '/' || strlen(path) >= sizeof(remote.sun_path) ||
		snprintf(local_path, sizeof(local_path), "/tmp/zator-adaptive/pr-%ld.sock", (long)getpid()) >= (int)sizeof(local_path)) return 2;
	if (lstat(local_path, &before) == 0 || errno != ENOENT) return 1;
	fd = socket(AF_UNIX, SOCK_DGRAM, 0);
	if (fd < 0) goto done;
	memset(&local, 0, sizeof(local)); local.sun_family = AF_UNIX;
	memcpy(local.sun_path, local_path, strlen(local_path) + 1);
	if (bind(fd, (struct sockaddr *)&local, sizeof(local)) != 0 || chmod(local_path, 0600) != 0 ||
		setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) != 0) goto done;
	memset(&remote, 0, sizeof(remote)); remote.sun_family = AF_UNIX;
	memcpy(remote.sun_path, path, strlen(path) + 1);
	if (sendto(fd, request, strlen(request), 0, (struct sockaddr *)&remote, sizeof(remote)) < 0) goto done;
	received = recv(fd, reply, reply_cap - 1, 0);
	if (received < 0) goto done;
	reply[received] = '\0';
	result = 0;
done:
	if (fd >= 0) close(fd);
	if (lstat(local_path, &current) == 0 && S_ISSOCK(current.st_mode) && current.st_uid == geteuid())
		(void)unlink(local_path);
	return result;
}

static int probe_begin_client(int argc, char **argv)
{
	char request[512], reply[160], *end;
	unsigned long port, profile, strategy;
	unsigned long long generation, probe_id;
	int n, attempt;
	if (argc != 8 || !probe_host_valid(argv[3])) return 2;
	port = strtoul(argv[4], &end, 10); if (!argv[4][0] || *end || port < 62000 || port > 62015) return 2;
	profile = strtoul(argv[5], &end, 10); if (!argv[5][0] || *end || profile != 1) return 2;
	strategy = strtoul(argv[6], &end, 10); if (!argv[6][0] || *end || !strategy || strategy > UINT32_MAX) return 2;
	generation = strtoull(argv[7], &end, 10); if (!argv[7][0] || *end || !generation) return 2;
	n = snprintf(request, sizeof(request), "PROBE_BEGIN\tv1\t%s\t%lu\t%lu\t%lu\t%llu\n",
		argv[3], port, profile, strategy, generation);
	if (n < 0 || (size_t)n >= sizeof(request)) return 2;
	for (attempt = 0; attempt < 4; attempt++) {
		if (controller_probe_request(argv[2], request, reply, sizeof(reply)) != 0) {
		fputs("adaptive_controller: probe lease request failed\n", stderr);
		return 1;
	}
		if (strncmp(reply, "ACK\tPROBE_BEGIN\tERR\tbusy",
			sizeof("ACK\tPROBE_BEGIN\tERR\tbusy") - 1) || attempt == 3) break;
		sleep(1);
	}
	if (sscanf(reply, "ACK\tPROBE_BEGIN\tOK\t%llu\n", &probe_id) != 1 || !probe_id) {
		fprintf(stderr, "adaptive_controller: probe lease rejected: %s", reply);
		return 1;
	}
	printf("probe_id=%llu\n", probe_id);
	return 0;
}

static int probe_result_client(int argc, char **argv)
{
	char request[256], reply[160], *end;
	unsigned long long id, elapsed;
	unsigned long curl_rc, http_status;
	int n;
	if (argc != 7) return 2;
	id = strtoull(argv[3], &end, 10); if (!argv[3][0] || *end || !id) return 2;
	curl_rc = strtoul(argv[4], &end, 10); if (!argv[4][0] || *end || curl_rc > 255) return 2;
	http_status = strtoul(argv[5], &end, 10); if (!argv[5][0] || *end || http_status > 599) return 2;
	elapsed = strtoull(argv[6], &end, 10); if (!argv[6][0] || *end) return 2;
	n = snprintf(request, sizeof(request), "PROBE_RESULT\tv1\t%llu\t%lu\t%lu\t%llu\n",
		id, curl_rc, http_status, elapsed);
	if (n < 0 || (size_t)n >= sizeof(request) ||
		controller_probe_request(argv[2], request, reply, sizeof(reply)) != 0) {
		fputs("adaptive_controller: probe result delivery failed\n", stderr);
		return 1;
	}
	if (strncmp(reply, "ACK\tPROBE_RESULT\tOK", 19)) {
		fprintf(stderr, "adaptive_controller: probe result rejected: %s", reply);
		return 1;
	}
	return 0;
}

static int run_stdin(void)
{
	char line[MAX_LINE];
	unsigned long line_no = 0;
	uint64_t last_checkpoint = monotonic_ms();
	if (controller_state_path && !restore_state(controller_state_path))
		fprintf(stderr, "adaptive_controller: state checkpoint discarded\n");
	puts("# ADAPTIVE_CONTROLLER_OUTPUT v3: FLOW_OUTCOME flow_id profile strategy generation evidence hostname champion challenger action independent confidence_lcb95_milli rank candidate_count top_strategy quarantine decision scope transport ip_family network_epoch network_health network_health_reason client_packets server_packets client_bytes server_bytes server_seen server_payload_seen client_rst server_rst client_fin server_fin start_ms last_seen_ms clienthello_count clienthello_retransmissions termination_reason source_port");
	while (fgets(line, sizeof(line), stdin)) {
		line_no++;
		if (!strchr(line, '\n') && !feof(stdin)) {
			int ch;
			while ((ch = getchar()) != '\n' && ch != EOF) {}
			printf("INPUT_REJECTED\t%lu\tline_too_long\n", line_no);
			continue;
		}
		process_line(line, line_no);
		if (controller_state_path) {
			uint64_t now = monotonic_ms();
			if (now >= last_checkpoint && now - last_checkpoint >= STATE_SAVE_INTERVAL_MS) {
				expire_state(now);
				if (!checkpoint_state(now))
					fprintf(stderr, "adaptive_controller: checkpoint write failed\n");
				last_checkpoint = now;
			}
		}
	}
	if (ferror(stdin)) {
		fputs("adaptive_controller: input read error\n", stderr);
		return 1;
	}
	report_open_flows();
	if (controller_state_path && !checkpoint_state(monotonic_ms()))
		fprintf(stderr, "adaptive_controller: final checkpoint write failed\n");
	return fflush(stdout) == EOF ? 1 : 0;
}

static int run_socket(const char *path)
{
	int fd, old_umask, probe_fd;
	struct sockaddr_un addr;
	struct stat before, current;
	char line[MAX_LINE];
	unsigned long line_no = 0;
	uint64_t last_checkpoint = monotonic_ms();
	struct sigaction sa;
	struct timeval recv_timeout;
	struct sockaddr_un peer;
	socklen_t peer_len;
	if (!path || path[0] != '/' || strlen(path) >= sizeof(addr.sun_path) ||
		!secure_parent_dir(path)) {
		fputs("adaptive_controller: socket path must be absolute and fit sun_path\n", stderr);
		return 2;
	}
	if (lstat(path, &before) == 0) {
		if (!S_ISSOCK(before.st_mode) || before.st_uid != geteuid()) {
			fputs("adaptive_controller: refusing to replace a non-owned socket path\n", stderr);
			return 1;
		}
		probe_fd = socket(AF_UNIX, SOCK_DGRAM, 0);
		if (probe_fd < 0) { perror("adaptive_controller: probe socket"); return 1; }
		memset(&addr, 0, sizeof(addr));
		addr.sun_family = AF_UNIX;
		memcpy(addr.sun_path, path, strlen(path) + 1);
		if (connect(probe_fd, (struct sockaddr *)&addr, sizeof(addr)) == 0) {
			close(probe_fd);
			fputs("adaptive_controller: socket is already active\n", stderr);
			return 1;
		}
		if (errno != ECONNREFUSED && errno != ENOENT) {
			perror("adaptive_controller: probe existing socket");
			close(probe_fd);
			return 1;
		}
		close(probe_fd);
		if (unlink(path) != 0) { perror("adaptive_controller: unlink stale socket"); return 1; }
	} else if (errno != ENOENT) {
		perror("adaptive_controller: inspect socket path");
		return 1;
	}
	fd = socket(AF_UNIX, SOCK_DGRAM, 0);
	if (fd < 0) { perror("adaptive_controller: socket"); return 1; }
	memset(&addr, 0, sizeof(addr));
	addr.sun_family = AF_UNIX;
	memcpy(addr.sun_path, path, strlen(path) + 1);
	old_umask = umask(077);
	if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
		umask(old_umask);
		perror("adaptive_controller: bind");
		close(fd);
		return 1;
	}
	umask(old_umask);
	if (chmod(path, 0600) != 0 || lstat(path, &before) != 0) {
		perror("adaptive_controller: secure socket");
		close(fd);
		unlink(path);
		return 1;
	}
	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = on_stop;
	sigemptyset(&sa.sa_mask);
	if (sigaction(SIGINT, &sa, NULL) != 0 || sigaction(SIGTERM, &sa, NULL) != 0) {
		perror("adaptive_controller: sigaction");
		close(fd);
		unlink(path);
		return 1;
	}
	recv_timeout.tv_sec = 30;
	recv_timeout.tv_usec = 0;
	if (setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &recv_timeout, sizeof(recv_timeout)) != 0) {
		perror("adaptive_controller: socket timeout");
		close(fd);
		unlink(path);
		return 1;
	}
	network_sampling_enabled = true;
	network_context_refresh(monotonic_ms());
	next_probe_id = ((uint64_t)(unsigned long)getpid() << 32) ^ monotonic_ms();
	if (!next_probe_id) next_probe_id = 1;
	if (controller_state_path && !restore_state(controller_state_path))
		fprintf(stderr, "adaptive_controller: state checkpoint discarded\n");
	puts("# ADAPTIVE_CONTROLLER_OUTPUT v3: FLOW_OUTCOME flow_id profile strategy generation evidence hostname champion challenger action independent confidence_lcb95_milli rank candidate_count top_strategy quarantine decision scope transport ip_family network_epoch network_health network_health_reason client_packets server_packets client_bytes server_bytes server_seen server_payload_seen client_rst server_rst client_fin server_fin start_ms last_seen_ms clienthello_count clienthello_retransmissions termination_reason source_port");
	while (!controller_stopping) {
		ssize_t n;
		recv_timeout.tv_sec = 30;
		recv_timeout.tv_usec = 0;
		if (active_probe.active) {
			uint64_t now = monotonic_ms();
			uint64_t wait_ms = active_probe.deadline_ms > now ? active_probe.deadline_ms - now : 1;
			if (active_probe.result_seen && active_probe.flow_seen &&
				active_probe.join_ready_ms > now && active_probe.join_ready_ms - now < wait_ms)
				wait_ms = active_probe.join_ready_ms - now;
			if (wait_ms > 30000) wait_ms = 30000;
			recv_timeout.tv_sec = (time_t)(wait_ms / 1000);
			recv_timeout.tv_usec = (suseconds_t)((wait_ms % 1000) * 1000);
			if (!recv_timeout.tv_sec && !recv_timeout.tv_usec) recv_timeout.tv_usec = 1000;
		}
		(void)setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &recv_timeout, sizeof(recv_timeout));
		memset(&peer, 0, sizeof(peer));
		peer_len = sizeof(peer);
		n = recvfrom(fd, line, sizeof(line) - 1, 0, (struct sockaddr *)&peer, &peer_len);
		if (n < 0) {
			if (errno == EINTR) continue;
			if (errno == EAGAIN || errno == EWOULDBLOCK) {
				uint64_t now = monotonic_ms();
				probe_maybe_finalize(now, active_probe.active && now >= active_probe.deadline_ms);
				network_context_maybe_refresh(now);
				if (controller_state_path && now >= last_checkpoint &&
					now - last_checkpoint >= STATE_SAVE_INTERVAL_MS) {
					expire_state(now);
					if (!checkpoint_state(now))
						fprintf(stderr, "adaptive_controller: checkpoint write failed\n");
					last_checkpoint = now;
				}
				continue;
			}
			perror("adaptive_controller: recv");
			break;
		}
		line_no++;
		if ((size_t)n >= sizeof(line) - 1) {
			printf("INPUT_REJECTED\t%lu\tdatagram_too_large\n", line_no);
			continue;
		}
		line[n] = '\0';
		if (n && line[n - 1] != '\n') { line[n++] = '\n'; line[n] = '\0'; }
		if (handle_probe_command(line, fd, &peer, peer_len, monotonic_ms())) {
			(void)fflush(stdout);
			continue;
		}
		process_line(line, line_no);
		probe_maybe_finalize(monotonic_ms(), active_probe.active &&
			monotonic_ms() >= active_probe.deadline_ms);
		(void)fflush(stdout);
		if (controller_state_path) {
			uint64_t now = monotonic_ms();
			if (now >= last_checkpoint && now - last_checkpoint >= STATE_SAVE_INTERVAL_MS) {
				expire_state(now);
				if (!checkpoint_state(now))
					fprintf(stderr, "adaptive_controller: checkpoint write failed\n");
				last_checkpoint = now;
			}
		}
	}
	report_open_flows();
	if (controller_state_path && !checkpoint_state(monotonic_ms()))
		fprintf(stderr, "adaptive_controller: final checkpoint write failed\n");
	close(fd);
	if (lstat(path, &current) == 0 && current.st_dev == before.st_dev && current.st_ino == before.st_ino)
		(void)unlink(path);
	return fflush(stdout) == EOF ? 1 : 0;
}

int main(int argc, char **argv)
{
	const char *socket_path = NULL, *output_path = NULL;
	int i, result;
	if (argc == 8 && !strcmp(argv[1], "--probe-begin")) return probe_begin_client(argc, argv);
	if (argc == 7 && !strcmp(argv[1], "--probe-result")) return probe_result_client(argc, argv);
	if (argc == 3 && !strcmp(argv[1], "--get-candidate"))
		return get_worker_candidate(argv[2]);
	if (argc == 5 && !strcmp(argv[1], "--set-candidate")) {
		char *end_profile, *end_strategy;
		unsigned long profile = strtoul(argv[3], &end_profile, 10);
		unsigned long strategy = strtoul(argv[4], &end_strategy, 10);
		if (!argv[3][0] || *end_profile || !argv[4][0] || *end_strategy ||
			!profile || profile > UINT32_MAX || !strategy || strategy > UINT32_MAX) {
			fputs("usage: adaptive-controller --set-candidate /worker.sock profile strategy\n", stderr);
			return 2;
		}
		return set_worker_candidate(argv[2], (uint32_t)profile, (uint32_t)strategy);
	}
	for (i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--help")) {
		puts("adaptive-controller: native shadow learner for nfqws2 TSV v2/v3");
		puts("usage: adaptive-controller [--socket /absolute/path] [--output /absolute/path] [--state /absolute/path] < events.tsv");
		puts("       adaptive-controller --set-candidate /worker.sock profile strategy");
		puts("       adaptive-controller --get-candidate /worker.sock");
		puts("       adaptive-controller --probe-begin /controller.sock host source_port profile strategy generation");
		puts("       adaptive-controller --probe-result /controller.sock probe_id curl_rc http_status elapsed_ms");
		puts("limits: 256 open flows, 128 contexts, 384 candidates; 7-day idle aggregate TTL");
		puts("socket mode consumes nonblocking-sender Unix datagrams; gaps invalidate open flows");
		puts("output: TSV FLOW_OUTCOME (confidence/rank; quarantine=NONE), TRACE_INCOMPLETE, overflow records");
		puts("optional output file is append-only and capped at 256 KiB");
		puts("optional state checkpoint is same-boot tmpfs data, capped at 128 KiB");
		return 0;
		}
		if ((!strcmp(argv[i], "--socket") || !strcmp(argv[i], "--output") ||
			!strcmp(argv[i], "--state")) && i + 1 < argc) {
			if (!strcmp(argv[i], "--socket")) socket_path = argv[++i];
			else if (!strcmp(argv[i], "--output")) output_path = argv[++i];
			else controller_state_path = argv[++i];
			continue;
		}
		fputs("usage: adaptive-controller [--help] [--socket /absolute/path] [--output /absolute/path] [--state /absolute/path] < events.tsv\n", stderr);
		return 2;
	}
	if (output_path && !controller_output_open(output_path)) {
		perror("adaptive_controller: open output");
		return 1;
	}
	if (socket_path) result = run_socket(socket_path);
	else result = run_stdin();
	if (controller_output && controller_output != stdout) {
		if (fclose(controller_output) != 0) return 1;
	}
	return result;
}
