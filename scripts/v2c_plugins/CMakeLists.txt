if(NOT v2c_scripts_plugins_install_dir)
  set(v2c_scripts_plugins_install_dir "${v2c_scripts_install_dir}/v2c_plugins")
endif(NOT v2c_scripts_plugins_install_dir)

install(FILES
  v2c_parser_vs7_vcproj.rb
  DESTINATION "${v2c_scripts_plugins_install_dir}"
)
