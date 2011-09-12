set(v2c_modules_source_dir "${CMAKE_CURRENT_SOURCE_DIR}")

function(v2c_install_populate_module_path _destination_dir)
  if(NOT _destination_dir)
    message(FATAL_ERROR "${CMAKE_CURRENT_LIST_FILE}: invalid destination directory!")
  endif(NOT _destination_dir)

  message(STATUS "Will install vcproj2cmake-specific CMake modules into ${_destination_dir}.")
  set(v2c_module_files_list vcproj2cmake_defs.cmake vcproj2cmake_func.cmake)
  foreach(module_file ${v2c_module_files_list})
    install(FILES "${v2c_modules_source_dir}/${module_file}"
      DESTINATION "${_destination_dir}"
    )
  endforeach(module_file ${v2c_module_files_list})
endfunction(v2c_install_populate_module_path _destination_dir)

v2c_install_populate_module_path("${v2c_module_path_install_dir}")
