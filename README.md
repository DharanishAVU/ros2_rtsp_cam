# Camera RTSP + ROS2 Publisher

Streams a USB camera as RTSP and publishes ROS2 image topics simultaneously using hardware-accelerated MJPEG decode on Jetson.

- **RTSP**: `rtsp://localhost:8554/camera` (H.264, downscaled to 1280×720 @ 30fps)
- **ROS2**: `/camera/image_raw` + `/camera/camera_info` (1920×1080 @ 30fps, RGB, `sensor_msgs/Image`)
- **Camera**: 1920×1080 @ 30fps MJPEG source (hardware-decoded on GPU)
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
  ├─ RTSP path: nvvidconv → h264enc → rtspclientsink (1280×720 @ 30fps)
  └─ ROS path:  videoconvert → RGB → shmsink (1920×1080 @ 30fps)
   ↓
camera_publisher.py (SHM-first, RTSP fallback)
   ↓
/camera/image_raw @ 29-30 Hz
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

All parameters are set in `docker-compose.yml` under `environment`. Key options:

### Camera & Decode

```yaml
environment:
  - DEVICE=/dev/video-side-front     # camera device path
  - WIDTH=1920                        # source capture width
  - HEIGHT=1080                       # source capture height
  - FRAMERATE=30                      # source capture rate (Hz)
  - USE_HW_MJPEG_DECODER=1            # 1=GPU decode (default), 0=CPU decode (jpegdec fallback)
```

### ROS2 Branch

```yaml
  - ROS_WIDTH=1920                    # ROS image width (full detail for ArUco)
  - ROS_HEIGHT=1080                   # ROS image height
  - ROS_FRAMERATE=30                  # ROS publish rate (Hz)
  - ROS2_ENABLED=1                    # 1=RTSP+ROS2, 0=RTSP only
```

### RTSP Branch

```yaml
  - RTSP_WIDTH=1280                   # RTSP stream width (downscaled, reduced bandwidth)
  - RTSP_HEIGHT=720                   # RTSP stream height
  - RTSP_FRAMERATE=30                 # RTSP stream rate (Hz)
```

### ROS2 Network

```yaml
  - ROS_DOMAIN_ID=0                   # match your ROS2 domain
  - RMW_IMPLEMENTATION=rmw_cyclonedds_cpp  # CycloneDDS (unicast, no multicast required)
  - CYCLONEDDS_URI=...                # unicast peer discovery (see troubleshoot.md Section 6)
```

## Performance Tuning

### CPU Usage Reduction (Hardware Decode Strategy)

Default configuration uses **hardware MJPEG decode (nvv4l2decoder)** on Jetson:

- **gst-launch CPU**: ~87.5% (down from ~100% with jpegdec)
- **python3 CPU**: ~56.2% (reduced overhead)
- **ROS fps**: stable 29-30 Hz
- **Latency**: minimal (SHM direct frame delivery)

If hardware decoder is unavailable, automatic fallback to software jpegdec (CPU-bound, higher load).

To force software decode:
```yaml
  - USE_HW_MJPEG_DECODER=0
```

### Resolution & Framerate Tuning

Decouple ROS and RTSP targets via tee branching:
- **ROS**: Keep at 1920×1080 @ 30Hz for maximum ArUco detail and stability.
- **RTSP**: Downscale to 1280×720 independently to reduce bandwidth/storage (example above).

### Low-Latency Profile

For drone live-view with minimal jitter:
```yaml
  - ROS_FRAMERATE=30                  # keep 30 Hz stable base
  - RTSP_FRAMERATE=30                 # match ROS rate to avoid async skew
```

### High-Bandwidth Profile

For higher fps if hardware allows:
```yaml
  - FRAMERATE=60                       # capture at 60 fps
  - ROS_FRAMERATE=30                  # downsample ROS to 30 Hz (ArUco-safe)
  - RTSP_FRAMERATE=60                 # RTSP stream all 60 fps for monitoring
  - USE_HW_MJPEG_DECODER=1            # hardware decode scales better at 60 fps
```

## Troubleshooting

See [`troubleshoot.md`](troubleshoot.md) for detailed guides:
- Section 6: ROS2 DDS topic discovery and unicast peer setup
- Section 8: SHM tee branch architecture and stability
- Section 9: Hardware MJPEG decode configuration and fallback behavior

### Common Issues

**ROS topic not visible on laptop?**
- Check [`troubleshoot.md` Section 6](troubleshoot.md#6-ros2-dds-topic-discovery-failing-from-laptop) for CycloneDDS unicast peer setup.

**Camera image low fps (~2 Hz instead of 30 Hz)?**
- Ensure hardware decode is active: check logs for "Using decoder: nvv4l2decoder mjpeg=1".
- If jpegdec is active on CPU, consider upgrading to Jetson Xavier/Orin for hardware NVDEC support.

**CPU usage still high?**
- Verify `gst-launch` process shows hardware decoder path in startup logs.
- Run `docker logs rtsp-camera | grep "Using decoder"` to confirm.
- If jpegdec fallback active, check for nvidia plugins availability or hardware constraints.
environment:
  - DEVICE=/dev/video0
```

### Camera calibration

Edit `camera_info.yaml` — loaded at startup from `/etc/camera_info.yaml` inside the container.

## Architecture

```
v4l2src (MJPEG 1920×1080@30fps)
  └─ jpegdec → videoconvert → x264enc → rtspclientsink → MediaMTX :8554
camera_publisher.py reads rtsp://127.0.0.1:8554/camera via OpenCV
  └─ publishes /camera/image_raw  (rgb8, 1920×1080)
  └─ publishes /camera/camera_info
```

## Troubleshooting

**Device busy on startup** — another container is holding the camera:
```bash
docker ps          # find the container
docker rm -f <id>
docker compose up -d
```

**No ROS2 topics on host** — container uses `network_mode: host`; ensure `ROS_DOMAIN_ID` matches.

**v4l2bufferpool "not free" warnings** — non-fatal, safe to ignore.
