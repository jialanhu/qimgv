# qimgv root
cmake_minimum_required(VERSION 3.16)
project(qimgv
    VERSION 1.0.2
    HOMEPAGE_URL "https://github.com/easymodo/qimgv"
    LANGUAGES CXX)

message(STATUS "Build configuration: " ${CMAKE_BUILD_TYPE})

# check for gcc
if(CMAKE_CXX_COMPILER_ID STREQUAL "GNU" AND
        CMAKE_CXX_COMPILER_VERSION VERSION_LESS 9.0)
    message(FATAL_ERROR "\n!!! THIS PROJECT REQUIRES GCC 9.0 OR LATER !!!\n")
endif()

# AUTOMOC
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)
set(CMAKE_AUTOUIC ON)
set(CMAKE_INCLUDE_CURRENT_DIR ON)

# USER OPTIONS
# Usage: cmake -DVIDEO_SUPPORT=ON [...]
option(EXIV2 "For reading/writing exif tags" ON)
option(VIDEO_SUPPORT "Enable video support" ON)
option(OPENCV_SUPPORT "Enable HQ scaling via OpenCV" ON)
option(KDE_SUPPORT "Support blur when using KDE" OFF)
option(USE_QT5 "Build with Qt5 instead of Qt6 (legacy)" OFF)

if(UNIX AND NOT APPLE)
    set(QT_EXTERN_PATH "" CACHE STRING "Tell compile external QT path, example: (/opt/Qt/6.2.0/gcc_64)")
    string(COMPARE EQUAL "${QT_EXTERN_PATH}" "" result)
    if (NOT result)
        set(CMAKE_INSTALL_RPATH "${QT_EXTERN_PATH}/lib")
    endif()
endif()

# FIND PACKAGES
if(USE_QT5)
    find_package(Qt5 5.12 REQUIRED COMPONENTS Core Widgets Svg PrintSupport)
    set(QT_VERSION_MAJOR 5)
    set(QT_VERSION ${Qt5_VERSION})
else()
    find_package(Qt6 6.12 REQUIRED COMPONENTS Core Widgets Svg PrintSupport OpenGLWidgets)
    set(QT_VERSION_MAJOR 6)
    set(QT_VERSION ${Qt6_VERSION})
endif()

message(STATUS "Qt Version: " ${QT_VERSION})

if(EXIV2)
    find_package(PkgConfig REQUIRED)
    pkg_check_modules(Exiv2 REQUIRED IMPORTED_TARGET exiv2)
endif()

if(KDE_SUPPORT)
    find_package(KF6WindowSystem REQUIRED)
endif()

if(OPENCV_SUPPORT)
    find_package(PkgConfig REQUIRED)
    find_package(OpenCV REQUIRED core imgproc)
endif()

##############################################################

add_subdirectory(qimgv)

if(VIDEO_SUPPORT)
    add_subdirectory(plugins/player_mpv)
endif()
