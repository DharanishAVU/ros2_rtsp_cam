# Camera RTSP + ROS2 Publisher

Streams a USB camera as RTSP and publishes ROS2 image topics simultaneously using hardware-accelerated MJPEG decode on Jetson.

- **RTSP**: `rtsp://localhost:8554/camera` (H.264, downscaled to 1280×720 @ 30fps)
- **ROS2**: `/camera/image_raw` + `/camera/camera_info` (1920×1080 @ 30fps default, RGB8, `sensor_msgs/Image`)
- **Camera**: 1920×1080 @ 30fps default MJPEG source (hardware-decoded on GPU)
- **Pipeline**: GStreamer tee branching (RTSP + SHM paths), shared-memory frame delivery to ROS2

## Architecture

```
v4l2src (MJPEG)
   ↓
[nvv4l2decoder OR jpegdec]  ← hardware-first, software fallback
   ↓
nvvidconv (normalize caps)
   ↓
tee branch
  ├─ RTSP path: nvvidconv → nvv4l2h264enc (HW) → rtspclientsink (1280×720 @ 30fps)
   └─ ROS path:  nvvidconv (BGRx, GPU) → videoconvert (RGB) → shmsink (1920×1080 @ configurable rate)
   ↓
camera_publisher (C++, GStreamer appsink — no videoconvert, no OpenCV)
   ↓
/camera/image_raw (rgb8) @ configurable rate (30 Hz default)
```

## Quick Start

```bash
docker compose build
docker compose up -d

# View ROS topics
docker exec rtsp-camera bash -lc "source /opt/ros/humble/setup.bash && ros2 topic hz /camera/image_raw"

# View RTSP stream
ffplay -rtsp_transport tcp rtsp://localhost:8554/camera
```

## ROS2 Topics

```bash
ros2 topic list
ros2 topic hz /camera/image_raw           # measure publish rate
ros2 topic echo /camera/camera_info       # camera calibration
ros2 run rqt_image_view rqt_image_view /camera/image_raw
```

## RTSP Stream

```bash
# TCP (reliable, higher latency)
ffplay -rtsp_transport tcp rtsp://localhost:8554/camera

# UDP (fastest, may skip frames on congestion)
ffplay rtsp://localhost:8554/camera
```

## Configuration

All parameters are set in `camera.env` — the single source of truth for runtime settings.
Edit this file and run `docker compose up -d` to apply changes (no rebuild needed).

Calibration updates are read from `camera_info.yaml`, mounted into the container as `/etc/camera_info.yaml`.
Updating `camera_info.yaml` and restarting/recreating the container is enough; no image rebuild is needed.

### When restart is enough

- **`docker restart rtsp-camera` is enough** for bind-mounted files such as `camera_info.yaml` and other runtime file edits.
- **Use `docker compose up -d --force-recreate`** after changing `camera.env`, `docker-compose.yml`, or service-level env/volume settings.
- **Use `docker compose up -d --build --force-recreate`** after changing `Dockerfile`, `entrypoint.sh`, `camera_publisher.cpp`, or other files copied into the image.

### Camera & Decode

```bash
DEVICE=/dev/video-front          # camera device path
WIDTH=1920                        # source capture width
HEIGHT=1080                       # source capture height
FRAMERATE=30                      # source capture rate (Hz, default)
USE_HW_MJPEG_DECODER=1            # 1=GPU decode (default), 0=CPU decode (jpegdec fallback)
```

### ROS2 Branch

```bash
ROS_WIDTH=1920                    # ROS image width (full detail for ArUco)
ROS_HEIGHT=1080                   # ROS image height
ROS_FRAMERATE=30                  # ROS publish rate (Hz, default)
ROS2_ENABLED=1                    # 1=RTSP+ROS2, 0=RTSP only
```

### RTSP Branch

```bash
RTSP_WIDTH=1280                   # RTSP stream width (downscaled, reduced bandwidth)
RTSP_HEIGHT=720                   # RTSP stream height
RTSP_FRAMERATE=30                 # RTSP stream rate (Hz)
```

### ROS2 Network

```bash
ROS_DOMAIN_ID=82                  # match your ROS2 domain
RMW_IMPLEMENTATION=rmw_cyclonedds_cpp  # CycloneDDS (unicast, no multicast required)
CYCLONEDDS_URI=...                # unicast peer discovery (see troubleshoot.md Section 6)
```

## Performance Tuning

### CPU Usage Reduction (Hardware Decode Strategy)

Default configuration uses **hardware MJPEG decode (nvv4l2decoder)** and **hardware H264 encode (nvv4l2h264enc)** on Jetson, with GPU-accelerated color conversion (nvvidconv BGRx) on the ROS SHM branch:

- **gst-launch CPU**: ~46% (hardware decode + encode + GPU color conversion)
- **camera_publisher CPU**: ~44% (C++ node, GStreamer direct appsink, no videoconvert)
- **ROS fps**: stable at configured rate (`/camera/image_raw`, 30 Hz default)
- **RTSP fps**: 30 Hz (independently rate-limited at encode step)
- **Latency**: minimal (SHM direct frame delivery, zero color conversion in publisher)

Hardware H264 encoder (nvv4l2h264enc / NVENC) is **required**. If unavailable (e.g. Orin Nano), the container will exit with an error.
If hardware MJPEG decoder is unavailable, automatic fallback to software jpegdec (CPU-bound, higher load).

To force software MJPEG decode:
```yaml
  - USE_HW_MJPEG_DECODER=0
```

> **Note:** Software H264 encoding (x264enc) has been disabled. The commented-out pipelines
> in `entrypoint.sh` can be restored if needed for devices without NVENC hardware.

### Resolution & Framerate Tuning

Decouple ROS and RTSP targets via tee branching:
- **ROS**: Keep at 1920×1080; run at 30Hz default and raise to 60Hz if your camera/compute budget supports it.
- **RTSP**: Downscale to 1280×720 @ 30Hz independently to reduce network bandwidth/storage.

> **Note on ArUco detection rate**: `/camera/image_raw` can publish up to 60 Hz, but downstream
> ArUco detection (CPU, OpenCV) typically outputs at 2–3 Hz on 1920×1080 frames (~400ms/frame on ARM).
> The camera pipeline is not the bottleneck — see [`troubleshoot.md` Section 13](troubleshoot.md#13-aruco-detection-rate-bottleneck) for analysis and fixes.

### Low-Latency Profile

For drone live-view with minimal jitter:
```bash
ROS_FRAMERATE=60                  # full 60 Hz for ArUco/control
RTSP_FRAMERATE=30                 # reduced rate for monitoring stream
```

### High-Bandwidth Profile

Use this profile when you need 60fps end-to-end and your hardware sustains it:
```bash
FRAMERATE=60                      # capture at 60 fps
ROS_FRAMERATE=60                  # publish full 60 Hz to ROS2
RTSP_FRAMERATE=30                 # RTSP at 30 Hz (bandwidth-limited)
USE_HW_MJPEG_DECODER=1            # hardware decode required at 60 fps
```

## Troubleshooting

See [`troubleshoot.md`](troubleshoot.md) for detailed guides:
- Section 6: ROS2 DDS topic discovery and unicast peer setup
- Section 8: SHM tee branch architecture and stability
- Section 9: Hardware MJPEG decode configuration and fallback behavior

### Common Issues

**ROS topic not visible on laptop?**
- Check [`troubleshoot.md` Section 6](troubleshoot.md#6-ros2-dds-topic-discovery-failing-from-laptop) for CycloneDDS unicast peer setup.

**Camera image low fps (~2 Hz instead of 60 Hz)?**
- Ensure hardware decode is active: check logs for "Using decoder: nvv4l2decoder mjpeg=1".
- If jpegdec is active on CPU, consider upgrading to Jetson Xavier/Orin for hardware NVDEC support.

**CPU usage still high?**
- Verify `gst-launch` process shows hardware decoder path in startup logs.
- Run `docker logs rtsp-camera | grep "Using decoder"` to confirm.
- If jpegdec fallback active, check for nvidia plugins availability or hardware constraints.
- Ensure hardware H264 encoder is detected: `docker logs rtsp-camera | grep "H264 encoder"`.

### Camera calibration

Edit `camera_info.yaml` in the repo root — it is volume-mounted into the container at `/etc/camera_info.yaml` via `docker-compose.yml`. Changes take effect on `docker compose up -d` with no rebuild needed.

### Additional Common Issues

**`/usr/local/bin/mediamtx: cannot execute binary file: Exec format error`**
- Usually indicates a stale or wrong-architecture binary persisted in an older image/container.
- Verify host + image architecture:
```bash
uname -m
docker image inspect ros2_rtsp_cam-rtsp-server --format '{{.Architecture}} {{.Os}}'
```
- Verify installed MediaMTX binary type in the built image:
```bash
docker run --rm --entrypoint /bin/bash ros2_rtsp_cam-rtsp-server -lc 'file /usr/local/bin/mediamtx'
```
- Rebuild cleanly and recreate container:
```bash
docker compose down
docker compose build --no-cache
docker compose up -d --force-recreate
```
- If the problem persists, inspect running container binary directly:
```bash
docker exec rtsp-camera file /usr/local/bin/mediamtx
```

**Device busy on startup** — another container is holding the camera:
```bash
docker ps          # find the container
docker rm -f <id>
docker compose up -d
```

**No ROS2 topics on host** — container uses `network_mode: host`; ensure `ROS_DOMAIN_ID` matches.

**v4l2bufferpool "not free" warnings** — non-fatal, safe to ignore.

**nvv4l2h264enc not available** — container will exit with error. This device lacks NVENC hardware (e.g. Orin Nano). Re-enable the commented-out SW encoding pipelines in `entrypoint.sh`.
