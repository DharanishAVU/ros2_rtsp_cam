cmake_minimum_required(VERSION 3.16)
project(camera_publisher)

find_package(ament_cmake REQUIRED)
find_package(rclcpp REQUIRED)
find_package(sensor_msgs REQUIRED)
find_package(std_msgs REQUIRED)
find_package(camera_info_manager REQUIRED)
find_package(PkgConfig REQUIRED)

pkg_check_modules(GST REQUIRED gstreamer-1.0 gstreamer-app-1.0)

add_executable(camera_publisher camera_publisher.cpp)
ament_target_dependencies(camera_publisher
  rclcpp
  sensor_msgs
  std_msgs
  camera_info_manager
)

target_include_directories(camera_publisher PRIVATE ${GST_INCLUDE_DIRS})
target_link_libraries(camera_publisher ${GST_LIBRARIES})

install(TARGETS camera_publisher DESTINATION bin)
