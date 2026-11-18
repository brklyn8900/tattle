# Prints one value that make app records in the app about the source in the current
# directory, or an empty line when it cannot be read. It never fails, so a build goes on
# without the value.
#   version  The newest release the code includes: the highest vYYYY.MM.DD.N tag reachable
#            from HEAD, without its v. A shallow clone may hold none.
#   commit   HEAD's short commit, with "-dirty" when the tree has changes.
# Neither is read outside a git checkout of its own: a source archive, or one unpacked inside
# another repository, has none.
top=$(git rev-parse --show-toplevel 2>/dev/null) || top=
if [ -z "$top" ] || [ "$(cd "$top" && pwd -P)" != "$(pwd -P)" ]; then
  echo
  exit 0
fi
case $1 in
version)
  # Sorted number by number, so .10 comes after .9.
  git tag --merged HEAD --list 'v*' 2>/dev/null | sed -n 's/^v//p' \
    | grep -E '^[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[1-9][0-9]*$' \
    | sort -t . -k 1,1n -k 2,2n -k 3,3n -k 4,4n | tail -n 1
  ;;
commit)
  commit=$(git rev-parse --short --verify --quiet HEAD) || commit=
  if [ -n "$commit" ] && [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    commit=$commit-dirty
  fi
  echo "$commit"
  ;;
*)
  echo "usage: sh scripts/source-version.sh version|commit" >&2
  exit 2
  ;;
esac
