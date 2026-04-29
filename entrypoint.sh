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
ROS_WIDTH="${ROS_WIDTH:-1920}"
ROS_HEIGHT="${ROS_HEIGHT:-1080}"
ROS_FRAMERATE="${ROS_FRAMERATE:-60}"
RTSP_WIDTH="${RTSP_WIDTH:-1280}"
RTSP_HEIGHT="${RTSP_HEIGHT:-720}"
RTSP_FRAMERATE="${RTSP_FRAMERATE:-30}"
USE_HW_MJPEG_DECODER="${USE_HW_MJPEG_DECODER:-1}"
ROS2_ENABLED="${ROS2_ENABLED:-1}"
ROS_SHM_SOCKET="${ROS_SHM_SOCKET:-/tmp/ros_frames}"

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
rm -f "$ROS_SHM_SOCKET"

# Require HW H264 encoder (nvv4l2h264enc).
if ! gst-inspect-1.0 nvv4l2h264enc >/dev/null 2>&1; then
    echo "ERROR: nvv4l2h264enc not available — hardware H264 encoder is required."
    exit 1
fi
echo "Using H264 encoder: nvv4l2h264enc (hardware)"

# --- SW H264 encoding (x264enc) is disabled. Uncomment below and restore the
# --- if/else on USE_HW_H264 if you need software fallback on devices without NVENC
# --- (e.g. Orin Nano 4GB/8GB).

if [ "$USE_HW_MJPEG_DECODER" = "1" ] && command -v gst-inspect-1.0 >/dev/null 2>&1 && gst-inspect-1.0 nvv4l2decoder >/dev/null 2>&1; then
        echo "Using decoder: jpegparse ! nvv4l2decoder mjpeg=1 (hardware)"
        # jpegparse before nvv4l2decoder is required for MJPEG on JetPack 6 (L4T R36+)
        # and is backwards-compatible with JetPack 5.
        gst-launch-1.0 -v \
            v4l2src device="$DEVICE" io-mode=2 do-timestamp=true ! \
                "image/jpeg,width=(int)$WIDTH,height=(int)$HEIGHT,framerate=(fraction)$FRAMERATE/1" ! \
            jpegparse ! \
            nvv4l2decoder mjpeg=1 ! \
                nvvidconv ! \
                "video/x-raw(memory:NVMM),format=(string)NV12,width=(int)$WIDTH,height=(int)$HEIGHT,framerate=(fraction)$FRAMERATE/1" ! \
            tee name=t \
                t. ! queue leaky=downstream max-size-buffers=2 ! \
                    nvvidconv ! \
                    "video/x-raw(memory:NVMM),format=(string)NV12,width=(int)$RTSP_WIDTH,height=(int)$RTSP_HEIGHT" ! \
                    nvv4l2h264enc preset-level=1 control-rate=1 bitrate=2000000 ! \
                    h264parse ! \
                    rtspclientsink location=rtsp://127.0.0.1:8554/camera protocols=tcp \
                t. ! queue leaky=downstream max-size-buffers=1 ! \
                    nvvidconv ! \
                    "video/x-raw,format=(string)BGRx,width=(int)$ROS_WIDTH,height=(int)$ROS_HEIGHT" ! \
                    videoconvert ! \
                    "video/x-raw,format=(string)RGB,width=(int)$ROS_WIDTH,height=(int)$ROS_HEIGHT" ! \
                    shmsink socket-path="$ROS_SHM_SOCKET" \
                        shm-size=67108864 wait-for-connection=false sync=false async=false &

        # --- [COMMENTED OUT] SW H264 encode with HW MJPEG decode:
        # gst-launch-1.0 -v \
        #     v4l2src device="$DEVICE" io-mode=2 do-timestamp=true ! \
        #         "image/jpeg,width=(int)$WIDTH,height=(int)$HEIGHT,framerate=(fraction)$FRAMERATE/1" ! \
        #     jpegparse ! \
        #     nvv4l2decoder mjpeg=1 ! \
        #         nvvidconv ! \
        #         "video/x-raw(memory:NVMM),format=(string)NV12,width=(int)$WIDTH,height=(int)$HEIGHT,framerate=(fraction)$FRAMERATE/1" ! \
        #     tee name=t \
        #         t. ! queue leaky=downstream max-size-buffers=2 ! \
        #             nvvidconv ! \
        #             "video/x-raw,format=(string)I420,width=(int)$RTSP_WIDTH,height=(int)$RTSP_HEIGHT,framerate=(fraction)$RTSP_FRAMERATE/1" ! \
        #             videoconvert ! \
        #             x264enc tune=zerolatency bitrate=2000 speed-preset=ultrafast ! \
        #             h264parse ! \
        #             rtspclientsink location=rtsp://127.0.0.1:8554/camera protocols=tcp \
        #         t. ! queue leaky=downstream max-size-buffers=1 ! \
        #             nvvidconv ! \
        #             "video/x-raw,format=(string)I420,width=(int)$ROS_WIDTH,height=(int)$ROS_HEIGHT,framerate=(fraction)$ROS_FRAMERATE/1" ! \
        #             videoconvert ! \
        #             "video/x-raw,format=(string)RGB,width=(int)$ROS_WIDTH,height=(int)$ROS_HEIGHT,framerate=(fraction)$ROS_FRAMERATE/1" ! \
        #             shmsink socket-path="$ROS_SHM_SOCKET" \
        #                 shm-size=67108864 wait-for-connection=false sync=false async=false &
else
        if [ "$USE_HW_MJPEG_DECODER" = "1" ]; then
                echo "nvv4l2decoder not available, falling back to jpegdec"
        fi
        echo "Using decoder: jpegdec (software)"
        gst-launch-1.0 -v \
            v4l2src device="$DEVICE" io-mode=2 do-timestamp=true ! \
                "image/jpeg,width=(int)$WIDTH,height=(int)$HEIGHT,framerate=(fraction)$FRAMERATE/1" ! \
            jpegdec ! \
                "video/x-raw,format=(string)I420,width=(int)$WIDTH,height=(int)$HEIGHT,framerate=(fraction)$FRAMERATE/1" ! \
            tee name=t \
                t. ! queue leaky=downstream max-size-buffers=2 ! \
                    nvvidconv ! \
                    "video/x-raw(memory:NVMM),format=(string)NV12,width=(int)$RTSP_WIDTH,height=(int)$RTSP_HEIGHT" ! \
                    nvv4l2h264enc preset-level=1 control-rate=1 bitrate=2000000 ! \
                    h264parse ! \
                    rtspclientsink location=rtsp://127.0.0.1:8554/camera protocols=tcp \
                t. ! queue leaky=downstream max-size-buffers=1 ! \
                    nvvidconv ! \
                    "video/x-raw,format=(string)BGRx,width=(int)$ROS_WIDTH,height=(int)$ROS_HEIGHT" ! \
                    videoconvert ! \
                    "video/x-raw,format=(string)RGB,width=(int)$ROS_WIDTH,height=(int)$ROS_HEIGHT" ! \
                    shmsink socket-path="$ROS_SHM_SOCKET" \
                        shm-size=67108864 wait-for-connection=false sync=false async=false &

        # --- [COMMENTED OUT] SW H264 encode with SW MJPEG decode:
        # gst-launch-1.0 -v \
        #     v4l2src device="$DEVICE" io-mode=2 do-timestamp=true ! \
        #         "image/jpeg,width=(int)$WIDTH,height=(int)$HEIGHT,framerate=(fraction)$FRAMERATE/1" ! \
        #     jpegdec ! \
        #         "video/x-raw,format=(string)I420,width=(int)$WIDTH,height=(int)$HEIGHT,framerate=(fraction)$FRAMERATE/1" ! \
        #     tee name=t \
        #         t. ! queue leaky=downstream max-size-buffers=2 ! \
        #             videoscale ! \
        #             "video/x-raw,format=(string)I420,width=(int)$RTSP_WIDTH,height=(int)$RTSP_HEIGHT,framerate=(fraction)$RTSP_FRAMERATE/1" ! \
        #             videoconvert ! \
        #             x264enc tune=zerolatency bitrate=2000 speed-preset=ultrafast ! \
        #             h264parse ! \
        #             rtspclientsink location=rtsp://127.0.0.1:8554/camera protocols=tcp \
        #         t. ! queue leaky=downstream max-size-buffers=1 ! \
        #             videoconvert ! \
        #             "video/x-raw,format=(string)RGB,width=(int)$ROS_WIDTH,height=(int)$ROS_HEIGHT,framerate=(fraction)$ROS_FRAMERATE/1" ! \
        #             shmsink socket-path="$ROS_SHM_SOCKET" \
        #                 shm-size=67108864 wait-for-connection=false sync=false async=false &
fi

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
echo "Starting ROS2 image publisher..."
# Ensure CAMERA_INFO_FILE exists inside container; copy packaged file if missing
if [ ! -f "$CAMERA_INFO_FILE" ]; then
    PUBLISHER_PATH="/usr/local/bin/camera_publisher"
    PUBLISHER_DIR="$(dirname "$(readlink -f "$PUBLISHER_PATH" 2>/dev/null || echo $PUBLISHER_PATH)")"
    CANDIDATES=("$PUBLISHER_DIR/camera_info.yaml" "/usr/local/share/ros2_rtsp_cam/camera_info.yaml" "/app/camera_info.yaml")
    for c in "${CANDIDATES[@]}"; do
        if [ -f "$c" ]; then
            echo "No $CAMERA_INFO_FILE found — copying packaged camera_info from $c"
            mkdir -p "$(dirname "$CAMERA_INFO_FILE")"
            cp "$c" "$CAMERA_INFO_FILE"
            break
        fi
    done
fi
# Reads from SHM tee branch (or RTSP fallback), publishes /camera/image_raw and /camera/camera_info
/usr/local/bin/camera_publisher --ros-args \
    -p shm_socket:="$ROS_SHM_SOCKET" \
    -p width:="$ROS_WIDTH" \
    -p height:="$ROS_HEIGHT" \
    -p framerate:="$ROS_FRAMERATE" \
    -p camera_info_file:="$CAMERA_INFO_FILE" \
    -p publish_rate:="${ROS_FRAMERATE}.0" &

ROS_PID=$!

# Wait for one of the main processes to fail
# Use || true so set -e doesn't abort before the cleanup kill
wait -n $MTX_PID $GST_PID $ROS_PID || true

# Kill remaining processes
kill $MTX_PID $GST_PID $ROS_PID 2>/dev/null || true
