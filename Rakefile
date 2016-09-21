require "date"

require "aws-sdk"
require "dotenv"

Dotenv.load

def try_execute(*args)
  if !system(*args)
    raise
  end
end

def base_dir
  File.expand_path(File.dirname(__FILE__))
end

def timestamp
  Time.now.utc.strftime("%Y%m%d%H%M%S")
end

desc "Build and deploy blog."
task :deploy do
  stack_name = ENV.fetch("STACK_NAME")
  template_file = File.join(base_dir, "cloudformation.yml")
  template = File.read(template_file)

  build_dir = File.join(base_dir, "build")
  build_tag = timestamp
  full_image_name = "asheehan/blog:#{build_tag}"

  input_params = {
    "VPC" => ENV.fetch("VPC_ID"),
    "Subnets" => ENV.fetch("SUBNETS"),
    "DomainName" => ENV.fetch("DOMAIN_NAME"),
    "KeypairName" => ENV.fetch("KEYPAIR_NAME"),
    "ContainerImage" => full_image_name
  }

  try_execute("rm", "-rf", build_dir)
  try_execute({ "MM_ROOT" => base_dir }, "bundle", "exec", "middleman", "build")
  try_execute("docker", "build", "-t", "asheehan/blog", base_dir)
  try_execute("docker", "tag", "asheehan/blog:latest", full_image_name)
  try_execute("docker", "push", full_image_name)

  parameters = input_params.map do |key, value|
    {
      parameter_key: key,
      parameter_value: value,
      use_previous_value: false
    }
  end

  client = Aws::CloudFormation::Client.new
  client.update_stack(stack_name: stack_name,
    template_body: template,
    capabilities: ["CAPABILITY_IAM", "CAPABILITY_NAMED_IAM"],
    parameters: parameters)
end
