# sglang_dev.Dockerfile
#
# SGLang Development Environment with TheRock ROCm
# - Built on Ubuntu 24.04 (configurable via BASE_IMAGE, default: ubuntu:24.04)
# - Installs ROCm from TheRock artifacts during build
# - Includes PyTorch ROCm, SGLang, and related ML/AI tools
#
# Build arguments:
# - BASE_IMAGE: Base Docker image (default: ubuntu:24.04)
# - THEROCK_VERSION: TheRock ROCm version (e.g., 7.12.0a20260318)
# - AMDGPU_FAMILY: AMD GPU family (default: gfx950)
# - RELEASE_TYPE: Release type (default: nightlies)
# - PYTHON_VERSION: Python version (default: 3.12, must match base image)
# - TORCH_INDEX: PyTorch wheel index URL (default: gfx950-dcgpu nightlies)
# - GPU_ARCH: GPU architecture for kernel compilation (default: gfx950)
#
# Build example:
#   docker build \
#     --build-arg THEROCK_VERSION=7.12.0a20260318 \
#     --build-arg AMDGPU_FAMILY=gfx950 \
#     -f dockerfiles/sglang_dev.Dockerfile \
#     -t sglang-dev:gfx950-7.12.0a20260318 \
#     dockerfiles/
#
# Run example:
#   docker run --rm -it --device=/dev/kfd --device=/dev/dri \
#     --security-opt seccomp=unconfined \
#     sglang-dev:latest bash

ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-lc"]

# ---- TheRock ROCm Installation ----
ARG THEROCK_VERSION
ARG AMDGPU_FAMILY=gfx950
ARG RELEASE_TYPE=nightlies

# Copy installation scripts
COPY install_rocm_deps.sh /tmp/
COPY install_rocm_tarball.sh /tmp/

# Install system dependencies for ROCm
RUN chmod +x /tmp/install_rocm_deps.sh && \
    /tmp/install_rocm_deps.sh

# Install ROCm from TheRock tarball
# Tarball extracts to /opt/rocm-{VERSION}/, with symlink /opt/rocm -> /opt/rocm-{VERSION}
RUN chmod +x /tmp/install_rocm_tarball.sh && \
    /tmp/install_rocm_tarball.sh \
        "${THEROCK_VERSION}" \
        "${AMDGPU_FAMILY}" \
        "${RELEASE_TYPE}" && \
    rm -f /tmp/install_rocm_deps.sh /tmp/install_rocm_tarball.sh

# Configure ROCm environment variables
ENV ROCM_PATH=/opt/rocm
ENV PATH="/opt/rocm/bin:${PATH}"

# ---- AMD SMI Installation (optional) ----
# Installs AMD SMI Python package from ROCm distribution if available
# Uncomment the following lines to enable:
# RUN set -eux; \
#     if [ -d "/opt/rocm/share/amd_smi" ]; then \
#       cd /opt/rocm/share/amd_smi && python3 -m pip install --no-cache-dir . ; \
#     fi

# ---- Base OS dependencies ----
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
      python3 python3-dev python3-pip python-is-python3 \
      wget git \
      kmod pciutils \
      ca-certificates \
      libstdc++-12-dev \
    && rm -rf /var/lib/apt/lists/*

# Upgrade pip tooling
RUN python3 -m pip install --no-cache-dir -U pip setuptools setuptools_scm wheel

# ---- PyTorch ROCm wheels ----
# PyTorch wheel index - maps to GPU architecture
# Common mappings:
#   gfx950  → https://rocm.nightlies.amd.com/v2-staging/gfx950-dcgpu/
#   gfx942  → https://rocm.nightlies.amd.com/v2-staging/gfx94X-dcgpu/
#   gfx94X  → https://rocm.nightlies.amd.com/v2-staging/gfx94X-dcgpu/
# Override via --build-arg TORCH_INDEX=... if needed
ARG TORCH_INDEX=https://rocm.nightlies.amd.com/v2-staging/gfx950-dcgpu/
ARG TORCH_VER="2.10.0"
ARG TORCHVISION_VER="0.25.0"
ARG TORCHAUDIO_VER="2.10.0"

RUN python3 -m pip install --no-cache-dir numpy \
    && python3 -m pip install --no-cache-dir \
         --index-url "${TORCH_INDEX}" \
         "torch==${TORCH_VER}" \
         "torchvision==${TORCHVISION_VER}" \
         "torchaudio==${TORCHAUDIO_VER}"

# Record installed packages
RUN python3 -m pip freeze

# ---- SGLang Build Configuration ----
ENV BUILD_VLLM="0"
ENV BUILD_TRITON="0"
ENV BUILD_LLVM="0"
ENV BUILD_AITER_ALL="0"
ENV BUILD_MOONCAKE="0"

# GPU architecture configuration
ARG GPU_ARCH=gfx950
ENV GPU_ARCH_LIST=${GPU_ARCH%-*}
ENV PYTORCH_ROCM_ARCH=gfx942;gfx950

# Repository configuration
ARG SGL_REPO="https://github.com/sgl-project/sglang.git"
ARG SGL_DEFAULT="main"
ARG SGL_BRANCH=060720c5733d3b0dce208f978fb424c851fe109a

# Version override for setuptools_scm (used in nightly builds)
ARG SETUPTOOLS_SCM_PRETEND_VERSION=""

WORKDIR /sgl-workspace

# ---- Install base dependencies ----
RUN apt-get purge -y sccache || true; \
    python -m pip uninstall -y sccache || true; \
    rm -f "$(which sccache)" || true

# Initialize ROCm SDK
RUN pip install --no-cache-dir --index-url "${TORCH_INDEX}" 'rocm[libraries,devel,profilers]' \
    && rocm-sdk init

# Python version (must match base image: Ubuntu 24.04 uses Python 3.12)
ARG PYTHON_VERSION=3.12

ENV CPATH=/usr/local/lib/python${PYTHON_VERSION}/dist-packages/_rocm_sdk_devel/include
ENV LIBRARY_PATH=/usr/local/lib/python${PYTHON_VERSION}/dist-packages/_rocm_sdk_devel/lib

# Install SGLang dependencies
RUN pip install --no-cache-dir \
    IPython \
    orjson \
    python-multipart \
    torchao==0.9.0 \
    pybind11

# ---- Build SGLang ----
ARG BUILD_TYPE=all
ENV SGLANG_USE_AITER=0

RUN pip uninstall -y sgl_kernel sglang || true

RUN git clone ${SGL_REPO} \
    && cd sglang \
    && if [ "${SGL_BRANCH}" = ${SGL_DEFAULT} ]; then \
         echo "Using ${SGL_DEFAULT}, default branch."; \
         git checkout ${SGL_DEFAULT}; \
       else \
         echo "Using ${SGL_BRANCH} branch."; \
         git checkout ${SGL_BRANCH}; \
       fi \
    && cd sgl-kernel \
    && rm -f pyproject.toml \
    && mv pyproject_rocm.toml pyproject.toml \
    && AMDGPU_TARGET=$GPU_ARCH_LIST python setup_rocm.py install \
    && cd .. \
    && rm -rf python/pyproject.toml && mv python/pyproject_other.toml python/pyproject.toml \
    && if [ "$BUILD_TYPE" = "srt" ]; then \
         export SETUPTOOLS_SCM_PRETEND_VERSION="${SETUPTOOLS_SCM_PRETEND_VERSION}" && python -m pip --no-cache-dir install -e "python[srt_hip,diffusion_hip]"; \
       else \
         export SETUPTOOLS_SCM_PRETEND_VERSION="${SETUPTOOLS_SCM_PRETEND_VERSION}" && python -m pip --no-cache-dir install -e "python[all_hip]"; \
       fi

# Patch SGLang to not use AITER
RUN sed -i '11 s/^_is_hip.*/_is_hip = False/' /sgl-workspace/sglang/python/sglang/srt/layers/quantization/quark/schemes/quark_w4a4_mxfp4.py; \
   sed -i '26 s/^_is_hip.*/_is_hip = False/' /sgl-workspace/sglang/python/sglang/srt/layers/quantization/quark_int4fp8_moe.py;

RUN python -m pip cache purge

# ---- Python development tools ----
RUN python3 -m pip install --no-cache-dir \
    py-spy \
    pre-commit \
    tabulate

# ---- Performance environment variables ----
# Skip CuDNN compatibility check - not applicable for ROCm (uses MIOpen instead)
ENV SGLANG_DISABLE_CUDNN_CHECK=1
ENV HIP_FORCE_DEV_KERNARG=1
ENV HSA_NO_SCRATCH_RECLAIM=1
ENV SGLANG_ALLOW_OVERWRITE_LONGER_CONTEXT_LEN=1
ENV SGLANG_INT4_WEIGHT=0
ENV SGLANG_MOE_PADDING=1
ENV SGLANG_ROCM_DISABLE_LINEARQUANT=0
ENV SGLANG_ROCM_FUSED_DECODE_MLA=1
ENV SGLANG_SET_CPU_AFFINITY=1
ENV SGLANG_USE_ROCM700A=1

ENV NCCL_MIN_NCHANNELS=112
ENV ROCM_QUICK_REDUCE_QUANTIZATION=INT8
ENV TORCHINDUCTOR_MAX_AUTOTUNE=1
ENV TORCHINDUCTOR_MAX_AUTOTUNE_POINTWISE=1

# Default command
CMD ["bash"]
