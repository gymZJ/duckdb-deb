#!/usr/bin/env bash
set -euo pipefail

UPSTREAM_REPO="duckdb/duckdb"
TAG="${1:?upstream tag is required}"
UPSTREAM_VERSION="${2:?upstream version is required}"
VERSION="${3:?Debian version is required}"
ARCH="${4:?Debian architecture is required}"
UPSTREAM_ARCH="${5:?upstream architecture is required}"
PACKAGE="$(awk '/^Package:/ { print $2; exit }' debian/control)"

write_control() {
  local target="$1"
  awk -v version="${VERSION}" -v arch="${ARCH}" '
    /^Package:/ {
      print
      print "Version: " version
      print "Architecture: " arch
      next
    }
    { print }
  ' debian/control > "${target}"
}

rm -rf work dist
mkdir -p work dist

asset="duckdb_cli-linux-${UPSTREAM_ARCH}.zip"
archive="work/${asset}"
extract_dir="work/extract"
package_root="work/pkg"

release_json="work/release.json"
gh api "repos/${UPSTREAM_REPO}/releases/tags/${TAG}" > "${release_json}"
digest="$(jq -r --arg asset "${asset}" '.assets[] | select(.name == $asset) | .digest' "${release_json}")"
test -n "${digest}"
test "${digest}" != "null"
case "${digest}" in
  sha256:*) ;;
  *) echo "Unsupported Release asset digest: ${digest}" >&2; exit 1 ;;
esac

gh release download "${TAG}" --repo "${UPSTREAM_REPO}" --pattern "${asset}" --dir work --clobber
printf '%s  %s\n' "${digest#sha256:}" "${archive}" | sha256sum --check --strict

mkdir -p "${extract_dir}" "${package_root}/DEBIAN" "${package_root}/usr/bin" "${package_root}/usr/share/doc/${PACKAGE}"
unzip -q "${archive}" -d "${extract_dir}"

duckdb_bin="$(find "${extract_dir}" -type f -name duckdb -print -quit)"
test -n "${duckdb_bin}"
test -x "${duckdb_bin}"
install -m 0755 "${duckdb_bin}" "${package_root}/usr/bin/duckdb"

# Ship the upstream license with the binary package without carrying upstream
# source code in this packaging repository.
gh api "repos/${UPSTREAM_REPO}/contents/LICENSE" --jq .content | tr -d '\n' | base64 --decode > "${package_root}/usr/share/doc/${PACKAGE}/copyright"
chmod 0644 "${package_root}/usr/share/doc/${PACKAGE}/copyright"

write_control "${package_root}/DEBIAN/control"

dpkg-deb --build --root-owner-group "${package_root}" "dist/${PACKAGE}_${VERSION}_${ARCH}.deb"

deb="dist/${PACKAGE}_${VERSION}_${ARCH}.deb"
dpkg-deb --info "${deb}" >/dev/null
contents="$(dpkg-deb --contents "${deb}")"
grep -q './usr/bin/duckdb' <<<"${contents}"
grep -q "./usr/share/doc/${PACKAGE}/copyright" <<<"${contents}"

echo "Built ${deb} from DuckDB ${UPSTREAM_VERSION} (${TAG})"
