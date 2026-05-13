#!/bin/bash
MAPPING="/d/Personal/Projects/mask-data/tests/bench-workspace/.github/hooks/.masked-files.json"
lines=()
readarray -t lines < <(python3 -c "
import json
data = json.load(open('\'))
for f in data.get('files', []):
    mrel = f.get('maskedRelPath','')
    oname = f.get('originalName','')
    print(mrel + '|' + oname)
" 2>/dev/null | tr -d '\r')
echo "readarray count: \"
