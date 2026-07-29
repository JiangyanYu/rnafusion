#!/usr/bin/env bash
#
# discover_run_folders.sh
#
# Resolve renamed MiSeq run folders + patient IDs (from a validation sample
# table) to actual on-disk run folders and FASTQ files, and write a mapping
# CSV for downstream rsync / nf-core samplesheet generation.
#
# All processing is local: no data leaves this machine.
#
# USAGE:
#   discover_run_folders.sh -r MISEQ_ROOT -i PAIRS_TSV -o OUTPUT_CSV [-v]
#
# REQUIRED ARGUMENTS:
#   -r, --root DIR         Root directory containing the MiSeq run folders
#                          (e.g. ~/smb/Devices/MiSeq_KGGM)
#   -i, --input FILE       TAB-separated, NO header, 2 columns: lauf<TAB>patient
#                          Generate from your table with, e.g.:
#                            tail -n +2 sample_table.tsv | cut -f1,3 | sort -u > pairs.tsv
#   -o, --output FILE      Path to write the resulting mapping CSV
#
# OPTIONAL ARGUMENTS:
#   -v, --verbose          Print progress to stderr while running
#   -h, --help             Show this help text and exit
#
# OUTPUT CSV COLUMNS:
#   lauf,patient,resolved_folder,match_basis,samplesheet_path,fastq_r1,fastq_r2,status
#
#   status is one of: OK | AMBIGUOUS | NO_FOLDER | NO_SAMPLE_MATCH

set -euo pipefail

readonly SCRIPT_NAME="$(basename "$0")"

usage() {
  sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
}

log() {
  # progress/debug messages go to stderr only, and only in verbose mode
  local verbose="$1"; shift
  if [ "$verbose" -eq 1 ]; then
    printf '[%s] %s\n' "$SCRIPT_NAME" "$*" >&2
  fi
}

die() {
  printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

parse_args() {
  # populates globals: ARG_ROOT ARG_INPUT ARG_OUTPUT ARG_VERBOSE
  ARG_ROOT=""
  ARG_INPUT=""
  ARG_OUTPUT=""
  ARG_VERBOSE=0

  while [ $# -gt 0 ]; do
    case "$1" in
      -r|--root)
        [ $# -ge 2 ] || die "$1 requires a value"
        ARG_ROOT="$2"; shift 2 ;;
      -i|--input)
        [ $# -ge 2 ] || die "$1 requires a value"
        ARG_INPUT="$2"; shift 2 ;;
      -o|--output)
        [ $# -ge 2 ] || die "$1 requires a value"
        ARG_OUTPUT="$2"; shift 2 ;;
      -v|--verbose)
        ARG_VERBOSE=1; shift ;;
      -h|--help)
        usage; exit 0 ;;
      *)
        die "unknown argument: $1 (see --help)" ;;
    esac
  done

  [ -n "$ARG_ROOT" ]   || die "missing required -r/--root (see --help)"
  [ -n "$ARG_INPUT" ]  || die "missing required -i/--input (see --help)"
  [ -n "$ARG_OUTPUT" ] || die "missing required -o/--output (see --help)"

  [ -d "$ARG_ROOT" ]  || die "root directory does not exist: $ARG_ROOT"
  [ -f "$ARG_INPUT" ] || die "input file does not exist: $ARG_INPUT"
}

# find_run_folder ROOT LAUF -> prints matching path(s), one per line
find_run_folder() {
  local root="$1" lauf="$2"
  local matches

  matches="$(find "$root" -mindepth 1 -maxdepth 1 -type d -iname "*${lauf}*" 2>/dev/null)"
  if [ -z "$matches" ]; then
    # loosen: collapse runs of whitespace in the search term into wildcards,
    # to survive double-spaces / minor typos in how the folder was renamed
    local loose
    loose="$(printf '%s' "$lauf" | sed -E 's/ +/.*/g')"
    matches="$(find "$root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | grep -iE "$loose" || true)"
  fi
  printf '%s\n' "$matches"
}

# find_sample_files RUN_DIR PATIENT_ID -> tab-separated: match_basis \t samplesheet \t fastq_r1 \t fastq_r2
find_sample_files() {
  local dir="$1" patient="$2"
  local numeric_suffix="${patient##*-}"
  local basis="" samplesheet="" r1="" r2=""

  samplesheet="$(find "$dir" -iname "SampleSheet*.csv" -exec grep -liE "${patient}|${numeric_suffix}" {} \; 2>/dev/null | head -n1 || true)"

  r1="$(find "$dir" -iname "*${patient}*_R1_*fastq.gz" 2>/dev/null | head -n1 || true)"
  if [ -n "$r1" ]; then
    basis="full_id"
  else
    r1="$(find "$dir" -iname "*${numeric_suffix}*_R1_*fastq.gz" 2>/dev/null | head -n1 || true)"
    [ -n "$r1" ] && basis="numeric_suffix"
  fi

  if [ -n "$r1" ]; then
    r2="${r1/_R1_/_R2_}"
    [ -f "$r2" ] || r2=""
  fi

  printf '%s\t%s\t%s\t%s\n' "$basis" "$samplesheet" "$r1" "$r2"
}

csv_escape() {
  # wrap in quotes and escape embedded quotes, for safe CSV output
  printf '"%s"' "$(printf '%s' "$1" | sed 's/"/""/g')"
}

process_pairs() {
  local root="$1" input="$2" output="$3" verbose="$4"

  echo "lauf,patient,resolved_folder,match_basis,samplesheet_path,fastq_r1,fastq_r2,status" > "$output"

  local lauf patient
  while IFS=$'\t' read -r lauf patient; do
    [ -z "$lauf" ] && continue

    log "$verbose" "resolving folder for Lauf='$lauf'"
    local folders folder_count resolved_folder status basis samplesheet r1 r2

    folders="$(find_run_folder "$root" "$lauf")"
    folder_count="$(printf '%s\n' "$folders" | sed '/^$/d' | wc -l)"

    if [ "$folder_count" -eq 0 ]; then
      resolved_folder=""; status="NO_FOLDER"; basis=""; samplesheet=""; r1=""; r2=""
    elif [ "$folder_count" -gt 1 ]; then
      resolved_folder="$(printf '%s' "$folders" | tr '\n' ';')"
      status="AMBIGUOUS"; basis=""; samplesheet=""; r1=""; r2=""
      log "$verbose" "AMBIGUOUS: '$lauf' matched $folder_count folders"
    else
      resolved_folder="$folders"
      log "$verbose" "matched '$lauf' -> $resolved_folder ; searching for patient '$patient'"
      IFS=$'\t' read -r basis samplesheet r1 r2 <<< "$(find_sample_files "$resolved_folder" "$patient")"
      if [ -z "$r1" ] && [ -z "$samplesheet" ]; then
        status="NO_SAMPLE_MATCH"
      else
        status="OK"
      fi
    fi

    printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "$(csv_escape "$lauf")" \
      "$(csv_escape "$patient")" \
      "$(csv_escape "$resolved_folder")" \
      "$(csv_escape "$basis")" \
      "$(csv_escape "$samplesheet")" \
      "$(csv_escape "$r1")" \
      "$(csv_escape "$r2")" \
      "$(csv_escape "$status")" >> "$output"
  done < "$input"
}

main() {
  parse_args "$@"
  process_pairs "$ARG_ROOT" "$ARG_INPUT" "$ARG_OUTPUT" "$ARG_VERBOSE"

  local total ok ambiguous no_folder no_sample
  total=$(($(wc -l < "$ARG_OUTPUT") - 1))
  ok=$(grep -c ',"OK"$' "$ARG_OUTPUT" || true)
  ambiguous=$(grep -c ',"AMBIGUOUS"$' "$ARG_OUTPUT" || true)
  no_folder=$(grep -c ',"NO_FOLDER"$' "$ARG_OUTPUT" || true)
  no_sample=$(grep -c ',"NO_SAMPLE_MATCH"$' "$ARG_OUTPUT" || true)

  printf '[%s] done: %d rows -> OK=%d AMBIGUOUS=%d NO_FOLDER=%d NO_SAMPLE_MATCH=%d\n' \
    "$SCRIPT_NAME" "$total" "$ok" "$ambiguous" "$no_folder" "$no_sample" >&2
  printf '[%s] mapping written to: %s\n' "$SCRIPT_NAME" "$ARG_OUTPUT" >&2
}

main "$@"
