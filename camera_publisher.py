#!/usr/bin/env python3
"""
Simple ROS2 node that consumes RTSP stream and publishes as ROS2 Image topics.
Avoids GStreamer threading issues by using separate process + OpenCV + RTSP.
"""

import cv2
import rclpy
from rclpy.node import Node
from sensor_msgs.msg import Image, CameraInfo
from cv_bridge import CvBridge
import yaml
import time

class RTSPCameraPublisher(Node):
    def __init__(self):
        super().__init__('rtsp_camera_publisher')
        
        # Parameters from environment or defaults
        self.declare_parameter('rtsp_url', 'rtsp://127.0.0.1:8554/camera')
        self.declare_parameter('camera_info_file', '/etc/camera_info.yaml')
        self.declare_parameter('frame_id', 'camera_optical_frame')
        self.declare_parameter('publish_rate', 30.0)
        
        self.rtsp_url = self.get_parameter('rtsp_url').value
        self.camera_info_file = self.get_parameter('camera_info_file').value
        self.frame_id = self.get_parameter('frame_id').value
        publish_rate = self.get_parameter('publish_rate').value
        
        # Create publishers
        self.image_pub = self.create_publisher(Image, '/camera/image_raw', 10)
        self.camera_info_pub = self.create_publisher(CameraInfo, '/camera/camera_info', 10)
        
        self.get_logger().info(f"Connecting to RTSP: {self.rtsp_url}")
        
        # OpenCV video capture - use FFmpeg backend for better RTSP support
        self.cap = cv2.VideoCapture(self.rtsp_url, cv2.CAP_FFMPEG)
        self.cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)  # Minimal buffer for low latency
        
        # Wait for first frame to ensure connection
        # Give up to 30s (30 attempts x 1s) for the GStreamer pipeline to be fully ready
        self.connected = False
        for attempt in range(30):
            ret, frame = self.cap.read()
            if ret:
                self.connected = True
                self.get_logger().info("Connected to RTSP stream")
                break
            self.get_logger().warn(f"Waiting for RTSP connection (attempt {attempt+1}/30)...")
            time.sleep(1.0)
        
        if not self.connected:
            self.get_logger().error("Failed to connect to RTSP stream after 10 attempts")
            raise RuntimeError("RTSP connection failed")
        
        self.bridge = CvBridge()
        
        # Load camera calibration
        self.camera_info = self.load_camera_info()
        
        # Publish at specified rate (default 30 Hz)
        self.create_timer(1.0/publish_rate, self.publish_frame)
        
        self.frame_count = 0
        self.get_logger().info(f"RTSP Camera Publisher started at {publish_rate} Hz")

    def load_camera_info(self):
        """Load camera calibration from YAML file"""
        try:
            with open(self.camera_info_file, 'r') as f:
                config = yaml.safe_load(f)
            
            info = CameraInfo()
            info.header.frame_id = self.frame_id
            info.height = config.get('image_height', 1080)
            info.width = config.get('image_width', 1920)
            info.distortion_model = 'plumb_bob'
            
            # Camera matrix K (3x3)
            if 'camera_matrix' in config:
                info.k = config['camera_matrix'].get('data', 
                    [1000, 0, 960, 0, 1000, 540, 0, 0, 1])
            
            # Distortion coefficients D (1x5)
            if 'distortion_coefficients' in config:
                info.d = config['distortion_coefficients'].get('data', 
                    [0, 0, 0, 0, 0])
            
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
            self.get_logger().warn("Failed to read frame from RTSP")
            return
        
        # Convert BGR to RGB (ROS convention)
        frame = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        
        # Convert to ROS Image message
        msg = self.bridge.cv2_to_imgmsg(frame, encoding='rgb8')
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
