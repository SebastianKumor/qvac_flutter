cmake_minimum_required(VERSION 3.18)
set(PROJECT_NAME "qvac_flutter")
project(${PROJECT_NAME} LANGUAGES CXX)

include("${CMAKE_CURRENT_SOURCE_DIR}/../cmake/qvac_binaries.cmake")

if(CMAKE_SYSTEM_PROCESSOR MATCHES "^(aarch64|arm64)$")
  qvac_binaries(linux-arm64 QVAC_DIR)
else()
  qvac_binaries(linux-x64 QVAC_DIR)
endif()

# BareKit, the addons and the worker bundle all go into the bundle's lib/ folder.
# BareKit loads the addons from its own folder.
file(GLOB QVAC_LIBRARIES "${QVAC_DIR}/*.so")
set(qvac_flutter_bundled_libraries ${QVAC_LIBRARIES} "${QVAC_DIR}/worker.bundle" PARENT_SCOPE)
