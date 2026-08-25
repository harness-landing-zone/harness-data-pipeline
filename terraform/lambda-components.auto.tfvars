# Non-secret desired component inventory. OpenTofu loads *.auto.tfvars files
# automatically, so adding another map entry extends the same for_each graph.
additional_zip_lambdas = {
  transform = {
    service_identifier = "transform_lambda"
    description        = "Transform a pipeline event using a separately released ZIP artifact."
    bootstrap_filename = "transform.zip"
  }
}
