cmake_minimum_required(VERSION 3.10)
project(edflib C)

# compile as C (not C++)
set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)

# sources
add_library(edflib SHARED
        edflib.c
)

# include headers
target_include_directories(edflib PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})

# link to Android log
find_library(log-lib log)
target_link_libraries(edflib PRIVATE ${log-lib})

# optional: set visibility (keeps symbol export simple)
if (CMAKE_C_COMPILER_ID MATCHES "GNU|Clang")
    target_compile_options(edflib PRIVATE -fvisibility=default)
endif()
