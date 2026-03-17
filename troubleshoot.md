# Troubleshooting Notes

## 1) MediaMTX download failed during Docker build

### Problem
Docker build failed while downloading MediaMTX:
- mediamtx_v1.9.0_linux_arm64.tar.gz not found

### Root Cause
Jetson Orin uses arm64, but MediaMTX release asset naming for this tag is linux_arm64v8, not linux_arm64.

### Solution
Use the correct release artifact:
- mediamtx_v1.9.0_linux_arm64v8.tar.gz

### Implementation
Updated Dockerfile MediaMTX install step to:
- download mediamtx_v1.9.0_linux_arm64v8.tar.gz
- extract and install mediamtx binary

---

## 2) GStreamer NVIDIA elements missing in container

### Problem
Pipeline failed with:
- no such element factory "nvvidconv"
- no such element factory "nvv4l2h264enc"

### Root Cause
Base image is generic Ubuntu. NVIDIA Jetson GStreamer hardware plugins come from JetPack on host and were not visible inside container.

### Solution
Bind-mount Jetson runtime paths and device tree into the container.

### Implementation
Updated docker-compose service with:
- privileged: true
- ipc: host
- volumes:
  - /dev/:/dev/
  - /usr/lib/aarch64-linux-gnu/gstreamer-1.0:/usr/lib/aarch64-linux-gnu/gstreamer-1.0:ro
  - /usr/lib/aarch64-linux-gnu/tegra:/usr/lib/aarch64-linux-gnu/tegra:ro
  - /usr/lib/aarch64-linux-gnu/tegra-eglstream-libs:/usr/lib/aarch64-linux-gnu/tegra-eglstream-libs:ro
- GPU reservation block under deploy.resources

---

## 3) MediaMTX port bind conflict

### Problem
MediaMTX printed:
- ERR listen udp :8000: bind: address already in use

### Root Cause
Another container named mediamtx was already running on host network, causing port conflicts.
Also, default MediaMTX WebRTC ICE mux uses UDP 8000 unless disabled.

### Solution
Avoid binding WebRTC mux ports in this project and ensure conflicting container is stopped when needed.

### Implementation
Updated mediamtx.yml:
- webrtcICEUDPMuxAddress: ""
- webrtcICETCPMuxAddress: ""

Operational action:
- check running containers with docker ps
- stop external mediamtx container if conflicting

---

## 4) Container restart loop after startup

### Problem
Container kept restarting after startup sequence.

### Root Cause
Two issues combined:
1. entrypoint.sh used set -e with wait -n, so any child non-zero exit terminated script immediately with code 1.
2. camera_publisher RTSP connection window was too short (5 seconds), causing early failure in some runs.

### Solution
Make entrypoint tolerant to first child exit and increase RTSP startup retry window.

### Implementation
Updated entrypoint.sh:
- wait -n $MTX_PID $GST_PID $ROS_PID || true

Updated camera_publisher.py:
- RTSP connect retries from 10 x 0.5s to 30 x 1.0s
- total wait window increased from 5s to 30s

---

## 5) Camera device path mismatch

### Problem
Project originally referenced a different camera device path.

### Root Cause
Configured device path did not match desired camera symlink.

### Solution
Use /dev/video-side-front consistently.

### Implementation
Updated:
- docker-compose DEVICE value
- entrypoint default DEVICE fallback
- relevant runtime mapping configuration

---

## 6) ROS2 DDS topic discovery failing from laptop

### Problem
`ros2 topic list` on laptop showed only `/parameter_events` and `/rosout` — no camera topics.

### Root Cause
FastRTPS (default RMW) relies on UDP multicast for peer discovery, which is blocked on most WiFi/LAN setups.
Also, `rmw_cyclonedds_cpp` was not installed in the laptop Docker image.

### Solution
Use CycloneDDS with explicit unicast peer pointing to Jetson IP on both sides.

### Implementation
Updated docker-compose.yml on Jetson:
```yaml
- RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
- CYCLONEDDS_URI=<CycloneDDS><Domain><General><Interfaces><NetworkInterface autodetermine="true"/></Interfaces></General><Discovery><Peers><Peer address="10.10.111.6"/></Peers></Discovery></Domain></CycloneDDS>
```

Working one-liner to view ROS2 image stream from laptop (installs cyclonedds + rqt):
```bash
xhost +local:docker && docker run --rm -it --network host \
  -e DISPLAY=$DISPLAY \
  -e ROS_DOMAIN_ID=0 \
  -e RMW_IMPLEMENTATION=rmw_cyclonedds_cpp \
  -e "CYCLONEDDS_URI=<CycloneDDS><Domain><Discovery><Peers><Peer address=\"10.10.111.6\"/></Peers></Discovery></Domain></CycloneDDS>" \
  -v /tmp/.X11-unix:/tmp/.X11-unix:rw \
  osrf/ros:humble-desktop bash -lc \
  "apt-get update -q && apt-get install -q -y ros-humble-rmw-cyclonedds-cpp ros-humble-rqt-image-view > /dev/null && source /opt/ros/humble/setup.bash && ros2 run rqt_image_view rqt_image_view /camera/image_raw"
```

---

## 7) Low ROS2 image topic FPS (~2Hz) and high CPU usage

### Problem
`ros2 topic hz /camera/image_raw` showed ~1.9Hz instead of expected 30Hz.
`top` inside container showed python3 (camera_publisher.py) consuming 120% CPU.

### Root Cause
camera_publisher.py reads the RTSP stream via OpenCV/FFmpeg which decodes H264 on CPU.
Decoding 1920x1080 H264 at 60fps on CPU is too expensive — each frame decode takes ~500ms,
throttling output to ~2 frames/second.

GStreamer already hardware-encodes to H264 using nvv4l2h264enc (NVENC), but
camera_publisher.py then re-decodes that H264 back on the CPU via OpenCV.

### Solution
Eliminate the CPU H264 decode bottleneck in camera_publisher.py by either:
- Switching to hardware-accelerated GStreamer appsink pipeline using nvv4l2decoder
- Reducing publish framerate and GStreamer framerate to a level CPU can handle
- Reading directly from v4l2/MJPEG source in Python (bypassing H264 encode/decode cycle)
