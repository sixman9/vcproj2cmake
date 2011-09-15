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
option(V2C_USE_AUTOMATIC_CMAKELISTS_REBUILDER "Automatically rebuild converted CMakeLists.txt files upon updates on .vcproj side?" ON)


# Global Install Enable flag, to indicate whether one wants
# to make use of pretty flexible vcproj2cmake-supplied install helper functions.
# We don't enable it as default setting, since the user should first get a build
# nicely running before having to worry about installation-related troubles...
set(v2c_install_enable_default_setting false)
option(V2C_INSTALL_ENABLE "Enable flexible vcproj2cmake-supplied installation handling of converted targets?" ${v2c_install_enable_default_setting})

# In case installation is allowed, should we install all targets by default?
set(V2C_INSTALL_ENABLE_ALL_TARGETS true)


# Pre-define hook include filenames
# (may be redefined/overridden by local content!)
set(V2C_HOOK_PROJECT "${V2C_LOCAL_CONFIG_DIR}/hook_project.txt")
set(V2C_HOOK_POST_SOURCES "${V2C_LOCAL_CONFIG_DIR}/hook_post_sources.txt")
set(V2C_HOOK_POST_DEFINITIONS "${V2C_LOCAL_CONFIG_DIR}/hook_post_definitions.txt")
set(V2C_HOOK_POST_TARGET "${V2C_LOCAL_CONFIG_DIR}/hook_post_target.txt")
set(V2C_HOOK_POST "${V2C_LOCAL_CONFIG_DIR}/hook_post.txt")
