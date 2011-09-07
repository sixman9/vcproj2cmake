if(NOT v2c_scripts_destination)
  message(FATAL_ERROR "no destination directory for scripts given!")
endif(NOT v2c_scripts_destination)

set(v2c_script_converter "vcproj2cmake.rb")
set(v2c_script_converter_recursive "vcproj2cmake_recursive.rb")
set(v2c_script_converter_settings "vcproj2cmake_settings.rb")

find_package(Ruby)
if(NOT RUBY_EXECUTABLE)
  message(FATAL_ERROR "vcproj2cmake .vcproj conversion script currently is Ruby-based, thus your system needs to have a Ruby package installed, aborting!")
endif(NOT RUBY_EXECUTABLE)

install(PROGRAMS
  "${v2c_script_converter}"
  "${v2c_script_converter_recursive}"
  DESTINATION "${v2c_scripts_destination}"
)
install(FILES
  "${v2c_script_converter_settings}"
  DESTINATION "${v2c_scripts_destination}"
)

# This function will be invoked _post_-install of the project.
function(v2c_scripts_convert_project_recursive _proj_source_root)
  set(stamp_file_dir "${CMAKE_CURRENT_BINARY_DIR}/stamps")
  file(MAKE_DIRECTORY "${stamp_file_dir}")
  set(conversion_stamp "${stamp_file_dir}/vcproj_converted.stamp")
  # should re-run this conversion target after each CMake configure run:
  file(REMOVE "${conversion_stamp}")
  set(v2c_vcproj2cmake_recursive_bin "${v2c_scripts_destination}/vcproj2cmake_recursive.rb")
  add_custom_command(OUTPUT "${conversion_stamp}"
    COMMAND "${RUBY_EXECUTABLE}" "${v2c_vcproj2cmake_recursive_bin}"
    COMMAND "${CMAKE_COMMAND}" -E touch "${conversion_stamp}"
    DEPENDS "${v2c_vcproj2cmake_recursive_bin}" "${RUBY_EXECUTABLE}"
    WORKING_DIRECTORY "${_proj_source_root}"
    COMMENT "Executing recursive vcproj2cmake conversion of the .vcproj-based project below ${v2c_vcproj_proj_source_root}, using ${v2c_vcproj2cmake_recursive_bin}"
  )
  add_custom_target(convert_source_root_recursive DEPENDS "${conversion_stamp}")
endfunction(v2c_scripts_convert_project_recursive _proj_source_root)
