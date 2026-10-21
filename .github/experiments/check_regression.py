"""Verify exact expected failing assertions rather than accepting arbitrary errors."""
from pathlib import Path
import re
import sys

variant, status, logfile = sys.argv[1:]
text = Path(logfile).read_text()
failed = [int(x) for x in re.findall(r"^not ok (\d+)\b", text, re.M)]
expected = {"stock": [1, 2, 7], "fifo": [3, 4, 8], "incremental": [], "quota": []}
assert failed == expected[variant], (variant, failed, expected[variant], text[-3000:])
assert (int(status) == 0) == (not failed), (variant, status)
assert "Tests=12" in text, text[-3000:]
print(variant, "expected failures:", failed)
