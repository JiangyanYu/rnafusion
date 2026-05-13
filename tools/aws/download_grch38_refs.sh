#!/usr/bin/env bash
# =============================================================================
# download_grch38_refs.sh  (v3 — Ensembl-based, full fusion caller refs)
#
# Downloads all GRCh38 reference data for:
#   STAR, Salmon, STARFusion, FusionCatcher, Arriba, HGNC
#
# Strategy: S3 (--no-sign-request) where available, HTTPS fallback elsewhere.
# No AWS credentials required for public buckets.
#
# Usage:
#   bash download_grch38_refs.sh [--outdir /data] [--threads 8] [--ensembl 115]
#
# Recommended: run locally, then rsync to remote:
#   rsync -avzP ./grch38_refs/ user@remote-host:/path/to/data/
# =============================================================================

set -uo pipefail  # no -e: errors handled per-block

# ---------- defaults ---------------------------------------------------------
OUTDIR="./grch38_refs"
THREADS=8
ENSEMBL_VERSION="115"
ARRIBA_VERSION="2.5.1"
GENOME_BUILD="GRCh38"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --outdir)   OUTDIR="$2";          shift 2 ;;
        --threads)  THREADS="$2";         shift 2 ;;
        --ensembl)  ENSEMBL_VERSION="$2"; shift 2 ;;
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
    "$OUTDIR/fasta" \
    "$OUTDIR/gtf" \
    "$OUTDIR/star_index" \
    "$OUTDIR/salmon_index" \
    "$OUTDIR/starfusion" \
    "$OUTDIR/fusioncatcher" \
    "$OUTDIR/arriba" \
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
echo " GRCh38 Reference Data Downloader v3"
echo " outdir  : $OUTDIR"
echo " Ensembl : v${ENSEMBL_VERSION}"
echo " Arriba  : v${ARRIBA_VERSION}"
echo " threads : $THREADS"
echo "============================================================"

ENSEMBL_FTP="https://ftp.ensembl.org/pub/release-${ENSEMBL_VERSION}/fasta/homo_sapiens/dna"
ENSEMBL_GTF="https://ftp.ensembl.org/pub/release-${ENSEMBL_VERSION}/gtf/homo_sapiens"


# =============================================================================
# 1. Ensembl genome FASTA
# =============================================================================
echo ""
echo "[1/8] Ensembl GRCh38 genome FASTA (release ${ENSEMBL_VERSION})"

FASTA_DEST="$OUTDIR/fasta/Homo_sapiens.GRCh38.dna.primary_assembly.fa.gz"

if [[ -f "$FASTA_DEST" ]]; then
    mark_skip "fasta"
else
    # Try nf-core iGenomes S3 first (Ensembl-sourced)
    s3_get \
        "s3://ngi-igenomes/igenomes/Homo_sapiens/Ensembl/GRCh38/Sequence/WholeGenomeFasta/genome.fa" \
        "$FASTA_DEST" \
        && mark_ok "fasta" \
        || {
            echo "  [warn] S3 failed — trying Ensembl FTP..."
            curl_get \
                "${ENSEMBL_FTP}/Homo_sapiens.GRCh38.dna.primary_assembly.fa.gz" \
                "$FASTA_DEST" \
                && mark_ok "fasta" \
                || mark_failed "fasta"
        }
fi


# =============================================================================
# 2. Ensembl GTF annotation
# =============================================================================
echo ""
echo "[2/8] Ensembl GRCh38 GTF (release ${ENSEMBL_VERSION})"

GTF_DEST="$OUTDIR/gtf/Homo_sapiens.GRCh38.${ENSEMBL_VERSION}.gtf.gz"

if [[ -f "$GTF_DEST" ]]; then
    mark_skip "gtf"
else
    s3_get \
        "s3://ngi-igenomes/igenomes/Homo_sapiens/Ensembl/GRCh38/Annotation/Genes/genes.gtf" \
        "$GTF_DEST" \
        && mark_ok "gtf" \
        || {
            echo "  [warn] S3 failed — trying Ensembl FTP..."
            curl_get \
                "${ENSEMBL_GTF}/Homo_sapiens.GRCh38.${ENSEMBL_VERSION}.gtf.gz" \
                "$GTF_DEST" \
                && mark_ok "gtf" \
                || mark_failed "gtf"
        }
fi


# =============================================================================
# 3. STAR index — nf-core iGenomes S3 (Ensembl GRCh38), fallback ENCODE S3
# =============================================================================
echo ""
echo "[3/8] STAR index (pre-built, S3)"

STAR_DEST="$OUTDIR/star_index/GRCh38_ensembl"

if [[ -d "$STAR_DEST" && -f "$STAR_DEST/SA" ]]; then
    mark_skip "star_index"
else
    mkdir -p "$STAR_DEST"
    s3_sync \
        "s3://ngi-igenomes/igenomes/Homo_sapiens/Ensembl/GRCh38/Sequence/STARIndex/" \
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
# 4. Salmon index — no S3 mirror; print build command
# =============================================================================
echo ""
echo "[4/8] Salmon index"

SALMON_DEST="$OUTDIR/salmon_index/ensembl_v${ENSEMBL_VERSION}"

if [[ -d "$SALMON_DEST" ]]; then
    mark_skip "salmon_index"
else
    echo "  [info] No public S3 mirror for Salmon indices."
    echo "         Build after downloading the FASTA:"
    echo ""
    echo "    # Extract transcript sequences from genome + GTF, then:"
    echo "    salmon index \\"
    echo "      -t $OUTDIR/fasta/Homo_sapiens.GRCh38.dna.primary_assembly.fa.gz \\"
    echo "      -d /dev/null \\"
    echo "      -i $SALMON_DEST \\"
    echo "      -p $THREADS"
    echo ""
    mark_manual "salmon_index"
fi


# =============================================================================
# 5. STARFusion — CTAT lib + fusion_lib.Mar2021.dat.gz
# =============================================================================
echo ""
echo "[5/8] STARFusion CTAT genome library + fusion annotation lib"

CTAT_DEST="$OUTDIR/starfusion/GRCh38_CTAT_lib"
FUSION_LIB_DEST="$OUTDIR/starfusion/fusion_lib.Mar2021.dat.gz"

# CTAT lib
if [[ -d "$CTAT_DEST" && "$(ls -A "$CTAT_DEST" 2>/dev/null)" ]]; then
    mark_skip "starfusion_ctat"
else
    mkdir -p "$CTAT_DEST"
    s3_sync \
        "s3://ctat-genome-lib/GRCh38/plug-n-play/GRCh38_gencode_v44_CTAT_lib/" \
        "$CTAT_DEST" \
        && mark_ok "starfusion_ctat" \
        || {
            echo "  [warn] CTAT S3 failed — trying Broad HTTPS..."
            CTAT_FILE="GRCh38_gencode_v43_CTAT_lib_Oct2023.plug-n-play.tar.gz"
            curl_get \
                "https://data.broadinstitute.org/Trinity/CTAT_RESOURCE_LIB/__genome_libs_StarFv1.10/${CTAT_FILE}" \
                "$OUTDIR/starfusion/${CTAT_FILE}" \
                && tar -xzf "$OUTDIR/starfusion/${CTAT_FILE}" -C "$OUTDIR/starfusion/" --strip-components=1 \
                && mark_ok "starfusion_ctat" \
                || mark_failed "starfusion_ctat"
        }
fi

# fusion_lib.Mar2021.dat.gz
if [[ -f "$FUSION_LIB_DEST" ]]; then
    mark_skip "starfusion_fusion_lib"
else
    curl_get \
        "https://data.broadinstitute.org/Trinity/CTAT_RESOURCE_LIB/fusion_lib.Mar2021.dat.gz" \
        "$FUSION_LIB_DEST" \
        && mark_ok "starfusion_fusion_lib" \
        || mark_failed "starfusion_fusion_lib"
fi


# =============================================================================
# 6. FusionCatcher reference — human_v102
#    Hosted on Google Drive (no direct wget); print manual download instructions
# =============================================================================
echo ""
echo "[6/8] FusionCatcher reference (human_v102)"

FC_DEST="$OUTDIR/fusioncatcher/human_v102"

if [[ -d "$FC_DEST" && "$(ls -A "$FC_DEST" 2>/dev/null)" ]]; then
    mark_skip "fusioncatcher"
else
    echo "  [info] FusionCatcher human_v102 is hosted on Google Drive (~18 GB)."
    echo "         Automated download is unreliable. Recommended approach:"
    echo ""
    echo "    # Install gdown (Python)"
    echo "    pip install gdown"
    echo ""
    echo "    # Download and extract"
    echo "    gdown --fuzzy 'https://drive.google.com/file/d/1F7j3OQoNpH3oDBjfcDl1tMLp_g0FVKZ3' \\"
    echo "          -O $OUTDIR/fusioncatcher/human_v102.tar.gz"
    echo "    tar -xzf $OUTDIR/fusioncatcher/human_v102.tar.gz -C $OUTDIR/fusioncatcher/"
    echo ""
    echo "    # Or via the FusionCatcher tool itself:"
    echo "    fusioncatcher-build -g homo_sapiens -o $FC_DEST"
    echo ""
    mark_manual "fusioncatcher"
fi


# =============================================================================
# 7. Arriba references — v2.5.1 (GitHub releases, HTTPS only)
# =============================================================================
echo ""
echo "[7/8] Arriba references (v${ARRIBA_VERSION})"

ARRIBA_BASE="https://github.com/suhrig/arriba/releases/download/v${ARRIBA_VERSION}"
ARRIBA_DEST="$OUTDIR/arriba"

declare -A ARRIBA_FILES=(
    ["blacklist"]="blacklist_hg38_GRCh38_v${ARRIBA_VERSION}.tsv.gz"
    ["cytobands"]="cytobands_hg38_GRCh38_v${ARRIBA_VERSION}.tsv"
    ["known_fusions"]="known_fusions_hg38_GRCh38_v${ARRIBA_VERSION}.tsv.gz"
    ["protein_domains"]="protein_domains_hg38_GRCh38_v${ARRIBA_VERSION}.gff3"
)

ARRIBA_OK=true
for key in "${!ARRIBA_FILES[@]}"; do
    fname="${ARRIBA_FILES[$key]}"
    dest="$ARRIBA_DEST/$fname"
    if [[ -f "$dest" ]]; then
        mark_skip "arriba_${key}"
    else
        curl_get "${ARRIBA_BASE}/${fname}" "$dest" \
            && mark_ok "arriba_${key}" \
            || { mark_failed "arriba_${key}"; ARRIBA_OK=false; }
    fi
done


# =============================================================================
# 8. HGNC — EBI FTP, try HTTPS then HTTP then genenames.org
# =============================================================================
echo ""
echo "[8/8] HGNC gene tables"

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
for key in \
    fasta gtf \
    star_index salmon_index \
    starfusion_ctat starfusion_fusion_lib \
    fusioncatcher \
    arriba_blacklist arriba_cytobands arriba_known_fusions arriba_protein_domains \
    hgnc
do
    result="${STATUS[$key]:-NOT RUN}"
    printf "  %-35s %s\n" "$key" "$result"
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
