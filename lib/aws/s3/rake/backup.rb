module AWS
  module S3
    module Rake

      class Backup < Base
        require 'tempfile'
        require 'fileutils'
        
        SCRATCH_SPACE = "#{RAILS_ROOT}/tmp"

        class << self
          def backup_bucket(name = backup_bucket_name)
            find_or_create_bucket(name)
          end

          def retrieve_object(key,bucket=nil)
            #for some reason, if you put this in the line above instaed of the nil, it doesn't work...
            bucket ||= backup_bucket_name
            if key.is_a?(String)
              # gpg -d -r 'app' staging.sweetspot.20070725062028.db.sweetspot_staging.tgz.gpg.sig | gpg -d -r 'sweetspot-backup2007@6bar8.com' | tar -xz            open(key, 'w') do |file|
              open(key, 'w'){|file| S3Object.stream(key, bucket){|chunk| file.write chunk } }
              unpack_retrieved_object(key)
            else
              #assume it is a hash...
              options = key
              entries = S3Bucket.find(bucket, options)
              entries.each{|e| unpack_retrieved_object(e.key)}
            end
          end
          # 
          # find(name = nil, options = {}):max_keys => 1 :prefix => 'classical'
          
          
          
          # Bucket.objects('jukebox', :marker => 'm', :max_keys => 2, :prefix => 'jazz')
# 
          #this method can take a LOT of different options and work in different modes
          #   * key == the name of the object you want to store.  Will be wrapped by the archive_name
          #   * cmd == OPTIONAL: the command you want to run and then package off to S3.  
          #            if you don't include a command, you better pass in a block, otherwise you are
          #            just going to see an empty directory pushed to s3
          #   * ignore_errors == OPTIONAL: do you want to throw hissy-fits if something happens?
          #                      DEFAULT: you bet!
          #   * options == OPTIONAL: allows you to overload some defaults, like the name of archive or
          #                the bucket you want to store it in
          #   * block == OPTIONAL: IF you want to run multiple commands (like mysqldump commands) run backup
          #              with a block.  It will pass back the location of the tmp directory you should dump 
          #              any files you want pushed to s3 into.
          def backup(key, cmd='mkdir', ignore_errors=false, options={}, &block)
            bucket = options[:bucket]
            archive_name = options[:archive_name]
            
            
            Utils.msg "backing up the #{key.upcase} to S3"
            arch_nm = archive_name.blank? ? archive_name(key.downcase) : archive_name
            add_cmd = " #{SCRATCH_SPACE}/#{arch_nm}"
            add_cmd += " 2>/dev/null" if ignore_errors
            # do NOT do this... it can show sensitive password information
            # Utils.msg "using command: #{cmd}"
            result = system(cmd + add_cmd)      
            raise "previous command failed.  msg: #{$?}" unless result || ignore_errors
            
            yield(add_cmd) if block_given?
            
            #lets see if the file is already compressed:
            tmp_archive = "#{SCRATCH_SPACE}/#{arch_nm}"
            results = `gzip -l #{tmp_archive} 2>/dev/null`
            
            unless results =~ /compressed/
              tmp_archive = "#{SCRATCH_SPACE}/#{arch_nm}.tgz"

              cmd = "cd #{SCRATCH_SPACE} && tar -czpf #{tmp_archive} #{arch_nm}"
              Utils.msg "archiving #{key.upcase}: #{cmd}"
              system cmd              
            end

            unless @@s3_configs['public_encryption_key'].blank? 
              Utils.msg "Encrypting backup with your public_encryption_key"
              encryptionKey = handle_encryption_key
              `gpg -e --trust-model always -r '#{encryptionKey}' #{tmp_archive}`
              tmp_archive += ".gpg"
            end

            unless @@s3_configs['private_signing_key_name'].blank?
              Utils.msg "Signing package with the servers private key name: #{@@s3_configs['private_signing_key_name']}"
              `gpg -s -r '#{@@s3_configs['private_signing_key_name']}' -o #{tmp_archive}.sig #{tmp_archive}`
              tmp_archive += ".sig"
            end

            # then use the resulting encrypted file #{arch_nm}.tgz.gpg
            size = `ls -lh #{tmp_archive}`.split[4]
            file_name = tmp_archive.split('/').last
            
            bucket_name = bucket.blank? ? backup_bucket_name : bucket
            
            Utils.msg "sending archived #{key.upcase} [size: #{size}, bucket: #{bucket_name}, key: #{file_name}] to S3"
            # put file with default 'private' ACL
            backup_bucket(bucket_name)
            S3Object.store(file_name, open(tmp_archive), bucket_name)
          ensure
            unless arch_nm.blank?
              cmd = "cd #{SCRATCH_SPACE} && rm -rf #{arch_nm}*" 
              Utils.msg "cleaning up: #{cmd}"
              system cmd
            end      
          end

          def cleanup(bucket, keep_num, convert_name=true)
            Utils.msg "cleaning up the #{bucket.name} bucket"
            entries = bucket.entries #will only retrieve the last 1000
            remove = entries.size-keep_num-1
            entries[0..remove].each do |entry|
              response = entry.delete  
              response = "Yes" if response == 'No Content'
              puts "deleting #{bucket.name}/#{entry.key}, #{entry.last_modified.to_s(:short)} UTC.  Successful? #{response}"
            end unless remove < 0
          end


          def archive_name(name)
            @timestamp ||= Time.now.utc.strftime("%Y%m%d%H%M%S")
            "#{Utils.project_name}.#{@timestamp}.#{name}"
          end

          def backup_bucket_name
            "#{Utils.project_name}_backup"
          end     

        end
      end
    end
  end
end
