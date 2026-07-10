#!/bin/sh
# geodata.sh - pre-seed mihomo's geo databases into the persistent config dir
# so the FIRST container start never blocks on a cross-border download: the
# GEOSITE/GEOIP rules need these files, mihomo fetches them at start when they
# are missing, and on a filtered network that fetch can hang the whole gateway
# boot. Once the files exist mihomo simply reuses them (geo-auto-update stays
# false in the committed template).
#
# The mirror list is overridable via GEODATA_MIRRORS (space-separated hosts,
# tried in order); the path mirrors the committed template's geox-url source.
# Every function here is non-fatal by design: callers treat a failed pre-seed
# as a warning, because mihomo can still self-download at start.
# POSIX /bin/sh (BusyBox-safe). No dependencies on the other lib modules.

GEODATA_MIRRORS="${GEODATA_MIRRORS:-testingcf.jsdelivr.net fastly.jsdelivr.net gcore.jsdelivr.net}"
GEODATA_PATH="/gh/MetaCubeX/meta-rules-dat@release"
# A real database is megabytes; a CDN error/block page is a few KB. Reject
# anything under this floor so an HTML page never lands as a database file.
GEODATA_MIN_BYTES="${GEODATA_MIN_BYTES:-65536}"

# _geodata_fetch URL OUT - download URL to OUT. rc 0 ok, non-zero failed
# (2 when no downloader exists). Kept tiny so the CI harness can stub it.
_geodata_fetch() {
  _gf_url="$1"; _gf_out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 10 --max-time 180 -o "$_gf_out" "$_gf_url" 2>/dev/null
  elif command -v wget >/dev/null 2>&1; then
    wget -q -T 20 -O "$_gf_out" "$_gf_url" 2>/dev/null
  else
    return 2
  fi
}

_geodata_file_ok() { [ -f "$1" ] && [ -s "$1" ]; }

# geodata_cached DIR - 0 iff both databases are already present, accepting any
# of the spellings mihomo reads/writes (GeoSite.dat is what a live install
# caches; country.mmdb is the pre-metadb spelling older cores used).
geodata_cached() {
  _gc_dir="$1"
  { _geodata_file_ok "$_gc_dir/GeoSite.dat" || _geodata_file_ok "$_gc_dir/geosite.dat"; } || return 1
  { _geodata_file_ok "$_gc_dir/geoip.metadb" || _geodata_file_ok "$_gc_dir/country.mmdb" \
      || _geodata_file_ok "$_gc_dir/Country.mmdb"; } || return 1
  return 0
}

# _geodata_seed_one DIR SRC_NAME TARGET_NAME - try each mirror in order for
# one file; download to a temp name and only mv a size-sane result into place
# so a partial/blocked download never shadows a later good one.
_geodata_seed_one() {
  _g1_dir="$1"; _g1_src="$2"; _g1_target="$3"
  _g1_tmp="$_g1_dir/.geodata.tmp"
  for _g1_host in $GEODATA_MIRRORS; do
    rm -f "$_g1_tmp" 2>/dev/null
    _geodata_fetch "https://$_g1_host$GEODATA_PATH/$_g1_src" "$_g1_tmp" || continue
    _g1_size="$(wc -c < "$_g1_tmp" 2>/dev/null | tr -d ' ')"
    [ -n "$_g1_size" ] && [ "$_g1_size" -ge "$GEODATA_MIN_BYTES" ] || continue
    mv "$_g1_tmp" "$_g1_dir/$_g1_target" && return 0
  done
  rm -f "$_g1_tmp" 2>/dev/null
  return 1
}

# geodata_preseed DIR - ensure both databases exist under DIR. rc 0 = already
# cached or fully seeded; rc 1 = at least one file could not be fetched
# (warn-only for callers: mihomo can still self-download at start).
geodata_preseed() {
  _gp_dir="$1"
  [ -d "$_gp_dir" ] || mkdir -p "$_gp_dir" 2>/dev/null || return 1
  geodata_cached "$_gp_dir" && return 0
  _gp_rc=0
  if ! _geodata_file_ok "$_gp_dir/GeoSite.dat" && ! _geodata_file_ok "$_gp_dir/geosite.dat"; then
    _geodata_seed_one "$_gp_dir" geosite.dat GeoSite.dat || _gp_rc=1
  fi
  if ! _geodata_file_ok "$_gp_dir/geoip.metadb" && ! _geodata_file_ok "$_gp_dir/country.mmdb" \
      && ! _geodata_file_ok "$_gp_dir/Country.mmdb"; then
    _geodata_seed_one "$_gp_dir" geoip.metadb geoip.metadb || _gp_rc=1
  fi
  return "$_gp_rc"
}
