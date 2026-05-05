#!/usr/bin/env bash
# =============================================================================
# download_grch38_refs.sh  (v2 — S3-first, resilient)
#
# Uses AWS S3 (--no-sign-request) wherever possible to avoid firewall blocks
# on EBI/Broad FTP/HTTPS endpoints. Falls back to curl only where no S3
# mirror exists.
#
# Usage:
#   bash download_grch38_refs.sh [--outdir /data] [--threads 4] [--gencode 44]
#
# AWS credentials: not required — all buckets used here are public.
# =============================================================================

set -uo pipefail   # no -e: we handle errors per-block

# ---------- defaults ---------------------------------------------------------
OUTDIR="/data"
THREADS=4
GENCODE_VERSION="44"
GENOME_BUILD="GRCh38"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --outdir)   OUTDIR="$2";          shift 2 ;;
        --threads)  THREADS="$2";         shift 2 ;;
        --gencode)  GENCODE_VERSION="$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

# ---------- status tracking --------------------------------------------------
declare -A STATUS

mark_ok()     { STATUS["$1"]="OK";             echo "  [ok] $1"; }
mark_failed() { STATUS["$1"]="FAILED";         echo "  [FAILED] $1 — see error above"; }
mark_skip()   { STATUS["$1"]="SKIPPED (exists)"; echo "  [skip] $1 already exists"; }
mark_manual() { STATUS["$1"]="BUILD MANUALLY"; }

# ---------- helpers ----------------------------------------------------------
mkdir -p \
    "$OUTDIR/genome_fasta" \
    "$OUTDIR/gencode" \
    "$OUTDIR/star_index" \
    "$OUTDIR/salmon_index" \
    "$OUTDIR/starfusion" \
    "$OUTDIR/hgnc"

s3_get() {
    aws s3 cp "$1" "$2" --no-sign-request
}

s3_sync() {
    aws s3 sync "$1" "$2" --no-sign-request
}

curl_get() {
    curl -fSL --retry 3 --retry-delay 5 --progress-bar "$1" -o "$2"
}

echo "============================================================"
echo " GRCh38 Reference Data Downloader v2 (S3-first)"
echo " outdir  : $OUTDIR"
echo " gencode : v${GENCODE_VERSION}"
echo " threads : $THREADS"
echo "============================================================"


# =============================================================================
# 1. Genome FASTA — nf-core iGenomes S3 (public, no credentials)
# =============================================================================
echo ""
echo "[1/7] Genome FASTA (nf-core iGenomes S3)"

FASTA_DEST="$OUTDIR/genome_fasta/${GENOME_BUILD}.primary_assembly.genome.fa"
IGENOMES_SEQ="s3://ngi-igenomes/igenomes/Homo_sapiens/NCBI/GRCh38/Sequence"

if [[ -f "$FASTA_DEST" || -f "${FASTA_DEST}.gz" ]]; then
    mark_skip "genome_fasta"
else
    s3_get "${IGENOMES_SEQ}/WholeGenomeFasta/genome.fa" "$FASTA_DEST" \
        && mark_ok "genome_fasta" \
        || mark_failed "genome_fasta"
fi


# =============================================================================
# 2. GENCODE GTF — AWS Open Data S3, fallback curl EBI
# =============================================================================
echo ""
echo "[2/7] GENCODE v${GENCODE_VERSION} GTF"

GTF_DEST="$OUTDIR/gencode/gencode.v${GENCODE_VERSION}.primary_assembly.annotation.gtf.gz"

if [[ -f "$GTF_DEST" ]]; then
    mark_skip "gencode_gtf"
else
    S3_GTF="s3://aws-roda-hcls-data/gencode/release_${GENCODE_VERSION}/gencode.v${GENCODE_VERSION}.primary_assembly.annotation.gtf.gz"
    s3_get "$S3_GTF" "$GTF_DEST" \
        && mark_ok "gencode_gtf" \
        || {
            echo "  [warn] S3 failed — trying EBI HTTPS..."
            curl_get \
                "https://ftp.ebi.ac.uk/pub/databases/gencode/Gencode_human/release_${GENCODE_VERSION}/gencode.v${GENCODE_VERSION}.primary_assembly.annotation.gtf.gz" \
                "$GTF_DEST" \
                && mark_ok "gencode_gtf" \
                || mark_failed "gencode_gtf"
        }
fi


# =============================================================================
# 3. GENCODE transcript FASTA (for Salmon) — AWS Open Data S3, fallback curl
# =============================================================================
echo ""
echo "[3/7] GENCODE v${GENCODE_VERSION} transcript FASTA (for Salmon)"

TX_DEST="$OUTDIR/gencode/gencode.v${GENCODE_VERSION}.transcripts.fa.gz"

if [[ -f "$TX_DEST" ]]; then
    mark_skip "gencode_transcripts"
else
    S3_TX="s3://aws-roda-hcls-data/gencode/release_${GENCODE_VERSION}/gencode.v${GENCODE_VERSION}.transcripts.fa.gz"
    s3_get "$S3_TX" "$TX_DEST" \
        && mark_ok "gencode_transcripts" \
        || {
            echo "  [warn] S3 failed — trying EBI HTTPS..."
            curl_get \
                "https://ftp.ebi.ac.uk/pub/databases/gencode/Gencode_human/release_${GENCODE_VERSION}/gencode.v${GENCODE_VERSION}.transcripts.fa.gz" \
                "$TX_DEST" \
                && mark_ok "gencode_transcripts" \
                || mark_failed "gencode_transcripts"
        }
fi


# =============================================================================
# 4. STAR index — nf-core iGenomes S3, fallback ENCODE S3
# =============================================================================
echo ""
echo "[4/7] STAR index (S3 pre-built)"

STAR_DEST="$OUTDIR/star_index/GRCh38"

if [[ -d "$STAR_DEST" && -f "$STAR_DEST/SA" ]]; then
    mark_skip "star_index"
else
    mkdir -p "$STAR_DEST"
    s3_sync \
        "${IGENOMES_SEQ}/STARIndex/" \
        "$STAR_DEST" \
        && mark_ok "star_index" \
        || {
            echo "  [warn] iGenomes S3 failed — trying ENCODE S3..."
            s3_sync \
                "s3://encode-pipeline-genome-data/hg38/STAR_genome_hg38_noALT_coarse_gencode.v29_oh100" \
                "$STAR_DEST" \
                && mark_ok "star_index" \
                || mark_failed "star_index"
        }
fi


# =============================================================================
# 5. Salmon index — no reliable universal S3 mirror; print build command
# =============================================================================
echo ""
echo "[5/7] Salmon index"

SALMON_DEST="$OUTDIR/salmon_index/gencode_v${GENCODE_VERSION}"

if [[ -d "$SALMON_DEST" ]]; then
    mark_skip "salmon_index"
else
    echo "  [info] No public S3 mirror for Salmon indices."
    echo "         Once transcript FASTA is downloaded, build with:"
    echo ""
    echo "    salmon index \\"
    echo "      -t $TX_DEST \\"
    echo "      -d /dev/null \\"
    echo "      -i $SALMON_DEST \\"
    echo "      -p $THREADS"
    echo ""
    mark_manual "salmon_index"
fi


# =============================================================================
# 6. STARFusion CTAT lib — CTAT S3 (public), fallback Broad HTTPS
# =============================================================================
echo ""
echo "[6/7] STARFusion CTAT genome library"

CTAT_DEST="$OUTDIR/starfusion/GRCh38_CTAT_lib"

if [[ -d "$CTAT_DEST" && "$(ls -A "$CTAT_DEST" 2>/dev/null)" ]]; then
    mark_skip "starfusion_ctat"
else
    mkdir -p "$CTAT_DEST"
    s3_sync \
        "s3://ctat-genome-lib/GRCh38/plug-n-play/GRCh38_gencode_v44_CTAT_lib/" \
        "$CTAT_DEST" \
        && mark_ok "starfusion_ctat" \
        || {
            echo "  [warn] CTAT S3 failed — trying Broad HTTPS (large file ~30 GB)..."
            CTAT_FILE="GRCh38_gencode_v43_CTAT_lib_Oct2023.plug-n-play.tar.gz"
            curl_get \
                "https://data.broadinstitute.org/Trinity/CTAT_RESOURCE_LIB/__genome_libs_StarFv1.10/${CTAT_FILE}" \
                "$OUTDIR/starfusion/${CTAT_FILE}" \
                && {
                    echo "  Extracting..."
                    tar -xzf "$OUTDIR/starfusion/${CTAT_FILE}" -C "$OUTDIR/starfusion/" --strip-components=1 \
                        && mark_ok "starfusion_ctat" \
                        || mark_failed "starfusion_ctat"
                } \
                || mark_failed "starfusion_ctat"
        }
fi


# =============================================================================
# 7. HGNC — EBI only; try HTTPS then HTTP then genenames.org
# =============================================================================
echo ""
echo "[7/7] HGNC gene tables"

HGNC_DEST="$OUTDIR/hgnc/hgnc_complete_set.txt"

if [[ -f "$HGNC_DEST" ]]; then
    mark_skip "hgnc"
else
    curl_get \
        "https://ftp.ebi.ac.uk/pub/databases/genenames/hgnc/tsv/hgnc_complete_set.txt" \
        "$HGNC_DEST" \
        && mark_ok "hgnc" \
        || {
            echo "  [warn] HTTPS failed — trying HTTP..."
            curl_get \
                "http://ftp.ebi.ac.uk/pub/databases/genenames/hgnc/tsv/hgnc_complete_set.txt" \
                "$HGNC_DEST" \
                && mark_ok "hgnc" \
                || {
                    echo "  [warn] HTTP failed — trying genenames.org..."
                    curl_get \
                        "https://www.genenames.org/cgi-bin/download/custom?col=gd_hgnc_id&col=gd_app_sym&col=gd_app_name&col=gd_status&col=gd_locus_type&col=gd_pub_chrom_map&status=Approved&format=text&submit=submit" \
                        "$HGNC_DEST" \
                        && mark_ok "hgnc" \
                        || mark_failed "hgnc"
                }
        }
fi


# =============================================================================
# Summary
# =============================================================================
echo ""
echo "============================================================"
echo " DOWNLOAD SUMMARY"
echo "============================================================"
FAILED=0
for key in genome_fasta gencode_gtf gencode_transcripts star_index salmon_index starfusion_ctat hgnc; do
    result="${STATUS[$key]:-NOT RUN}"
    printf "  %-25s %s\n" "$key" "$result"
    [[ "$result" == "FAILED" ]] && FAILED=$((FAILED + 1))
done
echo ""
echo "Disk usage:"
du -sh "$OUTDIR"/*/  2>/dev/null || true
echo "============================================================"
if [[ $FAILED -gt 0 ]]; then
    echo " $FAILED item(s) FAILED. Check output above for details."
    exit 1
else
    echo " All items completed (or queued for manual build)."
    exit 0
fi
