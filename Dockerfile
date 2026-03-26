# JetPack 6 / L4T R36.x — self-contained container with all NVIDIA GStreamer
# hardware plugins baked in. No host library bind-mounts needed.
#
# Base image: nvcr.io/nvidia/l4t-jetpack (guest-pullable from NGC, no auth)
# Includes: nvidia-l4t-gstreamer (nvv4l2decoder, nvvidconv, nvv4l2h264enc)
#           plus CUDA runtime, TensorRT, cuDNN (unused but harmless)
#
# r36.2.0 is ABI-compatible with JP6.0 GA (r36.3.0) and JP6.1 (r36.4.0) hosts
# (same Ubuntu 22.04 / GLIBC 2.35). One image tag works across all JP6 versions.
#
# Check your host version with: cat /etc/nv_tegra_release
ARG L4T_TAG=r36.2.0
FROM nvcr.io/nvidia/l4t-jetpack:${L4T_TAG}

ENV DEBIAN_FRONTEND=noninteractive
ENV ROS_DISTRO=humble

# Install minimal ROS2 Humble (ros-base only, no desktop)
RUN apt-get update && apt-get install -y \
    software-properties-common \
    curl \
    gnupg2 \
    lsb-release \
    && add-apt-repository universe \
    && curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key -o /usr/share/keyrings/ros-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros2/ubuntu $(. /etc/os-release && echo $UBUNTU_CODENAME) main" | tee /etc/apt/sources.list.d/ros2.list > /dev/null \
    && apt-get update && apt-get install -y \
    ros-humble-ros-base \
    ros-humble-image-transport \
    ros-humble-camera-info-manager \
    ros-humble-rmw-cyclonedds-cpp \
    && rm -rf /var/lib/apt/lists/*

# Install open-source GStreamer community plugins, RTSP tools, and kmod.
# NVIDIA hardware GStreamer plugins (nvv4l2decoder, nvvidconv, nvv4l2h264enc)
# are already installed in the l4t-jetpack base image — no separate install needed.
# kmod provides lsmod, required by nvv4l2h264enc on JetPack 6.2+ at runtime.
RUN apt-get update && apt-get install -y \
    gstreamer1.0-tools \
    gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad \
    gstreamer1.0-plugins-ugly \
    gstreamer1.0-libav \
    gstreamer1.0-rtsp \
    libgstreamer1.0-dev \
    libgstreamer-plugins-base1.0-dev \
    netcat-openbsd \
    wget \
    v4l-utils \
    kmod \
    && rm -rf /var/lib/apt/lists/*

# Install MediaMTX
RUN wget -q https://github.com/bluenviron/mediamtx/releases/download/v1.9.0/mediamtx_v1.9.0_linux_arm64v8.tar.gz \
    && tar -xzf mediamtx_v1.9.0_linux_arm64v8.tar.gz \
    && mv mediamtx /usr/local/bin/ \
    && rm mediamtx_v1.9.0_linux_arm64v8.tar.gz

# Setup ROS2 environment
RUN echo "source /opt/ros/humble/setup.bash" >> ~/.bashrc

# Build C++ camera publisher
COPY camera_publisher.cpp CMakeLists.txt /tmp/build/
RUN bash -c "source /opt/ros/humble/setup.bash && \
    cd /tmp/build && mkdir build && cd build && \
    cmake .. -DCMAKE_BUILD_TYPE=Release && \
    make -j\$(nproc) && \
    cp camera_publisher /usr/local/bin/" && \
    rm -rf /tmp/build

COPY mediamtx.yml /etc/mediamtx/mediamtx.yml
COPY camera_info.yaml /etc/camera_info.yaml
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
