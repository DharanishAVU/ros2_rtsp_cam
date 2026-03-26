#!/usr/bin/env python3
"""
ROS2 node that consumes camera frames and publishes ROS2 Image topics.
Prefers local GStreamer shared-memory frames (from entrypoint tee branch) to
avoid RTSP H264 re-decode in Python, with RTSP fallback for compatibility.
"""

import cv2
import rclpy
from rclpy.node import Node
from sensor_msgs.msg import Image, CameraInfo
from cv_bridge import CvBridge
import yaml
import os
import time

class RTSPCameraPublisher(Node):
    def __init__(self):
        super().__init__('rtsp_camera_publisher')
        
        # Parameters from environment or defaults
        self.declare_parameter('rtsp_url', 'rtsp://127.0.0.1:8554/camera')
        self.declare_parameter('shm_socket', '/tmp/ros_frames')
        default_camera_info = os.path.join(os.path.dirname(__file__), 'camera_info.yaml')
        self.declare_parameter('camera_info_file', default_camera_info)
        self.declare_parameter('frame_id', 'camera_optical_frame')
        self.declare_parameter('publish_rate', 30.0)
        self.declare_parameter('width', 1920)
        self.declare_parameter('height', 1080)
        self.declare_parameter('framerate', 60)
        
        self.rtsp_url = self.get_parameter('rtsp_url').value
        self.shm_socket = self.get_parameter('shm_socket').value
        self.camera_info_file = self.get_parameter('camera_info_file').value
        self.frame_id = self.get_parameter('frame_id').value
        publish_rate = self.get_parameter('publish_rate').value
        width = int(self.get_parameter('width').value)
        height = int(self.get_parameter('height').value)
        framerate = int(self.get_parameter('framerate').value)
        
        # Create publishers
        self.image_pub = self.create_publisher(Image, '/camera/image_raw', 1)
        self.camera_info_pub = self.create_publisher(CameraInfo, '/camera/camera_info', 1)
        
        # Primary path: shared memory frames produced by tee branch in entrypoint.sh.
        # This avoids CPU-heavy H264 decode in Python and keeps ROS publishing low-latency.
        shm_pipeline = (
            f"shmsrc socket-path={self.shm_socket} is-live=true do-timestamp=true "
            f"! video/x-raw,format=RGB,width={width},height={height},framerate={framerate}/1 "
            "! videoconvert "
            "! video/x-raw,format=BGR "
            "! queue leaky=downstream max-size-buffers=1 "
            "! appsink drop=1 max-buffers=1 sync=false"
        )

        self.get_logger().info(f"Connecting to shared-memory stream: {self.shm_socket}")
        self.cap = cv2.VideoCapture(shm_pipeline, cv2.CAP_GSTREAMER)
        self.frame_is_bgr = True
        
        # Wait for first frame to ensure connection.
        # If SHM path is not available, fall back to RTSP for compatibility.
        self.connected = False
        for attempt in range(30):
            ret, frame = self.cap.read()
            if ret:
                self.connected = True
                self.get_logger().info("Connected to shared-memory stream")
                break
            self.get_logger().warn(f"Waiting for shared-memory stream (attempt {attempt+1}/30)...")
            time.sleep(1.0)

        if not self.connected:
            self.get_logger().warn("Shared-memory stream unavailable, falling back to RTSP")
            self.cap.release()
            self.cap = cv2.VideoCapture(self.rtsp_url, cv2.CAP_FFMPEG)
            self.cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)
            self.frame_is_bgr = True

            for attempt in range(30):
                ret, frame = self.cap.read()
                if ret:
                    self.connected = True
                    self.get_logger().info("Connected to RTSP fallback stream")
                    break
                self.get_logger().warn(f"Waiting for RTSP fallback (attempt {attempt+1}/30)...")
                time.sleep(1.0)
        
        if not self.connected:
            self.get_logger().error("Failed to connect to both SHM and RTSP streams")
            raise RuntimeError("Camera stream connection failed")
        
        self.bridge = CvBridge()
        
        # Load camera calibration
        self.get_logger().info(f"Using camera_info_file: {self.camera_info_file}")
        self.camera_info = self.load_camera_info()
        self.camera_info.width = width
        self.camera_info.height = height
        
        # Publish at specified rate (default 30 Hz)
        self.create_timer(1.0/publish_rate, self.publish_frame)
        
        self.frame_count = 0
        self.read_fail_count = 0
        self.get_logger().info(f"RTSP Camera Publisher started at {publish_rate} Hz")

    def load_camera_info(self):
        """Load camera calibration from YAML file"""
        try:
            exists = os.path.exists(self.camera_info_file)
            self.get_logger().info(f"Loading camera_info from {self.camera_info_file} (exists={exists})")
            if not exists:
                raise FileNotFoundError(f"Camera info file not found: {self.camera_info_file}")

            with open(self.camera_info_file, 'r') as f:
                config = yaml.safe_load(f) or {}

            # If provided file lacks calibration data, try packaged camera_info.yaml as fallback
            cam_mat = config.get('camera_matrix', {}) or {}
            dist = config.get('distortion_coefficients', {}) or {}
            needs_fallback = not cam_mat.get('data') or not dist.get('data')
            if needs_fallback:
                packaged = os.path.join(os.path.dirname(__file__), 'camera_info.yaml')
                if os.path.exists(packaged):
                    try:
                        with open(packaged, 'r') as pf:
                            pconf = yaml.safe_load(pf) or {}
                        # merge missing keys
                        if not cam_mat.get('data') and pconf.get('camera_matrix'):
                            config['camera_matrix'] = pconf['camera_matrix']
                        if not dist.get('data') and pconf.get('distortion_coefficients'):
                            config['distortion_coefficients'] = pconf['distortion_coefficients']
                        self.get_logger().info(f"Merged missing K/D from packaged camera_info: {packaged}")
                    except Exception:
                        self.get_logger().warn(f"Failed to read packaged camera_info.yaml at {packaged}")

            info = CameraInfo()
            info.header.frame_id = self.frame_id
            info.height = config.get('image_height', 1080)
            info.width = config.get('image_width', 1920)
            info.distortion_model = config.get('distortion_model', 'plumb_bob')

            # Camera matrix K (3x3)
            cam_mat = config.get('camera_matrix', {}) or {}
            info.k = cam_mat.get('data', [1000, 0, 960, 0, 1000, 540, 0, 0, 1])

            # Distortion coefficients D (1x5)
            dist = config.get('distortion_coefficients', {}) or {}
            info.d = dist.get('data', [0, 0, 0, 0, 0])

            self.get_logger().info(f"Loaded camera calibration: {info.width}x{info.height}")
            return info
        except Exception as e:
            self.get_logger().warn(f"Failed to load camera_info from {self.camera_info_file}: {e}")

            # Return default calibration
            info = CameraInfo()
            info.header.frame_id = self.frame_id
            info.height = 1080
            info.width = 1920
            info.distortion_model = 'plumb_bob'
            info.k = [1000, 0, 960, 0, 1000, 540, 0, 0, 1]
            info.d = [0, 0, 0, 0, 0]

            self.get_logger().info("Using default camera calibration")
            return info

    def publish_frame(self):
        """Capture frame from RTSP and publish as ROS2 Image"""
        ret, frame = self.cap.read()
        
        if not ret:
            self.read_fail_count += 1
            if self.read_fail_count % 60 == 0:
                src = "RTSP fallback" if self.frame_is_bgr else "SHM"
                self.get_logger().warn(f"Failed to read frame from {src} ({self.read_fail_count} consecutive fails)")
            return

        self.read_fail_count = 0
        
        msg = self.bridge.cv2_to_imgmsg(frame, encoding='bgr8')
        msg.header.stamp = self.get_clock().now().to_msg()
        msg.header.frame_id = self.frame_id
        
        # Update camera info timestamp to match image
        self.camera_info.header.stamp = msg.header.stamp
        
        # Publish both messages
        self.image_pub.publish(msg)
        self.camera_info_pub.publish(self.camera_info)
        
        self.frame_count += 1
        if self.frame_count % 30 == 0:
            self.get_logger().debug(f"Published {self.frame_count} frames")

    def destroy_node(self):
        """Cleanup resources"""
        if self.cap and self.cap.isOpened():
            self.cap.release()
        super().destroy_node()


def main(args=None):
    rclpy.init(args=args)
    node = RTSPCameraPublisher()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
