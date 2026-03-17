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
JETSON_IP=10.10.111.6
xhost +local:docker && docker run --rm -it --network host \
  -e DISPLAY=$DISPLAY \
  -e ROS_DOMAIN_ID=0 \
  -e RMW_IMPLEMENTATION=rmw_cyclonedds_cpp \
  -e "CYCLONEDDS_URI=<CycloneDDS><Domain><Discovery><Peers><Peer address=\"${JETSON_IP}\"/></Peers></Discovery></Domain></CycloneDDS>" \
  -v /tmp/.X11-unix:/tmp/.X11-unix:rw \
  osrf/ros:humble-desktop bash -lc \
  "apt-get update -q && apt-get install -q -y ros-humble-rmw-cyclonedds-cpp ros-humble-rqt-image-view > /dev/null && source /opt/ros/humble/setup.bash && ros2 run rqt_image_view rqt_image_view /camera/image_raw"
```

Replace `JETSON_IP` with your Jetson device IP if different.

---

## 7) Historical: Low ROS2 image topic FPS (~2Hz) and high CPU usage

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

Status: Historical issue. The implemented and validated fix path is documented in Section 8 (SHM tee branch).

---

## 8) SHM tee branch enabled for ROS2 output (smooth rqt view)

### Problem
Even after tee branching, camera_publisher intermittently failed to consume SHM and fell back to RTSP decode.
This caused higher CPU, unstable publish behavior, and choppy image output.

### Root Cause
Shared-memory sender/receiver caps were not fully fixed and aligned end-to-end.
OpenCV backend support also mattered: pip OpenCV builds typically lacked GStreamer support.

### Solution
Use a dedicated SHM branch from the main GStreamer tee with explicit, fixed caps on both sides.
Make camera_publisher prefer SHM first and only fall back to RTSP when SHM is unavailable.

### Implementation
Updated Dockerfile:
- switched to apt `python3-opencv` to guarantee GStreamer-enabled OpenCV

Updated entrypoint.sh:
- added tee branch architecture for RTSP + SHM outputs
- fixed SHM sender caps before `shmsink` (RGB, width/height/framerate)
- kept low-latency queue settings for real-time behavior

Updated camera_publisher.py:
- SHM-first capture path with RTSP fallback
- SHM receiver pipeline requests matching fixed caps
- conversion to ROS-friendly BGR publish path
- throttled repetitive warning logs during reconnect/retry loops

### Validation / Outcome
- camera_publisher now logs successful SHM connection
- ROS topic publish rate recovered to ~28-30 Hz (`/camera/image_raw`)
- rqt image output appears smooth and stable
- CPU dropped significantly compared to RTSP CPU decode path (python load notably reduced)

---

## 9) Hardware MJPEG decode (nvv4l2decoder) for CPU reduction

### Problem
Even with SHM tee branching at stable 30 Hz, gst-launch and python3 CPU usage remained high (>150% combined).
The bottleneck was software JPEG decode (jpegdec) on each captured frame.

### Root Cause
jpegdec is a CPU-bound plugin; decoding 1920×1080 MJPEG at 30 fps consumes significant CPU cycles.
Jetson hardware includes NVDEC (nvv4l2decoder), which can decode MJPEG on-GPU for a fraction of CPU cost.

### Solution
Implement a dual-pipeline architecture in entrypoint.sh:
- Hardware path (primary): use nvv4l2decoder mjpeg=1 to decode on GPU.
- Software fallback path: revert to jpegdec if nvv4l2decoder is unavailable or fails at startup.
Control via USE_HW_MJPEG_DECODER environment variable (default=1).

### Implementation
Updated entrypoint.sh:
- Split GStreamer launch into conditional if/else based on USE_HW_MJPEG_DECODER check.
- Hardware path flow: nvv4l2decoder → nvvidconv (normalize to NVMM NV12) → tee branches.
- Software fallback: jpegdec → caps filter → tee branches.
- ROS SHM branch (both paths): nvvidconv to I420 → videoconvert to RGB → shmsink.
- RTSP branch (both paths): nvvidconv to NVMM NV12 → nvv4l2h264enc → rtspclientsink.
- Fixed caps negotiation: nvv4l2decoder outputs NVMM I420; inserted nvvidconv immediately to normalize to NV12 before tee.

Updated docker-compose.yml:
- Set USE_HW_MJPEG_DECODER=1 by default for hardware-first performance.
- Kept FRAMERATE=30, ROS_FRAMERATE=30, RTSP_FRAMERATE=30 as tested stable targets.

### Validation / Outcome
- Hardware pipeline starts successfully and connects SHM via shared-memory stream log.
- ROS topic publish rate stable at ~29-30 Hz with hardware decode active.
- CPU snapshot after hardware decode fix:
  - gst-launch-1.0: ~87.5% (down from ~100% with jpegdec)
  - python3: ~56.2% (down from ~67% passive load)
  - Combined CPU load reduced; headroom available for further optimization or load growth.
- Automatic fallback to jpegdec if nvv4l2decoder unavailable ensures robustness across hardware variants.

### Tuning Knobs
- `USE_HW_MJPEG_DECODER=0`: Disable hardware decode, force jpegdec (useful for debugging or older Jetson hardware).
- `ROS_FRAMERATE=30`: Adjust ROS publish rate (default 30 Hz stable for ArUco at 1080p).
- `RTSP_FRAMERATE=30`: Adjust RTSP stream rate independently (decoupled from ROS via tee).
- `ROS_WIDTH=1920, ROS_HEIGHT=1080`: Full-res ROS for ArUco detail; RTSP can downscale separately.
