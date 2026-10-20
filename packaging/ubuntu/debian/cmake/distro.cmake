# Distribution additions to the dlt-viewer build, kept out of the upstream
# CMake files. Injected by debian/rules with
#   -DCMAKE_PROJECT_dlt-viewer_INCLUDE=<this file>
# which runs right after project(dlt-viewer); the real work is deferred until
# the whole source tree has been configured and the qdlt target exists.

set(DLT_DISTRO_CMAKE_DIR "${CMAKE_CURRENT_LIST_DIR}")

function(dlt_distro_qdlt)
    if(NOT DLT_USE_STANDARD_INSTALLATION_LOCATION)
        message(FATAL_ERROR "distro.cmake requires -DDLT_USE_STANDARD_INSTALLATION_LOCATION=ON")
    endif()

    # The plugin ABI is not stable across viewer versions, so the soname
    # carries major.minor: a plugin built for another viewer fails to load
    # instead of crashing.
    set_target_properties(qdlt PROPERTIES
        VERSION ${dlt-viewer_VERSION}
        SOVERSION ${dlt-viewer_VERSION_MAJOR}.${dlt-viewer_VERSION_MINOR})

    string(REGEX REPLACE "^Qt" "" DLT_QT_MAJOR "${QT_PREFIX}")
    configure_file("${DLT_DISTRO_CMAKE_DIR}/qdlt.pc.in" "${CMAKE_BINARY_DIR}/qdlt.pc" @ONLY)
    install(FILES "${CMAKE_BINARY_DIR}/qdlt.pc"
        DESTINATION "${CMAKE_INSTALL_LIBDIR}/pkgconfig"
        COMPONENT qdlt_sdk)
endfunction()

cmake_language(DEFER DIRECTORY "${CMAKE_SOURCE_DIR}" CALL dlt_distro_qdlt)
