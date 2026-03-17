#!/bin/bash
set -e

# Source ROS2
source /opt/ros/humble/setup.bash

DEVICE="${DEVICE:-/dev/video-front}"
FRAME_ID="${FRAME_ID:-camera_optical_frame}"
CAMERA_NAME="${CAMERA_NAME:-camera}"
CAMERA_INFO_FILE="${CAMERA_INFO_FILE:-/etc/camera_info.yaml}"
WIDTH="${WIDTH:-1920}"
HEIGHT="${HEIGHT:-1080}"
FRAMERATE="${FRAMERATE:-60}"
ROS2_ENABLED="${ROS2_ENABLED:-1}"

echo "Starting MediaMTX RTSP server..."
mediamtx /etc/mediamtx/mediamtx.yml &
MTX_PID=$!

echo "Waiting for MediaMTX to be ready..."
for i in $(seq 1 30); do
    if ! kill -0 $MTX_PID 2>/dev/null; then
        echo "ERROR: MediaMTX process died! Check configuration."
        exit 1
    fi
    
    if nc -z 127.0.0.1 8554 2>/dev/null; then
        echo "MediaMTX is ready."
        break
    fi
    echo "  attempt $i/30..."
    sleep 1
    
    if [ $i -eq 30 ]; then
        echo "ERROR: MediaMTX failed to start after 30 seconds"
        exit 1
    fi
done

echo "Starting GStreamer RTSP pipeline..."
gst-launch-1.0 -v \
  v4l2src device="$DEVICE" io-mode=2 do-timestamp=true ! \
  'image/jpeg,width=(int)1920,height=(int)1080,framerate=(fraction)60/1' ! \
  jpegdec ! \
  nvvidconv ! \
  'video/x-raw(memory:NVMM),format=(string)NV12' ! \
  nvv4l2h264enc preset-level=1 control-rate=1 bitrate=2000000 ! \
  h264parse ! \
  rtspclientsink location=rtsp://127.0.0.1:8554/camera protocols=tcp &

GST_PID=$!
sleep 3

if [ "$ROS2_ENABLED" = "0" ]; then
    echo "Mode: RTSP-only (no ROS2)"
    # Just wait for processes to finish
    wait -n $MTX_PID $GST_PID
    kill $MTX_PID $GST_PID 2>/dev/null || true
    exit 0
fi

echo "Mode: RTSP + ROS2 image publishing"
echo "Starting ROS2 RTSP consumer..."
# Reads from RTSP stream, publishes to /camera/image_raw and /camera/camera_info
/usr/local/bin/camera_publisher.py &

ROS_PID=$!

# Wait for one of the main processes to fail
wait -n $MTX_PID $GST_PID $ROS_PID

# Kill remaining processes
kill $MTX_PID $GST_PID $ROS_PID 2>/dev/null || true
