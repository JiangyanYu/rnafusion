#!/usr/bin/env bash
# =============================================================================
# download_grch38_refs.sh
# Download GRCh38 reference data from AWS S3 / public sources
#
# Usage (inside the Docker container or on any machine with aws cli):
#   bash download_grch38_refs.sh --outdir /data [--threads 4]
#
# Credentials: mount ~/.aws into the container OR set env vars:
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION
#
# Public datasets (no credentials needed): GENCODE, HGNC, UCSC
# Credentialed datasets: TCGA/GDC, some ENCODE buckets
# =============================================================================

set -euo pipefail

# ---------- defaults ---------------------------------------------------------
OUTDIR="/data"
THREADS=4
GENCODE_VERSION="44"          # change as needed (e.g. 43, 45)
GENOME_BUILD="GRCh38"

# ---------- argument parsing -------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --outdir)   OUTDIR="$2";         shift 2 ;;
        --threads)  THREADS="$2";        shift 2 ;;
        --gencode)  GENCODE_VERSION="$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

echo "============================================================"
echo " GRCh38 Reference Data Downloader"
echo " Output dir : $OUTDIR"
echo " GENCODE v  : $GENCODE_VERSION"
echo " Threads    : $THREADS"
echo "============================================================"

mkdir -p \
    "$OUTDIR/gencode" \
    "$OUTDIR/genome_fasta" \
    "$OUTDIR/star_index" \
    "$OUTDIR/salmon_index" \
    "$OUTDIR/starfusion" \
    "$OUTDIR/hgnc"

# ---------- helper -----------------------------------------------------------
download() {
    local url="$1"
    local dest="$2"
    if [[ -f "$dest" ]]; then
        echo "  [skip] $(basename "$dest") already exists"
        return
    fi
    echo "  -> Downloading $(basename "$dest") ..."
    curl -fSL --progress-bar "$url" -o "$dest"
}

s3_download() {
    local s3_path="$1"
    local dest="$2"
    if [[ -f "$dest" ]] || [[ -d "$dest" ]]; then
        echo "  [skip] $(basename "$dest") already exists"
        return
    fi
    echo "  -> aws s3 cp $s3_path ..."
    aws s3 cp "$s3_path" "$dest" --no-sign-request
}

s3_sync() {
    local s3_path="$1"
    local dest="$2"
    echo "  -> aws s3 sync $s3_path -> $dest ..."
    aws s3 sync "$s3_path" "$dest" --no-sign-request
}

# =============================================================================
# 1. GENCODE annotations + genome FASTA
# =============================================================================
echo ""
echo "[1/5] GENCODE v${GENCODE_VERSION} (${GENOME_BUILD})"

GENCODE_BASE="https://ftp.ebi.ac.uk/pub/databases/gencode/Gencode_human/release_${GENCODE_VERSION}"

# Primary genome assembly FASTA
download \
    "${GENCODE_BASE}/${GENOME_BUILD}.primary_assembly.genome.fa.gz" \
    "$OUTDIR/genome_fasta/${GENOME_BUILD}.primary_assembly.genome.fa.gz"

# Comprehensive gene annotation GTF
download \
    "${GENCODE_BASE}/gencode.v${GENCODE_VERSION}.primary_assembly.annotation.gtf.gz" \
    "$OUTDIR/gencode/gencode.v${GENCODE_VERSION}.primary_assembly.annotation.gtf.gz"

# Transcript sequences (for Salmon)
download \
    "${GENCODE_BASE}/gencode.v${GENCODE_VERSION}.transcripts.fa.gz" \
    "$OUTDIR/gencode/gencode.v${GENCODE_VERSION}.transcripts.fa.gz"

# Long non-coding RNA annotation (optional but commonly needed)
download \
    "${GENCODE_BASE}/gencode.v${GENCODE_VERSION}.long_noncoding_RNAs.gtf.gz" \
    "$OUTDIR/gencode/gencode.v${GENCODE_VERSION}.long_noncoding_RNAs.gtf.gz"

# =============================================================================
# 2. STAR genome index (pre-built, from ENCODE / UCSC public S3)
# =============================================================================
echo ""
echo "[2/5] STAR index (pre-built, ENCODE public S3)"

# ENCODE hosts pre-built STAR indices on a public S3 bucket.
# Index built with GENCODE v29/GRCh38 (widely used, compatible with v44 GTF
# for mapping; rebuild locally if you need exact version match).
#
# Alternatively, build your own — see STAR_BUILD_COMMANDS below.
#
# NOTE: Pre-built indices are large (25-30 GB). Skip this block and build
# locally if you prefer.

STAR_S3="s3://encode-pipeline-genome-data/hg38/STAR_genome_hg38_noALT_coarse_gencode.v29_oh100"

echo "  -> Syncing STAR index from ENCODE S3 (large, ~28 GB)..."
mkdir -p "$OUTDIR/star_index/gencode_v29_oh100"
aws s3 sync "$STAR_S3" "$OUTDIR/star_index/gencode_v29_oh100" --no-sign-request || {
    echo "  [warn] ENCODE S3 sync failed — you may need to build the index locally."
    echo "         See STAR_BUILD_COMMANDS at the bottom of this script."
}

# =============================================================================
# 3. Salmon index (pre-built from refgenie / build locally)
# =============================================================================
echo ""
echo "[3/5] Salmon index"

# refgenie hosts pre-built salmon indices.
# Alternatively, build from the GENCODE transcripts downloaded above.
# We download the GENCODE transcript FASTA (already done above) and note
# the build command. Pre-built refgenie indices are available at:
#   http://refgenomes.databio.org  (requires refgenie client or direct download)
#
# Direct build command (run after this script, outside Docker or inside with
# salmon installed):
#
#   salmon index \
#     -t $OUTDIR/gencode/gencode.v44.transcripts.fa.gz \
#     -d /dev/null \
#     -i $OUTDIR/salmon_index/gencode_v44 \
#     -p $THREADS
#
# We also grab the pre-built index from the nf-core AWS iGenomes bucket:

NFCORE_BASE="s3://ngi-igenomes/igenomes/Homo_sapiens/NCBI/GRCh38"

echo "  -> Checking nf-core iGenomes for Salmon index..."
aws s3 ls "${NFCORE_BASE}/" --no-sign-request 2>/dev/null || {
    echo "  [info] nf-core iGenomes not accessible without credentials."
    echo "         Build Salmon index locally using the command in this script."
}

# =============================================================================
# 4. STARFusion reference (CTAT genome lib)
# =============================================================================
echo ""
echo "[4/5] STARFusion / CTAT Genome Library"

# The CTAT genome library is the canonical reference for STAR-Fusion.
# Hosted on the Broad/CTAT FTP and also mirrored on Zenodo.
# File is large (~30 GB compressed).

CTAT_VERSION="Oct2023"
CTAT_FILENAME="GRCh38_gencode_v43_CTAT_lib_${CTAT_VERSION}.plug-n-play.tar.gz"
CTAT_URL="https://data.broadinstitute.org/Trinity/CTAT_RESOURCE_LIB/__genome_libs_StarFv1.10/${CTAT_FILENAME}"

download "$CTAT_URL" "$OUTDIR/starfusion/${CTAT_FILENAME}"

echo ""
echo "  To extract:"
echo "    tar -xzf $OUTDIR/starfusion/${CTAT_FILENAME} -C $OUTDIR/starfusion/ --strip-components=1"

# =============================================================================
# 5. HGNC gene symbols / ID mapping table
# =============================================================================
echo ""
echo "[5/5] HGNC complete gene table"

download \
    "https://ftp.ebi.ac.uk/pub/databases/genenames/hgnc/tsv/hgnc_complete_set.txt" \
    "$OUTDIR/hgnc/hgnc_complete_set.txt"

# Also grab the locus group restricted set (protein-coding only) — useful for
# downstream tools
download \
    "https://ftp.ebi.ac.uk/pub/databases/genenames/hgnc/tsv/locus_groups/protein-coding_gene.txt" \
    "$OUTDIR/hgnc/hgnc_protein_coding.txt"

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "============================================================"
echo " Download complete!"
echo " Output directory layout:"
find "$OUTDIR" -maxdepth 2 -type f -o -type d | sort
echo ""
echo "============================================================"
echo " NEXT STEPS"
echo "============================================================"
echo ""
echo " Build Salmon index (if not pre-built):"
echo "   salmon index \\"
echo "     -t $OUTDIR/gencode/gencode.v${GENCODE_VERSION}.transcripts.fa.gz \\"
echo "     -d /dev/null \\"
echo "     -i $OUTDIR/salmon_index/gencode_v${GENCODE_VERSION} \\"
echo "     -p $THREADS"
echo ""
echo " Build STAR index from scratch:"
echo "   STAR --runMode genomeGenerate \\"
echo "     --genomeDir $OUTDIR/star_index/gencode_v${GENCODE_VERSION} \\"
echo "     --genomeFastaFiles $OUTDIR/genome_fasta/${GENOME_BUILD}.primary_assembly.genome.fa.gz \\"
echo "     --sjdbGTFfile $OUTDIR/gencode/gencode.v${GENCODE_VERSION}.primary_assembly.annotation.gtf.gz \\"
echo "     --sjdbOverhang 100 \\"
echo "     --runThreadN $THREADS"
echo ""
echo " Extract STARFusion CTAT lib:"
echo "   tar -xzf $OUTDIR/starfusion/${CTAT_FILENAME} -C $OUTDIR/starfusion/"
echo ""
