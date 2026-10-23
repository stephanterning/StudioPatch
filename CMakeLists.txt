cmake_minimum_required(VERSION 3.20)
project(StudioPatch LANGUAGES CXX OBJCXX)
set(CMAKE_CXX_STANDARD 17)
add_compile_options(-fblocks)
set(CMAKE_OSX_DEPLOYMENT_TARGET 14.0)
file(GLOB ASPL_SOURCES CONFIGURE_DEPENDS Vendor/libASPL/src/*.cpp)
add_library(aspl STATIC ${ASPL_SOURCES})
target_include_directories(aspl PUBLIC Vendor/libASPL/include)
target_compile_options(aspl PRIVATE -Wno-deprecated-declarations)
target_compile_options(aspl PUBLIC -Wno-reorder-init-list)
target_link_libraries(aspl PUBLIC "-framework CoreFoundation" "-framework CoreAudio")
add_library(StudioPatchDriver MODULE Sources/Driver.cpp)
add_executable(StudioPatchBroker Sources/TransportBroker.cpp)
target_link_libraries(StudioPatchDriver PRIVATE aspl)
set_target_properties(StudioPatchDriver PROPERTIES PREFIX "" OUTPUT_NAME StudioPatch SUFFIX "")
add_executable(core-tests Tests/CoreTests.cpp)
target_link_libraries(core-tests PRIVATE aspl)
target_compile_options(core-tests PRIVATE -UNDEBUG)
enable_testing()
add_test(NAME core-tests COMMAND core-tests)
set_tests_properties(core-tests PROPERTIES TIMEOUT 20)
add_library(patchbridge STATIC Sources/Bridge.mm)
target_compile_options(patchbridge PRIVATE -fobjc-arc)
target_link_libraries(patchbridge PUBLIC "-framework Foundation" "-framework CoreAudio")
add_executable(patch-inspect Sources/Inspect.cpp)
target_link_libraries(patch-inspect PRIVATE patchbridge)
add_executable(route-tests Tests/RouteTests.mm)
target_compile_options(route-tests PRIVATE -fobjc-arc -UNDEBUG)
target_link_libraries(route-tests PRIVATE "-framework Foundation" "-framework CoreAudio")
add_test(NAME route-tests COMMAND route-tests)
add_executable(direct-tests Tests/DirectTests.mm)
target_compile_options(direct-tests PRIVATE -fobjc-arc -UNDEBUG)
target_link_libraries(direct-tests PRIVATE "-framework Foundation" "-framework CoreAudio")
add_test(NAME direct-tests COMMAND direct-tests)
add_executable(rate-tests Tests/RateTests.cpp)
target_compile_options(rate-tests PRIVATE -UNDEBUG)
add_test(NAME rate-tests COMMAND rate-tests)

find_program(XCRUN_EXECUTABLE xcrun REQUIRED)
add_custom_command(OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/preset-tests"
    COMMAND "${XCRUN_EXECUTABLE}" swiftc -parse-as-library -swift-version 5
        -module-cache-path "${CMAKE_CURRENT_BINARY_DIR}/swift-cache"
        "${CMAKE_CURRENT_SOURCE_DIR}/Sources/Preset.swift"
        "${CMAKE_CURRENT_SOURCE_DIR}/Tests/PresetTests.swift"
        -o "${CMAKE_CURRENT_BINARY_DIR}/preset-tests"
    DEPENDS Sources/Preset.swift Tests/PresetTests.swift VERBATIM)
add_custom_target(preset-tests-build ALL DEPENDS "${CMAKE_CURRENT_BINARY_DIR}/preset-tests")
add_test(NAME preset-tests COMMAND "${CMAKE_CURRENT_BINARY_DIR}/preset-tests")

add_custom_command(OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/session-tests"
    COMMAND "${XCRUN_EXECUTABLE}" swiftc -parse-as-library -swift-version 5
        -D STUDIOPATCH_MODEL_TESTS
        -module-cache-path "${CMAKE_CURRENT_BINARY_DIR}/swift-cache"
        -import-objc-header "${CMAKE_CURRENT_SOURCE_DIR}/Sources/Bridge.h"
        "${CMAKE_CURRENT_SOURCE_DIR}/Sources/Preset.swift"
        "${CMAKE_CURRENT_SOURCE_DIR}/Sources/SessionStore.swift"
        "${CMAKE_CURRENT_SOURCE_DIR}/Sources/Matrix.swift"
        "${CMAKE_CURRENT_SOURCE_DIR}/Sources/RuntimeConnection.swift"
        "${CMAKE_CURRENT_SOURCE_DIR}/Sources/RuntimeTypes.swift"
        "${CMAKE_CURRENT_SOURCE_DIR}/Sources/RuntimeController.swift"
        "${CMAKE_CURRENT_SOURCE_DIR}/Sources/App.swift"
        "${CMAKE_CURRENT_SOURCE_DIR}/Tests/SessionTests.swift"
        "$<TARGET_FILE:patchbridge>"
        -framework UserNotifications -framework SwiftUI -framework AppKit -framework Foundation -framework CoreAudio -lc++
        -o "${CMAKE_CURRENT_BINARY_DIR}/session-tests"
    DEPENDS Sources/Preset.swift Sources/SessionStore.swift Sources/Matrix.swift Sources/RuntimeConnection.swift Sources/RuntimeTypes.swift Sources/RuntimeController.swift Sources/App.swift Sources/Bridge.h Tests/SessionTests.swift patchbridge VERBATIM)
add_custom_target(session-tests-build ALL DEPENDS "${CMAKE_CURRENT_BINARY_DIR}/session-tests")
add_test(NAME session-tests COMMAND "${CMAKE_CURRENT_BINARY_DIR}/session-tests")

add_executable(latency-capture Tools/latency-capture.cpp)
target_link_libraries(latency-capture PRIVATE "-framework CoreAudio" "-framework CoreFoundation")
add_executable(capture-stream-tests Tests/CaptureStreamTests.cpp)
target_compile_options(capture-stream-tests PRIVATE -UNDEBUG)
target_link_libraries(capture-stream-tests PRIVATE "-framework CoreAudio" "-framework CoreFoundation")
add_test(NAME capture-stream-tests COMMAND capture-stream-tests)

add_executable(async-resource-tests Tests/AsyncResourceTests.cpp)
target_compile_options(async-resource-tests PRIVATE -UNDEBUG)
add_test(NAME async-resource-tests COMMAND async-resource-tests)
add_executable(profile-review Tools/profile-review.cpp)
target_link_libraries(profile-review PRIVATE aspl)
