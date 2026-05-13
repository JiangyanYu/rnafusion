# GRCh38 Reference Data Downloader — Setup Guide

## Overview

```
Local Ubuntu machine
  └─ docker build → docker push → DockerHub
                                      └─ docker pull (remote machine)
                                             └─ docker run → download_grch38_refs.sh
```

> **Firewall note:** The script is S3-first. All public buckets use
> `--no-sign-request` (no AWS credentials needed). EBI/Broad HTTPS URLs are
> used only as fallbacks. If outbound port 443 is fully blocked on the remote
> machine, see the [Firewall Troubleshooting](#firewall-troubleshooting) section.

---

## Data sources

| Reference | S3 (primary) | HTTPS (fallback) |
|---|---|---|
| Genome FASTA | `s3://ngi-igenomes/igenomes/Homo_sapiens/NCBI/GRCh38/Sequence/WholeGenomeFasta/genome.fa` | `https://ftp.ebi.ac.uk/pub/databases/gencode/Gencode_human/release_44/GRCh38.primary_assembly.genome.fa.gz` |
| GENCODE GTF | `s3://aws-roda-hcls-data/gencode/release_44/gencode.v44.primary_assembly.annotation.gtf.gz` | `https://ftp.ebi.ac.uk/pub/databases/gencode/Gencode_human/release_44/gencode.v44.primary_assembly.annotation.gtf.gz` |
| Transcript FASTA | `s3://aws-roda-hcls-data/gencode/release_44/gencode.v44.transcripts.fa.gz` | `https://ftp.ebi.ac.uk/pub/databases/gencode/Gencode_human/release_44/gencode.v44.transcripts.fa.gz` |
| STAR index | `s3://ngi-igenomes/igenomes/Homo_sapiens/NCBI/GRCh38/Sequence/STARIndex/` | build locally (see Notes) |
| STARFusion CTAT | `s3://ctat-genome-lib/GRCh38/plug-n-play/GRCh38_gencode_v44_CTAT_lib/` | `https://data.broadinstitute.org/Trinity/CTAT_RESOURCE_LIB/__genome_libs_StarFv1.10/GRCh38_gencode_v43_CTAT_lib_Oct2023.plug-n-play.tar.gz` |
| HGNC | — (no S3 mirror) | `https://ftp.ebi.ac.uk/pub/databases/genenames/hgnc/tsv/hgnc_complete_set.txt` |

---

## Step 1 — Build on your local Ubuntu machine

```bash
mkdir aws-grch38 && cd aws-grch38
# Place Dockerfile and download_grch38_refs.sh here

docker build -t your-dockerhub-user/aws-grch38:latest .
```

---

## Step 2 — Push to DockerHub

```bash
docker login
docker push your-dockerhub-user/aws-grch38:latest
```

---

## Step 3 — Pull on the remote machine

```bash
docker pull your-dockerhub-user/aws-grch38:latest
```

> **If DockerHub is blocked:** export as a tarball and transfer via scp:
> ```bash
> # Local
> docker save your-dockerhub-user/aws-grch38:latest | gzip > aws-grch38.tar.gz
> scp aws-grch38.tar.gz user@remote-host:/tmp/
>
> # Remote
> docker load < /tmp/aws-grch38.tar.gz
> ```

---

## Step 4 — Run the download script

All S3 buckets are public — no AWS credentials required.

```bash
# Copy the script into your output directory first
cp download_grch38_refs.sh /path/to/output/

docker run --rm \
    -v /path/to/output:/data \
    your-dockerhub-user/aws-grch38:latest \
    bash /data/download_grch38_refs.sh --outdir /data --threads 8 \
    2>&1 | tee /path/to/output/download.log
```

If you do have AWS credentials (e.g. for private buckets):
```bash
docker run --rm \
    -v ~/.aws:/root/.aws:ro \
    -v /path/to/output:/data \
    your-dockerhub-user/aws-grch38:latest \
    bash /data/download_grch38_refs.sh --outdir /data --threads 8 \
    2>&1 | tee /path/to/output/download.log
```

---

## Expected output layout

```
/data/
├── genome_fasta/
│   └── GRCh38.primary_assembly.genome.fa          (~3.2 GB)
├── gencode/
│   ├── gencode.v44.primary_assembly.annotation.gtf.gz  (~50 MB)
│   └── gencode.v44.transcripts.fa.gz               (~200 MB)
├── star_index/
│   └── GRCh38/                                     (~28 GB, pre-built)
├── salmon_index/
│   └── gencode_v44/                                (built locally)
├── starfusion/
│   └── GRCh38_CTAT_lib/                            (~100 GB extracted)
└── hgnc/
    └── hgnc_complete_set.txt
```

---

## Disk space requirements

| Dataset         | Compressed | Extracted |
|-----------------|-----------|-----------|
| Genome FASTA    | ~900 MB   | ~3.2 GB   |
| GENCODE GTF     | ~50 MB    | ~300 MB   |
| STAR index      | ~28 GB    | ~28 GB    |
| Salmon index    | ~1 GB     | ~1 GB     |
| STARFusion CTAT | ~30 GB    | ~100 GB   |
| HGNC            | ~30 MB    | ~30 MB    |

**Total: ~160 GB extracted** — provision at least 200 GB.

---

## Firewall troubleshooting

The script requires outbound HTTPS (port 443). If it fails entirely:

**1. Check for a required proxy**
```bash
env | grep -i proxy
# If empty, ask your sysadmin: "What proxy should I use for outbound HTTPS?"
# Then pass it to docker run:
docker run --rm -e HTTPS_PROXY=http://proxy.institution.edu:3128 ...
```

**2. Check if data already exists on the remote machine**
```bash
find /reference /data /shared /nfs /mnt -maxdepth 4 \
    -name "*.fa" -o -name "GRCh38*" -o -name "*.gtf" 2>/dev/null
```

**3. Download locally and transfer via rsync**
```bash
# Run the script on your local machine
bash download_grch38_refs.sh --outdir ./grch38_refs

# Transfer over SSH (port 22 is usually open)
rsync -avzP ./grch38_refs/ user@remote-host:/path/to/data/
```

---

## Notes

- **GENCODE version**: Default is v44. Override with `--gencode 43` etc.
- **STARFusion**: The CTAT plug-n-play lib bundles its own STAR genome index — you may not need a separate STAR index if STARFusion is your only use case.
- **Salmon index**: No public S3 mirror exists. Build locally after downloading the transcript FASTA — the script prints the exact command.
- **STAR index**: Pre-built index from iGenomes may not exactly match your GENCODE version. To build from scratch: `STAR --runMode genomeGenerate --genomeDir ... --genomeFastaFiles ... --sjdbGTFfile ... --runThreadN 8`
