# user-modifiable file containing common vcproj2cmake settings, included by all vcproj2cmake scripts.

# local config directory as created in every project which needs specific settings
# (possibly required in root project space only)
$v2c_config_dir_local = "./cmake/vcproj2cmake"

# directory where local CMake modules reside, filename case is not really standardized,
# thus you might want to tweak this setting
$v2c_module_path_local = "./cmake/Modules"

# Whether to verify that files that are listed in a project are ok
# (e.g. they might not exist, perhaps due to filename having wrong case).
$v2c_validate_vcproj_ensure_files_ok = 1

# Whether to actively fail the conversion in case any errors have been
# encountered. Strongly recommended to active this,
# since generating an incorrect CMakeLists.txt
# will make a CMake configure run barf,
# at which point the previous CMake-generated build system is history
# and thus targets for automatic rebuild of CMakeLists.txt are gone, too,
# necessitating a painful manual re-execution
# of vcproj2cmake_recursive.rb plus arguments
# after having fixed all problematic .vcproj settings.
$v2c_validate_vcproj_abort_on_error = 1

# Configures amount of useful comments left in generated CMakeLists.txt
# files
# 0 == completely disabled (not recommended)
# 1 == useful bare minimum
# 2 == standard (default)
# 3 == verbose
# 4 == extra verbose
$v2c_generated_comments_level = 2
