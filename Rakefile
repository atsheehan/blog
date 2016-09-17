def base_dir
  File.expand_path(File.dirname(__FILE__))
end

desc "Generate the static site."
task :build do
  system({ "MM_ROOT" => base_dir }, "middleman build")

  build_dir = File.join(base_dir, "build")
  archive_filename = File.join(build_dir, "site.tar.gz")

  system("tar", "zcf", archive_filename, "-C", build_dir, "foobarium")
end
