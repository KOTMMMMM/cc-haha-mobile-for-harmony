cmake_minimum_required(VERSION 3.5.0)
project(tailscale_ohos_bridge)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

include_directories(${NATIVERENDER_ROOT_PATH})
include_directories(${NATIVERENDER_ROOT_PATH}/include)

add_library(tailscale_go SHARED IMPORTED)
set_target_properties(tailscale_go PROPERTIES
    IMPORTED_LOCATION ${NATIVERENDER_ROOT_PATH}/../../../libs/${OHOS_ARCH}/libtailscale_go.so)

add_library(tailscale_ohos_bridge SHARED napi_init.cpp)

target_link_libraries(tailscale_ohos_bridge PUBLIC
    tailscale_go
    libace_napi.z.so
    libhilog_ndk.z.so)
