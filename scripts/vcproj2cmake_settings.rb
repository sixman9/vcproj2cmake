# user-modifiable file containing common vcproj2cmake settings, included by all vcproj2cmake scripts.

# local config directory as created in every project which needs specific settings
# (possibly required in root project space only)
$v2c_config_dir_local = "./cmake/vcproj2cmake"

# directory where local CMake modules reside, filename case is not really standardized,
# thus you might want to tweak this setting
$v2c_module_path_local = "./cmake/Modules"

# Configures amount of useful comments left in generated CMakeLists.txt
# files
# 0 == completely disabled (not recommended)
# 1 == useful bare minimum
# 2 == standard (default)
# 3 == verbose
# 4 == extra verbose
$v2c_generated_comments_level = 2
