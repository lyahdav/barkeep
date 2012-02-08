# This file contains core tasks that are used to deploy your application to the
# destination servers. This is a decent initial setup, but is completely configurable.

namespace :fezzik do
  # Any variables set in deploy.rb with "env" will be saved on the server in two files:
  # config/environment.sh and config/environment.rb. The first is loaded into the shell
  # environment before the run script is called, and the second is made available to
  # be required into your code. You can use your own environment.rb file for development,
  # and it will be overwritten by this task when the code deploys.
  desc "saves variables set by 'env' in deploy.rb into config/environment.sh and config/environment.rb"
  task :save_environment do
    system("mkdir -p /tmp/#{app}/config")
    File.open("/tmp/#{app}/config/environment.rb", "w") do |file|
      @environment.each do |key, value|
        if value.is_a?(Array)
          puts "\033[01;34m>>>> key: #{key.inspect}\e[m"
          file.puts %Q/#{key.to_s.upcase} = [#{value.map { |item| %Q["#{item}"] }.join(",")}]/
        else
          file.puts "#{key.to_s.upcase} = \"#{value}\""
        end
      end
    end
    File.open("/tmp/#{app}/config/environment.sh", "w") do |file|
      @environment.each do |key, value|
        # TODO(caleb) Write array values in environment.sh in the future.
        file.puts "export #{key.to_s.upcase}=\"#{value}\"" unless value.is_a?(Array)
      end
    end
  end

  desc "stages the project for deployment in /tmp"
  task :stage do
    puts "staging project in /tmp/#{app}"
    `rm -Rf /tmp/#{app}`
    # --delete removes files in the dest directory which no longer exist in the source directory.
    # --safe-links copies symlinks as symlinks, but ignores any which point outside of the tree.
    command = "rsync -r --archive --safe-links --delete --exclude=.git* --exclude=log --exclude=tmp " +
        "#{local_path}/ '/tmp/#{app}/'"
    puts `#{command}`
    # Write out a bit of useful deploy-time info
    `./config/recipes/write_git_info.sh > /tmp/#{app}/git_deploy_info.txt`
    `git log --pretty=%H > /tmp/#{app}/all_commits.txt`
    Rake::Task["fezzik:save_environment"].invoke
  end

  desc "performs any necessary setup on the destination servers prior to deployment"
  remote_task :setup do
    puts "setting up servers"
    run "mkdir -p #{deploy_to}/releases #{deploy_to}/repos"
  end

  desc "rsyncs the project from its stages location to each destination server"
  remote_task :push => [:stage, :setup] do
    puts "pushing to #{target_host}:#{release_path}"
    # Copy on top of previous release to optimize rsync
    rsync "-q", "--copy-dest=#{current_path}", "/tmp/#{app}/", "#{target_host}:#{release_path}"

    # Store a few directories outside of the release directory which should be shared across releases.
    # tmp/ contains Google's open ID tokens. If it's not shared, we'll log everyone out every push.
    run "mkdir -p #{deploy_to}/shared/log #{deploy_to}/shared/tmp"
    run "cd #{release_path} && ln -fns #{deploy_to}/shared/log log"
    run "cd #{release_path} && ln -fns #{deploy_to}/shared/tmp tmp"
  end

  desc "symlinks the latest deployment to /deploy_path/project/current"
  remote_task :symlink do
    puts "symlinking current to #{release_path}"
    run "cd #{deploy_to} && ln -fns #{release_path} current"
  end

  desc "installs gems with bundler"
  remote_task :install_gems do
    puts "installing gems"

    run "cd #{current_path} && rbenv rehash" +
        " && (gem list bundler | grep bundler > /dev/null || gem install bundler --no-ri --no-rdoc)" +
        " && bundle install"
  end

  desc "runs migrations from root of project directory"
  remote_task :run_migrations do
    print "creating the database if it doesn't exist..."
    run "mysqladmin -uroot create barkeep 2> >(grep -v 'database exists') || true"
    puts "done"
    print "running migrations... "
    run "cd #{current_path} && bundle exec ruby run_migrations.rb"
    puts "done"
  end

  desc "runs the executable in project/bin"
  remote_task :start do
    puts "starting from #{capture_output { run "readlink #{current_path}" }}"
    run "cd #{current_path} && source config/environment.sh && ./bin/run_app.sh"
  end

  desc "kills the application by searching for the specified process name"
  remote_task :stop do
    puts "stopping app"
    # TODO(philc): We should be using unicorn here, and we should use pid files instead of kill.
    run "(kill `ps -ef | grep 'thin start -p 80' | grep -v grep | awk '{print $2}'` " +
        "2> >(grep -v 'usage: kill') || true)"
    sleep 3
    run "(kill -9 `ps -ef | grep 'thin start -p 80' | grep -v grep | awk '{print $2}'` " +
        "2> >(grep -v 'usage: kill') || true)"
    run "kill `ps -ef | grep 'resque' | grep -v grep | awk '{print $2}'`" +
        " 2> >(grep -v 'usage: kill') || true"
    run "kill `ps -ef | grep 'run_clockwork' | grep -v grep | awk '{print $2}'`" +
        " 2> >(grep -v 'usage: kill') || true"
  end

  desc "restarts the application"
  remote_task :restart do
    Rake::Task["fezzik:stop"].invoke
    Rake::Task["fezzik:start"].invoke
  end

  desc "full deployment pipeline"
  task :deploy do
    Rake::Task["fezzik:push"].invoke
    Rake::Task["fezzik:symlink"].invoke
    Rake::Task["fezzik:install_gems"].invoke
    Rake::Task["fezzik:run_migrations"].invoke
    Rake::Task["fezzik:restart"].invoke
    puts "#{app} deployed!"
  end
end
