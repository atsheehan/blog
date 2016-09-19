require "date"

def base_dir
  File.expand_path(File.dirname(__FILE__))
end

def timestamp
  Time.now.utc.strftime("%Y%m%d%H%M%S")
end

desc "Generate the static site."
task :build do
  build_dir = File.join(base_dir, "build")
  build_tag = timestamp

  system("rm", "-rf", build_dir)
  system({ "MM_ROOT" => base_dir }, "bundle", "exec", "middleman", "build")
  system("docker", "build", "-t", "blog", base_dir)
  system("docker", "tag", "blog:latest", "blog:#{build_tag}")
end
