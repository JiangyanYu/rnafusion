#!/usr/bin/env python3
"""
build_rsync_script.py

Take the mapping.csv produced by find_patient_fastqs.py (run with
--max-distance 0) and:

  1. Resolve AMBIGUOUS patients by picking the candidate whose
     run_folder_name sorts latest (real MiSeq run folders start with
     YYMMDD, so lexicographic sort == chronological order).
  2. Write a resolved_mapping.csv (one row per patient) noting how each
     row was resolved.
  3. Write an rsync.sh script that copies each resolved patient's R1/R2
     FASTQ files to a destination directory, one subfolder per patient.

Rows with status NO_MATCH are skipped (logged, not copied) since there is
nothing to rsync for them.

All processing is local; no data leaves this machine.

USAGE:
    build_rsync_script.py --mapping MAPPING_CSV --dest DEST_DIR \
        --resolved-output RESOLVED_CSV --script-output RSYNC_SH [--verbose]

ARGUMENTS:
    -m, --mapping FILE         mapping.csv from find_patient_fastqs.py
    -d, --dest DIR              Destination root directory for rsync
    -r, --resolved-output FILE   Path to write the resolved (one-row-per-
                                 patient) mapping CSV
    -s, --script-output FILE     Path to write the generated rsync.sh script
    -v, --verbose                Print progress to stderr

RESOLVED CSV COLUMNS:
    lauf,patient,matched_sample_name,run_folder,run_folder_name,
    fastq_r1,fastq_r2,resolution

    resolution is one of: unambiguous | resolved_latest_folder | no_match
"""

import argparse
import csv
import shlex
import sys
from pathlib import Path


def log(verbose: bool, message: str) -> None:
    if verbose:
        print(f"[build_rsync_script] {message}", file=sys.stderr)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Resolve ambiguous matches and generate an rsync script from mapping.csv."
    )
    parser.add_argument("-m", "--mapping", required=True, type=Path,
                         help="mapping.csv produced by find_patient_fastqs.py")
    parser.add_argument("-d", "--dest", required=True, type=Path,
                         help="Destination root directory for rsync")
    parser.add_argument("-r", "--resolved-output", required=True, type=Path,
                         help="Path to write the resolved mapping CSV")
    parser.add_argument("-s", "--script-output", required=True, type=Path,
                         help="Path to write the generated rsync.sh script")
    parser.add_argument("-v", "--verbose", action="store_true",
                         help="Print progress to stderr")
    args = parser.parse_args(argv)

    if not args.mapping.is_file():
        parser.error(f"mapping file does not exist: {args.mapping}")

    return args


def read_mapping(path: Path) -> list[dict]:
    with path.open(newline="") as fh:
        return list(csv.DictReader(fh))


def group_by_pair(rows: list[dict]) -> dict[tuple[str, str], list[dict]]:
    groups: dict[tuple[str, str], list[dict]] = {}
    for row in rows:
        key = (row["lauf"], row["patient"])
        groups.setdefault(key, []).append(row)
    return groups


def resolve_group(rows: list[dict], verbose: bool) -> dict | None:
    """Return a single resolved row for this (lauf, patient) group, or None if NO_MATCH."""
    statuses = {row["status"] for row in rows}

    if statuses == {"NO_MATCH"}:
        lauf, patient = rows[0]["lauf"], rows[0]["patient"]
        log(verbose, f"NO_MATCH, skipping: patient={patient} lauf={lauf}")
        return None

    if len(rows) == 1:
        row = rows[0]
        return {**row, "resolution": "unambiguous"}

    # Multiple candidate rows (status AMBIGUOUS): pick the one whose
    # run_folder_name sorts latest -> chronologically most recent real run.
    chosen = max(rows, key=lambda r: r["run_folder_name"])
    discarded = [r["run_folder_name"] for r in rows if r is not chosen]
    log(
        verbose,
        f"resolved ambiguous patient={chosen['patient']} lauf={chosen['lauf']}: "
        f"chose '{chosen['run_folder_name']}', discarded {discarded}",
    )
    return {**chosen, "resolution": "resolved_latest_folder"}


def resolve_all(rows: list[dict], verbose: bool) -> list[dict]:
    resolved: list[dict] = []
    for _key, group_rows in group_by_pair(rows).items():
        result = resolve_group(group_rows, verbose)
        if result is not None:
            resolved.append(result)
    return resolved


def write_resolved_csv(resolved: list[dict], output: Path) -> None:
    fieldnames = [
        "lauf", "patient", "matched_sample_name",
        "run_folder", "run_folder_name",
        "fastq_r1", "fastq_r2", "resolution",
    ]
    with output.open("w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=fieldnames)
        writer.writeheader()
        for row in resolved:
            writer.writerow({field: row.get(field, "") for field in fieldnames})


def write_rsync_script(resolved: list[dict], dest: Path, output: Path, verbose: bool) -> None:
    lines = [
        "#!/usr/bin/env bash",
        "#",
        "# Auto-generated by build_rsync_script.py -- do not edit by hand,",
        "# regenerate from mapping.csv instead.",
        "",
        "set -euo pipefail",
        "",
        f"DEST={shlex.quote(str(dest))}",
        "",
    ]

    skipped_no_r2 = 0
    for row in resolved:
        patient = row["patient"]
        r1 = row.get("fastq_r1", "")
        r2 = row.get("fastq_r2", "")

        if not r1:
            continue

        patient_dir = f'"$DEST"/{shlex.quote(patient)}'
        lines.append(f"mkdir -p {patient_dir}")

        if r2:
            lines.append(f"rsync -avP {shlex.quote(r1)} {shlex.quote(r2)} {patient_dir}/")
        else:
            skipped_no_r2 += 1
            lines.append(f"# WARNING: no R2 found for patient {patient}, copying R1 only")
            lines.append(f"rsync -avP {shlex.quote(r1)} {patient_dir}/")
        lines.append("")

    if skipped_no_r2:
        log(verbose, f"{skipped_no_r2} patient(s) had no R2 match, see WARNING comments in script")

    output.write_text("\n".join(lines) + "\n")
    output.chmod(0o755)


def main(argv: list[str]) -> int:
    args = parse_args(argv)

    rows = read_mapping(args.mapping)
    log(args.verbose, f"loaded {len(rows)} rows from {args.mapping}")

    resolved = resolve_all(rows, args.verbose)
    write_resolved_csv(resolved, args.resolved_output)
    write_rsync_script(resolved, args.dest, args.script_output, args.verbose)

    n_unambiguous = sum(1 for r in resolved if r["resolution"] == "unambiguous")
    n_resolved = sum(1 for r in resolved if r["resolution"] == "resolved_latest_folder")
    n_groups = len(group_by_pair(rows))
    n_skipped = n_groups - len(resolved)

    print(
        f"[build_rsync_script] done: {n_groups} patients -> "
        f"unambiguous={n_unambiguous} resolved_ambiguous={n_resolved} skipped_no_match={n_skipped}",
        file=sys.stderr,
    )
    print(f"[build_rsync_script] resolved mapping written to: {args.resolved_output}", file=sys.stderr)
    print(f"[build_rsync_script] rsync script written to: {args.script_output}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
