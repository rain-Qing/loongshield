# src/daemon/CMakeLists.txt - Build loonjit runtime and loongshield daemon
#
# Uses centralized paths from cmake/modules/Dependencies.cmake
# Uses DBus/Systemd detection from cmake/modules/Find*.cmake

# Version metadata for embedded Lua module.
# Packaging can override these values explicitly so release artifacts remain
# stable even when building from an exported source tarball without .git.
if(NOT DEFINED LOONGSHIELD_VERSION OR "${LOONGSHIELD_VERSION}" STREQUAL "")
    set(LOONGSHIELD_VERSION_FILE "${CMAKE_SOURCE_DIR}/VERSION")
    if(EXISTS "${LOONGSHIELD_VERSION_FILE}")
        file(READ "${LOONGSHIELD_VERSION_FILE}" LOONGSHIELD_VERSION)
        string(STRIP "${LOONGSHIELD_VERSION}" LOONGSHIELD_VERSION)
    else()
        set(LOONGSHIELD_VERSION "0.0.0")
    endif()
endif()

if(NOT DEFINED LOONGSHIELD_COMMIT OR "${LOONGSHIELD_COMMIT}" STREQUAL "")
    execute_process(
        COMMAND git rev-parse HEAD
        WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
        OUTPUT_VARIABLE LOONGSHIELD_COMMIT
        OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_QUIET
    )
    if(NOT LOONGSHIELD_COMMIT)
        set(LOONGSHIELD_COMMIT "unknown")
    endif()
endif()

configure_file(
    "${CMAKE_CURRENT_SOURCE_DIR}/modules/runtime/version.lua.in"
    "${CMAKE_CURRENT_BINARY_DIR}/modules/runtime/version.lua"
    @ONLY
)

set(GENERATED_VERSION_LUA "${CMAKE_CURRENT_BINARY_DIR}/modules/runtime/version.lua")
set(GENERATED_DAEMON_INCLUDE_DIR "${CMAKE_CURRENT_BINARY_DIR}/generated")
set(RAMFS_STAGING_DIR "${CMAKE_CURRENT_BINARY_DIR}/ramfs")
set(RAMFS_STAGING_MODULES_DIR "${RAMFS_STAGING_DIR}/modules")
set(GENERATED_RAMFS_LUAC_H "${GENERATED_DAEMON_INCLUDE_DIR}/bin_ramfs_luac.h")
set(GENERATED_INITRD_TAR_H "${GENERATED_DAEMON_INCLUDE_DIR}/bin_initrd_tar.h")

file(GLOB_RECURSE DAEMON_LUA_MODULES CONFIGURE_DEPENDS
    "${CMAKE_CURRENT_SOURCE_DIR}/modules/*.lua"
)

# Static libraries to link
set(LIBS_STATIC
    libluajit
    libuv
    luv
    lyaml
    yaml
    lua-cjson
    luafilesystem
    lua-openssl
    ${OPENSSL_LIBSSL}
    ${OPENSSL_LIBCRYPTO}
    curl
    lua-curlv3
    lpeg
    libkmod
    cap
    psx
    luaposix
    bpf
    luasocket
)

# Dynamic libraries (Linux only)
set(LIBS_DYNAMIC
    m
    dl
    pthread
    archive
    audit
    mount
    rpm
    rpmio
)

# Common source files for Lua bindings
set(SRCS_LUALIBS
    lualibs.c
    luauxlib.c
    lua_kmod.c
    lua_systemd.c
    lua_archive.c
    lua_audit.c
    lua_mount.c
    lua_rpm.c
    lua_dbus.c
    lua_capability.c
    lua_xattr.c
    lua_fs.c
)

# Common include directories (eliminates duplication)
set(DAEMON_INCLUDE_DIRS
    ${LUAJIT_INCLUDE_DIR}
    ${LUA_COMPAT_DIR}
    ${KMOD_INCLUDE_DIR}
    ${OPENSSL_INCLUDE_DIR}
    ${LIBCAP_INCLUDE_DIR}
)

################################# loonjit #################################

set(RUNTIME_NAME loonjit)

add_executable(${RUNTIME_NAME} ${SRCS_LUALIBS} luajit.c)
target_link_libraries(${RUNTIME_NAME} PRIVATE ${LIBS_STATIC})

if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    target_link_libraries(${RUNTIME_NAME} PRIVATE ${LIBS_DYNAMIC})
    # DBus via imported target
    target_link_libraries(${RUNTIME_NAME} PRIVATE DBus::DBus)
    # Public libsystemd API
    if(TARGET Systemd::Systemd)
        target_link_libraries(${RUNTIME_NAME} PRIVATE Systemd::Systemd)
    endif()
endif()

target_include_directories(${RUNTIME_NAME} PRIVATE ${DAEMON_INCLUDE_DIRS})

################################# daemon #################################

set(DAEMON_NAME loongshield)

set(SRCS_DAEMON
    ${SRCS_LUALIBS}
    main.c
    debug.c
    ramfs.c
    ${GENERATED_RAMFS_LUAC_H}
    ${GENERATED_INITRD_TAR_H}
)

# Generate ramfs headers using loonjit
add_custom_command(OUTPUT ${GENERATED_RAMFS_LUAC_H} ${GENERATED_INITRD_TAR_H}
    COMMAND ${CMAKE_COMMAND} -E make_directory "${RAMFS_STAGING_DIR}"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${GENERATED_DAEMON_INCLUDE_DIR}"
    COMMAND ${CMAKE_COMMAND} -E rm -rf "${RAMFS_STAGING_MODULES_DIR}"
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        "${CMAKE_CURRENT_SOURCE_DIR}/modules"
        "${RAMFS_STAGING_MODULES_DIR}"
    COMMAND ${CMAKE_COMMAND} -E copy
        "${GENERATED_VERSION_LUA}"
        "${RAMFS_STAGING_MODULES_DIR}/runtime/version.lua"
    COMMAND $<TARGET_FILE:${RUNTIME_NAME}>
        "${CMAKE_CURRENT_SOURCE_DIR}/build.lua"
        "ramfs/modules"
        "${GENERATED_RAMFS_LUAC_H}"
        "${GENERATED_INITRD_TAR_H}"
        "2"
    WORKING_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}"
    DEPENDS
        ${RUNTIME_NAME}
        ${DAEMON_LUA_MODULES}
        ${GENERATED_VERSION_LUA}
        "${CMAKE_CURRENT_SOURCE_DIR}/build.lua"
    COMMENT "Generating embedded ramfs headers..."
)

add_executable(${DAEMON_NAME} ${SRCS_DAEMON})
target_link_libraries(${DAEMON_NAME} PRIVATE ${LIBS_STATIC})

if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    target_link_libraries(${DAEMON_NAME} PRIVATE ${LIBS_DYNAMIC})
    # DBus via imported target
    target_link_libraries(${DAEMON_NAME} PRIVATE DBus::DBus)
    # Public libsystemd API
    if(TARGET Systemd::Systemd)
        target_link_libraries(${DAEMON_NAME} PRIVATE Systemd::Systemd)
    endif()
endif()

target_include_directories(${DAEMON_NAME} PRIVATE ${DAEMON_INCLUDE_DIRS} "${CMAKE_CURRENT_BINARY_DIR}")

# Debug flag (target-based, not global)
target_compile_definitions(${DAEMON_NAME} PRIVATE DEBUG)

# Ensure loonjit is built before daemon (for ramfs generation)
add_dependencies(${DAEMON_NAME} ${RUNTIME_NAME})
