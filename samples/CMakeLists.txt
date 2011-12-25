# NOTE: this CMakeLists.txt file is NOT a "sample" file -
# its purpose is to install the actual collection of sample files
# located within this directory.

if(NOT v2c_samples_install_dir)
  message(FATAL_ERROR "no installation sub directory for vcproj2cmake tools given!")
endif(NOT v2c_samples_install_dir)

set(v2c_samples_hook_post "hook_post.txt")
set(v2c_samples_hook_project "hook_project.txt")
set(v2c_samples_project_exclude_list "project_exclude_list.txt")

install(FILES
  "${v2c_samples_hook_post}"
  "${v2c_samples_hook_project}"
  "${v2c_samples_project_exclude_list}"
  DESTINATION "${v2c_samples_install_dir}"
)
