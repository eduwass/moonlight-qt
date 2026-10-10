#!/bin/bash
# check-next: what can be checked about the fork without building it. Run before committing.
#   scripts/check-next.sh          the checks
#   scripts/check-next.sh --site   and build the docs site (needs bun)
# Exit status is the number of failures.
cd "$(dirname "$0")/.." || exit 1
fails=0
bad() { echo "FAIL  $1"; fails=$((fails + 1)); }

# Every source file of the fork is in the build.
for f in $(grep -l -E "^// Fork-only" -r app --include=*.cpp --include=*.mm); do
  grep -q "$(echo "${f#app/}" | sed 's/[.]/\\./g')" app/app.pro || bad "$f is not in app/app.pro"
done

# The link scheme the docs promise is the one the bundle claims.
grep -q "<string>moonlightnext</string>" app/Info.plist || bad "app/Info.plist does not claim moonlightnext://"

# Every parameter a link understands is in the docs, and the docs name none it does not.
code=$(sed -n '/^- (BOOL)open:(NSURL\*)url/,/^}/p' app/manager_mac.mm | grep -o 'item.name isEqualToString:@"[a-z]*"' | sed 's/.*@"\(.*\)"/\1/' | sort -u)
docs=$(sed -n '/^## What a connect link can say/,/^## /p' site/docs/05-links.mdx | grep -o '^| `[a-z]*`' | tr -d '|` ' | sort -u)
[ -n "$code" ] || bad "found no link parameters in app/manager_mac.mm (has the code moved?)"
[ "$code" = "$docs" ] || bad "link parameters differ: code has [$(echo $code)], site/docs/05-links.mdx has [$(echo $docs)]"

# Every switch the fork reads from the environment is written down somewhere a person will look.
for v in $(grep -h -o -E '"MOONLIGHT_[A-Z_]+"' -r app --include=*.cpp --include=*.mm --include=*.h | tr -d '"' | sort -u); do
  grep -q -r "$v" site/docs || case "$v" in
    # Set by the app for its own stream processes, or left over from experiments; not for a person to set.
    MOONLIGHT_DEVICE|MOONLIGHT_CHROMELESS|MOONLIGHT_GAMES_WARNING|MOONLIGHT_RETRIED) ;;
    *) bad "$v is read by the code and not mentioned in site/docs" ;;
  esac
done

# Every switch the device window sets for one stream is one it takes out again
# before starting anything else (plainEnvironment): a stream's process can
# start the device window, and that one the next stream, with its switches
# still in the environment. A switch set and not taken out would follow along.
taken=$(sed -n '/^static NSMutableDictionary\* plainEnvironment()/,/^}/p' app/manager_mac.mm | grep -o '@"[A-Z_]*"' | tr -d '@"' | sort -u)
[ -n "$taken" ] || bad "found no list in plainEnvironment() in app/manager_mac.mm (has the code moved?)"
for v in $(grep -o -E 'environment\[@"MOONLIGHT_[A-Z_]+"\]|@\{@"MOONLIGHT_[A-Z_]+"' app/manager_mac.mm | grep -o 'MOONLIGHT_[A-Z_]*' | sed 's/^MOONLIGHT_//' | sort -u); do
  echo "$taken" | grep -qx "$v" || bad "MOONLIGHT_$v is set for a stream in app/manager_mac.mm and not taken out in plainEnvironment()"
done

if [ "${1:-}" = --site ]; then
  (cd site && bun install --frozen-lockfile >/dev/null 2>&1 && bun run build >/dev/null 2>&1) || bad "the docs site does not build"
fi

[ $fails = 0 ] && echo "check-next: ok" || echo "check-next: $fails failed"
exit $fails
