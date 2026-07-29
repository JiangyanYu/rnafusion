#!/usr/bin/env python3
"""
find_patient_fastqs.py

Search MiSeq_KGGM/<run-name>/Alignment_1/*/Fastq/*.fastq.gz for FASTQ files
belonging to a set of patients, allowing up to N characters of difference
in the sample-name portion of the filename (the lab is not perfectly
consistent about formatting).

Takes the same lauf/patient pairs file used earlier in this project. The
"lauf" value is carried straight through into the output for reference only
-- it is NOT used to locate files (MiSeq_KGGM run folders are not renamed;
searching happens directly under every run's Alignment_1/*/Fastq/).

All processing is local; no data leaves this machine.

USAGE:
    find_patient_fastqs.py --root MISEQ_ROOT --pairs PAIRS_TSV \
        --output OUTPUT_CSV [--max-distance 1] [--verbose]

ARGUMENTS:
    -r, --root DIR          Root directory containing run folders, e.g.
                             ~/smb/Devices/MiSeq_KGGM
    -i, --pairs FILE        TAB-separated, NO header, 2 columns: lauf<TAB>patient
                             (same file used for the earlier folder-matching
                             attempt, e.g. generated via:
                               tail -n +3 sample_table.tsv | cut -f1,3 | sort -u > pairs.tsv)
    -o, --output FILE       Path to write the resulting mapping CSV
    -d, --max-distance INT  Max allowed edit distance between patient ID and
                             extracted sample name (default: 1)
    -v, --verbose           Print progress to stderr

SEARCH PATTERN:
    <root>/*/Alignment_1/*/Fastq/*_R1_*fastq.gz   (R2 derived from R1 match)

OUTPUT CSV COLUMNS:
    lauf,patient,matched_sample_name,edit_distance,
    run_folder,run_folder_name,
    fastq_r1,fastq_r1_name,fastq_r2,fastq_r2_name,
    status

    - lauf, patient          : the original input pair, carried through unchanged
    - run_folder             : full path to the matched run folder
    - run_folder_name        : just the folder's basename
    - fastq_r1 / fastq_r2    : full path to the matched FASTQ file(s)
    - fastq_r1_name / _r2_name : just the filename of the matched FASTQ file(s)

    status is one of: OK | AMBIGUOUS | NO_MATCH
    AMBIGUOUS means more than one distinct (run, sample_name) match was found
    within the max-distance threshold; all candidates are listed as separate
    rows so you can inspect and pick manually.
"""

import argparse
import csv
import re
import sys
from pathlib import Path

# Matches the standard bcl2fastq/DRAGEN naming convention:
#   <SampleName>_S<#>_L<###>_R<1|2>_001.fastq.gz
#   <SampleName>_S<#>_R<1|2>_001.fastq.gz   (no lane, e.g. MiSeq single-lane)
SAMPLE_NAME_SUFFIX_RE = re.compile(
    r"_S\d+(?:_L\d+)?_R[12]_001\.fastq\.gz$", re.IGNORECASE
)


def log(verbose: bool, message: str) -> None:
    if verbose:
        print(f"[find_patient_fastqs] {message}", file=sys.stderr)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Fuzzy-match patient IDs to FASTQ files under MiSeq run folders."
    )
    parser.add_argument("-r", "--root", required=True, type=Path,
                         help="Root directory containing run folders")
    parser.add_argument("-i", "--pairs", required=True, type=Path,
                         help="TAB-separated file, no header: lauf<TAB>patient")
    parser.add_argument("-o", "--output", required=True, type=Path,
                         help="Path to write the resulting mapping CSV")
    parser.add_argument("-d", "--max-distance", type=int, default=1,
                         help="Max edit distance allowed (default: 1)")
    parser.add_argument("-v", "--verbose", action="store_true",
                         help="Print progress to stderr")
    args = parser.parse_args(argv)

    if not args.root.is_dir():
        parser.error(f"root directory does not exist: {args.root}")
    if not args.pairs.is_file():
        parser.error(f"pairs file does not exist: {args.pairs}")

    return args


def load_pairs(path: Path) -> list[tuple[str, str]]:
    """Load TAB-separated (lauf, patient) pairs, skipping blank lines."""
    pairs: list[tuple[str, str]] = []
    with path.open() as fh:
        for line_num, line in enumerate(fh, start=1):
            line = line.rstrip("\n")
            if not line.strip():
                continue
            fields = line.split("\t")
            if len(fields) < 2:
                print(
                    f"[find_patient_fastqs] WARNING: line {line_num} in {path} "
                    f"is not tab-separated into 2 fields, skipping: {line!r}",
                    file=sys.stderr,
                )
                continue
            lauf, patient = fields[0].strip(), fields[1].strip()
            if patient:
                pairs.append((lauf, patient))
    return pairs


def extract_sample_name(fastq_path: Path) -> str:
    """Strip the _S#_L###_R#_001.fastq.gz suffix to recover the sample name."""
    return SAMPLE_NAME_SUFFIX_RE.sub("", fastq_path.name)


def discover_r1_fastqs(root: Path, verbose: bool) -> list[Path]:
    """Find all R1 fastq files under <root>/*/Alignment_1/*/Fastq/."""
    pattern = "*/Alignment_1/*/Fastq/*_R1_*fastq.gz"
    matches = sorted(root.glob(pattern))
    log(verbose, f"discovered {len(matches)} R1 fastq files under {root}/{pattern}")
    return matches


def levenshtein(a: str, b: str) -> int:
    """Standard edit distance (insertions, deletions, substitutions)."""
    if a == b:
        return 0
    if not a:
        return len(b)
    if not b:
        return len(a)

    previous_row = list(range(len(b) + 1))
    for i, char_a in enumerate(a, start=1):
        current_row = [i]
        for j, char_b in enumerate(b, start=1):
            insert_cost = current_row[j - 1] + 1
            delete_cost = previous_row[j] + 1
            substitute_cost = previous_row[j - 1] + (char_a != char_b)
            current_row.append(min(insert_cost, delete_cost, substitute_cost))
        previous_row = current_row
    return previous_row[-1]


def find_r2(r1_path: Path) -> Path | None:
    r2_name = r1_path.name.replace("_R1_", "_R2_")
    r2_path = r1_path.with_name(r2_name)
    return r2_path if r2_path.is_file() else None


def run_folder_of(fastq_path: Path) -> Path:
    """<root>/<run-name>/Alignment_1/*/Fastq/file.fastq.gz -> <root>/<run-name>"""
    # Fastq -> <subdir> -> Alignment_1 -> <run-name>
    return fastq_path.parents[3]


def match_pairs(
    pairs: list[tuple[str, str]],
    r1_fastqs: list[Path],
    max_distance: int,
    verbose: bool,
) -> list[dict]:
    # Pre-extract sample names once, not per-pair, to avoid redundant work
    indexed = [(r1, extract_sample_name(r1)) for r1 in r1_fastqs]

    rows: list[dict] = []
    for lauf, patient in pairs:
        candidates = []
        for r1_path, sample_name in indexed:
            distance = levenshtein(patient, sample_name)
            if distance <= max_distance:
                candidates.append((distance, sample_name, r1_path))

        if not candidates:
            rows.append({
                "lauf": lauf,
                "patient": patient,
                "matched_sample_name": "",
                "edit_distance": "",
                "run_folder": "",
                "run_folder_name": "",
                "fastq_r1": "",
                "fastq_r1_name": "",
                "fastq_r2": "",
                "fastq_r2_name": "",
                "status": "NO_MATCH",
            })
            log(verbose, f"NO_MATCH: {patient} (lauf={lauf})")
            continue

        # distinct (run_folder, sample_name) pairs -> ambiguity check
        distinct_keys = {(run_folder_of(r1), name) for _, name, r1 in candidates}
        status = "OK" if len(distinct_keys) == 1 else "AMBIGUOUS"
        if status == "AMBIGUOUS":
            log(verbose, f"AMBIGUOUS: {patient} (lauf={lauf}) matched {len(distinct_keys)} distinct candidates")

        for distance, sample_name, r1_path in sorted(candidates, key=lambda c: c[0]):
            r2_path = find_r2(r1_path)
            run_folder = run_folder_of(r1_path)
            rows.append({
                "lauf": lauf,
                "patient": patient,
                "matched_sample_name": sample_name,
                "edit_distance": distance,
                "run_folder": str(run_folder),
                "run_folder_name": run_folder.name,
                "fastq_r1": str(r1_path),
                "fastq_r1_name": r1_path.name,
                "fastq_r2": str(r2_path) if r2_path else "",
                "fastq_r2_name": r2_path.name if r2_path else "",
                "status": status,
            })

    return rows


def write_csv(rows: list[dict], output: Path) -> None:
    fieldnames = [
        "lauf", "patient", "matched_sample_name", "edit_distance",
        "run_folder", "run_folder_name",
        "fastq_r1", "fastq_r1_name",
        "fastq_r2", "fastq_r2_name",
        "status",
    ]
    with output.open("w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def main(argv: list[str]) -> int:
    args = parse_args(argv)

    pairs = load_pairs(args.pairs)
    log(args.verbose, f"loaded {len(pairs)} lauf/patient pairs from {args.pairs}")

    r1_fastqs = discover_r1_fastqs(args.root, args.verbose)
    rows = match_pairs(pairs, r1_fastqs, args.max_distance, args.verbose)
    write_csv(rows, args.output)

    ok = sum(1 for r in rows if r["status"] == "OK")
    ambiguous_patients = {r["patient"] for r in rows if r["status"] == "AMBIGUOUS"}
    no_match = sum(1 for r in rows if r["status"] == "NO_MATCH")

    print(
        f"[find_patient_fastqs] done: {len(pairs)} pairs -> "
        f"OK={ok} AMBIGUOUS_patients={len(ambiguous_patients)} NO_MATCH={no_match}",
        file=sys.stderr,
    )
    print(f"[find_patient_fastqs] mapping written to: {args.output}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
