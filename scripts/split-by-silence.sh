#!/bin/sh
#
# Split an audio file into tracks at silent gaps — for mixes/albums that have
# no chapters and no tracklist, but do have short pauses between tracks.
#
# Uses ffmpeg's `silencedetect` to find the pauses, then cuts at the midpoint
# of each pause. POSIX sh — runs under busybox (Alpine) without bash.
# Needs: ffmpeg, ffprobe, awk.
#
set -eu

NOISE="-30dB"   # level below which audio counts as silence; lower (e.g. -40dB) = stricter
DUR="0.8"       # minimum pause length in seconds to treat as a track boundary
MINLEN="0"      # drop a split that would make a track shorter than this many seconds (0 = off)
REENCODE=0      # 1 = re-encode (sample-accurate); 0 = stream copy (fast, lossless)
DELETE=0        # 1 = delete the source file, but ONLY after a successful split
PREFIX=""       # track-name prefix; default = source filename (whitespace-trimmed)
OUTDIR=""

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") [-n NOISE] [-d DUR] [-m MINLEN] [-r] [-o OUTDIR] <audiofile>

  -n NOISE   silence threshold (default ${NOISE}); use -40dB for stricter, -25dB for looser
  -d DUR     minimum pause length in seconds to split on (default ${DUR})
  -m MINLEN  ignore splits producing tracks shorter than MINLEN seconds (default off)
             — helps avoid splitting on quiet passages inside a track
  -r         re-encode for sample-accurate cuts (default: stream copy, instant & lossless)
  -D         delete the source file after a SUCCESSFUL split (kept if no pauses found)
  -p PREFIX  track filename prefix (default: source filename) — files are "<PREFIX> - Track NN.ext"
  -o OUTDIR  output directory (default: a folder named after the input file, next to it)
EOF
  exit 1
}

while getopts "n:d:m:rDp:o:h" opt; do
  case "$opt" in
    n) NOISE="$OPTARG" ;;
    d) DUR="$OPTARG" ;;
    m) MINLEN="$OPTARG" ;;
    r) REENCODE=1 ;;
    D) DELETE=1 ;;
    p) PREFIX="$OPTARG" ;;
    o) OUTDIR="$OPTARG" ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))
[ $# -eq 1 ] || usage

FILE="$1"
[ -f "$FILE" ] || { echo "No such file: $FILE" >&2; exit 1; }

ext="${FILE##*.}"
base="$(basename "$FILE")"; base="${base%.*}"
# strip leading/trailing whitespace from the title — YouTube titles sometimes carry it
base="$(printf '%s' "$base" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
OUTDIR="${OUTDIR:-$(dirname "$FILE")/$base}"
PREFIX="${PREFIX:-$base}"

total="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$FILE")"

echo "Detecting silence (noise=$NOISE, d=$DUR) ..." >&2

# Detect silences, then emit one "index start end" line per output segment.
# awk: collect each pause midpoint, apply MINLEN, then build the segment list
# [0->mid1, mid1->mid2, ..., midN->total]. Prints nothing if no pause is found.
segments="$(
  ffmpeg -hide_banner -nostats -i "$FILE" -af "silencedetect=noise=${NOISE}:d=${DUR}" -f null - 2>&1 \
  | awk -v total="$total" -v minlen="$MINLEN" '
      { for (i = 1; i <= NF; i++) {
          if ($i == "silence_start:") s = $(i + 1)
          if ($i == "silence_end:")  e = $(i + 1)
        }
      }
      /silence_end:/ { m++; mid[m] = (s + e) / 2 }
      END {
        prev = 0; k = 0
        for (j = 1; j <= m; j++)
          if (mid[j] - prev >= minlen) { k++; bnd[k] = mid[j]; prev = mid[j] }
        if (k < 1) exit 0
        start = 0
        for (j = 1; j <= k; j++) { printf "%d %.6f %.6f\n", j, start, bnd[j]; start = bnd[j] }
        printf "%d %.6f %.6f\n", k + 1, start, total
      }
    '
)"

if [ -z "$segments" ]; then
  echo "No pauses found — nothing to split. Try a smaller -d or a higher -n (e.g. -25dB)." >&2
  exit 0
fi

ntracks="$(printf '%s\n' "$segments" | wc -l | tr -d ' ')"
mkdir -p "$OUTDIR"
echo "Found $((ntracks - 1)) pause(s) -> $ntracks tracks; writing to: $OUTDIR/" >&2

printf '%s\n' "$segments" | while read -r idx start end; do
  dur="$(awk "BEGIN { printf \"%.6f\", $end - $start }")"
  title="${PREFIX} - Track $(printf '%02d' "$idx")"
  out="$OUTDIR/${title}.${ext}"
  if [ "$REENCODE" -eq 1 ]; then
    ffmpeg -nostdin -hide_banner -loglevel error -y -ss "$start" -i "$FILE" -t "$dur" \
           -metadata track="$idx" -metadata title="$title" "$out"
  else
    ffmpeg -nostdin -hide_banner -loglevel error -y -ss "$start" -i "$FILE" -t "$dur" \
           -c copy -metadata track="$idx" -metadata title="$title" "$out"
  fi
  printf '  %s  [%ss -> %ss]\n' "$out" "$start" "$end" >&2
done

if [ "$DELETE" -eq 1 ]; then
  rm -f "$FILE"
  echo "Removed source: $FILE" >&2
fi

echo "Done." >&2
