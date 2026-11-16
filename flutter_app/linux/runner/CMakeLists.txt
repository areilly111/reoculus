cmake_minimum_required(VERSION 3.13)
# C is enabled as well as CXX: the H.264 decoder plugin
# (h264_decoder_plugin.c) is plain C.
project(runner LANGUAGES C CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME}
  "main.cc"
  "my_application.cc"
  "h264_decoder_plugin.c"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the application ID.
add_definitions(-DAPPLICATION_ID="${APPLICATION_ID}")

# Add dependency libraries. Add any application-specific dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::GTK)

# The H.264 decoder plugin (linux/runner/h264_decoder_plugin.c)
# loads the system ffmpeg libraries at runtime with dlopen (see
# the comment at the top of that file), so nothing is linked here.
# Linking ffmpeg statically drags in the whole codec registry, and
# bundling the shared libraries means shipping ffmpeg's whole
# dependency closure. The plugin only needs the headers to build,
# which the ffmpeg -dev packages provide on the build machine.

target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")
