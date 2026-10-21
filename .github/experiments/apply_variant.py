"""Apply isolated scheduling experiments to a checkout of nginx 1.31.8."""
from pathlib import Path
import sys

variant = sys.argv[1]
header = Path("src/http/v2/ngx_http_v2.h")
text = header.read_text()
old = "return s->node->id <= stream->node->id;"
assert text.count(old) == 1
if variant == "fifo":
    text = text.replace(old, "return 1;")
elif variant in {"incremental", "quota"}:
    text = text.replace(old, "return a->incremental || s->node->id <= stream->node->id;")
elif variant != "stock":
    raise SystemExit("Unknown experiment")
header.write_text(text)

if variant == "quota":
    source = Path("src/http/v2/ngx_http_v2.c")
    text = source.read_text()
    old = """        if (!wev->delayed) {
            wev->handler(wev);

            if (h2c->send_window == 0) {
                break;
            }
        }
    }

    return ngx_http_v2_state_complete(h2c, pos, end);
}"""
    new = """        if (!wev->delayed) {
            /*
             * Experiment only: expose at most one default frame of
             * connection credit while other incremental streams wait.
             */
            window = 0;

            if (stream->priority.effective.incremental
                && !ngx_queue_empty(&h2c->waiting)
                && h2c->send_window > NGX_HTTP_V2_DEFAULT_FRAME_SIZE)
            {
                window = h2c->send_window - NGX_HTTP_V2_DEFAULT_FRAME_SIZE;
                h2c->send_window -= window;
            }

            wev->handler(wev);

            h2c->send_window += window;

            if (h2c->send_window == 0) {
                break;
            }
        }
    }

    return ngx_http_v2_state_complete(h2c, pos, end);
}"""
    assert text.count(old) == 1, "Window-update experiment anchor changed"
    source.write_text(text.replace(old, new))
