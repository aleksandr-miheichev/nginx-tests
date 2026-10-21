"""Accept only the specifically documented baseline behavior and leak failures."""
from pathlib import Path
import re, sys
status, logfile = sys.argv[1:]
text = Path(logfile).read_text()
assert int(status) == 1, (status, text[-2500:])
errors = re.findall(r"ERROR: ((?:AddressSanitizer|LeakSanitizer):[^\n]+)", text)
assert errors and all(x.startswith("LeakSanitizer:") for x in errors), errors
allowed = {
    "no alerts", "no sanitizer errors", "incremental waiting streams",
    "explicit incremental waiting streams", "PRIORITY_UPDATE enables incremental sharing",
}
failures = set(re.findall(r"#\s+Failed test '([^']+)'", text))
assert failures <= allowed, failures
assert {"incremental waiting streams", "explicit incremental waiting streams",
        "PRIORITY_UPDATE enables incremental sharing"} <= failures, failures
assert "Files=55" in text and "Bail out!" not in text and "Bad plan" not in text
print("Unchanged upstream reproduces leak reports; no unexpected ASan access failures.")
print("Observed failing checks:", sorted(failures))
