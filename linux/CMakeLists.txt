cmake_minimum_required(VERSION 3.18)
set(PROJECT_NAME "qvac_flutter")
project(${PROJECT_NAME} LANGUAGES CXX)

include("${CMAKE_CURRENT_SOURCE_DIR}/../cmake/qvac_binaries.cmake")

# Flutter passes the target, which differs from the host on cross builds.
if(FLUTTER_TARGET_PLATFORM)
  set(QVAC_TARGET "${FLUTTER_TARGET_PLATFORM}")
elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "^(aarch64|arm64)$")
  set(QVAC_TARGET "linux-arm64")
else()
  set(QVAC_TARGET "linux-x64")
endif()
qvac_binaries(${QVAC_TARGET} QVAC_DIR)

# BareKit, the addons and the worker bundle all go into the bundle's lib/ folder,
# where the Dart side loads them from.
file(GLOB QVAC_LIBRARIES "${QVAC_DIR}/*.so")
set(qvac_flutter_bundled_libraries ${QVAC_LIBRARIES} "${QVAC_DIR}/worker.bundle" PARENT_SCOPE)
# Relative, so it lands under the bundle, which Flutter sets as the prefix later.
install(DIRECTORY "${QVAC_DIR}/backends/" DESTINATION "lib/qvac_backends" COMPONENT Runtime)
