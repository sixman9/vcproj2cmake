set(v2c_vcproj2cmake_mappings_source_dir "${CMAKE_CURRENT_SOURCE_DIR}")

function(v2c_install_populate_vcproj2cmake_mappings_dir _destination_dir)
  if(NOT _destination_dir)
    message(FATAL_ERROR "${CMAKE_CURRENT_LIST_FILE}: invalid destination directory!")
  endif(NOT _destination_dir)

  message(STATUS "Will install vcproj2cmake-specific define/dependency/include mappings files (sample files!) into ${_destination_dir}.")
  set(v2c_mappings_files_list define_mappings.txt dependency_mappings.txt include_mappings.txt)
  foreach(mappings_file ${v2c_mappings_files_list})
    install(FILES "${v2c_vcproj2cmake_mappings_source_dir}/${mappings_file}"
      DESTINATION "${_destination_dir}"
    )
  endforeach(mappings_file ${v2c_mappings_files_list})
endfunction(v2c_install_populate_vcproj2cmake_mappings_dir _destination_dir)

v2c_install_populate_vcproj2cmake_mappings_dir("${v2c_mappings_install_dir}")
