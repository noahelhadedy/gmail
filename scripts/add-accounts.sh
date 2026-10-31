#!/bin/bash
# Adds Google accounts one by one through the gmailmenubar:// hook.
# Each consent page opens in your Chrome; you click Advanced > Go to Gmail Menu Bar > Continue.
# Usage: ./scripts/add-accounts.sh email1 email2 ...
D="$HOME/Library/Application Support/Gmail"
for email in "$@"; do
  echo "== $email"
  rm -f "$D/pending-auth-url.txt"
  open "gmailmenubar://add-account?login_hint=$email"
  for i in $(seq 1 20); do [ -f "$D/pending-auth-url.txt" ] && break; sleep 0.5; done
  open -a "Google Chrome" "$(cat "$D/pending-auth-url.txt")"
  for i in $(seq 1 300); do [ -f "$D/pending-auth-url.txt" ] || break; sleep 1; done
  sleep 2; open "gmailmenubar://status"; sleep 2
  python3 -c "import json;d=json.load(open('$D/accounts-status.json'));l=d.get('lastAddAccount') or {};print('   ok' if l.get('ok') else '   failed: '+str(l.get('error')))"
done
open "gmailmenubar://status"; sleep 2
python3 -c "import json;d=json.load(open('$D/accounts-status.json'));[print(a['email'],a['state'],a.get('unreadCount')) for a in d['accounts']]"
