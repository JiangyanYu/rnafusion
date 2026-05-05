# GRCh38 Reference Data Downloader — Setup Guide

## Overview

```
Local Ubuntu machine
  └─ docker build → docker push → DockerHub
                                      └─ docker pull (remote machine)
                                             └─ docker run → download_grch38_refs.sh
```

---

## Step 1 — Build on your local Ubuntu machine

```bash
# Clone / copy these files into a working directory
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
# Only needs internet access to DockerHub (hub.docker.com)
docker pull your-dockerhub-user/aws-grch38:latest
```

> **Tip — if DockerHub is also blocked:**
> Export the image as a tarball on your local machine, transfer via scp/rsync, load on remote:
> ```bash
> # Local
> docker save your-dockerhub-user/aws-grch38:latest | gzip > aws-grch38.tar.gz
> scp aws-grch38.tar.gz user@remote-host:/tmp/
>
> # Remote
> docker load < /tmp/aws-grch38.tar.gz
> ```

---

## Step 4 — Set up AWS credentials

Choose ONE of:

### Option A — Mount your local credentials (simplest)
```bash
# Assumes ~/.aws/credentials exists with [default] profile
docker run --rm \
    -v ~/.aws:/root/.aws:ro \
    -v /path/to/output:/data \
    your-dockerhub-user/aws-grch38:latest \
    bash /data/download_grch38_refs.sh --outdir /data
```

### Option B — Environment variables
```bash
docker run --rm \
    -e AWS_ACCESS_KEY_ID=AKIA... \
    -e AWS_SECRET_ACCESS_KEY=... \
    -e AWS_DEFAULT_REGION=us-east-1 \
    -v /path/to/output:/data \
    your-dockerhub-user/aws-grch38:latest \
    bash /data/download_grch38_refs.sh --outdir /data
```

### Option C — Public datasets (no credentials)
Most of the downloads (GENCODE, HGNC, CTAT/STARFusion) use **public HTTPS URLs**
and need no AWS credentials at all. Only the pre-built STAR index sync from
ENCODE S3 uses `--no-sign-request`. If you don't have AWS keys, the script will
still download the majority of the data.

---

## Step 5 — Copy the download script into your output volume

```bash
# On remote machine — copy the script into your output dir first
cp download_grch38_refs.sh /path/to/output/

# Then run the container
docker run --rm \
    -v /path/to/output:/data \
    your-dockerhub-user/aws-grch38:latest \
    bash /data/download_grch38_refs.sh --outdir /data --threads 8
```

---

## Expected output layout

```
/data/
├── genome_fasta/
│   └── GRCh38.primary_assembly.genome.fa.gz       (~900 MB)
├── gencode/
│   ├── gencode.v44.primary_assembly.annotation.gtf.gz  (~50 MB)
│   ├── gencode.v44.transcripts.fa.gz               (~200 MB)
│   └── gencode.v44.long_noncoding_RNAs.gtf.gz
├── star_index/
│   └── gencode_v29_oh100/                          (~28 GB, pre-built)
├── salmon_index/
│   └── gencode_v44/                                (built locally)
├── starfusion/
│   └── GRCh38_gencode_v43_CTAT_lib_Oct2023.plug-n-play.tar.gz  (~30 GB)
└── hgnc/
    ├── hgnc_complete_set.txt
    └── hgnc_protein_coding.txt
```

---

## Disk space requirements

| Dataset        | Compressed | Extracted |
|----------------|-----------|-----------|
| GENCODE genome | ~900 MB   | ~3.2 GB   |
| GENCODE GTF    | ~50 MB    | ~300 MB   |
| STAR index     | ~28 GB    | ~28 GB    |
| Salmon index   | ~1 GB     | ~1 GB     |
| STARFusion CTAT| ~30 GB    | ~100 GB   |
| HGNC tables    | ~30 MB    | ~30 MB    |

**Total: ~160 GB extracted** — provision at least 200 GB on your output volume.

---

## Notes

- **GENCODE version**: Default is v44. Change with `--gencode 43` etc.
- **STAR index**: Pre-built index from ENCODE uses gencode v29. For an exact
  version match, build locally using the `STAR --runMode genomeGenerate` command
  printed at the end of the download script.
- **STARFusion**: The CTAT plug-n-play lib bundles its own STAR genome index,
  so you may not need a separate STAR index if you're only running STARFusion.
- **Salmon index**: Must be built from the downloaded transcript FASTA (command
  shown at end of download script). Salmon is not included in this Docker image —
  run it separately or add it to the Dockerfile.
