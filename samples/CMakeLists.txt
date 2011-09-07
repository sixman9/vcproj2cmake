if(NOT v2c_samples_destination)
  message(FATAL_ERROR "no destination sub directory for vcproj2cmake tools given!")
endif(NOT v2c_samples_destination)

set(v2c_samples_hook_post "hook_post.txt")
set(v2c_samples_hook_project "hook_project.txt")
set(v2c_samples_project_exclude_list "project_exclude_list.txt")

install(FILES
  "${v2c_samples_hook_post}"
  "${v2c_samples_hook_project}"
  "${v2c_samples_project_exclude_list}"
  DESTINATION "${v2c_samples_destination}"
)
