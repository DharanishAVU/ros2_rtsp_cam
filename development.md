# Development Notes: Camera RTSP + ROS2 Publisher

## Final Implementation Status ✅

**Hardware-accelerated streaming and high-performance ROS2 publishing fully operational**

**Performance Profile (Jetson Orin):**
- ROS2: `/camera/image_raw` @ 1920×1080 @ 29-30 Hz (SHM delivery, full detail for ArUco)
- RTSP: `rtsp://localhost:8554/camera` — H.264 @ 1280×720 @ 30 fps (bandwidth-optimized)
- gst-launch CPU: ~87.5% (hardware MJPEG decode)
- python3 CPU: ~56.2% (SHM direct delivery, no re-decode)
- Publish latency: minimal (shared-memory direct frame transfer)

## Current Architecture

### GStreamer Pipeline (entrypoint.sh)
```
v4l2src (MJPEG source, 1920×1080@30fps)
  ↓
[nvv4l2decoder mjpeg=1 OR jpegdec fallback]  ← Hardware decode (GPU/CPU)
  ↓
nvvidconv (caps normalization)
  ↓
tee branching (low-latency, zero-copy)
  ├─ RTSP Path
  │   └─ nvvidconv → NVMM NV12 (1280×720) → nvv4l2h264enc → rtspclientsink
  └─ ROS Path (SHM)
      └─ nvvidconv → I420 → videoconvert → RGB → shmsink (/tmp/ros_frames)
```

### ROS2 Publisher (camera_publisher.py)
**SHM-First Path (Primary):**
```
shmsrc (connect to /tmp/ros_frames, GStreamer SHM source)
  ↓
videoconvert (RGB → BGR)
  ↓
appsink (drop frames if late, low-latency settings)
  ↓
cv_bridge.cv2_to_imgmsg(encoding='rgb8')
  ↓
publish to /camera/image_raw @ 30 Hz
```

**RTSP Fallback Path:**
```
cv2.VideoCapture("rtsp://127.0.0.1:8554/camera", cv2.CAP_FFMPEG)
  ↓
cv2.cvtColor(COLOR_BGR2RGB)
  ↓
publish to /camera/image_raw @ 30 Hz (if SHM unavailable)
```

## Journey: From Single-Process to Hybrid to Current Hardware-Optimized

### Phase 1: Initial Problem (Segmentation Fault)
- Goal: Stream USB camera to RTSP AND publish ROS2 simultaneously
- Attempted: Direct GStreamer + ROS2 in single container with tee branching
- Result: Segmentation fault in `rclpy/executors.py:645`
- Root cause: GLib mainloop (GStreamer) incompatible with ROS2 executor threading

### Phase 2: Hybrid Process Breakthrough ✅
- Solution: Decouple into two processes (GStreamer background + ROS2 Python)
- RTSP as contract between them (standard protocol, no direct coupling)
- Outcome: Stable streaming + ROS2 publishing, but bottleneck exposed: CPU H264 re-decode in Python

### Phase 3: SHM Tee Branching for Low-Latency ROS (Current)
- Problem: ROS publisher reading from RTSP H374 decode was CPU-intensive (~120% Python)
- Solution: Add SHM branch directly from GStreamer tee, skip RTSP re-decode
- Outcome: ROS rate improved to ~30 Hz, python3 CPU reduced to ~67%

### Phase 4: Hardware MJPEG Decode Optimization (Current)
- Problem: jpegdec still CPU-bound for 1920×1080 @ 30 fps (~100% gst-launch)
- Solution: Hardware decoder (nvv4l2decoder mjpeg=1) with automatic jpegdec fallback
- Outcome: gst-launch CPU reduced to ~87.5%, python3 ~56.2%, stable 30 Hz ROS publishing

## Key Design Decisions

### 1. Per-Branch Resolution & Framerate Decoupling
- ROS: 1920×1080 @ 30 fps (full detail for ArUco marker detection)
- RTSP: 1280×720 @ 30 fps (bandwidth-reduced for remote viewing)
- Mechanism: GStreamer tee branching allows independent nvvidconv caps per branch
- Benefit: ROS data quality never sacrificed for RTSP transmission efficiency

### 2. SHM Direct Delivery vs RTSP Re-Decode
- Initial: Python read RTSP, re-decode H264 on CPU (high latency, high CPU)
- Current: Python read SHM from GStreamer tee, zero re-decode (low latency, low CPU)
- Fallback: If SHM unavailable at startup, automatic RTSP fallback (30s retry window)
- Robustness: Both paths available; SHM primary, RTSP safe default

### 3. Hardware-First with Automatic Fallback
- Primary: nvv4l2decoder mjpeg=1 (GPU decode on Jetson NVDEC)
- Fallback: jpegdec (software decode if hardware unavailable)
- Control: `USE_HW_MJPEG_DECODER` flag in docker-compose.yml (default=1)
- Portability: Works on Jetson Xavier/Orin; older hardware/missing JetPack plugins automatically revert to jpegdec

### 4. CycloneDDS Unicast for ROS2 Network Discovery
- Problem: FastRTPS multicast blocked on WiFi/LAN
- Solution: CycloneDDS with explicit unicast peer (see troubleshoot.md Section 6)
- Robustness: ROS2 topics visible across subnets without multicast relay

## Environment Variables & Tuning

| Variable | Default | Purpose | Impact |
|----------|---------|---------|--------|
| `USE_HW_MJPEG_DECODER` | `1` | Hardware MJPEG decode | 87.5% CPU (hardware) vs 100% (software) |
| `ROS_FRAMERATE` | `30` | ROS publish rate (Hz) | Latency vs throughput trade-off |
| `RTSP_FRAMERATE` | `30` | RTSP stream rate (Hz) | Bandwidth vs freshness |
| `ROS_WIDTH` | `1920` | ROS image width | ArUco marker detail |
| `ROS_HEIGHT` | `1080` | ROS image height | ArUco marker detail |
| `RTSP_WIDTH` | `1280` | RTSP stream width | Bandwidth optimization |
| `RTSP_HEIGHT` | `720` | RTSP stream height | Bandwidth optimization |
| `FRAMERATE` | `30` | Source capture rate | Source fps (input to pipeline) |

## Deprecated Approaches (Phase 1 Experiments)

Files in `final/` folder record failed attempts:

- `ros2_gst_publisher.py` — direct GStreamer callback to ROS2 thread (unsafe, crashed with segfault)
- `ros2_gst_publisher_clean.py` — queue-based decoupling at Python level (still crashed in rclpy C++ layer)
- `docker-compose-debug.yml` — debug variant with extra logging
- `stream_test_gst.sh` — pure GStreamer pipeline test script

These were necessary experiments to isolate root cause (incompatible threading models). The hybrid + SHM + hardware-decode approach avoids the problem entirely.
- These are harmless v4l2 driver messages, not errors
- GStreamer recovers automatically
- Safe to ignore

**CycloneDDS deprecated NetworkInterfaceAddress** (removed)
- The cyclonedds.xml file only set defaults
- Removed in final version — CycloneDDS works identically without it
- Eliminates deprecation warning spam from logs

## Testing Checklist

- ✅ RTSP stream accessible via ffplay
- ✅ ROS2 topics registered and publishing
- ✅ Camera calibration loaded from YAML
- ✅ No segmentation faults
- ✅ No threading conflicts
- ✅ Stable 30 FPS sustained
- ✅ RTSP-only mode works (ROS2_ENABLED=0)
- ✅ Combined mode works (ROS2_ENABLED=1)

## Performance Characteristics

- **Image capture**: ~33ms per frame (30 Hz)
- **RTSP encoding**: H.264 @ 8 Mbps, zerolatency tuning
- **ROS2 publishing**: 30 Hz via timer callback
- **Container size**: ~950 MB (ROS2 Humble ros-base + GStreamer + MediaMTX)
- **CPU usage**: ~15-20% per core (MJPEG decode + H.264 encode + ROS2 DDS)
- **Latency**: RTSP ~100-200ms (network), ROS2 ~5-10ms (DDS local)

## Jetson Notes

The current production pipeline is CPU-oriented and portable:

```
v4l2src ! jpegdec ! videoconvert ! x264enc ! h264parse ! rtspclientsink
```

For NVIDIA Jetson, the expected optimization is to move color conversion and H.264 encoding onto NVIDIA hardware.

### Recommended GStreamer changes for Jetson

Replace:

```
videoconvert ! \
video/x-raw,format=I420,width="$WIDTH",height="$HEIGHT",framerate="$FRAMERATE"/1 ! \
x264enc tune=zerolatency bitrate=8000 speed-preset=ultrafast key-int-max=30 !
```

With:

```
nvvidconv ! \
video/x-raw(memory:NVMM),format=I420,width="$WIDTH",height="$HEIGHT",framerate="$FRAMERATE"/1 ! \
nvv4l2h264enc bitrate=8000000 insert-sps-pps=true idrinterval=30 !
```

Resulting Jetson-oriented pipeline:

```
v4l2src device="$DEVICE" io-mode=2 do-timestamp=true ! \
image/jpeg,width="$WIDTH",height="$HEIGHT",framerate="$FRAMERATE"/1 ! \
jpegdec ! \
nvvidconv ! \
video/x-raw(memory:NVMM),format=I420,width="$WIDTH",height="$HEIGHT",framerate="$FRAMERATE"/1 ! \
nvv4l2h264enc bitrate=8000000 insert-sps-pps=true idrinterval=30 ! \
h264parse ! \
rtspclientsink location=rtsp://127.0.0.1:8554/camera protocols=tcp
```

### Why these changes matter

- `nvvidconv` uses Jetson video hardware instead of CPU-based `videoconvert`
- `nvv4l2h264enc` uses the hardware encoder instead of CPU-based `x264enc`
- This should materially reduce CPU load and improve thermal behavior on Jetson

### Deployment notes for Jetson

- The Docker base image would likely need to be changed to a Jetson-compatible L4T image
- Required Jetson GStreamer plugins must be present in the container
- Container runtime typically needs NVIDIA runtime support enabled
- The ROS2 OpenCV consumer can stay unchanged; only the RTSP-producing GStreamer path needs Jetson-specific acceleration

### Status

- This is documented guidance only
- The production files in this repository were intentionally left unchanged
- Any Jetson-specific variant should be validated on the target JetPack version because plugin names and caps can vary by release

## References

- See3CAM_24CUG: USB 3.0 UVC camera, native MJPEG output
- MediaMTX: RTSP server, lightweight pure Go implementation
- GStreamer 1.0: Industry standard media framework
- ROS2 Humble: Stable LTS release, CycloneDDS middleware
- OpenCV: cv2.VideoCapture + FFmpeg for robust RTSP decoding
