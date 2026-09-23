#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#define B_SIZE 8192
#define B_MASK (B_SIZE - 1)
#define NANOSECONDS_PER_SECOND 1000000000LL
#define HDA_TIMER_TICKS 1000000
#define QEMU_CLOCK_VIRTUAL 0
#define MIN(a,b) ((a) < (b) ? (a) : (b))
typedef struct { const char *name; } Node;
typedef struct { int hda, audio_be; } State;
typedef struct {
    int64_t wpos, rpos, buft_start;
    uint8_t buf[B_SIZE];
    unsigned rate, stream;
    bool running;
    Node *node;
    State *state;
    struct { int out; } voice;
    int buft;
} HDAAudioStream;
static int64_t now;
static unsigned capacity, transferred, recovered, written_total;
static uint8_t written[B_SIZE];
static int64_t qemu_clock_get_ns(int clock) { (void)clock; return now; }
static int64_t muldiv64(int64_t a, int64_t b, int64_t c)
{ return (int64_t)((__int128)a * b / c); }
static unsigned hda_bytes_per_second(HDAAudioStream *s) { return s->rate * 4; }
static void timer_mod_anticipate_ns(int timer, int64_t deadline)
{ (void)timer; assert(deadline == now + HDA_TIMER_TICKS); }
static int hda_codec_xfer(int *hda, unsigned stream, bool output, uint8_t *buf, unsigned len)
{ (void)hda; (void)stream; assert(output); memset(buf, 0x77, len); transferred += len; return 1; }
static unsigned audio_be_write(int backend, int voice, uint8_t *buf, unsigned len)
{
    (void)backend; (void)voice;
    unsigned n = MIN(len, capacity);
    assert(written_total + n <= B_SIZE);
    memcpy(written + written_total, buf, n);
    written_total += n; capacity -= n;
    return n;
}
static void trace_hda_audio_full_recovery(const char *name, int64_t timestamp,
                                        int64_t queued, int avail)
{ (void)name; (void)avail; assert(timestamp == now && queued == B_SIZE); recovered++; }
/* Model the existing bounded clock correction; the patch does not change it. */
static void hda_timer_sync_adjust(HDAAudioStream *s, int64_t target)
{
    int64_t limit = B_SIZE / 8, corr = 0;
    if (target > limit) corr = HDA_TIMER_TICKS;
    if (target < -limit) corr = -HDA_TIMER_TICKS;
    if (target < -2 * limit) corr = -4 * HDA_TIMER_TICKS;
    s->buft_start += corr;
}
/* PATCHED_FUNCTIONS */
static void run(unsigned rate, int64_t offset, unsigned queued, unsigned avail, unsigned accept)
{
    Node node = { "test" }; State state = {0};
    HDAAudioStream s = { .rpos = offset, .wpos = offset + queued,
        .rate = rate, .node = &node, .state = &state, .running = true };
    uint8_t expected[B_SIZE];
    for (unsigned i = 0; i < queued; i++) {
        expected[i] = (uint8_t)(i * 37 + 11);
        s.buf[(offset + i) & B_MASK] = expected[i];
    }
    now = 100000000000LL;
    s.buft_start = now - muldiv64(s.wpos, NANOSECONDS_PER_SECOND, rate * 4) - 10000000000LL;
    capacity = accept; written_total = transferred = recovered = 0;
    hda_audio_output_cb(&s, avail);
    unsigned count = MIN(queued, MIN(avail, accept));
    assert(written_total == count && memcmp(written, expected, count) == 0);
    assert(s.rpos == offset + count && s.wpos == offset + queued);
    assert(recovered == (queued == B_SIZE));
    if (queued == B_SIZE) {
        /* Even after a ten-second stall, the producer must not chase ten seconds
         * of elapsed time. Existing clock correction permits at most 4 ms. */
        hda_audio_output_timer(&s);
        assert(transferred <= (rate * 4 * 4 / 1000 + 4));
        assert(s.wpos - s.rpos <= B_SIZE);
        /* Drain the original remainder byte-for-byte, including ring wrap. */
        capacity = B_SIZE; written_total = 0;
        hda_audio_output_cb(&s, queued - count);
        assert(written_total == queued - count);
        assert(memcmp(written, expected + count, queued - count) == 0);
    }
}
int main(void)
{
    unsigned rates[] = {44100, 48000};
    int64_t offsets[] = {0, 8188, 8192LL * 1000000 + 100};
    for (unsigned r = 0; r < 2; r++) for (unsigned o = 0; o < 3; o++) {
        run(rates[r], offsets[o], B_SIZE, B_SIZE, B_SIZE);
        run(rates[r], offsets[o], B_SIZE, 2048, 2048);
        run(rates[r], offsets[o], B_SIZE, B_SIZE, 512);
        run(rates[r], offsets[o], B_SIZE, B_SIZE, 0);
        run(rates[r], offsets[o], B_SIZE, 0, B_SIZE);
        run(rates[r], offsets[o], 1024, 512, 256);
        run(rates[r], offsets[o], 0, B_SIZE, B_SIZE);
    }
    puts("HDA recovery: full, partial, zero, wrap, long-running counters and stall recovery passed");
    return 0;
}
