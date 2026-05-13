#!/bin/bash
MAPPING='/d/Personal/Projects/mask-data/tests/bench-workspace/.github/hooks/.masked-files.json'
echo -n "python3 available: "; python3 --version 2>&1 | head -1
lines=$(python3 -c "
import json
data = json.load(open('$MAPPING'))
for f in data.get('files', []):
    mrel = f.get('maskedRelPath') or ''
    oname = f.get('originalName', '')
    print(mrel + '|' + oname)
" 2>/dev/null | tr -d '\r' | wc -l)
echo "python3 lines: $lines"
awk_lines=$(awk '
  /maskedRelPath/ { match($0, /"maskedRelPath": *"([^"]+)"/, a); mrel=a[1] }
  /originalName/  { match($0, /"originalName": *"([^"]+)"/, a); oname=a[1] }
  /originalPath/  { if (oname != "") print mrel "|" oname; mrel=""; oname="" }
' "$MAPPING" | wc -l)
echo "awk lines: $awk_lines"
