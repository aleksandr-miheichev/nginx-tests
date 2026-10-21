#include <ngx_config.h>
#include <ngx_core.h>
#include <ngx_http.h>
#include <stdio.h>

static unsigned checks;

static int
check_order(ngx_http_v2_connection_t *h2c, ngx_http_v2_out_frame_t *frames,
    const int *expected, int n)
{
    ngx_http_v2_out_frame_t *f;
    int actual[8], count = 0, i;

    for (f = h2c->last_out; f; f = f->next) {
        if (count == 8) {
            fprintf(stderr, "cycle or excessive queue length\n");
            return 1;
        }
        actual[count++] = (int) (f - frames);
    }
    if (count != n) {
        fprintf(stderr, "incorrect frame count\n");
        return 1;
    }
    for (i = 0; i < n; i++) {
        if (actual[n - i - 1] != expected[i]) {
            fprintf(stderr, "queue check %u: at %d got %d expected %d\n",
                    checks + 1, i, actual[n - i - 1], expected[i]);
            return 1;
        }
    }
    checks++;
    return 0;
}

int
main(void)
{
    static const int permutations[6][3] = {
        {0, 1, 2}, {0, 2, 1}, {1, 0, 2},
        {1, 2, 0}, {2, 0, 1}, {2, 1, 0}
    };
    ngx_http_v2_connection_t h2c;
    ngx_http_v2_stream_t streams[3];
    ngx_http_v2_node_t nodes[3];
    ngx_http_v2_out_frame_t frames[4];
    int incremental, barrier, p, i, expected[4], offset;

    for (incremental = 0; incremental < 2; incremental++) {
        for (barrier = 0; barrier < 3; barrier++) {
            for (p = 0; p < 6; p++) {
                ngx_memzero(&h2c, sizeof(h2c));
                ngx_memzero(streams, sizeof(streams));
                ngx_memzero(nodes, sizeof(nodes));
                ngx_memzero(frames, sizeof(frames));

                for (i = 0; i < 3; i++) {
                    nodes[i].id = 2 * i + 1;
                    streams[i].node = &nodes[i];
                    streams[i].priority.effective.urgency = 3;
                    streams[i].priority.effective.incremental = incremental;
                    frames[i].stream = &streams[i];
                }

                offset = barrier != 0;
                if (barrier) {
                    frames[3].blocked = barrier == 1;
                    frames[3].stream = barrier == 1 ? &streams[0] : NULL;
                    h2c.last_out = &frames[3];
                    expected[0] = 3;
                }
                for (i = 0; i < 3; i++) {
                    ngx_http_v2_queue_frame(&h2c, &frames[permutations[p][i]]);
                    expected[i + offset] = incremental ? permutations[p][i] : i;
                }
                if (check_order(&h2c, frames, expected, 3 + offset)) {
                    return 1;
                }
            }
        }
    }

    ngx_memzero(&h2c, sizeof(h2c));
    ngx_memzero(frames, sizeof(frames));
    for (i = 0; i < 3; i++) {
        frames[i].stream = &streams[0];
        ngx_http_v2_queue_frame(&h2c, &frames[i]);
        expected[i] = i;
    }
    if (check_order(&h2c, frames, expected, 3)) {
        return 1;
    }

    ngx_memzero(&h2c, sizeof(h2c));
    ngx_memzero(frames, sizeof(frames));
    streams[0].priority.effective.urgency = 7;
    streams[0].priority.effective.incremental = 0;
    streams[1].priority.effective.urgency = 0;
    streams[1].priority.effective.incremental = 1;
    streams[2].priority.effective.urgency = 0;
    streams[2].priority.effective.incremental = 0;
    for (i = 0; i < 3; i++) {
        frames[i].stream = &streams[i];
        ngx_http_v2_queue_frame(&h2c, &frames[i]);
    }
    expected[0] = 2;
    expected[1] = 1;
    expected[2] = 0;
    if (check_order(&h2c, frames, expected, 3)) {
        return 1;
    }

    printf("%u frame queue checks passed\n", checks);
    return 0;
}
