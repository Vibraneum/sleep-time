cmake_minimum_required(VERSION 3.14)
project(watchdog LANGUAGES CXX)

set(WATCHDOG_BINARY_NAME "sleep_time_watchdog")

# A tiny no-window Win32 exe (WIN32 = no console). NO Flutter dependency.
add_executable(${WATCHDOG_BINARY_NAME} WIN32
  "watchdog_main.cpp"
)

# Same warning-clean settings as the runner (/W4 /WX with 4100 suppressed).
apply_standard_settings(${WATCHDOG_BINARY_NAME})

# Unicode entry point + standard defs to match the rest of the project.
target_compile_definitions(${WATCHDOG_BINARY_NAME} PRIVATE "NOMINMAX")

# Reuse the shared, dependency-free lock-state reader from the runner.
target_include_directories(${WATCHDOG_BINARY_NAME} PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/../runner")

# shell32 for SHGetFolderPathW used by sleep_lock_state.h.
target_link_libraries(${WATCHDOG_BINARY_NAME} PRIVATE "shell32.lib")

# Install next to the runner exe so they sit side-by-side in the bundle.
install(TARGETS ${WATCHDOG_BINARY_NAME} RUNTIME
  DESTINATION "${CMAKE_INSTALL_PREFIX}" COMPONENT Runtime)
