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
  build_tag = "blog:#{timestamp}"

  system("rm", "-rf", build_dir)
  system({ "MM_ROOT" => base_dir }, "bundle", "exec", "middleman", "build")
  system("docker", "build", "-t", build_tag, base_dir)
end
