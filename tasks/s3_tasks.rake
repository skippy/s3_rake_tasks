namespace :s3 do

  namespace :static do
    desc "Upload your public directory to a bucket in S3.\n    BUCKET=bucket.\n    FORCE=true to blow away contents of bucket"
    task :upload do      
      #put this require here because we don't want it to always run... see the rake.rb file for details...
      require File.join(File.dirname(__FILE__), "../lib/aws/s3/rake.rb")
      options = {
        :bucket => "static.#{Utils.project_name}",
        :force => false,
        :access => :public_read
        }
        options[:force] = true if ENV['FORCE'] == 'true'
        options[:bucket] = ENV['BUCKET'] if ENV['BUCKET']
        options[:access] = ENV['ACCESS'].to_sym if ENV['ACCESS']
        bucket = Static.find_or_create_bucket(options[:bucket], options)
        if ENV['FORCE'] == 'true'
          Utils.msg "cleaning bucket '#{bucket.name}'."
          bucket.delete_all 
        end
        Utils.msg "uploading public/static files from '#{RAILS_ROOT}/public/' to bucket '#{bucket.name}'."        
        Static.upload("#{RAILS_ROOT}/public/", bucket, options)
    end
    
    # task :create_bucket do
    #   options = {
    #     :bucket => "static.#{Utils.project_name}",
    #     :acces => :public_read
    #   }
    #   options[:bucket] = ENV['BUCKET'] if ENV['BUCKET']
    #   options[:access] = ENV['ACCESS'].to_sym if EVN['ACCESS']
    #   Bucket.create(options[:bucket], options)
    # end
    
  end
  
  desc "Backup code, database, and scm to S3"
  task :backup => [ "s3:backup:code",  "s3:backup:db", "s3:backup:scm"]
  
  namespace :backup do
    desc "Backup a log directory.  REQUIRED: DIR=/log/dir BUCKET=s3_bucket OPTIONAL (show defaults): KEEP=10 REMOVE=true"
    task :logs do
      require File.join(File.dirname(__FILE__), "../lib/aws/s3/rake.rb")
      dir = ENV['DIR']
      raise Exception, "The directory '#{dir}' does not exist" unless File.exists?(dir)

      keep = (ENV['KEEP'] || 5).to_i
      remove_files = ENV['REMOVE'] || true
      remove_files = true if ENV['REMOVE'] && ENV['REMOVE'].downcase == 'true'
      files =  files = `ls -t #{dir}/`.split.reverse
      if files.blank?
        raise Exception, "No files found in directory #{dir}"
      end
      
      files = files[0..-keep]

      bucket = ENV['BUCKET']
      start = Time.now
      ready_to_remove = []
      files.each do |file|
        cmd = "cp -RpL #{dir}/#{file} "
        Utils.msg "Running #{cmd} ... "
        Backup.backup('log', cmd, false, {:bucket => bucket, :archive_name => file })  
        ready_to_remove << "#{dir}/#{file}"     
      end
      if remove_files && !ready_to_remove.blank?
        Utils.msg "about to remove the following files: #{ready_to_remove.inspect}"
        FileUtils.rm(ready_to_remove) if remove_files
      end
    end
    
    desc "Backup the code to S3"
    task :code  do
      require File.join(File.dirname(__FILE__), "../lib/aws/s3/rake.rb")
      start = Time.now
      # use -L so we follow the symlinks and get the interesting stuff like the mugshots, client code, etc.
      # this will make the checkins a LOT larger
      # cmd = "cp -RpL #{Dir.pwd} "
      cmd = "tar hc --exclude 'log' --exclude 'tmp' --exclude '.svn' -C #{Dir.pwd} . | tar xC "
      Utils.msg "Running #{cmd} ... "
      Backup.backup("code", 'mkdir', true) do |tmp_dir|
        `#{cmd} #{tmp_dir}`
      end
      Utils.msg "  (runtime: #{Time.now - start} secs)"
    end #end code task

    desc "Backup the database to S3"
    task :db  do
      require File.join(File.dirname(__FILE__), "../lib/aws/s3/rake.rb")
      start = Time.now
      database, user, password, host = Backup.retrieve_db_info
      skip_tables = %w{sessions}

      # is --opt going to give us problems because it locks all the tables?  leave for now, as when we get to that high-level
      # usage that locking becomes an issue, we will probably want to do a different backup strategy!
      # removing: --flush-privileges... only supported on the very newest of mysql databases....
      cmd = "mysqldump --opt --skip-add-locks --quick --triggers --quote-names --tz-utc "
      cmd += "-h'#{host}' " unless host.blank?
      cmd += " -u'#{user}' "
      Utils.msg "Running #{cmd} -p[password filtered] #{database} > (to a local file)"
      cmd += " -p'#{password}' " unless password.nil?
      #this is a bit of a hack.... 
      Backup.backup("db.#{database}") do |tmp_dir|
        skip_tables.each do |t|
          `#{cmd} --no-data #{database} #{t} > #{tmp_dir}/#{t}.sql`
        end
        cmd += " #{database} "
        (ActiveRecord::Base.connection.tables - skip_tables).each do |t|
          `#{cmd} #{t} > #{tmp_dir}/#{t}.sql`
        end
      end
      Utils.msg "  (runtime: #{Time.now - start} secs)"
    end
    
    desc "Backup the current scm repository to S3.\n    To backup a different repository, enter the full url SVN='svn+ssh://server.net/some/repo"
    task :scm do
      require File.join(File.dirname(__FILE__), "../lib/aws/s3/rake.rb")
      start = Time.now
      svn_info = {}
      IO.popen("svn info") do |f|
        f.each do |line|
          line.strip!
          next if line.empty?
          split = line.split(':')
          svn_info[split.shift.strip] = split.join(':').strip
        end
      end
      
      url_type, repo_path = svn_info['URL'].split('://')
      repo_path.gsub!(/\/+/, '/').strip!
      url_type.strip!
      
      use_svnadmin = true
      final_path = svn_info['URL']
      if url_type =~ /^file/
        Utils.msg "'#{svn_info['URL']} is local!"
        final_path = find_scm_dir(repo_path)
      else
        Utils.msg "We will see if we can find a local path for '#{svn_info['URL']}'"
        repo_path = repo_path[repo_path.index('/')...repo_path.size]
        repo_path = find_scm_dir(repo_path)
        if File.exists?(repo_path)
          uuid = File.read("#{repo_path}/db/uuid").strip!
          if uuid == svn_info['Repository UUID']
            Utils.msg "We have found the same SVN repo at: #{repo_path} with a matching UUID of '#{uuid}'"
            final_path = find_scm_dir(repo_path)
          else
            Utils.msg "We have not found the SVN repo at: #{repo_path}.  The uuid's are different."
            use_svnadmin = false
            final_path = svn_info['URL']
          end
        else
          Utils.msg "No SVN repository at #{repo_path}."
          use_svnadmin = false
          final_path = svn_info['URL']          
        end
      end
      
      #ok, now we need to do the work...
      cmd = use_svnadmin ? "svnadmin dump -q #{final_path} > " : "svn co -q --ignore-externals --non-interactive #{final_path}"

      Utils.msg "Running #{cmd} ... "
      Backup.backup('scm', cmd )
      Utils.msg "  (runtime: #{Time.now - start} secs)"
    end #end scm task

  end # end backup namespace

  desc "retrieve an object from any bucket.  KEY=object_key. Optional: BUCKET=bucket, otherwise defaults to current backup bucket"
  task :retrieve do
    require File.join(File.dirname(__FILE__), "../lib/aws/s3/rake.rb")
    raise "Specify a KEY=key object that you want to retrieve.  Optional: BUCKET=bucket, otherwise defaults to current backup bucket" unless ENV['KEY']
    Backup.retrieve_object(ENV['KEY'], ENV['BUCKET'])
  end
  # namespace :retrieve do
  #   desc "retrieve the latest revision of code, database, and scm from S3."
  #   task :recent => [ "s3:retrieve:code",  "s3:retrieve:db", "s3:retrieve:scm"]
  # 
  #   desc "retrieve the latest code backup from S3, or optionally specify a VERSION=this_archive.tar.gz"
  #   task :code  do
  #     retrieve_file 'code', ENV['VERSION']
  #   end
  #   
  #   desc "retrieve the latest db backup from S3, or optionally specify a VERSION=this_archive.tar.gz"
  #   task :db  do
  #     retrieve_file 'db', ENV['VERSION']
  #   end
  #   
  #   desc "retrieve the latest scm backup from S3, or optionally specify a VERSION=this_archive.tar.gz"
  #   task :scm  do
  #     retrieve_file 'scm', ENV['VERSION']
  #   end    
  # end #end retrieve namespace

  desc "List all your s3 buckets"
  task :list => [ "s3:list:buckets"]
  namespace :list do
    desc "list all your backup archives"
    task :backups  do
      require File.join(File.dirname(__FILE__), "../lib/aws/s3/rake.rb")
      Utils.print_bucket(Backup.backup_bucket)
    end

    desc "list all your S3 buckets"
    task :buckets do
      require File.join(File.dirname(__FILE__), "../lib/aws/s3/rake.rb")
      ti, ts = 0, 0
      buckets = []
      Service.buckets.map do |bucket|
        entries = Utils.retrieve_all_entries(bucket)
         ti += entries.size
         ts += entries.sum{|e| e[:size]}
        buckets << {
                    :num_items => entries.size.to_s, 
                    :size => Utils.print_bucket_size(entries).to_s, 
                    :time => entries.last.nil? ? "created on: #{bucket.creation_date.to_s(:short)}" : "last updated on: #{bucket.entries.last.last_modified.to_s(:long)}",
                    :name => bucket.name }
      
      end
      name_width = buckets.collect{|b| b[:name]}.collect{|n| n.length}.max
      num_items_width = buckets.collect{|b| b[:num_items]}.collect{|n| n.length}.max
      size_width = buckets.collect{|b| b[:size]}.collect{|n| n.length}.max
      
      buckets.each do |b|
        puts "#{b[:name].rjust(name_width)} [ items: #{b[:num_items].ljust(num_items_width)}    total_size: #{b[:size].ljust(size_width)}    #{b[:time]} UTC ]"
      end      
      puts "--------\nsummary:\n  total num items : #{ti}\n  total size      : #{Utils.print_formatted_size(ts)}"
    end
    
    desc "list the contents of a particular bucket by specifying BUCKET=backup"
    task :bucket do
      require File.join(File.dirname(__FILE__), "../lib/aws/s3/rake.rb")
      raise "Specify a BUCKET=bucket that you want to list" unless ENV['BUCKET']
      Utils.print_bucket(Bucket.find(ENV['BUCKET'], Backup.bucket_options))
    end
  end

    desc "Remove all but the last 200 most recent backup archives or optionally specify KEEP=50 to keep the last 50.  You can specity BUCKET=bucket_name"
    task :cleanup  do
      require File.join(File.dirname(__FILE__), "../lib/aws/s3/rake.rb")
      keep_num = ENV['KEEP'] ? ENV['KEEP'].to_i : 200
      bucket = Bucket.find(ENV['BUCKET']) rescue Backup.backup_bucket
      puts "keeping the last #{keep_num}"
      Backup.cleanup(bucket, keep_num)
    end
    
    desc 'Installs required config/s3.yml config file'
    task :install_config do
      require File.join(File.dirname(__FILE__), "../lib/aws/s3/rake.rb")
      h = {
        :aws_access_key => '<Your Access Key Here />',
        :aws_secret_access_key => '<Your Top-Secret access key here />',
        :options => {
          :use_ssl => true,
          :persistent => true
          }
      }
      raise "#{RAILS_ROOT}/config/s3.yml already exists!" if File.exists?("#{RAILS_ROOT}/config/s3.yml")
      # File.open("#{RAILS_ROOT}/config/s3.yml", 'w') { |file| file.write h.to_yaml }
      File.copy "#{File.dirname(__FILE__) }/../templates/s3.yml", "#{RAILS_ROOT}/config/s3.yml", true
      Utils.msg "Installed #{RAILS_ROOT}/config/s3.yml.  You need to modify it to connect to Amazon's S3"
    end

    desc "delete a particular bucket or object in a specific bucket.\n    Require BUCKET=bucket\n    KEY=key is optional.\n    FORCE=true to delete a bucket that is not empty.\n"
    task :delete do
      require File.join(File.dirname(__FILE__), "../lib/aws/s3/rake.rb")
      raise "Specify a BUCKET=bucket that you want deleted" unless ENV['BUCKET']
      if ENV['KEY']
        raise "Specify a KEY=key AND BUCKET=bucket of the object that you want to delete within the BUCKET" unless ENV['KEY'] && ENV['BUCKET']
        S3Object.delete ENV['KEY'], ENV['BUCKET']              
      else
        options = {}
        options.merge!(:force => true) if ENV['FORCE'] == 'true'
        # Bucket.delete doesn't work if you have force delete it... it will then say the bucket cannot be found!  Very odd...
        # not spending time looking at it...right now.
        b = Bucket.find(ENV['BUCKET'])
        size = b.size
        b.delete_all if ENV['FORCE'] == 'true'
        b.delete
        str = "deleting bucket #{ENV['BUCKET']}"
        str += ", which contained #{size} objects"  if size > 0
        Utils.msg str
      end      
    end
    
    desc <<-DSC 
   create a bucket; specify BUCKET=bucket.
     Optionally, specify the access level ACCESS= 'private' (default choice),
     'public_read', 'public_read_write', 'authenticated_read' (see AWS::S3::ACL)
   DSC
    task :create_bucket do
      require File.join(File.dirname(__FILE__), "../lib/aws/s3/rake.rb")
      raise "Specify the BUCKET=bucket that you want to create" unless ENV['BUCKET']
      access = ENV['ACCESS'] ? ENV['ACCESS'].to_sym : :private
      Bucket.create(ENV['BUCKET'], :access => access)
    end    
end

  
  private
  def find_scm_dir(path)
    #double check if the path is a real physical path vs a svn path
    final_path = path
    tmp_path = final_path
    len = tmp_path.split('/').size
    while !File.exists?(tmp_path) && len > 0 do
      len -= 1
      tmp_path = final_path.split('/')[0..len].join('/')
    end
    final_path = tmp_path if len > 1
    final_path
  end
