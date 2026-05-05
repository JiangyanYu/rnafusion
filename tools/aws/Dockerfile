# Dockerfile: AWS CLI on Ubuntu
# Build on local machine, push to DockerHub, pull on remote
FROM ubuntu:22.04

LABEL maintainer="you@example.com"
LABEL description="AWS CLI v2 for downloading GRCh38 reference data"

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    curl \
    unzip \
    ca-certificates \
    bash \
    less \
    groff \
    && rm -rf /var/lib/apt/lists/*

# Install AWS CLI v2
RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip \
    && unzip /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/awscliv2.zip /tmp/aws

# Verify installation
RUN aws --version

# Create working directory for downloads
RUN mkdir -p /data

WORKDIR /data

# Default: interactive shell (override with download script)
CMD ["/bin/bash"]
