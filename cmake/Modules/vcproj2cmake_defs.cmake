# reset common variables used by all converted CMakeLists.txt files
set(V2C_LIBS )
set(V2C_LIB_DIRS )
set(V2C_SOURCES )

set(V2C_LOCAL_CONFIG_DIR ./cmake/vcproj2cmake CACHE STRING "Relative path to vcproj2cmake-specific content, located within every sub-project")

# Add a filter variable for someone to customize in case he/she doesn't want
# a rebuild somewhere for some reason (such as having multiple builds
# operate simultaneously on a single source tree,
# thus fiddling with source tree content during build would be a big No-No
# in such case).
set(V2C_USE_AUTOMATIC_CMAKELISTS_REBUILDER true CACHE BOOL "Automatically rebuild converted CMakeLists.txt files upon updates on .vcproj side?")

# Pre-define hook include filenames
# (may be redefined/overridden by local content!)
set(V2C_HOOK_PROJECT ${V2C_LOCAL_CONFIG_DIR}/hook_project.txt)
set(V2C_HOOK_PROJECT ${V2C_LOCAL_CONFIG_DIR}/hook_project.txt)
set(V2C_HOOK_POST_SOURCES ${V2C_LOCAL_CONFIG_DIR}/hook_post_sources.txt)
set(V2C_HOOK_POST_DEFINITIONS ${V2C_LOCAL_CONFIG_DIR}/hook_post_definitions.txt)
set(V2C_HOOK_POST_TARGET ${V2C_LOCAL_CONFIG_DIR}/hook_post_target.txt)
set(V2C_HOOK_POST ${V2C_LOCAL_CONFIG_DIR}/hook_post.txt)
