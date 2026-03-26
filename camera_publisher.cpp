#include <chrono>
#include <string>
#include <thread>

#include <rclcpp/rclcpp.hpp>
#include <sensor_msgs/msg/image.hpp>
#include <sensor_msgs/msg/camera_info.hpp>
#include <camera_info_manager/camera_info_manager.hpp>

#include <gst/gst.h>
#include <gst/app/gstappsink.h>

using namespace std::chrono_literals;

class CameraPublisherNode : public rclcpp::Node
{
public:
  CameraPublisherNode() : Node("rtsp_camera_publisher")
  {
    // Declare parameters
    declare_parameter<std::string>("shm_socket", "/tmp/ros_frames");
    declare_parameter<std::string>("rtsp_url", "rtsp://127.0.0.1:8554/camera");
    declare_parameter<std::string>("camera_info_file", "/etc/camera_info.yaml");
    declare_parameter<std::string>("frame_id", "camera_optical_frame");
    declare_parameter<double>("publish_rate", 30.0);
    declare_parameter<int>("width", 1920);
    declare_parameter<int>("height", 1080);
    declare_parameter<int>("framerate", 30);

    auto shm_socket = get_parameter("shm_socket").as_string();
    rtsp_url_ = get_parameter("rtsp_url").as_string();
    auto camera_info_file = get_parameter("camera_info_file").as_string();
    frame_id_ = get_parameter("frame_id").as_string();
    auto publish_rate = get_parameter("publish_rate").as_double();
    width_ = get_parameter("width").as_int();
    height_ = get_parameter("height").as_int();
    auto framerate = get_parameter("framerate").as_int();

    frame_size_ = width_ * height_ * 3;  // RGB, 3 bytes per pixel

    // Create publishers
    image_pub_ = create_publisher<sensor_msgs::msg::Image>("/camera/image_raw", 1);
    camera_info_pub_ = create_publisher<sensor_msgs::msg::CameraInfo>("/camera/camera_info", 1);

    // Initialize GStreamer
    gst_init(nullptr, nullptr);

    // Try SHM connection first (direct RGB — no videoconvert needed)
    std::string shm_pipeline =
      "shmsrc socket-path=" + shm_socket + " is-live=true do-timestamp=true "
      "! video/x-raw,format=RGB,width=" + std::to_string(width_) +
      ",height=" + std::to_string(height_) +
      ",framerate=" + std::to_string(framerate) + "/1 "
      "! queue leaky=downstream max-size-buffers=1 "
      "! appsink name=sink drop=true max-buffers=1 sync=false emit-signals=false";

    RCLCPP_INFO(get_logger(), "Connecting to shared-memory stream: %s", shm_socket.c_str());

    bool connected = false;
    pipeline_ = gst_parse_launch(shm_pipeline.c_str(), nullptr);
    if (pipeline_) {
      appsink_ = gst_bin_get_by_name(GST_BIN(pipeline_), "sink");
      gst_element_set_state(pipeline_, GST_STATE_PLAYING);

      for (int attempt = 0; attempt < 30; ++attempt) {
        if (try_pull_frame()) {
          connected = true;
          encoding_ = "rgb8";
          RCLCPP_INFO(get_logger(), "Connected to shared-memory stream (rgb8, no videoconvert)");
          break;
        }
        RCLCPP_WARN(get_logger(), "Waiting for shared-memory stream (attempt %d/30)...", attempt + 1);
        std::this_thread::sleep_for(1s);
      }

      if (!connected) {
        cleanup_pipeline();
      }
    }

    // Fallback to RTSP via GStreamer (needs decodebin + videoconvert)
    if (!connected) {
      RCLCPP_WARN(get_logger(), "Shared-memory stream unavailable, falling back to RTSP");

      std::string rtsp_pipeline =
        "rtspsrc location=" + rtsp_url_ + " latency=0 "
        "! rtph264depay ! h264parse ! avdec_h264 "
        "! videoconvert "
        "! video/x-raw,format=RGB "
        "! queue leaky=downstream max-size-buffers=1 "
        "! appsink name=sink drop=true max-buffers=1 sync=false emit-signals=false";

      pipeline_ = gst_parse_launch(rtsp_pipeline.c_str(), nullptr);
      if (pipeline_) {
        appsink_ = gst_bin_get_by_name(GST_BIN(pipeline_), "sink");
        gst_element_set_state(pipeline_, GST_STATE_PLAYING);

        for (int attempt = 0; attempt < 30; ++attempt) {
          if (try_pull_frame()) {
            connected = true;
            encoding_ = "rgb8";
            RCLCPP_INFO(get_logger(), "Connected to RTSP fallback stream");
            break;
          }
          RCLCPP_WARN(get_logger(), "Waiting for RTSP fallback (attempt %d/30)...", attempt + 1);
          std::this_thread::sleep_for(1s);
        }
      }
    }

    if (!connected) {
      RCLCPP_FATAL(get_logger(), "Failed to connect to both SHM and RTSP streams");
      throw std::runtime_error("Camera stream connection failed");
    }

    // Load camera calibration via camera_info_manager
    std::string camera_info_url = "file://" + camera_info_file;
    camera_info_mgr_ = std::make_shared<camera_info_manager::CameraInfoManager>(
      this, "camera", camera_info_url);

    if (!camera_info_mgr_->isCalibrated()) {
      RCLCPP_WARN(get_logger(), "Camera not calibrated, using defaults");
    } else {
      RCLCPP_INFO(get_logger(), "Loaded camera calibration from %s", camera_info_file.c_str());
    }

    camera_info_ = camera_info_mgr_->getCameraInfo();
    camera_info_.width = width_;
    camera_info_.height = height_;
    camera_info_.header.frame_id = frame_id_;

    // Pre-allocate reusable Image message
    img_msg_.encoding = encoding_;
    img_msg_.width = width_;
    img_msg_.height = height_;
    img_msg_.step = width_ * 3;
    img_msg_.is_bigendian = false;
    img_msg_.data.resize(frame_size_);

    // Create publish timer
    auto period = std::chrono::duration<double>(1.0 / publish_rate);
    timer_ = create_wall_timer(
      std::chrono::duration_cast<std::chrono::nanoseconds>(period),
      std::bind(&CameraPublisherNode::publish_frame, this));

    RCLCPP_INFO(get_logger(), "Camera Publisher started at %.1f Hz (%s)", publish_rate, encoding_.c_str());
  }

  ~CameraPublisherNode()
  {
    cleanup_pipeline();
  }

private:
  bool try_pull_frame()
  {
    if (!appsink_) return false;
    GstSample *sample = gst_app_sink_try_pull_sample(GST_APP_SINK(appsink_), GST_SECOND);
    if (sample) {
      gst_sample_unref(sample);
      return true;
    }
    return false;
  }

  void cleanup_pipeline()
  {
    if (appsink_) {
      gst_object_unref(appsink_);
      appsink_ = nullptr;
    }
    if (pipeline_) {
      gst_element_set_state(pipeline_, GST_STATE_NULL);
      gst_object_unref(pipeline_);
      pipeline_ = nullptr;
    }
  }

  void publish_frame()
  {
    GstSample *sample = gst_app_sink_try_pull_sample(GST_APP_SINK(appsink_), 0);
    if (!sample) {
      ++read_fail_count_;
      if (read_fail_count_ % 60 == 0) {
        RCLCPP_WARN(get_logger(), "Failed to read frame (%d consecutive fails)", read_fail_count_);
      }
      return;
    }
    read_fail_count_ = 0;

    GstBuffer *buffer = gst_sample_get_buffer(sample);
    GstMapInfo map;
    if (!gst_buffer_map(buffer, &map, GST_MAP_READ)) {
      gst_sample_unref(sample);
      return;
    }

    // Stamp header
    auto stamp = now();
    img_msg_.header.stamp = stamp;
    img_msg_.header.frame_id = frame_id_;

    // Copy frame data directly into pre-allocated message buffer
    size_t copy_size = std::min(static_cast<size_t>(map.size), static_cast<size_t>(frame_size_));
    std::memcpy(img_msg_.data.data(), map.data, copy_size);

    gst_buffer_unmap(buffer, &map);
    gst_sample_unref(sample);

    // Sync camera_info timestamp
    camera_info_.header.stamp = stamp;

    image_pub_->publish(img_msg_);
    camera_info_pub_->publish(camera_info_);

    ++frame_count_;
    if (frame_count_ % 30 == 0) {
      RCLCPP_DEBUG(get_logger(), "Published %d frames", frame_count_);
    }
  }

  GstElement *pipeline_ = nullptr;
  GstElement *appsink_ = nullptr;
  std::string frame_id_;
  std::string rtsp_url_;
  std::string encoding_;
  int width_ = 0;
  int height_ = 0;
  int frame_size_ = 0;

  sensor_msgs::msg::Image img_msg_;
  sensor_msgs::msg::CameraInfo camera_info_;
  std::shared_ptr<camera_info_manager::CameraInfoManager> camera_info_mgr_;

  rclcpp::Publisher<sensor_msgs::msg::Image>::SharedPtr image_pub_;
  rclcpp::Publisher<sensor_msgs::msg::CameraInfo>::SharedPtr camera_info_pub_;
  rclcpp::TimerBase::SharedPtr timer_;

  int frame_count_ = 0;
  int read_fail_count_ = 0;
};

int main(int argc, char * argv[])
{
  rclcpp::init(argc, argv);
  auto node = std::make_shared<CameraPublisherNode>();
  rclcpp::spin(node);
  rclcpp::shutdown();
  return 0;
}
