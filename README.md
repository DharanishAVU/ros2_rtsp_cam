# Camera RTSP + ROS2 Publisher

Streams a USB camera as RTSP and publishes ROS2 image topics simultaneously.

- **RTSP**: `rtsp://localhost:8554/camera` (H.264, always active)
- **ROS2**: `/camera/image_raw` + `/camera/camera_info` (`sensor_msgs/Image`)
- **Camera**: 1920×1080 @ 30fps MJPEG source

## Quick Start

```bash
docker compose build
docker compose up -d
```

## ROS2 Topics

```bash
ros2 topic list
ros2 topic hz /camera/image_raw
ros2 topic echo /camera/camera_info
```

## RTSP Stream

```bash
ffplay -rtsp_transport tcp rtsp://localhost:8554/camera
```

## Configuration

All parameters are set in `docker-compose.yml` under `environment`:

```yaml
environment:
  - DEVICE=/dev/video4   # camera device path
  - WIDTH=1920           # capture width
  - HEIGHT=1080          # capture height
  - FRAMERATE=30         # frames per second
  - ROS2_ENABLED=1       # 1 = RTSP + ROS2,  0 = RTSP only
  - ROS_DOMAIN_ID=0      # match your ROS2 network domain
```

### Change camera device

Update both `devices` and `DEVICE`:

```yaml
devices:
  - /dev/video0:/dev/video0
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
