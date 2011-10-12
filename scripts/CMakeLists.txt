if(NOT v2c_scripts_install_dir)
  message(FATAL_ERROR "no installation directory for scripts given!")
endif(NOT v2c_scripts_install_dir)

# Specify QUIET since it will print an annoying message
# in case of an executable-only Ruby install
# (we _do_ need the Ruby executable only)
find_package(Ruby QUIET)
if(NOT RUBY_EXECUTABLE)
  message(FATAL_ERROR "vcproj2cmake .vcproj conversion script currently is Ruby-based, thus your system needs to have a Ruby package installed, aborting!")
endif(NOT RUBY_EXECUTABLE)

set(v2c_script_converter "vcproj2cmake.rb")
set(v2c_script_converter_recursive "vcproj2cmake_recursive.rb")
set(v2c_script_converter_settings "vcproj2cmake_settings.rb")

install(PROGRAMS
  "${v2c_script_converter}"
  "${v2c_script_converter_recursive}"
  DESTINATION "${v2c_scripts_install_dir}"
)
install(FILES
  "${v2c_script_converter_settings}"
  DESTINATION "${v2c_scripts_install_dir}"
)


# A subdir precisely named "lib/" is a standard Ruby mechanism
# to automatically locate local modules.
set(v2c_scripts_modules_subdir "lib")

# http://devblog.vworkapp.com/post/910714976/best-practice-for-rubys-require
# strongly recommends a "namespace" subdir within local module load path.
set(v2c_scripts_modules_namespace "vcproj2cmake")



set(v2c_script_converter_module_util_file
  "${v2c_scripts_modules_subdir}/${v2c_scripts_modules_namespace}/util_file.rb"
)

set(v2c_scripts_modules_install_dir
  "${v2c_scripts_install_dir}/${v2c_scripts_modules_subdir}/${v2c_scripts_modules_namespace}"
)

install(FILES
  "${v2c_script_converter_module_util_file}"
  DESTINATION "${v2c_scripts_modules_install_dir}"
)

# This function will be invoked _post_-install of the project.
function(v2c_scripts_convert_project_recursive _proj_source_root)
  set(stamp_file_dir "${CMAKE_CURRENT_BINARY_DIR}/stamps")
  file(MAKE_DIRECTORY "${stamp_file_dir}")
  set(conversion_stamp "${stamp_file_dir}/vcproj_converted.stamp")
  # Should have this conversion target properly re-run
  # after each potential change due to CMake configure run:
  file(REMOVE "${conversion_stamp}")
  set(v2c_vcproj2cmake_recursive_bin "${CMAKE_INSTALL_PREFIX}/${v2c_scripts_install_dir}/vcproj2cmake_recursive.rb")
  add_custom_command(OUTPUT "${conversion_stamp}"
    COMMAND "${RUBY_EXECUTABLE}" "${v2c_vcproj2cmake_recursive_bin}"
    COMMAND "${CMAKE_COMMAND}" -E touch "${conversion_stamp}"
    DEPENDS "${v2c_vcproj2cmake_recursive_bin}" "${RUBY_EXECUTABLE}"
    WORKING_DIRECTORY "${_proj_source_root}"
    COMMENT "Executing recursive vcproj2cmake conversion of the .vcproj-based project below ${v2c_vcproj_proj_source_root}, using ${v2c_vcproj2cmake_recursive_bin}"
  )
  add_custom_target(convert_source_root_recursive DEPENDS "${conversion_stamp}")
endfunction(v2c_scripts_convert_project_recursive _proj_source_root)
