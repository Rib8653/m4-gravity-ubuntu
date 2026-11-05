#!/bin/bash
# Static checks and unit tests. No network access, no root.
set -euo pipefail
cd "$(dirname "$0")/.."

status=0
step() { printf '\n== %s\n' "$*"; }

step "shellcheck"
if command -v shellcheck >/dev/null; then
    mapfile -t bash_files < <(ls scripts/*.sh image/configure.sh tests/*.sh platform/libexec/firstboot-user.sh)
    mapfile -t sh_files < <(ls platform/sbin/* platform/kernel/* platform/initramfs-tools/hooks/* \
        platform/initramfs-tools/scripts/*/* platform/libexec/setup-swap.sh platform/libexec/install-extras.sh \
        platform/libexec/firstboot-grub.sh)
    shellcheck -x -s bash -e SC1091 "${bash_files[@]}" || status=1
    shellcheck -s sh -e SC1091 "${sh_files[@]}" || status=1
else
    echo "shellcheck not installed; skipped"
fi

step "syntax"
for f in scripts/*.sh image/configure.sh platform/libexec/*.sh platform/sbin/* platform/kernel/* \
         platform/initramfs-tools/hooks/* platform/initramfs-tools/scripts/*/*; do
    case "$(head -1 "$f")" in
        *bash*) bash -n "$f" || status=1 ;;
        *) sh -n "$f" || status=1 ;;
    esac
done
sh -n installer/bootstrap-ubuntu.sh.in || status=1

step "python unit tests"
python3 -m unittest discover -s tests -p 'test_*.py' -v || status=1

exit $status
