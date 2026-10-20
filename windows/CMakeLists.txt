cmake_minimum_required(VERSION 3.18)
set(PROJECT_NAME "qvac_flutter")
project(${PROJECT_NAME} LANGUAGES CXX)

include("${CMAKE_CURRENT_SOURCE_DIR}/../cmake/qvac_binaries.cmake")

if(FLUTTER_TARGET_PLATFORM)
  set(QVAC_TARGET "${FLUTTER_TARGET_PLATFORM}")
else()
  set(QVAC_TARGET "windows-x64")
endif()
qvac_binaries(${QVAC_TARGET} QVAC_DIR)

# BareKit, the addons and the worker bundle all go next to the app's .exe, where
# Windows looks for DLLs first.
file(GLOB QVAC_LIBRARIES "${QVAC_DIR}/*.dll")
set(qvac_flutter_bundled_libraries ${QVAC_LIBRARIES} "${QVAC_DIR}/worker.bundle" PARENT_SCOPE)
