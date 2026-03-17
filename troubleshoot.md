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

---

## 10) Development Journey & Architecture Rationale

### Overview
The camera streaming + ROS publishing system evolved through multiple architectural phases, each phase solving fundamental constraints while maintaining stability and performance.

### Phase 1: Initial Architecture Problem (Segmentation Fault)
**What We Tried:**
- Single process running GStreamer pipeline + ROS2 executor in same thread using tee branching for parallel output.
- Goal: Minimize process overhead, share decoded frame data between RTSP and ROS topics.

**Why It Failed:**
- GStreamer uses GLib event loop (mainloop-based, blocking I/O)
- ROS2 Humble uses rclpy executor (thread-pool based, periodic spinners)
- When both run in same process, they conflict at C/C++ level with incompatible threading models
- Result: Segmentation fault in `rclpy/executors.py:645` when executor tried to process callbacks while GLib mainloop held locks

**Lesson Learned:**
Two event loops with different threading models cannot safely share the same Python/C process boundary. This is a fundamental constraint, not a coding bug.

### Phase 2: Hybrid Process Breakthrough (Process Isolation)
**What We Implemented:**
- Separate GStreamer pipeline into background service (entrypoint.sh)
- Separate ROS2 publisher into independent Python process (camera_publisher.py)
- Contract between them: RTSP stream over localhost:8554 (standard protocol)

**Why It Works:**
- Each process has own event loop + threading model (no C++ layer conflicts)
- RTSP is stable, proven protocol with clear semantics (no shared memory tricks needed)
- Graceful degradation: if one process fails, other continues functioning
- Industry standard pattern (e.g., VLC separates encoders from viewers)

**Trade-off Accepted:**
- Added one re-decode step: ROS publisher reads RTSP stream, OpenCV FFmpeg backend re-decodes H.264
- CPU cost: ~120% python3 load (re-decode bottleneck)
- Latency: 2-3 frames (RTSP buffering + re-decode pipeline)
- Solution worked, but left optimization opportunity

### Phase 3: SHM Tee Branching (Low-Latency ROS Path)
**What We Implemented:**
- GStreamer tee branching: decode once, send to multiple outputs
  - RTSP branch: H.264 encode at downscaled resolution (1280×720)
  - ROS SHM branch: direct raw frame to shared-memory socket (1920×1080)
- ROS publisher reads SHM directly, bypassing RTSP re-decode entirely

**Why It Helped:**
- SHM is zero-copy between processes on same host (direct mmap)
- Eliminates RTSP re-decode from ROS pipeline (python3 CPU dropped from ~120% to ~67%)
- ROS publish rate climbed from ~2 Hz (bottlenecked by decode) to ~28-30 Hz (real 30 fps source)
- Maintained RTSP output at independent resolution (1280×720 for bandwidth efficiency)

**Architecture Lesson:**
Per-branch pipeline optimization allows decoupled tuning: one feed (source @ 1920×1080@30fps) can serve multiple consumers with different quality/rate profiles without replicating the decode step.

### Phase 4: Hardware MJPEG Decode (GPU Acceleration)
**What We Observed:**
- SHM tee branching stable at 30 Hz, but gst-launch CPU remained high (~100%)
- Root cause: jpegdec plugin is CPU-bound; decoding 1920×1080 MJPEG at 30 fps taxed single-core performance

**What We Implemented:**
- Conditional hardware decoder selection via USE_HW_MJPEG_DECODER flag
  - Hardware path (primary): nvv4l2decoder with automatic NVMM format normalization via nvvidconv
  - Software fallback (safety): jpegdec if hardware unavailable at startup
- Caps negotiation fix: inserted nvvidconv immediately post-decoder to normalize I420 NVMM → NV12 (mismatched formats were causing early pipeline failures)

**Why It Helped:**
- nvv4l2decoder offloads JPEG decode to GPU NVDEC core, freeing CPU cycles
- gst-launch CPU reduced from ~100% to ~87.5% (headroom for future features)
- python3 CPU reduced from ~67% to ~56.2% (lighter passive load from tee-fed SHM pipe)
- ROS publish rate remained stable at 29-30 Hz (decode faster, no backlog)

**Backward Compatibility:**
- Automatic fallback to jpegdec preserves functionality on hardware without NVIDIA JetPack or older Jetson models
- USE_HW_MJPEG_DECODER=0 allows forced software decode for debugging on problematic hardware

### Architecture Summary

```
USB Camera (MJPEG, 1920×1080@30fps)
  ↓
v4l2src (frame capture)
  ↓
[nvv4l2decoder (GPU) OR jpegdec (CPU) fallback]
  ↓
nvvidconv (caps normalization: I420 NVMM → NV12 / SHM RGB)
  ↓
tee (zero-copy branching)
  ├─ RTSP Branch
  │   ├─ nvvidconv (scale to 1280×720, NVMM NV12)
  │   └─ nvv4l2h264enc + rtspclientsink → MediaMTX :8554
  │
  └─ ROS SHM Branch
      ├─ videoconvert (normalized → RGB 1920×1080)
      └─ shmsink (/tmp/ros_frames) → camera_publisher.py
```

**ROS2 Publisher Path:**

```
camera_publisher.py (separate process)
  ├─ SHM Primary Path (active)
  │   ├─ shmsrc /tmp/ros_frames
  │   ├─ videoconvert RGB → BGR
  │   └─ appsink (low-latency, drop late frames)
  │       └─ publish /camera/image_raw @ 30 Hz
  │
  └─ RTSP Fallback Path (if SHM unavailable)
      ├─ cv2.VideoCapture("rtsp://localhost:8554/camera")
      ├─ cv2.cvtColor(BGR → RGB)
      └─ publish /camera/image_raw @ 30 Hz (retry every 30s)
```

### Configuration Knobs (Environment Variables)

| Variable | Default | Phase | Purpose |
|----------|---------|-------|---------|
| `USE_HW_MJPEG_DECODER` | 1 | 4 | hardware-first decode (nvv4l2decoder) |
| `ROS_FRAMERATE` | 30 | 3 | SHM branch publish rate (Hz) |
| `RTSP_FRAMERATE` | 30 | 3 | RTSP branch stream rate (Hz) |
| `ROS_WIDTH` | 1920 | 3 | ROS full-detail capture width |
| `ROS_HEIGHT` | 1080 | 3 | ROS full-detail capture height |
| `RTSP_WIDTH` | 1280 | 3 | RTSP bandwidth-reduced width |
| `RTSP_HEIGHT` | 720 | 3 | RTSP bandwidth-reduced height |
| `FRAMERATE` | 30 | all | Source capture framerate (input to v4l2src) |

### Why Multi-Phase Evolution Matters

Each phase locked in a constraint or revealed a limitation:

1. **Phase 1 → 2**: Process isolation is mandatory due to event loop incompatibility (C++ library limitation, not solvable in Python)
2. **Phase 2 → 3**: SHM branching unlocks low-latency ROS without sacrificing RTSP (added zero-copy path)
3. **Phase 3 → 4**: Hardware decode reduces CPU further without architectural changes (orthogonal optimization)

Result: Final system is **stable**, **performant**, **fault-tolerant** (both paths available), and **tunable** (per-branch parameters).

### Known Constraints & Workarounds

- **GStreamer + ROS2 in single process**: Not feasible due to event loop conflict (Phase 1 discovery)
- **RTSP H.264 re-decode cost**: Eliminated via SHM branch (Phase 3 solution)
- **CPU-bound JPEG decode**: Mitigated via hardware decoder + fallback (Phase 4 solution)
- **CycloneDDS multicast blocked**: Solved via unicast peer configuration (see Section 6)

### Deprecated Experimental Code

See `development.md` for earlier attempts in `final/` folder:
- `ros2_gst_publisher.py` — direct threading attempt (crashed)
- `ros2_gst_publisher_clean.py` — queue-based sync attempt (crashed in rclpy)
- `stream_test_gst.sh` — pure GStreamer validation script (kept for reference)
