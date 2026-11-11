from lambda_script import parse_log

with open("./mock-logs", encoding="utf-8") as f:
    summary = parse_log(f.read())

import json
print(json.dumps(summary, indent=2))