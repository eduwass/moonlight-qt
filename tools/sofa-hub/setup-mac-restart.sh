#!/bin/bash
# Lets the Sofa app restart this Mac (mac-receiver.swift's restart) so that it comes back logged in:
# a sudo rule for `fdesetup authrestart -inputplist`, and the login password in the login keychain as
# "sofa-receiver-login", which the receiver reads with `security`. Run once, on the Mac, in a terminal:
#   bash ~/Sites/moonlight-qt/tools/sofa-hub/setup-mac-restart.sh
# Run it again after changing the login password.
set -euo pipefail
user=$(id -un)
fdesetup status | grep -q "FileVault is On" || echo "!! FileVault is off: fdesetup authrestart needs it on"

read -rsp "Login password for $user: " pw; echo
# Checked by sudo, read from stdin: the password never goes on a command line.
printf '%s\n' "$pw" | sudo -k -S -p "" -v 2>/dev/null || { echo "!! wrong password"; exit 1; }

echo "== sudo rule"
rule=$(mktemp)
echo "$user ALL=(root) NOPASSWD: /usr/bin/fdesetup authrestart -inputplist" > "$rule"
sudo visudo -cf "$rule" >/dev/null
sudo install -m 0440 -o root -g wheel "$rule" /etc/sudoers.d/sofa-authrestart
rm -f "$rule"
sudo -k
sudo -n -l /usr/bin/fdesetup authrestart -inputplist >/dev/null || { echo "!! the rule does not apply"; exit 1; }

echo "== keychain item sofa-receiver-login"
# Through security's interactive mode on stdin, quoted, so the password is not in any process's arguments.
esc=${pw//\\/\\\\}
esc=${esc//\"/\\\"}
printf 'add-generic-password -U -s sofa-receiver-login -a %s -w "%s"\n' "$user" "$esc" | security -i
unset pw esc
[ "$(security find-generic-password -s sofa-receiver-login -a "$user" -w)" ] || { echo "!! not stored"; exit 1; }
echo "== done: the Sofa app can restart this Mac"
