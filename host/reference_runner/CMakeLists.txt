cmake_minimum_required(VERSION 3.20)
project(sc88_reference VERSION 1.0 LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(GEAR "${CMAKE_CURRENT_SOURCE_DIR}/../../external/gearmulator/source")

# Compile the pinned SC-88Pro board unchanged, with the upstream interpreter backends.
add_compile_definitions(CHIPS_FORCE_NO_JIT=1 _CRT_SECURE_NO_WARNINGS)
if(MSVC)
    add_compile_options(/utf-8 /permissive-)
    # Upstream baseLib uses C++17 filesystem::u8string returning std::string.
    set_source_files_properties("${GEAR}/framework/baseLib/filesystem.cpp"
        PROPERTIES COMPILE_OPTIONS /std:c++17)
endif()

set(BUILD_TESTING OFF)
add_subdirectory("${GEAR}/cpu/common" "upstream/common")
add_subdirectory("${GEAR}/cpu/h8500" "upstream/h8500")
add_subdirectory("${GEAR}/ronaldo/custom_chips/xp" "upstream/xp")
add_subdirectory("${GEAR}/ronaldo/custom_chips/lsp" "upstream/lsp")
add_library(sc88_board STATIC
    "${GEAR}/ronaldo/88emu/88lib/boards/sc88pro.cpp"
    "${GEAR}/ronaldo/88emu/88lib/mcu/sc88_submcu.cpp"
    "${GEAR}/ronaldo/88emu/88lib/rom/rom.cpp"
    "${GEAR}/framework/hardwareLib/hd44780.cpp"
    "${GEAR}/framework/baseLib/filesystem.cpp"
    "${GEAR}/framework/baseLib/md5.cpp"
    "${GEAR}/framework/baseLib/os.cpp"
    "${GEAR}/framework/synthLib/midi/smfReader.cpp"
    "${GEAR}/framework/synthLib/midiBufferParser.cpp"
)
target_include_directories(sc88_board PUBLIC
    "${GEAR}" "${GEAR}/framework" "${GEAR}/ronaldo" "${GEAR}/ronaldo/88emu")
target_link_libraries(sc88_board PUBLIC h8500 xpLib lspLib)
if(WIN32)
    target_link_libraries(sc88_board PRIVATE shell32 ole32)
endif()
add_executable(sc88_reference_runner main.cpp)
target_link_libraries(sc88_reference_runner PRIVATE sc88_board)

if(SC88_BUILD_TRACE)
    set(OVERLAY "${CMAKE_CURRENT_SOURCE_DIR}/../../build/trace-overlay")
    set(TRACE "${CMAKE_CURRENT_SOURCE_DIR}/../trace")
    get_target_property(BOARD_SOURCES sc88_board SOURCES)
    list(REMOVE_ITEM BOARD_SOURCES "${GEAR}/ronaldo/88emu/88lib/boards/sc88pro.cpp")
    add_library(sc88_trace_board STATIC ${BOARD_SOURCES} "${OVERLAY}/sc88pro.cpp")
    target_include_directories(sc88_trace_board BEFORE PUBLIC "${OVERLAY}" "${TRACE}")
    target_include_directories(sc88_trace_board PUBLIC "${GEAR}" "${GEAR}/framework" "${GEAR}/ronaldo" "${GEAR}/ronaldo/88emu")
    target_link_libraries(sc88_trace_board PUBLIC h8500 xpLib lspLib PRIVATE shell32 ole32)
    add_executable(sc88_register_trace main.cpp "${TRACE}/trace.cpp")
    target_compile_definitions(sc88_register_trace PRIVATE SC88_TRACE_EXPORT=1)
    target_link_libraries(sc88_register_trace PRIVATE sc88_trace_board)

    # Deliberately no board or H8 library on the replay link boundary.
    add_executable(sc88_trace_replay "${TRACE}/replay.cpp" "${TRACE}/trace.cpp" "${GEAR}/framework/baseLib/md5.cpp")
    target_include_directories(sc88_trace_replay PRIVATE "${TRACE}" "${GEAR}/framework" "${GEAR}/ronaldo")
    target_link_libraries(sc88_trace_replay PRIVATE xpLib lspLib)
    if(MSVC)
        target_link_options(sc88_trace_replay PRIVATE "/MAP:${CMAKE_BINARY_DIR}/sc88_trace_replay.map")
    endif()
endif()

if(SC88_BUILD_PARAMETERS)
    set(PARAM_OVERLAY "${CMAKE_CURRENT_SOURCE_DIR}/../../build/offline-player-overlay")
    set(PARAM "${CMAKE_CURRENT_SOURCE_DIR}/../offline_player")
    get_target_property(XP_SOURCES xpLib SOURCES)
    list(REMOVE_ITEM XP_SOURCES xp_voice.cpp xp.cpp)
    list(TRANSFORM XP_SOURCES PREPEND "${GEAR}/ronaldo/custom_chips/xp/")
    foreach(MODE export replay)
        add_library(xp_parameter_${MODE} STATIC ${XP_SOURCES}
            "${PARAM_OVERLAY}/xp_${MODE}.cpp" "${PARAM_OVERLAY}/xp_voice_${MODE}.cpp")
        target_include_directories(xp_parameter_${MODE} PUBLIC
            "${GEAR}/ronaldo/custom_chips/xp" "${GEAR}/ronaldo" "${PARAM}")
    endforeach()
    get_target_property(PARAM_BOARD_SOURCES sc88_board SOURCES)
    list(REMOVE_ITEM PARAM_BOARD_SOURCES "${GEAR}/ronaldo/88emu/88lib/boards/sc88pro.cpp")
    add_library(sc88_parameter_board STATIC ${PARAM_BOARD_SOURCES} "${PARAM_OVERLAY}/sc88pro.cpp")
    target_include_directories(sc88_parameter_board BEFORE PUBLIC "${PARAM_OVERLAY}" "${PARAM}")
    target_include_directories(sc88_parameter_board PUBLIC
        "${GEAR}" "${GEAR}/framework" "${GEAR}/ronaldo" "${GEAR}/ronaldo/88emu")
    target_link_libraries(sc88_parameter_board PUBLIC h8500 xp_parameter_export lspLib PRIVATE shell32 ole32)
    add_executable(sc88_parameter_export "${PARAM_OVERLAY}/main.cpp" "${PARAM}/parameter.cpp" "${CMAKE_CURRENT_SOURCE_DIR}/../trace/trace.cpp")
    target_compile_definitions(sc88_parameter_export PRIVATE SC88_PARAMETER_EXPORT=1)
    target_include_directories(sc88_parameter_export PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../trace")
    target_link_libraries(sc88_parameter_export PRIVATE sc88_parameter_board)
    add_executable(sc88_parameter_replay "${PARAM}/replay.cpp" "${PARAM}/parameter.cpp"
        "${CMAKE_CURRENT_SOURCE_DIR}/../trace/trace.cpp" "${GEAR}/framework/baseLib/md5.cpp")
    target_include_directories(sc88_parameter_replay PRIVATE "${PARAM}" "${CMAKE_CURRENT_SOURCE_DIR}/../trace" "${GEAR}/framework" "${GEAR}/ronaldo")
    target_link_libraries(sc88_parameter_replay PRIVATE xp_parameter_replay lspLib)
    target_sources(sc88_parameter_replay PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../../software/ps/sc88_parameter_effects.cpp")
    target_include_directories(sc88_parameter_replay PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../../software/ps")
    foreach(MODE 0 1 2)
        add_executable(sc88_offline_irq_${MODE} "${CMAKE_CURRENT_SOURCE_DIR}/../offline_irq_probe.cpp"
            "${PARAM}/parameter.cpp" "${CMAKE_CURRENT_SOURCE_DIR}/../trace/trace.cpp")
        target_compile_definitions(sc88_offline_irq_${MODE} PRIVATE SC88_PROBE_MODE=${MODE})
        target_include_directories(sc88_offline_irq_${MODE} PRIVATE "${PARAM}" "${CMAKE_CURRENT_SOURCE_DIR}/../trace")
        if(MODE EQUAL 0)
            target_link_libraries(sc88_offline_irq_${MODE} PRIVATE xpLib lspLib)
        elseif(MODE EQUAL 1)
            target_link_libraries(sc88_offline_irq_${MODE} PRIVATE xp_parameter_export lspLib)
        else()
            target_link_libraries(sc88_offline_irq_${MODE} PRIVATE xp_parameter_replay lspLib)
        endif()
    endforeach()
    if(MSVC)
        target_link_options(sc88_parameter_replay PRIVATE "/MAP:${CMAKE_BINARY_DIR}/sc88_parameter_replay.map")
    endif()
endif()
