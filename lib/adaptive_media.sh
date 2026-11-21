#!/usr/bin/env bash
# Safe bridge from the existing YouTube resolver cache to adaptive media probes.
# Signed URLs stay in the caller's private tmpfs; callers must never log/archive them.

adaptive_media_googlevideo_host_valid() {
  local host="${1,,}"
  [[ "$host" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+googlevideo\.com$ && ${#host} -le 253 ]]
}

adaptive_media_url_from_cache() {
  [[ $# = 3 ]] || return 2
  local dir="$1" kind="$2" expected_host="${3,,}" config params url url_host metadata_host expires now
  case "$kind" in audio|video) ;; *) return 2 ;; esac
  adaptive_media_googlevideo_host_valid "$expected_host" || return 2
  [[ -d "$dir" && ! -L "$dir" && -f "$dir/$kind.curl" && ! -L "$dir/$kind.curl" &&
     -f "$dir/$kind.params" && ! -L "$dir/$kind.params" && -f "$dir/expires" && ! -L "$dir/expires" ]] || return 1
  config="$dir/$kind.curl"
  params="$dir/$kind.params"
  # The resolver writes a single validated curl-config URL. Never source/eval it.
  url="$(sed -n 's/^url = "\([^"]*\)"$/\1/p' "$config")"
  [[ -n "$url" && "$(wc -l < "$config")" -eq 1 ]] || return 1
  type z2r_media_url_valid >/dev/null 2>&1 && z2r_media_url_valid "$url" || return 1
  url_host="${url#https://}"; url_host="${url_host%%/*}"
  IFS='|' read -r _ _ metadata_host expires < "$params" || return 1
  [[ "${url_host,,}" = "$expected_host" && "${metadata_host,,}" = "$expected_host" &&
     "$expires" =~ ^[1-9][0-9]{0,11}$ ]] || return 1
  IFS= read -r now < <(date +%s) || return 1
  [[ "$now" =~ ^[0-9]{1,10}$ ]] && (( expires > now + 120 )) || return 1
  # stdout is intentionally the only URL channel; diagnostics contain no URL.
  printf '%s\n' "$url"
}

# Resolve once per exact target so a short Ramp/plain series compares the same
# media object. Only the URL hash leaves this helper; the signed URL stays in
# a private, short-lived tmpfs directory.
adaptive_media_prepare_ramp_cache() {
  [[ $# = 6 ]] || return 2
  local cache_root="$1" host="${2,,}" ip="$3" video_id="$4" media_dir="$5" now="$6"
  local key dir created expires metadata_host url hash stale stale_created stale_expiry tmp
  adaptive_media_googlevideo_host_valid "$host" &&
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ && ${#video_id} -le 4096 && "$video_id" != *$'\n'* &&
       "$now" =~ ^[0-9]{1,10}$ && -d "$media_dir" && ! -L "$media_dir" ]] || return 2
  if [[ "$video_id" == https://* ]]; then
    type z2r_media_url_valid >/dev/null 2>&1 && z2r_media_url_valid "$video_id" || return 2
  else
    [[ "$video_id" =~ ^[A-Za-z0-9_-]{6,32}$ ]] || return 2
  fi
  mkdir -m 700 -p "$cache_root" || return 1
  chmod 700 "$cache_root" || return 1
  key="$(printf '%s|%s|%s' "$host" "$ip" "$video_id" | sha256sum | awk '{print $1}')"
  [[ "$key" =~ ^[a-f0-9]{64}$ ]] || return 1
  dir="$cache_root/$key"
  for stale in "$cache_root"/*; do
    [[ -d "$stale" && ! -L "$stale" ]] || continue
    stale_created="" stale_expiry=""
    IFS= read -r stale_created < "$stale/created" 2>/dev/null || :
    IFS='|' read -r _ _ _ stale_expiry < "$stale/video.params" 2>/dev/null || :
    if [[ ! "$stale_created" =~ ^[0-9]{1,10}$ || ! "$stale_expiry" =~ ^[1-9][0-9]{0,11}$ ]] ||
       (( stale_created > now || now - stale_created > 1200 || stale_expiry <= now + 120 )); then
      rm -rf "$stale"
    fi
  done
  created="" expires="" metadata_host=""
  if [[ -d "$dir" && ! -L "$dir" && -f "$dir/created" && ! -L "$dir/created" &&
        -f "$dir/video.curl" && ! -L "$dir/video.curl" &&
        -f "$dir/video.params" && ! -L "$dir/video.params" &&
        -f "$dir/expires" && ! -L "$dir/expires" ]]; then
    IFS= read -r created < "$dir/created" || :
    IFS='|' read -r _ _ metadata_host expires < "$dir/video.params" || :
  fi
  if [[ "$created" =~ ^[0-9]{1,10}$ && "$expires" =~ ^[1-9][0-9]{0,11}$ && "$metadata_host" = "$host" ]] &&
     (( created <= now && now - created <= 1200 && expires > now + 120 )); then
    cp "$dir/video.curl" "$media_dir/video.curl" && cp "$dir/video.params" "$media_dir/video.params" &&
      cp "$dir/expires" "$media_dir/expires" || return 1
  else
    rm -rf "$dir"
    z2r_media_resolve "$video_id" "$media_dir" >/dev/null || return 1
    url="$(adaptive_media_url_from_cache "$media_dir" video "$host")" || return 1
    IFS='|' read -r _ _ metadata_host expires < "$media_dir/video.params" || return 1
    [[ "$metadata_host" = "$host" && "$expires" =~ ^[1-9][0-9]{0,11}$ ]] && (( expires > now + 120 )) || return 1
    tmp="$dir.tmp.$$.$RANDOM"
    mkdir -m 700 "$tmp" || return 1
    cp "$media_dir/video.curl" "$media_dir/video.params" "$media_dir/expires" "$tmp/" &&
      printf '%s\n' "$now" > "$tmp/created" && mv "$tmp" "$dir" || {
        rm -rf "$tmp"; return 1;
      }
  fi
  url="$(adaptive_media_url_from_cache "$media_dir" video "$host")" || return 1
  hash="$(printf '%s' "$url" | sha256sum | awk '{print $1}')"
  [[ "$hash" =~ ^[a-f0-9]{64}$ ]] || return 1
  printf '%s\n' "$hash"
}

