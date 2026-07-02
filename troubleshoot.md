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
Updated `camera.env` on Jetson (environment variables moved out of docker-compose.yml):
```bash
RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
CYCLONEDDS_URI=<CycloneDDS><Domain><General><Interfaces><NetworkInterface autodetermine="true"/></Interfaces><MaxMessageSize>65500B</MaxMessageSize><FragmentSize>65000B</FragmentSize></General><Discovery><Peers><Peer address="10.10.111.6"/></Peers></Discovery></Domain></CycloneDDS>
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
- CPU snapshot after hardware decode fix (Phase 4 only, before Phase 5 optimizations):
  - gst-launch-1.0: ~87.5% (down from ~100% with jpegdec)
  - python3: ~56.2% (down from ~67% passive load)
  - Combined CPU load reduced; further optimized in Phase 5 (gst-launch down to ~38%).
- Automatic fallback to jpegdec if nvv4l2decoder unavailable ensures robustness across hardware variants.

### Tuning Knobs
- `USE_HW_MJPEG_DECODER=0`: Disable hardware decode, force jpegdec (useful for debugging or older Jetson hardware).
- `ROS_FRAMERATE=30`: Adjust ROS publish rate (default 30 Hz stable for ArUco at 1080p).
- `RTSP_FRAMERATE=30`: Adjust RTSP stream rate independently (decoupled from ROS via tee).
- `ROS_WIDTH=1920, ROS_HEIGHT=1080`: Full-res ROS for ArUco detail; RTSP can downscale separately.

---

## 10) Configuration refactored to camera.env; framerate bumped to 60fps

### Problem
Runtime environment variables were inline in `docker-compose.yml`, making it easy to accidentally
trigger a rebuild by editing them and requiring familiarity with Docker Compose YAML structure.
Additionally, default framerate was 30fps while the camera hardware supports 60fps.

### Solution
Extract all runtime parameters into a dedicated `camera.env` file (single source of truth).
`docker-compose.yml` references it via `env_file: - camera.env`.
Editing `camera.env` + running `docker compose up -d` applies changes with no rebuild.

Camera calibration (`camera_info.yaml`) is now also volume-mounted from the repo root,
so calibration updates apply on `docker compose up -d` without rebuilding.

### Implementation
Updated `docker-compose.yml`:
- Replaced `environment:` block with `env_file: - camera.env`
- Added `./camera_info.yaml:/etc/camera_info.yaml:ro` volume mount

Updated `camera.env`:
- `FRAMERATE=60` — capture and ROS branch both at 60fps (camera hardware supports it)
- `ROS_FRAMERATE=60` — publisher defaults raised to match
- `USE_HW_MJPEG_DECODER=1` — hardware decode on by default
- `RTSP_FRAMERATE=30` — RTSP stream kept at 30fps (bandwidth reduction)
- `DEVICE=/dev/video-front` — updated to match current symlink

Updated `entrypoint.sh`:
- Default values updated to match `camera.env` (60fps, hardware decode on)
- Removed explicit `framerate=` caps from `nvvidconv` pipeline strings — framerate is now
  governed by `v4l2src` at source; removing it from mid-pipeline caps avoids negotiation mismatches

Updated `camera_publisher.cpp`:
- Default `publish_rate` raised to 60.0 Hz
- Default `framerate` raised to 60 (used in SHM pipeline caps negotiation)

### Outcome
- `/camera/image_raw` publishes at 60 Hz
- `camera_info.yaml` editable without rebuild
- All runtime tuning in one place (`camera.env`)

---

## 11) CycloneDDS large image transport over network

### Problem
After SHM fix restored full 1920×1080 ROS publishing, `ros2 topic echo /camera/image_raw` from a remote laptop showed:
```
sequence size exceeds remaining buffer
```
Images were not received despite topics being visible.

### Root Cause
Default CycloneDDS `MaxMessageSize` (14720 bytes) and `FragmentSize` (1344 bytes) are too small
for efficient transport of 1920×1080 BGR8 frames (~6 MB/frame). The receiver could not reassemble
the heavily fragmented message within default buffer limits.

Previously this worked because SHM was failing and the publisher fell back to RTSP at 1280×720
(~2.7 MB/frame), which stayed within limits.

### Solution
Increase `MaxMessageSize` and `FragmentSize` in CYCLONEDDS_URI on **both** Jetson and laptop.
Values must include unit suffix (`B`) — CycloneDDS in ROS Humble warns on bare numbers.

Note: `<Internal><ReceiveBufferSize>` is not a valid element in ROS Humble's CycloneDDS and will
cause `rmw_create_node` to fail with "unknown element".

### Implementation
Updated docker-compose.yml CYCLONEDDS_URI:
```xml
<CycloneDDS>
  <Domain>
    <General>
      <Interfaces><NetworkInterface autodetermine="true"/></Interfaces>
      <MaxMessageSize>65500B</MaxMessageSize>
      <FragmentSize>65000B</FragmentSize>
    </General>
    <Discovery>
      <Peers><Peer address="REMOTE_IP"/></Peers>
    </Discovery>
  </Domain>
</CycloneDDS>
```

The **same CYCLONEDDS_URI** (with appropriate peer IP) must be set on the receiving side (laptop container).

---

## 12) Development Journey & Architecture Rationale

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
nvvidconv (caps normalization: I420 NVMM → NV12)
  ↓
tee (zero-copy branching)
  ├─ RTSP Branch
  │   ├─ nvvidconv (scale to 1280×720, NVMM NV12)
  │   └─ nvv4l2h264enc (HW, required) + rtspclientsink → MediaMTX :8554
  │
  └─ ROS SHM Branch
      ├─ nvvidconv (NV12 → BGRx, GPU-accelerated color conversion + scale)
      ├─ videoconvert (BGRx → RGB, cheap alpha strip)
      └─ shmsink (/tmp/ros_frames) → camera_publisher (C++)
```

**ROS2 Publisher Path (C++ node, Phase 6):**

```
camera_publisher (C++ binary, GStreamer C API)
  ├─ SHM Primary Path (active)
  │   ├─ shmsrc /tmp/ros_frames
  │   ├─ video/x-raw,format=RGB (direct passthrough, NO videoconvert)
  │   └─ appsink → gst_app_sink_try_pull_sample()
  │       └─ memcpy into pre-allocated Image msg
  │       └─ publish /camera/image_raw (rgb8) @ 30 Hz
  │
  └─ RTSP Fallback Path (if SHM unavailable)
      ├─ rtspsrc → rtph264depay → avdec_h264 → videoconvert → RGB
      └─ publish /camera/image_raw (rgb8) @ 30 Hz
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
4. **Phase 4 → 5**: GPU color conversion + eliminating redundant conversions cuts gst-launch CPU from ~96% to ~38%
5. **Phase 5 → 6**: C++ port with GStreamer direct API eliminates videoconvert from publisher, cuts publisher CPU from ~78% to ~44%

Result: Final system is **stable**, **performant**, **fault-tolerant** (SHM + RTSP fallback), and **tunable** (per-branch parameters). Combined CPU usage reduced from ~156% (Phase 4) to ~90% (Phase 6).

### Phase 5: HW-Only H264 Encoding + GPU Color Conversion (CPU Optimization)
**What We Observed:**
- With Phase 4 hardware MJPEG decode active, gst-launch still consumed ~96% CPU
- Root cause 1: `videoconvert` in the ROS SHM branch was doing I420→RGB color conversion on CPU at 1920×1080@30fps (~186 MB/s)
- Root cause 2: camera_publisher.py performed a double color conversion: GStreamer RGB→BGR (videoconvert), then Python BGR→RGB (cv2.cvtColor), then published as rgb8
- Software H264 encoding (x264enc) fallback paths added unnecessary complexity

**What We Implemented:**
- **entrypoint.sh:**
  - Require hardware H264 encoder (nvv4l2h264enc) — exit with error if unavailable
  - Commented out all software H264 encoding (x264enc) pipelines
  - Simplified from 4 pipeline variants (2×2 matrix) to 2 (HW vs SW MJPEG decode only)
  - Changed ROS SHM branch: `nvvidconv` outputs BGRx (GPU-accelerated color conversion) instead of I420, then `videoconvert` does a cheap BGRx→RGB strip
- **camera_publisher.py:**
  - Publish as `bgr8` encoding directly instead of converting BGR→RGB and publishing as `rgb8`
  - Eliminated `cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)` call entirely

**Why It Helped:**
- `nvvidconv` does NV12→BGRx conversion on GPU (was previously NV12→I420 on GPU + I420→RGB on CPU)
- `videoconvert` BGRx→RGB is near-free (strip alpha byte) vs I420→RGB (full color space conversion)
- Eliminating cv2.cvtColor in Python saves ~6 MB/frame of CPU memcpy
- gst-launch CPU: **96% → 38.5%** (2.5× reduction)
- python3 CPU: **60% → 57%** (modest reduction, bulk of work is frame I/O + ROS serialization)
- ROS publish rate: stable 29-30 Hz

**Trade-off Accepted:**
- Hardware H264 encoder is now required — devices without NVENC (e.g. Orin Nano 4GB/8GB) will fail at startup
- SW encoding pipelines are commented out in entrypoint.sh and can be restored if needed
- ROS topic encoding changed from `rgb8` to `bgr8` — downstream nodes using cv_bridge handle both natively

### Phase 6: C++ Port with GStreamer Direct API (Eliminate videoconvert)
**What We Observed:**
- After Phase 5, python3 still consumed ~78% CPU despite C++ cv_bridge being efficient
- Root cause: `videoconvert` RGB→BGR running inside the publisher process (same C code whether Python or C++)
- cv::VideoCapture (OpenCV) required `videoconvert` for caps negotiation with appsink
- Initial C++ port using OpenCV showed identical CPU (~78%) — confirmed Python was not the bottleneck

**What We Implemented:**
- **camera_publisher.cpp:** Rewrote using GStreamer C API directly (no OpenCV, no cv_bridge)
  - `gst_app_sink_try_pull_sample()` reads RGB frames from shmsrc with zero color conversion
  - Pre-allocated `sensor_msgs::msg::Image` with single `memcpy` from GStreamer buffer
  - RTSP fallback via GStreamer `rtspsrc` pipeline (replaces OpenCV FFMPEG backend)
- **CMakeLists.txt:** Standalone cmake build, links GStreamer + ROS2 (no colcon workspace)
- **Dockerfile:** Removed Python deps (python3-opencv, numpy, pyyaml), added GStreamer dev headers, C++ build step
- **entrypoint.sh:** Launches C++ binary instead of Python script

**Why It Helped:**
- Eliminated `videoconvert` entirely from the publisher — reads RGB directly from shmsrc
- No OpenCV overhead (VideoCapture, Mat allocation, format negotiation)
- No cv_bridge overhead (toImageMsg copies)
- Single memcpy from GStreamer buffer into pre-allocated ROS message
- camera_publisher CPU: **78% → 44%** (1.8× reduction)
- gst-launch CPU: ~46% (unchanged, expected)
- ROS topic encoding: `rgb8` (matches shmsink output directly)
- Combined CPU: ~90% (down from ~135% with Python publisher)

**Trade-off Accepted:**
- camera_publisher.py removed — C++ binary is less convenient to modify
- Python fallback no longer available; requires Docker rebuild for changes
- RTSP fallback uses GStreamer rtspsrc instead of OpenCV FFMPEG (different error behavior)

---

## 13) ArUco Detection Rate Bottleneck (2.5 Hz output vs 60 Hz camera input)

### Problem
ArUco detection node outputs `/aruco_pose` at ~2.5 Hz average despite `/camera/image_raw` publishing at 60 Hz.

Measured topic rates on Jetson:
```
/camera/image_raw   →  30.0 Hz   (camera pipeline, healthy)
/aruco_pose         →   2.5 Hz   (ArUco detection output)
/dock_goal_pose     →   3.3 Hz   (goal pose selector output)
landing controller  →  50.0 Hz   (control loop spin rate)
```

### Root Cause
CPU-bound ArUco detection at 1920×1080 takes ~400ms per frame on ARM (Jetson).
At 2.5 Hz, the detector processes only 1 in ~12 frames it receives and drops the rest via queue backpressure.

This is **not** a camera pipeline or transport bandwidth issue — `/camera/image_raw` publishes correctly and
CycloneDDS loopback transport is not the bottleneck (both publisher and subscriber are on the same Jetson host).

### Impact on Precision Landing
The landing controller spins at 50 Hz (20ms cycle), but receives a fresh ArUco pose only every ~400ms.
For a 30cm marker at 15m detection range:
- Marker footprint: ~24px wide at 1920×1080 with 90° HFoV — at the detection margin
- During descent at 0.5 m/s, 400ms blind windows = ~20cm of unguided flight per detection cycle
- This is the primary obstacle to stable precision landing below ~5m altitude

### Solution
Two complementary fixes are required, both outside the camera pipeline:

1. **GPU-accelerated ArUco detection** (primary fix) — use CUDA OpenCV (`cv::cuda`) on Jetson; the GPU
   is largely idle during detection and can sustain 30+ Hz at 1080p.

2. **Downscaled image topic** (optional) — add a third GStreamer tee branch in `entrypoint.sh` publishing
   a second topic at e.g. 960×540 for closer-range fast detection. At 15m the marker would be ~12px wide
   (borderline), but below 8m it is well above the detection threshold and the smaller image cuts
   CPU detection time by ~4×.

### Status
Camera pipeline confirmed healthy. Detection-rate optimization requires changes in the ArUco detection node.
See `troubleshoot.md` Section 12 (Architecture Rationale) for the full pipeline context.

---

### Known Constraints & Workarounds

- **GStreamer + ROS2 in single process**: Not feasible due to event loop conflict (Phase 1 discovery)
- **RTSP H.264 re-decode cost**: Eliminated via SHM branch (Phase 3 solution)
- **CPU-bound JPEG decode**: Mitigated via hardware decoder + fallback (Phase 4 solution)
- **CPU-bound color conversion**: Offloaded to GPU via nvvidconv BGRx output (Phase 5 solution)
- **Software H264 encoding**: Disabled; nvv4l2h264enc (NVENC) required. Commented-out x264enc pipelines in entrypoint.sh can be restored for devices without NVENC.
- **CycloneDDS multicast blocked**: Solved via unicast peer configuration (see Section 6)

---

## 14) MediaMTX "Exec format error" at startup

### Problem
Container logs repeatedly show:
```bash
/entrypoint.sh: line 17: /usr/local/bin/mediamtx: cannot execute binary file: Exec format error
```

### Likely Root Cause
Architecture mismatch between the running container and the installed MediaMTX binary, most often caused by stale image/container layers.

Even if Dockerfile is correct now, an older locally cached image or container can still be used.

### Quick Diagnosis
Check host architecture:
```bash
uname -m
```

Check built image architecture:
```bash
docker image inspect ros2_rtsp_cam-rtsp-server --format '{{.Architecture}} {{.Os}}'
```

Check binary type inside image:
```bash
docker run --rm --entrypoint /bin/bash ros2_rtsp_cam-rtsp-server -lc 'file /usr/local/bin/mediamtx'
```

Check binary type in running container:
```bash
docker exec rtsp-camera file /usr/local/bin/mediamtx
```

For Jetson, all should report arm64/aarch64.

### Recovery
Perform a clean rebuild and container recreate:
```bash
docker compose down
docker compose build --no-cache
docker compose up -d --force-recreate
```

If still failing, remove stale project images and rebuild again:
```bash
docker compose down --rmi local
docker compose build --no-cache
docker compose up -d --force-recreate
```

### Notes
- `docker restart rtsp-camera` does not rebuild image layers, so it will not fix a wrong binary baked into the image.
- `docker restart rtsp-camera` is still valid for runtime bind-mounted file changes (for example `camera_info.yaml`).

### Deprecated Experimental Code

See `development.md` for earlier attempts in `final/` folder:
- `ros2_gst_publisher.py` — direct threading attempt (crashed)
- `ros2_gst_publisher_clean.py` — queue-based sync attempt (crashed in rclpy)
- `stream_test_gst.sh` — pure GStreamer validation script (kept for reference)
