lambdas = {
  lambda_one = {
    description = "Example ZIP Lambda deployed by Harness CD."
    memory_size = 128
    timeout     = 10
    environment_variables = {
      LOG_LEVEL = "INFO"
    }
  }

  # lambda_two = {
  #   description = "Second ZIP Lambda deployed by Harness CD."
  #   memory_size = 256
  #   timeout     = 30
  #   environment_variables = {
  #     LOG_LEVEL = "DEBUG"
  #   }
  # }
}
