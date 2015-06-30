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

namespace :packer do
  desc "Builds and registers an AMI containing the blog."
  task :build_ami do
    packerfile = File.join(base_dir, "deploy", "packer.json")
    vars_file = File.join(base_dir, "deploy", "packer_vars.json")

    system("packer", "build", "--var-file", vars_file, packerfile)
  end
end

namespace :vagrant do
  vagrantfile = File.join(base_dir, "deploy", "Vagrantfile")
  env = { "VAGRANT_VAGRANTFILE" => vagrantfile }

  desc "Stage the blog on a virtual machine."
  task provision: :build  do
    system(env, "vagrant up")
    system(env, "vagrant provision")
  end

  desc "Open a shell on the staged server."
  task ssh: :provision do
    system(env, "vagrant ssh")
  end

  desc "Shuts down the virtual machine."
  task :halt do
    system(env, "vagrant halt")
  end
end
