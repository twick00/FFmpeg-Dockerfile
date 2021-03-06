FROM ubuntu:16.04
MAINTAINER "Tyler Wickline <tyler@oakion.com>"

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates apt-transport-https gnupg-curl && \
    rm -rf /var/lib/apt/lists/* && \
    NVIDIA_GPGKEY_SUM=d1be581509378368edeec8c1eb2958702feedf3bc3d17011adbf24efacce4ab5 && \
    NVIDIA_GPGKEY_FPR=ae09fe4bbd223a84b2ccfce3f60f4b3d7fa2af80 && \
    apt-key adv --fetch-keys https://developer.download.nvidia.com/compute/cuda/repos/ubuntu1604/x86_64/7fa2af80.pub && \
    apt-key adv --export --no-emit-version -a $NVIDIA_GPGKEY_FPR | tail -n +5 > cudasign.pub && \
    echo "$NVIDIA_GPGKEY_SUM  cudasign.pub" | sha256sum -c --strict - && rm cudasign.pub && \
    echo "deb https://developer.download.nvidia.com/compute/cuda/repos/ubuntu1604/x86_64 /" > /etc/apt/sources.list.d/cuda.list && \
    echo "deb https://developer.download.nvidia.com/compute/machine-learning/repos/ubuntu1604/x86_64 /" > /etc/apt/sources.list.d/nvidia-ml.list

ENV CUDA_VERSION 9.1.85

ENV PATH=$PATH:/root/bin
ENV PKG_CONFIG_PATH="/root/ffmpeg_build/lib/pkgconfig"
ENV FFMPEG_BUILD="/root/ffmpeg_build"
ENV BINDIR="/root/bin"

ENV CUDA_PKG_VERSION 9-1=$CUDA_VERSION-1
RUN apt-get update && apt-get install -y --no-install-recommends \
        cuda-cudart-$CUDA_PKG_VERSION && \
    ln -s cuda-9.1 /usr/local/cuda && \
    rm -rf /var/lib/apt/lists/*

# nvidia-docker 1.0
LABEL com.nvidia.volumes.needed="nvidia_driver"
LABEL com.nvidia.cuda.version="${CUDA_VERSION}"

RUN echo "/usr/local/nvidia/lib" >> /etc/ld.so.conf.d/nvidia.conf && \
    echo "/usr/local/nvidia/lib64" >> /etc/ld.so.conf.d/nvidia.conf

ENV PATH /usr/local/nvidia/bin:/usr/local/cuda/bin:${PATH}
ENV LD_LIBRARY_PATH /usr/local/nvidia/lib:/usr/local/nvidia/lib64

# nvidia-container-runtime
ENV NVIDIA_VISIBLE_DEVICES all
ENV NVIDIA_DRIVER_CAPABILITIES video,compute,utility
ENV NVIDIA_REQUIRE_CUDA "cuda>=9.1"
ENV NCCL_VERSION 2.2.12

RUN apt-get update && apt-get install -y --no-install-recommends \
        cuda-libraries-$CUDA_PKG_VERSION \
        libnccl2=$NCCL_VERSION-1+cuda9.1 && \
    rm -rf /var/lib/apt/lists/*

RUN apt-get update && apt-get install -y --no-install-recommends \
        cuda-libraries-dev-$CUDA_PKG_VERSION \
        cuda-nvml-dev-$CUDA_PKG_VERSION \
        cuda-minimal-build-$CUDA_PKG_VERSION \
        cuda-command-line-tools-$CUDA_PKG_VERSION \
        libnccl-dev=$NCCL_VERSION-1+cuda9.1 && \
    rm -rf /var/lib/apt/lists/*

ENV LIBRARY_PATH /usr/local/cuda/lib64/stubs

# Install dependent packages
RUN apt-get -y update && apt-get install -y wget nano git-core build-essential pkg-config \
    autoconf automake cmake libass-dev libfreetype6-dev libtool libvorbis-dev pkg-config texinfo \
    wget zlib1g-dev mercurial libnuma-dev \
#   Install drivers for openCL
    ocl-icd-opencl-dev opencl-headers

#   Intall headers for NVIDIA
RUN git clone https://github.com/FFmpeg/nv-codec-headers /root/nv-codec-headers && \
  cd /root/nv-codec-headers &&\
  make -j8 && \
  make install -j8 && \
  cd /root && rm -rf nv-codec-headers

RUN mkdir -p /root/ffmpeg_sources \
    mkdir /root/bin

#Build/Install NASM Assembly driver
RUN cd /root/ffmpeg_sources && \
    wget https://www.nasm.us/pub/nasm/releasebuilds/2.13.03/nasm-2.13.03.tar.bz2 && \
    tar xjvf nasm-2.13.03.tar.bz2 && \
    cd nasm-2.13.03 && \
    ./autogen.sh && ./configure --prefix=$FFMPEG_BUILD --bindir=$BINDIR && \
    make -j6 && \
    make install

#Install driver for H.264
RUN cd /root/ffmpeg_sources && \
    git -C x264 pull 2> /dev/null || git clone --depth 1 https://git.videolan.org/git/x264 && \
    cd x264 && \
    ./configure --prefix=$FFMPEG_BUILD --bindir=$BINDIR --enable-static --enable-pic && \
    make -j6 && \
    make install

##Install drivers for H.265
RUN cd /root/ffmpeg_sources && \
    hg clone https://bitbucket.org/multicoreware/x265 -r e41a9bf && \
    cd x265/build/linux && \
    cmake -G 'Unix Makefiles' -DCMAKE_INSTALL_PREFIX=$FFMPEG_BUILD -DENABLE_SHARED:bool=off ../../source && \
    make -j6 && \
    make install

#Install drivers for VPX/
RUN cd ~/ffmpeg_sources && \
    git -C libvpx pull 2> /dev/null || git clone --depth 1 https://chromium.googlesource.com/webm/libvpx.git && \
    cd libvpx && \
    ./configure --prefix=$FFMPEG_BUILD --disable-examples --disable-unit-tests --enable-vp9-highbitdepth --as=nasm && \
    make -j6 && \
    make install

#Install drivers for AOM
RUN cd ~/ffmpeg_sources && \
    git -C aom pull 2> /dev/null || git clone --depth 1 https://aomedia.googlesource.com/aom && \
    mkdir aom_build && \
    cd aom_build && \
    cmake -G 'Unix Makefiles' -DCMAKE_INSTALL_PREFIX=$FFMPEG_BUILD -DENABLE_SHARED=off -DENABLE_NASM=on ../aom && \
    make -j6 && \
    make install

RUN git clone https://github.com/FFmpeg/FFmpeg /root/ffmpeg_sources/ffmpeg

RUN cd /root/ffmpeg_sources/ffmpeg && ./configure \
    --prefix=$FFMPEG_BUILD \
    --enable-version3 \
    --enable-nonfree --disable-shared \
    --enable-nvenc --enable-cuda \
    --enable-cuvid --enable-libnpp \
    --extra-cflags="-I/usr/local/cuda/include" \
    --extra-cflags="-I/usr/local/include" \
    --extra-ldflags="-L/usr/local/cuda/lib64" \
    --enable-libvpx --enable-libx264 \
    --enable-libx265 --enable-opencl \
    --enable-gpl \
    --pkg-config-flags=--static \
    --extra-cflags="-I/root/ffmpeg_build/include" \
    --extra-cflags="-I$BINDIR" \
    --extra-ldflags="-L/root/ffmpeg_build/lib" \
    --extra-libs="-lpthread -lm" \
    --bindir=$BINDIR && \
    make -j8 && \
    make install -j8 && \
    cd /root && rm -rf ffmpeg

WORKDIR /opt

# ffmpeg -i Netflix_SquareAndTimelapse_1080P_30FPS.mkv -c:v h264_nvenc -preset default output.mp4
# -it --runtime=nvidia -v /Library/Sources/Public-DockerExternal:/opt
