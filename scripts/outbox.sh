#!/usr/bin/env bash
# Host-side helper for the sandbox outbox. Runs on the HOST, never inside
# the container. Three subcommands:
#
#   outbox.sh <container> list                  show everything in the outbox
#   outbox.sh <container> diff <file> <dest>    diff an outbox file against a host file
#   outbox.sh <container> pull <file> <dest>    copy ONE regular file out
#
# <file> is relative to /workspace/outbox. <dest> is a host path (file).
#
# Why this exists instead of a bare `docker cp`:
#   - `list` renders names through `cat -v`, so a file name carrying
#     terminal escape sequences can't disguise itself, and it shows the
#     file type so a symlink is obvious.
#   - `pull` refuses symlinks and directories, never passes `-L`, and
#     warns on destination paths that execute when touched on the host
#     (.envrc, .git/hooks/, editor task files, Makefiles, ...) or that
#     define the sandbox itself (compose files, Dockerfiles, squid.conf,
#     managed settings) -- those need a line-by-line read, not a skim.
#   - `pull` onto an existing file shows the diff first and asks.
set -euo pipefail

OUTBOX=${OUTBOX:-/workspace/outbox}   # overridable only for testing the script itself

die() { printf 'outbox: %s\n' "$*" >&2; exit 1; }

[ $# -ge 2 ] || die "usage: $0 <container> list | diff <file> <dest> | pull <file> <dest>"
C=$1; CMD=$2; shift 2

docker inspect "$C" >/dev/null 2>&1 || die "no such container: $C"

# Runs a command inside the container. Everything that comes back is data
# produced by the sandbox and is treated as untrusted.
inbox() { docker exec "$C" "$@"; }

check_rel() {
  case "$1" in
    ''|/*|*/../*|../*|*/..|..) die "file must be a relative path with no '..': $1" ;;
  esac
}

case "$CMD" in
  list)
    # type / mode / size / name / symlink target. GNU find; the image is Debian.
    # cat -v before awk so escape sequences in names are shown, not interpreted.
    inbox find "$OUTBOX" -mindepth 1 -printf '%y\t%M\t%s\t%P\t%l\n' 2>/dev/null \
      | cat -v \
      | awk -F'\t' 'BEGIN{printf "%-4s %-10s %8s  %s\n","type","mode","size","name"}
                    {n=$4; if($5!="") n=n" -> "$5; printf "%-4s %-10s %8s  %s\n",$1,$2,$3,n}'
    echo
    echo "type: f=file d=dir l=SYMLINK (never pull these). Names shown through cat -v."
    ;;

  diff)
    [ $# -eq 2 ] || die "usage: $0 $C diff <file> <dest>"
    REL=$1; DEST=$2; check_rel "$REL"
    [ -f "$DEST" ] || die "host file does not exist: $DEST (use pull for new files)"
    inbox test -f "$OUTBOX/$REL" || die "not a regular file in the outbox: $REL"
    inbox test ! -L "$OUTBOX/$REL" || die "refusing: $REL is a symlink"
    inbox cat "$OUTBOX/$REL" | diff -u --label "host:$DEST" --label "outbox:$REL" "$DEST" - || true
    ;;

  pull)
    [ $# -eq 2 ] || die "usage: $0 $C pull <file> <dest>"
    REL=$1; DEST=$2; check_rel "$REL"
    inbox test -e "$OUTBOX/$REL" || die "no such file in outbox: $REL"
    inbox test ! -L "$OUTBOX/$REL" || die "refusing: $REL is a symlink"
    inbox test -f "$OUTBOX/$REL" || die "refusing: $REL is not a regular file (pull files one at a time)"
    [ -d "$DEST" ] && die "dest must be a file path, not a directory: $DEST"

    case "$DEST" in
      */.git/*|.git/*)             echo "WARNING: writing inside .git/ -- hooks there run on your next git command." ;;
      */.envrc|.envrc)             echo "WARNING: .envrc runs when you cd into the directory (direnv)." ;;
      */.vscode/*|.vscode/*|*/.idea/*|.idea/*)
                                   echo "WARNING: editor config can run tasks when the project is opened." ;;
      */Makefile|Makefile|*/Rakefile|Rakefile|*/justfile|justfile|*/package.json|package.json|*/.pre-commit-config.yaml|.pre-commit-config.yaml)
                                   echo "WARNING: build/task file -- its commands run when you invoke the tool." ;;
    esac
    case "$DEST" in
      *docker-compose*|*compose.y*ml|*Dockerfile*|*squid.conf|*dnsmasq.conf|*managed-settings*|*managed-mcp*|*.env.claude*)
        echo "WARNING: this file DEFINES THE SANDBOX. Read every changed line; a loosened"
        echo "         mount, cap_add, network, or ACL here is the escape path."
        ;;
    esac

    if [ -e "$DEST" ]; then
      echo "--- $DEST exists; diff (host -> outbox):"
      inbox cat "$OUTBOX/$REL" | diff -u --label "host:$DEST" --label "outbox:$REL" "$DEST" - || true
      printf 'Overwrite %s? [y/N] ' "$DEST"; read -r ans
      [ "$ans" = y ] || die "aborted"
    fi

    mkdir -p "$(dirname "$DEST")"
    # No -L: we've already verified it isn't a symlink, and -L would follow
    # one if a race swapped it in.
    docker cp "$C:$OUTBOX/$REL" "$DEST"
    # docker cp preserves the container's mode bits; drop any exec bit so a
    # pulled script can't be run by accident before it's been read.
    chmod a-x "$DEST"
    printf 'pulled %s -> %s (%s bytes, exec bit cleared)\n' "$REL" "$DEST" "$(stat -c %s "$DEST")"
    ;;

  *) die "unknown subcommand: $CMD" ;;
esac
